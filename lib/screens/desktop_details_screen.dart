import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xconn/xconn.dart';
import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:deskconn_mobile_app/core/responsive.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_encryption.dart';
import 'package:deskconn_mobile_app/core/wallpaper/wallpaper_cache.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/machine_switcher.dart';
import 'package:deskconn_mobile_app/core/window_manager/desktop_window.dart';
import 'package:deskconn_mobile_app/screens/account_screen.dart';
import 'package:deskconn_mobile_app/screens/file_explorer_screen.dart';
import 'package:deskconn_mobile_app/screens/port_forward_screen.dart';
import 'package:deskconn_mobile_app/screens/vpn_screen.dart';
import 'package:deskconn_mobile_app/screens/remote_control_screen.dart';
import 'package:deskconn_mobile_app/screens/resource_monitor_screen.dart';
import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/core/device/device_identity.dart';
import 'package:deskconn_mobile_app/screens/settings_screen.dart';
import 'package:deskconn_mobile_app/widgets/app_dock.dart';
import 'package:deskconn_mobile_app/widgets/floating_window.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:deskconn_mobile_app/core/terminal/terminal_screen.dart';

import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';

Uint8List _coerceBytes(dynamic raw) {
  if (raw is Uint8List) return raw;
  if (raw is List<int>) return Uint8List.fromList(raw);
  if (raw is String) return Uint8List.fromList(base64.decode(raw));
  throw FormatException('Unsupported payload type: ${raw.runtimeType}');
}

enum _DesktopConnectionStatus { checking, routed, p2p, offline }

class DesktopDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> desktop;

  const DesktopDetailsScreen({super.key, required this.desktop});

  @override
  State<DesktopDetailsScreen> createState() => _DesktopDetailsScreenState();
}

class _DesktopDetailsScreenState extends State<DesktopDetailsScreen> {
  bool _openingTerminal = false;
  _DesktopConnectionStatus _connectionStatus = _DesktopConnectionStatus.checking;
  Uint8List? _wallpaperBytes;
  final DesktopWindowManager _windowManager = DesktopWindowManager();
  bool _dockAutoHide = false;
  final Map<String, GlobalKey<NavigatorState>> _appNavigators = {};

  String? get _realm => widget.desktop['realm']?.toString();

  @override
  void initState() {
    super.initState();
    unawaited(_probeDesktopConnection());
    unawaited(_loadCachedWallpaper());
    unawaited(_loadDockAutoHide());
    ConnectivityService().addListener(_handleConnectivityChanged);
  }

