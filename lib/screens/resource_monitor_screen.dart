import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:deskconn_mobile_app/core/resource_monitor/models.dart';
import 'package:deskconn_mobile_app/core/resource_monitor/resource_monitor_controller.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/widgets/ring_gauge.dart';
import 'package:deskconn_mobile_app/widgets/sparkline_chart.dart';

const _pollInterval = Duration(seconds: 2);
const _historyLength = 30;

const _cpuColor = Color(0xFF3B82F6);
const _memColor = Color(0xFF2563EB);
const _diskColor = Color(0xFF7C3AED);
const _netColor = Color(0xFF0891B2);

String _formatBytes(double bytes) {
  const unit = 1000;
  if (bytes < unit) return '${bytes.toStringAsFixed(0)} B';
  if (bytes < unit * unit) return '${(bytes / unit).toStringAsFixed(1)} KB';
  if (bytes < unit * unit * unit) return '${(bytes / unit / unit).toStringAsFixed(1)} MB';
  return '${(bytes / unit / unit / unit).toStringAsFixed(2)} GB';
}

String _formatBytesPs(double bytesPerSec) => '${_formatBytes(bytesPerSec)}/s';

Color _cpuColorFor(double pct) {
  if (pct < 50) return const Color(0xFF22C55E);
  if (pct < 80) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

bool _isMissingProcedureError(Object error) => error.toString().toLowerCase().contains('wamp.error.no_such_procedure');

String _friendlyError(Object error) {
  if (_isMissingProcedureError(error)) return 'Desktop offline or does not support resource monitoring.';
  if (error is TimeoutException) return 'Request timed out. Try again.';
  return error.toString();
}

class ResourceMonitorScreen extends StatelessWidget {
  final DesktopSessionLaunchConfig config;

  const ResourceMonitorScreen({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(config.desktopName)),
      body: ResourceMonitorView(config: config),
    );
  }
}

class ResourceMonitorView extends StatefulWidget {
  final DesktopSessionLaunchConfig config;
  final bool embedded;

  const ResourceMonitorView({super.key, required this.config, this.embedded = false});

  @override
  State<ResourceMonitorView> createState() => _ResourceMonitorViewState();
}

class _ResourceMonitorViewState extends State<ResourceMonitorView> with SingleTickerProviderStateMixin {
  static const _tabs = [
    (icon: Icons.apps_rounded, label: 'Apps'),
    (icon: Icons.list_alt_rounded, label: 'Processes'),
    (icon: Icons.developer_board, label: 'Processor'),
    (icon: Icons.memory, label: 'Memory'),
    (icon: Icons.storage_rounded, label: 'Disk'),
    (icon: Icons.swap_vert_rounded, label: 'Network'),
  ];

  late final TabController _tabController;
  ResourceMonitorController? _controller;
  Timer? _timer;

  bool _loading = true;
  String? _error;
  String? _actionError;

  DeviceInfo? _info;
  List<ProcessInfo> _processes = [];
  List<AppInfo> _apps = [];
  String _processSearch = '';
  bool _showLogicalCpus = false;

  final List<double> _netHistory = [];