  Future<void> _loadDockAutoHide() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _dockAutoHide = prefs.getBool(prefKeyDockAutoHide) ?? false);
  }

  @override
  void dispose() {
    ConnectivityService().removeListener(_handleConnectivityChanged);
    final realm = _realm;
    if (realm != null) DesktopConnectionManager().get(realm)?.onDisconnected = null;
    _windowManager.dispose();
    super.dispose();
  }

  Future<void> _openMachines() async {
    await switchMachine(context, currentRealm: _realm);
    if (mounted) unawaited(_probeDesktopConnection());
  }

  void _handleConnectivityChanged() {
    if (!mounted) return;
    if (!ConnectivityService().hasConnection) {
      if (_connectionStatus != _DesktopConnectionStatus.offline) {
        setState(() => _connectionStatus = _DesktopConnectionStatus.offline);
      }
      return;
    }
    if (_connectionStatus == _DesktopConnectionStatus.offline) {
      unawaited(_probeDesktopConnection());
    }
  }

  Future<void> _loadCachedWallpaper() async {
    final realm = _realm;
    if (realm == null) return;
    final cached = await WallpaperCache.load(realm);
    if (cached != null && mounted) {
      setState(() => _wallpaperBytes = cached);
    }
  }

  Future<void> _refreshWallpaper(Session session) async {
    final realm = _realm;
    if (realm == null) return;
    try {
      final checksumResult = await session
          .call(DeskconnProcedures.deskconndWallpaperChecksum)
          .timeout(DeskconnConfig.callTimeout);
      if (checksumResult.args.isEmpty) return;
      final checksum = checksumResult.args[0].toString();

      final cachedChecksum = await WallpaperCache.cachedChecksum(realm);
      if (cachedChecksum == checksum && _wallpaperBytes != null) return;

      final getResult = await session
          .call(DeskconnProcedures.deskconndWallpaperGet)
          .timeout(const Duration(seconds: 120));
      if (getResult.args.length < 2) return;

      final bytes = _coerceBytes(getResult.args[1]);
      await WallpaperCache.store(realm, bytes, checksum);
      if (mounted) setState(() => _wallpaperBytes = bytes);
    } catch (e) {
      debugPrint('Wallpaper refresh failed: $e');
    }
  }

  DesktopWindowEntry? get _activeMobileApp {
    DesktopWindowEntry? top;
    for (final w in _windowManager.windows) {
      if (w.minimized || !_appNavigators.containsKey(w.id)) continue;
      if (top == null || w.zIndex > top.zIndex) top = w;
    }
    return top;
  }

  void _openMobileApp(
    DesktopAppKind kind, {
    String? category,
    required String title,
    required IconData icon,
    required Color iconColor,
    bool handlesBack = false,
    required Widget Function(VoidCallback minimize, VoidCallback close) builder,
  }) {
    final navigatorKey = GlobalKey<NavigatorState>();
    late final String id;
    void minimize() => _minimizeMobileApp(id);
    void close() => _closeMobileApp(id);
    final app = builder(minimize, close);
    final entry = _windowManager.open(
      kind,
      category: category,
      title: title,
      icon: icon,
      iconColor: iconColor,
      content: Navigator(
        key: navigatorKey,
        onGenerateInitialRoutes: (_, _) => [
          PageRouteBuilder<void>(pageBuilder: (_, _, _) => const SizedBox.shrink()),
          MaterialPageRoute<void>(
            builder: (_) => handlesBack
                ? app
                : PopScope(
                    canPop: false,
                    onPopInvokedWithResult: (didPop, _) {
                      if (!didPop) minimize();
                    },
                    child: app,
                  ),
          ),
        ],
      ),
      workspaceSize: MediaQuery.sizeOf(context),
    );
    id = entry.id;
    _appNavigators.putIfAbsent(id, () => navigatorKey);
    _showMobileApp(id);
  }

  void _minimizeMobileApp(String id) {
    FocusManager.instance.primaryFocus?.unfocus();
    _windowManager.minimize(id);
  }

  void _showMobileApp(String id) {
    FocusManager.instance.primaryFocus?.unfocus();
    for (final w in _windowManager.windows) {
      if (w.id != id && !w.minimized) _windowManager.minimize(w.id);
    }
    _windowManager.restore(id);
  }

  void _closeMobileApp(String id) {
    _appNavigators.remove(id);
    _windowManager.close(id);
  }

  Future<void> _handleMobileBack() async {
    final app = _activeMobileApp;
    if (app == null) return;
    final handled = await _appNavigators[app.id]?.currentState?.maybePop() ?? false;
    if (!handled) _minimizeMobileApp(app.id);
  }

  void _showRunningApps(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: _windowManager,
        builder: (sheetContext, _) {
          final apps = _windowManager.windows.where((w) => _appNavigators.containsKey(w.id)).toList();
          if (apps.isEmpty) {
            return const SizedBox(height: 120, child: Center(child: Text('No running apps')));
          }
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final app in apps)
                  ListTile(
                    leading: Icon(app.icon, color: app.iconColor),
                    title: Text(app.title),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => _closeMobileApp(app.id),
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _showMobileApp(app.id);
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final terminalEnabled =
        (_connectionStatus == _DesktopConnectionStatus.routed || _connectionStatus == _DesktopConnectionStatus.p2p) &&
        !_openingTerminal;

    final wallpaper = _wallpaperBytes;

    if (isDesktopLayout(context)) {
      return _buildDesktopWorkspace(context, wallpaper: wallpaper, terminalEnabled: terminalEnabled);
    }

    return ListenableBuilder(
      listenable: _windowManager,
      builder: (context, _) {
        final activeApp = _activeMobileApp;
        return PopScope(
          canPop: activeApp == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_handleMobileBack());
          },
          child: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                wallpaper != null
                    ? Image.memory(
                        wallpaper,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(color: Theme.of(context).scaffoldBackgroundColor),
                      )
                    : Container(color: Theme.of(context).scaffoldBackgroundColor),
                if (wallpaper != null) Container(color: Colors.black.withValues(alpha: 0.25)),
                SafeArea(
                  bottom: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            final palette = DeskconnPalette.of(context);
                            return GridView.count(
                              padding: const EdgeInsets.fromLTRB(12, 20, 12, 4),
                              crossAxisCount: 4,
                              crossAxisSpacing: 4,
                              mainAxisSpacing: 4,
                              childAspectRatio: 0.85,
                              children: [
                                _LauncherTile(
                                  icon: Icons.description_outlined,
                                  badgeColor: palette.osUbuntu,
                                  title: "Documents",
                                  enabled: terminalEnabled,
                                  onWallpaper: wallpaper != null,
                                  onTap: () => _openFileExplorer(context, category: 'documents'),
                                ),
                                _LauncherTile(
                                  icon: Icons.folder_open,
                                  badgeColor: palette.osKubuntu,
                                  title: "Files",
                                  enabled: terminalEnabled,
                                  onWallpaper: wallpaper != null,
                                  onTap: () => _openFileExplorer(context),
                                ),
                                _LauncherTile(
                                  icon: Icons.image_outlined,
                                  badgeColor: palette.osXubuntu,
                                  title: "Photos",
                                  enabled: terminalEnabled,
                                  onWallpaper: wallpaper != null,
                                  onTap: () => _openFileExplorer(context, category: 'images'),
                                ),
                                _LauncherTile(
                                  icon: Icons.settings_remote_outlined,
                                  badgeColor: palette.osMint,
                                  title: "Remote Ctrl",
                                  enabled: terminalEnabled,
                                  onWallpaper: wallpaper != null,
                                  onTap: () => _openRemoteControl(context),
                                ),
                                _LauncherTile(
                                  icon: Icons.terminal,
                                  badgeColor: palette.osDebian,
                                  title: "Terminal",
                                  enabled: terminalEnabled,
                                  onWallpaper: wallpaper != null,
                                  onTap: () => _openTerminal(context),
                                ),
                                _LauncherTile(
                                  icon: Icons.video_library_outlined,
                                  badgeColor: palette.osWindows,
                                  title: "Videos",
                                  enabled: terminalEnabled,
                                  onWallpaper: wallpaper != null,
                                  onTap: () => _openFileExplorer(context, category: 'videos'),
                                ),
                                _LauncherTile(
                                  icon: Icons.speed_outlined,
                                  badgeColor: palette.osUbuntu,
                                  title: "Monitor",
                                  enabled: terminalEnabled,
                                  onWallpaper: wallpaper != null,
                                  onTap: () => _openResourceMonitor(context),
                                ),
                                _LauncherTile(
                                  icon: Icons.swap_horiz,
                                  badgeColor: palette.osXubuntu,
                                  title: "Ports",
                                  enabled: terminalEnabled,
                                  onWallpaper: wallpaper != null,
                                  onTap: () => _openPortForward(context),
                                ),
                                if (Platform.isAndroid)
                                  _LauncherTile(
                                    icon: Icons.vpn_lock_outlined,
                                    badgeColor: palette.osMint,
                                    title: "VPN",
                                    enabled: terminalEnabled,
                                    onWallpaper: wallpaper != null,
                                    onTap: () => _openVpn(context),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                      _ConnectionStatusChip(
                        status: _connectionStatus,
                        name: widget.desktop['name']?.toString() ?? '',
                        onWallpaper: wallpaper != null,
                      ),
                      _DesktopNavBar(
                        onWallpaper: wallpaper != null,
                        onMachineTap: _openMachines,
                        onWindowsTap: () => _showRunningApps(context),
                        onSettingsTap: () =>
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                      ),
                    ],
                  ),
                ),
                for (final entry in _windowManager.windows)
                  if (_appNavigators.containsKey(entry.id))
                    Offstage(
                      key: ValueKey(entry.id),
                      offstage: entry.id != activeApp?.id,
                      child: TickerMode(enabled: entry.id == activeApp?.id, child: entry.content),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDesktopWorkspace(BuildContext context, {required Uint8List? wallpaper, required bool terminalEnabled}) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          wallpaper != null
              ? Image.memory(
                  wallpaper,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(color: Theme.of(context).scaffoldBackgroundColor),
                )
              : Container(color: Theme.of(context).scaffoldBackgroundColor),
          if (wallpaper != null) Container(color: Colors.black.withValues(alpha: 0.25)),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final workspaceRect = Rect.fromLTWH(0, 0, constraints.maxWidth, constraints.maxHeight);
                      return AnimatedBuilder(
                        animation: _windowManager,
                        builder: (context, _) {
                          final open = _windowManager.openWindows;
                          final topId = open.isEmpty ? null : open.last.id;
                          return Stack(
                            children: [
                              for (final entry in open)
                                FloatingWindow(
                                  key: ValueKey(entry.id),
                                  manager: _windowManager,
                                  entry: entry,
                                  focused: entry.id == topId,
                                  workspaceRect: workspaceRect,
                                  child: entry.content,
                                ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
                _AutoHideDock(
                  enabled: _dockAutoHide,
                  child: AppDock(
                    manager: _windowManager,
                    realm: _realm ?? '',
                    machineName: widget.desktop['name']?.toString() ?? 'Desktop',
                    appsEnabled: terminalEnabled,
                    connectionStatusLabel: _connectionStatusLabel,
                    connectionStatusColor: _connectionStatusColor(context),
                    onMachineTap: _openMachines,
                    onProfileTap: () =>
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountScreen())),
                    onOpen: (kind, {category}) {
                      switch (kind) {
                        case DesktopAppKind.remoteControl:
                          _openRemoteControl(context);
                          break;
                        case DesktopAppKind.terminal:
                          _openTerminal(context);
                          break;
                        case DesktopAppKind.fileExplorer:
                          _openFileExplorer(context, category: category);
                          break;
                        case DesktopAppKind.resourceMonitor:
                          _openResourceMonitor(context);
                          break;
                        case DesktopAppKind.portForward:
                          _openPortForward(context);
                          break;
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _connectionStatusLabel => switch (_connectionStatus) {
    _DesktopConnectionStatus.checking => 'Connecting',
    _DesktopConnectionStatus.p2p => 'P2P',
    _DesktopConnectionStatus.routed => 'Routed',
    _DesktopConnectionStatus.offline => 'Offline',
  };

  Color _connectionStatusColor(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    return switch (_connectionStatus) {
      _DesktopConnectionStatus.checking => palette.subtle,
      _DesktopConnectionStatus.p2p => palette.statusOnline,
      _DesktopConnectionStatus.routed => palette.statusRouted,
      _DesktopConnectionStatus.offline => palette.statusOffline,
    };
  }

  Future<void> _probeDesktopConnection() async {
    final realm = _realm;

    final cached = realm == null ? null : DesktopConnectionManager().get(realm);
    if (cached != null && cached.isAgentOnline) {
      cached.onDisconnected = _handleConnectionDisconnected;
      if (mounted) {
        setState(
          () => _connectionStatus = cached.isP2P ? _DesktopConnectionStatus.p2p : _DesktopConnectionStatus.routed,
        );
      }
      unawaited(_refreshWallpaper(cached.session));
      return;
    }

    if (!ConnectivityService().hasConnection) {
      if (mounted) {
        setState(() => _connectionStatus = _DesktopConnectionStatus.offline);
      }
      return;
    }

    if (mounted) {
      setState(() => _connectionStatus = _DesktopConnectionStatus.checking);
    }

    final authId = await DeviceIdentity.lastEmail();
    final privateKey = await DeviceIdentity.privateKey();
    final prefs = await SharedPreferences.getInstance();
    final webRtcEnabled = prefs.getBool(prefKeyWebRtcEnabled) ?? defaultWebRtcEnabled;

    if (authId == null || privateKey == null || realm == null) {
      if (mounted) {
        setState(() => _connectionStatus = _DesktopConnectionStatus.offline);
      }
      return;
    }

    final status = await _attemptConnection(realm, authId, privateKey, webRtcEnabled);
    if (mounted) {
      setState(() => _connectionStatus = status ?? _DesktopConnectionStatus.offline);
    }
    if (status != null) {
      final session = DesktopConnectionManager().get(realm)?.session;
      if (session != null) unawaited(_refreshWallpaper(session));
    }

    if (status == null) {
      unawaited(_retryInBackground(realm, authId, privateKey, webRtcEnabled));
    }
  }

  Future<void> _retryInBackground(String realm, String authId, String privateKey, bool webRtcEnabled) async {
    final status = await _attemptConnection(realm, authId, privateKey, webRtcEnabled);
    if (status != null && mounted) {
      setState(() => _connectionStatus = status);
      final session = DesktopConnectionManager().get(realm)?.session;
      if (session != null) unawaited(_refreshWallpaper(session));
    }
  }

  Future<_DesktopConnectionStatus?> _attemptConnection(
    String realm,
    String authId,
    String privateKey,
    bool webRtcEnabled,
  ) async {
    try {
      final connection = await DesktopConnectionManager().acquire(
        realm: realm,
        authId: authId,
        privateKey: privateKey,
        webRtcEnabled: webRtcEnabled,
      );
      connection.onDisconnected = _handleConnectionDisconnected;

      if (connection.isAgentOnline) {
        return connection.isP2P ? _DesktopConnectionStatus.p2p : _DesktopConnectionStatus.routed;
      }

      final desktopOnline = await _isDesktopAgentOnline(connection.session);
      if (desktopOnline) {
        connection.isAgentOnline = true;
        return connection.isP2P ? _DesktopConnectionStatus.p2p : _DesktopConnectionStatus.routed;
      }

      connection.onDisconnected = null;
      await DesktopConnectionManager().release(realm);
      return null;
    } catch (e) {
      _appendTerminalLog("Desktop connection failed: ${e.toString().split('\n').first}");
      return null;
    }
  }

  void _handleConnectionDisconnected() {
    if (!mounted) return;
    setState(() => _connectionStatus = _DesktopConnectionStatus.checking);
    unawaited(_probeDesktopConnection());
  }

  Future<bool> _isDesktopAgentOnline(Session session) async {
    try {
      final enc = await Encryption.create();
      await session
          .call(DeskconnProcedures.deskconndKeyExchange, args: [enc.clientPublicKey])
          .timeout(const Duration(seconds: 3));
      return true;
    } catch (e) {
      if (e.toString().toLowerCase().contains('wamp.error.no_such_procedure')) {
        return false;
      }
      if (e is TimeoutException) return false;
      return false;
    }
  }

  Future<void> _openRemoteControl(BuildContext context) async {
    final realm = _realm;
    if (realm == null ||
        (_connectionStatus != _DesktopConnectionStatus.routed && _connectionStatus != _DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.lastEmail();
      final privateKey = await DeviceIdentity.privateKey();
      if (authId == null || privateKey == null) {
        throw Exception("Missing credentials.");
      }

      if (!context.mounted) return;

      final config = _terminalConfig(realm: realm, authId: authId, privateKey: privateKey, status: _connectionStatus);

      if (isDesktopLayout(context)) {
        final palette = DeskconnPalette.of(context);
        _windowManager.open(
          DesktopAppKind.remoteControl,
          title: 'Remote Ctrl',
          icon: Icons.settings_remote_outlined,
          iconColor: palette.osMint,
          content: RemoteControlView(config: config, embedded: true),
          workspaceSize: MediaQuery.sizeOf(context),
        );
        return;
      }

      _openMobileApp(
        DesktopAppKind.remoteControl,
        title: 'Remote Ctrl',
        icon: Icons.settings_remote_outlined,
        iconColor: DeskconnPalette.of(context).osMint,
        builder: (_, _) => RemoteControlScreen(config: config),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open Remote Control: $e")));
      }
    }
  }

  Future<void> _openResourceMonitor(BuildContext context) async {
    final realm = _realm;
    if (realm == null ||
        (_connectionStatus != _DesktopConnectionStatus.routed && _connectionStatus != _DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.lastEmail();
      final privateKey = await DeviceIdentity.privateKey();
      if (authId == null || privateKey == null) {
        throw Exception("Missing credentials.");
      }

      if (!context.mounted) return;

      final config = _terminalConfig(realm: realm, authId: authId, privateKey: privateKey, status: _connectionStatus);

      if (isDesktopLayout(context)) {
        final palette = DeskconnPalette.of(context);
        _windowManager.open(
          DesktopAppKind.resourceMonitor,
          title: 'Monitor',
          icon: Icons.speed_outlined,
          iconColor: palette.osUbuntu,
          content: ResourceMonitorView(config: config, embedded: true),
          workspaceSize: MediaQuery.sizeOf(context),
          width: 700,
          height: 560,
        );
        return;
      }

      _openMobileApp(
        DesktopAppKind.resourceMonitor,
        title: 'Monitor',
        icon: Icons.speed_outlined,
        iconColor: DeskconnPalette.of(context).osUbuntu,
        builder: (_, _) => ResourceMonitorScreen(config: config),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open Resource Monitor: $e")));
      }
    }
  }

  Future<void> _openPortForward(BuildContext context) async {
    final realm = _realm;
    if (realm == null ||
        (_connectionStatus != _DesktopConnectionStatus.routed && _connectionStatus != _DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.lastEmail();
      final privateKey = await DeviceIdentity.privateKey();
      if (authId == null || privateKey == null) {
        throw Exception("Missing credentials.");
      }

      if (!context.mounted) return;

      final config = _terminalConfig(realm: realm, authId: authId, privateKey: privateKey, status: _connectionStatus);

      if (isDesktopLayout(context)) {
        final palette = DeskconnPalette.of(context);
        _windowManager.open(
          DesktopAppKind.portForward,
          title: 'Ports',
          icon: Icons.swap_horiz,
          iconColor: palette.osXubuntu,
          content: PortForwardView(config: config, embedded: true),
          workspaceSize: MediaQuery.sizeOf(context),
          width: 560,
          height: 460,
        );
        return;
      }

      _openMobileApp(
        DesktopAppKind.portForward,
        title: 'Ports',
        icon: Icons.swap_horiz,
        iconColor: DeskconnPalette.of(context).osXubuntu,
        builder: (_, _) => PortForwardScreen(config: config),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open Port Forwarding: $e")));
      }
    }
  }

  Future<void> _openVpn(BuildContext context) async {
    final realm = _realm;
    if (realm == null ||
        (_connectionStatus != _DesktopConnectionStatus.routed && _connectionStatus != _DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.lastEmail();
      final privateKey = await DeviceIdentity.privateKey();
      if (authId == null || privateKey == null) {
        throw Exception("Missing credentials.");
      }
      if (!context.mounted) return;

      final config = _terminalConfig(realm: realm, authId: authId, privateKey: privateKey, status: _connectionStatus);
      await Navigator.push(context, MaterialPageRoute(builder: (_) => VpnScreen(config: config)));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open VPN: $e")));
      }
    }
  }

  Future<void> _openFileExplorer(BuildContext context, {String? category}) async {
    final realm = _realm;
    if (realm == null ||
        (_connectionStatus != _DesktopConnectionStatus.routed && _connectionStatus != _DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.lastEmail();
      final privateKey = await DeviceIdentity.privateKey();
      if (authId == null || privateKey == null) {
        throw Exception("Missing credentials.");
      }

      if (!context.mounted) return;

      final config = _terminalConfig(realm: realm, authId: authId, privateKey: privateKey, status: _connectionStatus);

      final palette = DeskconnPalette.of(context);
      final title = switch (category) {
        'documents' => 'Documents',
        'images' => 'Photos',
        'videos' => 'Videos',
        _ => 'Files',
      };

      if (isDesktopLayout(context)) {
        late final VoidCallback closeFilesWindow;
        final entry = _windowManager.open(
          DesktopAppKind.fileExplorer,
          category: category,
          title: title,
          icon: Icons.folder_open,
          iconColor: palette.osKubuntu,
          content: FileExplorerScreen(
            config: config,
            category: category,
            embedded: true,
            onRequestClose: () => closeFilesWindow(),
          ),
          workspaceSize: MediaQuery.sizeOf(context),
          width: 900,
          height: 600,
        );
        closeFilesWindow = () => _windowManager.close(entry.id);
        return;
      }

      _openMobileApp(
        DesktopAppKind.fileExplorer,
        category: category,
        title: title,
        icon: Icons.folder_open,
        iconColor: palette.osKubuntu,
        handlesBack: true,
        builder: (minimize, _) =>
            FileExplorerScreen(config: config, category: category, embedded: true, onRequestClose: minimize),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open Files: $e")));
      }
    }
  }

  Future<void> _openTerminal(BuildContext context) async {
    final realm = _realm;
    if (_openingTerminal ||
        realm == null ||
        (_connectionStatus != _DesktopConnectionStatus.routed && _connectionStatus != _DesktopConnectionStatus.p2p)) {
      return;
    }

    setState(() => _openingTerminal = true);
    _appendTerminalLog("Starting terminal connection");

    try {
      final desktopName = widget.desktop['name']?.toString() ?? 'Desktop';
      final webRtcEnabled = _connectionStatus == _DesktopConnectionStatus.p2p;

      if (!context.mounted) return;

      setState(() => _openingTerminal = false);

      if (isDesktopLayout(context)) {
        _appendTerminalLog("Opening terminal window");
        late final VoidCallback closeTerminalWindow;
        final entry = _windowManager.open(
          DesktopAppKind.terminal,
          title: 'Terminal',
          icon: Icons.terminal,
          iconColor: DeskconnPalette.of(context).osDebian,
          content: TerminalTabsView(
            realm: realm,
            desktopName: desktopName,
            webRtcEnabled: webRtcEnabled,
            embedded: true,
            onRequestClose: () => closeTerminalWindow(),
          ),
          workspaceSize: MediaQuery.sizeOf(context),
          width: 800,
          height: 520,
        );
        closeTerminalWindow = () => _windowManager.close(entry.id);
        return;
      }

      _appendTerminalLog("Opening terminal app");

      _openMobileApp(
        DesktopAppKind.terminal,
        title: 'Terminal',
        icon: Icons.terminal,
        iconColor: DeskconnPalette.of(context).osDebian,
        builder: (_, close) => Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            bottom: false,
            child: TerminalTabsView(
              realm: realm,
              desktopName: desktopName,
              webRtcEnabled: webRtcEnabled,
              embedded: true,
              onRequestClose: close,
            ),
          ),
        ),
      );
    } catch (e) {
      final message = _friendlyTerminalError(e);
      _appendTerminalLog("Terminal open failed: $message");
      if (context.mounted) {
        await _showTerminalErrorDialog(context, message);
      }
    } finally {
      if (mounted) {
        setState(() => _openingTerminal = false);
      }
    }
  }

  DesktopSessionLaunchConfig _terminalConfig({
    required String realm,
    required String authId,
    required String privateKey,
    required _DesktopConnectionStatus status,
  }) {
    return DesktopSessionLaunchConfig(
      sessionKey: 'terminal:$realm',
      desktopName: widget.desktop['name']?.toString() ?? 'Desktop',
      realm: realm,
      authId: authId,
      privateKey: privateKey,
      webRtcEnabled: status == _DesktopConnectionStatus.p2p,
    );
  }

  void _appendTerminalLog(String message) {
    final line = "[${DateTime.now().toIso8601String()}] $message";
    debugPrint("DesktopDetailsScreen: $line");
  }

  Future<void> _showTerminalErrorDialog(BuildContext context, String message) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Terminal Unavailable"),
          content: Text(message),
          actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text("Close"))],
        );
      },
    );
  }

  bool _isMissingProcedureError(String errorText) {
    final normalized = errorText.toLowerCase();
    return normalized.contains("wamp.error.no_such_procedure");
  }

  String _friendlyTerminalError(Object error) {
    final errorText = error.toString();
    if (_isMissingProcedureError(errorText)) {
      return "Remote device offline. Check internet and try again.";
    }
    if (errorText.toLowerCase().contains("timeout")) {
      return "Terminal connection timed out. Try again.";
    }
    return "Remote device offline or Check internet and try again.";
  }
}

class _LauncherTile extends StatelessWidget {
  final IconData icon;
  final Color badgeColor;
  final String title;
  final VoidCallback onTap;
  final bool enabled;
  final bool onWallpaper;

  const _LauncherTile({
    required this.icon,
    required this.badgeColor,
    required this.title,
    required this.onTap,
    this.enabled = true,
    this.onWallpaper = false,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = onWallpaper
        ? (enabled ? Colors.white : Colors.white54)
        : (enabled ? Theme.of(context).colorScheme.onSurface : Theme.of(context).disabledColor);
    final textShadows = onWallpaper ? [Shadow(color: Colors.black.withValues(alpha: 0.7), blurRadius: 6)] : null;
    final effectiveBadgeColor = enabled ? badgeColor : badgeColor.withValues(alpha: 0.4);

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: effectiveBadgeColor,
              borderRadius: BorderRadius.circular(14),
              boxShadow: onWallpaper
                  ? [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6, offset: const Offset(0, 2))]
                  : null,
            ),
            child: Icon(icon, size: 26, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(color: textColor, fontWeight: FontWeight.w500, fontSize: 13, shadows: textShadows),
          ),
        ],
      ),
    );
  }
}

class _ConnectionStatusChip extends StatelessWidget {
  final _DesktopConnectionStatus status;
  final String name;
  final bool onWallpaper;

  const _ConnectionStatusChip({required this.status, required this.name, required this.onWallpaper});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = DeskconnPalette.of(context);
    final (dotColor, label) = switch (status) {
      _DesktopConnectionStatus.checking => (palette.subtle, 'Connecting'),
      _DesktopConnectionStatus.p2p => (palette.statusOnline, 'P2P'),
      _DesktopConnectionStatus.routed => (palette.statusRouted, 'Routed'),
      _DesktopConnectionStatus.offline => (palette.statusOffline, 'Offline'),
    };
    final textColor = onWallpaper ? Colors.white : colorScheme.onSurface;
    final statusStyle = TextStyle(
      color: name.isEmpty ? textColor : textColor.withValues(alpha: 0.75),
      fontSize: 12,
      fontWeight: name.isEmpty ? FontWeight.w600 : FontWeight.w400,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: onWallpaper ? Colors.black.withValues(alpha: 0.45) : colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: onWallpaper ? Colors.white.withValues(alpha: 0.16) : colorScheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text.rich(
                TextSpan(
                  children: [
                    if (name.isNotEmpty)
                      TextSpan(
                        text: name,
                        style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    TextSpan(text: name.isEmpty ? label : ' ($label)', style: statusStyle),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopNavBar extends StatelessWidget {
  final bool onWallpaper;
  final VoidCallback onMachineTap;
  final VoidCallback onWindowsTap;
  final VoidCallback onSettingsTap;

  const _DesktopNavBar({
    required this.onMachineTap,
    required this.onWindowsTap,
    required this.onSettingsTap,
    this.onWallpaper = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = onWallpaper ? Colors.black.withValues(alpha: 0.86) : colorScheme.surface;
    final dividerColor = onWallpaper ? Colors.white.withValues(alpha: 0.14) : colorScheme.outlineVariant;
    final selectedColor = onWallpaper ? Colors.white : colorScheme.primary;
    final unselectedColor = onWallpaper
        ? Colors.white.withValues(alpha: 0.6)
        : colorScheme.onSurface.withValues(alpha: 0.55);

    return Container(
      decoration: BoxDecoration(
        color: background,
        border: Border(top: BorderSide(color: dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              _DesktopNavBarItem(
                icon: Icons.desktop_windows_outlined,
                label: 'Machine',
                color: unselectedColor,
                onTap: onMachineTap,
              ),
              _DesktopNavBarItem(
                icon: Icons.grid_view_rounded,
                label: 'Apps',
                color: selectedColor,
                onTap: onWindowsTap,
                selected: true,
              ),
              _DesktopNavBarItem(
                icon: Icons.settings_outlined,
                label: 'Settings',
                color: unselectedColor,
                onTap: onSettingsTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopNavBarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool selected;

  const _DesktopNavBarItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AutoHideDock extends StatefulWidget {
  final bool enabled;
  final Widget child;

  const _AutoHideDock({required this.enabled, required this.child});

  @override
  State<_AutoHideDock> createState() => _AutoHideDockState();
}

class _AutoHideDockState extends State<_AutoHideDock> {
  bool _visible = true;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return MouseRegion(
      onEnter: (_) => setState(() => _visible = true),
      onExit: (_) => setState(() => _visible = false),
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        offset: _visible ? Offset.zero : const Offset(0, 1),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _visible ? 1 : 0,
          child: widget.child,
        ),
      ),
    );
  }
}