  final Map<String, Uint8List> _iconCache = {};
  final Set<String> _iconFailed = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    unawaited(_initialize());
    ConnectivityService().addListener(_handleConnectivityChanged);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    ConnectivityService().removeListener(_handleConnectivityChanged);
    super.dispose();
  }

  void _handleConnectivityChanged() {
    if (!mounted) return;
    if (!ConnectivityService().hasConnection) {
      setState(() => _actionError = 'No internet connection');
      return;
    }
    if (_controller == null) {
      unawaited(_initialize());
    } else {
      unawaited(_pollTick());
    }
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == 1) {
      unawaited(_fetchProcesses());
    } else if (_tabController.index == 0) {
      unawaited(_fetchApps());
    }
  }

  Future<void> _initialize() async {
    if (!ConnectivityService().hasConnection) {
      if (mounted) {
        setState(() {
          _error = 'No internet connection';
          _loading = false;
        });
      }
      return;
    }
    try {
      final existing = DesktopConnectionManager().get(widget.config.realm);
      final connection =
          existing ??
          await DesktopConnectionManager().acquire(
            realm: widget.config.realm,
            authId: widget.config.authId,
            privateKey: widget.config.privateKey,
            webRtcEnabled: widget.config.webRtcEnabled,
          );
      _controller = ResourceMonitorController(connection.session);
      _startPolling();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  bool _reconnecting = false;

  Future<void> _reconnect() async {
    if (_reconnecting) return;
    if (!ConnectivityService().hasConnection) {
      if (mounted) setState(() => _actionError = 'No internet connection');
      return;
    }
    _reconnecting = true;
    if (mounted) setState(() => _actionError = 'Reconnecting…');
    try {
      final connection = await DesktopConnectionManager().reacquire(
        realm: widget.config.realm,
        authId: widget.config.authId,
        privateKey: widget.config.privateKey,
        webRtcEnabled: widget.config.webRtcEnabled,
      );
      connection.isAgentOnline = true;
      if (!mounted) {
        _reconnecting = false;
        return;
      }
      _controller = ResourceMonitorController(connection.session);
      setState(() {
        _actionError = null;
        _reconnecting = false;
      });
    } catch (e) {
      _reconnecting = false;
      if (mounted) setState(() => _actionError = _friendlyError(e));
    }
  }

  void _startPolling() {
    _timer?.cancel();
    unawaited(_pollTick());
    _timer = Timer.periodic(_pollInterval, (_) => _pollTick());
  }

  Future<void> _pollTick() async {
    if (!ConnectivityService().hasConnection) {
      if (mounted) setState(() => _actionError = 'No internet connection');
      return;
    }
    await _fetchInfo();
    if (_tabController.index == 1) {
      await _fetchProcesses();
    } else if (_tabController.index == 0) {
      await _fetchApps();
    }
  }

  void _pushHistory(List<double> history, double value) {
    history.add(value);
    if (history.length > _historyLength) history.removeAt(0);
  }

  Future<void> _fetchInfo() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final info = await controller.fetchInfo();
      if (!mounted) return;
      setState(() {
        _info = info;
        _error = null;
        _actionError = null;
        _loading = false;
        _pushHistory(_netHistory, info.networkTotalBps);
      });
    } catch (e) {
      if (!mounted) return;
      final sessionAlive = !DesktopConnectionManager().isDeadSessionError(controller.session, e);
      final message = _friendlyError(e);
      setState(() {
        _loading = false;
        if (_info == null) {
          _error = message;
        } else {
          _actionError = message;
        }
      });
      if (!sessionAlive && !_reconnecting) {
        unawaited(_reconnect());
      }
    }
  }

  Future<void> _fetchProcesses() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final processes = await controller.fetchProcesses();
      if (!mounted) return;
      setState(() {
        _processes = processes;
        _actionError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionError = _friendlyError(e));
    }
  }

  Future<void> _fetchApps() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final apps = await controller.fetchApps();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _actionError = null;
      });
      for (final app in apps) {
        if (app.iconName.isNotEmpty) unawaited(_ensureIcon(app.iconName));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionError = _friendlyError(e));
    }
  }

  Future<void> _ensureIcon(String iconName) async {
    if (_iconCache.containsKey(iconName) || _iconFailed.contains(iconName)) return;
    final controller = _controller;
    if (controller == null) return;
    try {
      final icon = await controller.fetchIcon(iconName);
      final bytes = base64Decode(icon.data);
      if (!mounted) return;
      setState(() => _iconCache[iconName] = bytes);
    } catch (_) {
      _iconFailed.add(iconName);
    }
  }

  Future<void> _signalPids(List<int> pids, String signal) async {
    final controller = _controller;
    if (controller == null || pids.isEmpty) return;
    try {
      await controller.signalPids(pids, signal);
      if (mounted) setState(() => _actionError = null);
    } catch (e) {
      if (mounted) setState(() => _actionError = _friendlyError(e));
    } finally {
      if (_tabController.index == 1) {
        await _fetchProcesses();
      } else if (_tabController.index == 0) {
        await _fetchApps();
      }
    }
  }

  void _showActionSheet({required String label, required List<int> pids}) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                label,
                style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('End'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_signalPids(pids, 'term'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.dangerous_outlined, color: Colors.red),
              title: const Text('Kill', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_signalPids(pids, 'kill'));
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildStatRow(context),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _info == null
              ? _ErrorView(message: _error!)
              : Column(
                  children: [
                    if (_actionError != null)
                      Container(
                        width: double.infinity,
                        color: _reconnecting
                            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
                            : Colors.red.withValues(alpha: 0.08),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            if (_reconnecting)
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              )
                            else
                              const Icon(Icons.error_outline, color: Colors.red, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _actionError!,
                                style: TextStyle(
                                  color: _reconnecting ? Theme.of(context).colorScheme.primary : Colors.red,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            if (!_reconnecting)
                              IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => setState(() => _actionError = null),
                              ),
                          ],
                        ),
                      ),
                    TabBar(
                      controller: _tabController,
                      isScrollable: false,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                      labelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                      unselectedLabelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
                      tabs: [for (final t in _tabs) Tab(height: 48, icon: Icon(t.icon, size: 16), text: t.label)],
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildAppsTab(),
                          _buildProcessesTab(),
                          _buildProcessorTab(),
                          _buildMemoryTab(),
                          _buildDiskTab(),
                          _buildNetworkTab(),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildStatRow(BuildContext context) {
    final info = _info;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          RingGauge(
            percent: info?.cpuOverall ?? 0,
            value: info == null ? '--' : '${info.cpuOverall.toStringAsFixed(0)}%',
            label: 'CPU',
            color: _cpuColor,
            size: 84,
            strokeWidth: 7,
          ),
          RingGauge(
            percent: info?.ramUsedPercent ?? 0,
            value: info == null ? '--' : '${info.ramUsedPercent.toStringAsFixed(0)}%',
            label: 'RAM',
            color: _memColor,
            size: 84,
            strokeWidth: 7,
          ),
          RingGauge(
            percent: info?.diskUsedPercent ?? 0,
            value: info == null ? '--' : '${info.diskUsedPercent.toStringAsFixed(0)}%',
            label: 'Storage',
            color: _diskColor,
            size: 84,
            strokeWidth: 7,
          ),
        ],
      ),
    );
  }

  Widget _buildAppsTab() {
    if (_apps.isEmpty) return const _EmptyView(message: 'No apps found.');
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _apps.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final app = _apps[index];
        final iconBytes = _iconCache[app.iconName];
        return ListTile(
          onLongPress: () => _showActionSheet(label: app.name, pids: app.pids),
          leading: CircleAvatar(
            backgroundColor: DeskconnPalette.of(context).surfaceTint,
            backgroundImage: iconBytes != null ? MemoryImage(iconBytes) : null,
            onBackgroundImageError: iconBytes != null ? (_, _) {} : null,
            child: iconBytes == null ? const Icon(Icons.apps, size: 18) : null,
          ),
          title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_formatBytes(app.memRss), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              Text('${app.cpuPercent.toStringAsFixed(1)}%', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProcessesTab() {
    final query = _processSearch.trim().toLowerCase();
    final filtered =
        (query.isEmpty ? _processes : _processes.where((p) => p.name.toLowerCase().contains(query)).toList())
          ..sort((a, b) => b.memRss.compareTo(a.memRss));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search processes…',
              prefixIcon: Icon(Icons.search, size: 20),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _processSearch = v),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const _EmptyView(message: 'No processes found.')
              : ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final process = filtered[index];
                    return ListTile(
                      onLongPress: () => _showActionSheet(label: process.name, pids: [process.pid]),
                      leading: const Icon(Icons.settings_outlined, size: 20),
                      title: Text(process.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('PID ${process.pid} · ${process.user}', style: const TextStyle(fontSize: 11)),
                      trailing: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _formatBytes(process.memRss),
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${process.cpuPercent.toStringAsFixed(1)}%',
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildProcessorTab() {
    final info = _info;
    if (info == null) return const _EmptyView(message: 'No data.');
    final overall = info.cpuOverall;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Processor', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(
              '${overall.toStringAsFixed(1)}%',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _cpuColorFor(overall)),
            ),
          ],
        ),
        if (info.cpuModel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              info.cpuModel,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const SizedBox(height: 12),
        _SettingRow(
          label: 'Show usage of logical CPUs',
          value: _showLogicalCpus,
          onChanged: (v) => setState(() => _showLogicalCpus = v),
        ),
        const SizedBox(height: 12),
        if (_showLogicalCpus) ...[
          Text('${info.cpuPhysical}P / ${info.cpuLogical}L', style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 8),
          ...List.generate(info.cpuUsages.length, (i) {
            final usage = info.cpuUsages[i];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text('CPU $i', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: (usage / 100).clamp(0, 1).toDouble(),
                        minHeight: 12,
                        backgroundColor: Colors.grey.withValues(alpha: 0.2),
                        valueColor: AlwaysStoppedAnimation(_cpuColorFor(usage)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${usage.toStringAsFixed(0)}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _cpuColorFor(usage)),
                    ),
                  ),
                ],
              ),
            );
          }),
        ] else
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: RingGauge(
                percent: overall,
                value: '${overall.toStringAsFixed(0)}%',
                label: 'CPU Used',
                color: _cpuColor,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMemoryTab() {
    final info = _info;
    if (info == null) return const _EmptyView(message: 'No data.');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Memory', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(
              '${_formatBytes(info.ramTotal - info.ramAvailable)} / ${_formatBytes(info.ramTotal)}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _memColor),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: RingGauge(
              percent: info.ramUsedPercent,
              value: _formatBytes(info.ramTotal - info.ramAvailable),
              label: 'Memory Used',
              color: _memColor,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Available: ${_formatBytes(info.ramAvailable)}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            Text(
              'Buff/Cache: ${_formatBytes(info.ramBuffCache)}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        if (info.swapTotal > 0) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              const Text(
                'Swap',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: (info.swapUsedPercent / 100).clamp(0, 1).toDouble(),
                    minHeight: 5,
                    backgroundColor: Colors.grey.withValues(alpha: 0.2),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF8B5CF6)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_formatBytes(info.swapUsed)} / ${_formatBytes(info.swapTotal)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildDiskTab() {
    final info = _info;
    if (info == null) return const _EmptyView(message: 'No data.');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Disk (/)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(
              '${_formatBytes(info.diskUsed)} / ${_formatBytes(info.diskTotal)}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _diskColor),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: RingGauge(
              percent: info.diskUsedPercent,
              value: _formatBytes(info.diskUsed),
              label: 'Space Used',
              color: _diskColor,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Free: ${_formatBytes(info.diskFree)}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(
              'Used: ${info.diskUsedPercent.toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNetworkTab() {
    final info = _info;
    if (info == null) return const _EmptyView(message: 'No data.');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Network', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 12),
        _GraphCard(color: _netColor, history: _netHistory, maxValue: null, label: null),
        const SizedBox(height: 12),
        if (info.networkInterfaces.isEmpty)
          const _EmptyView(message: 'No network interfaces.')
        else
          ...info.networkInterfaces.map(
            (iface) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 90,
                    child: Text(
                      iface.name,
                      style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600, fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        const Icon(Icons.arrow_upward, size: 14, color: _netColor),
                        Text(
                          _formatBytesPs(iface.bytesSentPs),
                          style: const TextStyle(fontSize: 11, color: _netColor, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        const Icon(Icons.arrow_downward, size: 14, color: Color(0xFF059669)),
                        Text(
                          _formatBytesPs(iface.bytesRecvPs),
                          style: const TextStyle(fontSize: 11, color: Color(0xFF059669), fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _GraphCard extends StatelessWidget {
  final Color color;
  final List<double> history;
  final double? maxValue;
  final String? label;

  const _GraphCard({required this.color, required this.history, required this.maxValue, required this.label});

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.surfaceTint,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 80,
            width: double.infinity,
            child: SparklineChart(values: history, maxValue: maxValue, color: color),
          ),
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(label!, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingRow({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: palette.surfaceTint, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final String message;

  const _EmptyView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(message, style: const TextStyle(color: Colors.grey)),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;

  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 32),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
