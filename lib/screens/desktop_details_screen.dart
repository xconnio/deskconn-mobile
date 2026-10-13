import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:xconn/xconn.dart';
import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:deskconn_mobile_app/core/responsive.dart';
import 'package:deskconn_mobile_app/core/wallpaper/wallpaper_cache.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/machine_switcher.dart';
import 'package:deskconn_mobile_app/core/wamp/session_encryption.dart';
import 'package:deskconn_mobile_app/core/window_manager/desktop_window.dart';
import 'package:deskconn_mobile_app/screens/account_screen.dart';
import 'package:deskconn_mobile_app/screens/file_explorer_screen.dart';
import 'package:deskconn_mobile_app/screens/network_screen.dart';
import 'package:deskconn_mobile_app/screens/port_forward_screen.dart';
import 'package:deskconn_mobile_app/screens/vpn_screen.dart';
import 'package:deskconn_mobile_app/screens/resource_monitor_screen.dart';
import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/theme/page_transitions.dart';
import 'package:deskconn_mobile_app/core/device/device_identity.dart';
import 'package:deskconn_mobile_app/screens/settings_screen.dart';
import 'package:deskconn_mobile_app/widgets/app_dock.dart';
import 'package:deskconn_mobile_app/widgets/floating_window.dart';
import 'package:deskconn_mobile_app/widgets/recents_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:deskconn_mobile_app/core/terminal/terminal_screen.dart';

import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';

enum _DesktopConnectionStatus { checking, routed, p2p, offline }

const String _prefKeyLauncherOrder = 'launcher_order';

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
  final Map<String, GlobalKey> _appSnapshotKeys = {};
  final Map<String, ui.Image> _appSnapshots = {};
  List<String> _launcherOrder = [];

  String? get _realm => widget.desktop['realm']?.toString();

  @override
  void initState() {
    super.initState();
    unawaited(_probeDesktopConnection());
    unawaited(_loadCachedWallpaper());
    unawaited(_loadDockAutoHide());
    unawaited(_loadLauncherOrder());
    ConnectivityService().addListener(_handleConnectivityChanged);
  }

  Future<void> _loadDockAutoHide() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _dockAutoHide = prefs.getBool(prefKeyDockAutoHide) ?? false);
  }

  Future<void> _loadLauncherOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final order = prefs.getStringList(_prefKeyLauncherOrder);
    if (order != null && mounted) setState(() => _launcherOrder = order);
  }

  List<String> _orderedLauncherIds(Iterable<String> ids) {
    final available = ids.toSet();
    return [..._launcherOrder.where(available.contains), ...ids.where((id) => !_launcherOrder.contains(id))];
  }

  void _moveLauncherTile(List<String> ids, String id, String targetId) {
    if (id == targetId) return;
    final order = [...ids]..remove(id);
    order.insert(ids.indexOf(targetId), id);
    setState(() => _launcherOrder = order);
    unawaited(SharedPreferences.getInstance().then((prefs) => prefs.setStringList(_prefKeyLauncherOrder, order)));
  }

  @override
  void dispose() {
    ConnectivityService().removeListener(_handleConnectivityChanged);
    final realm = _realm;
    if (realm != null) DesktopConnectionManager().get(realm)?.onDisconnected = null;
    _windowManager.dispose();
    for (final image in _appSnapshots.values) {
      image.dispose();
    }
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
      final encryption = SessionEncryption.deskconnd(session);
      final checksum = await encryption.call(DeskconnProcedures.deskconndWallpaperChecksum) as String;

      final cachedChecksum = await WallpaperCache.cachedChecksum(realm);
      if (cachedChecksum == checksum && _wallpaperBytes != null) return;

      final wallpaper =
          await encryption.call(DeskconnProcedures.deskconndWallpaperGet, timeout: const Duration(seconds: 120))
              as Map<String, dynamic>;
      final data = wallpaper['data'] as String?;
      if (data == null || data.isEmpty) return;

      final bytes = base64.decode(data);
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

  // Recents may still be painting the old image during its exit transition.
  void _disposeSnapshotLater(ui.Image? image) {
    if (image != null) Future.delayed(const Duration(seconds: 1), image.dispose);
  }

  void _captureSnapshot(String id) {
    final boundary = _appSnapshotKeys[id]?.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return;
    try {
      final image = boundary.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context) * 0.5);
      _disposeSnapshotLater(_appSnapshots.remove(id));
      _appSnapshots[id] = image;
    } catch (e) {
      debugPrint('Snapshot failed for $id: $e');
    }
  }

  void _minimizeMobileApp(String id) {
    FocusManager.instance.primaryFocus?.unfocus();
    _captureSnapshot(id);
    _windowManager.minimize(id);
  }

  void _showMobileApp(String id) {
    FocusManager.instance.primaryFocus?.unfocus();
    final current = _activeMobileApp;
    if (current != null && current.id != id) _captureSnapshot(current.id);
    for (final w in _windowManager.windows) {
      if (w.id != id && !w.minimized) _windowManager.minimize(w.id);
    }
    _windowManager.restore(id);
  }

  void _discardMobileApp(String id) {
    _appNavigators.remove(id);
    _appSnapshotKeys.remove(id);
    _disposeSnapshotLater(_appSnapshots.remove(id));
    _windowManager.close(id);
  }

  void _closeMobileApp(String id) {
    final wasActive = _activeMobileApp?.id == id;
    _discardMobileApp(id);
    if (!wasActive) return;

    DesktopWindowEntry? next;
    for (final w in _windowManager.windows) {
      if (!_appNavigators.containsKey(w.id)) continue;
      if (next == null || w.zIndex > next.zIndex) next = w;
    }
    if (next != null) _showMobileApp(next.id);
  }

  Future<void> _handleMobileBack() async {
    final app = _activeMobileApp;
    if (app == null) return;
    final handled = await _appNavigators[app.id]?.currentState?.maybePop() ?? false;
    if (!handled) _minimizeMobileApp(app.id);
  }

  Map<String, Widget> _launcherTiles(BuildContext context, {required bool enabled, required bool onWallpaper}) {
    final palette = DeskconnPalette.of(context);
    void launch(VoidCallback open) => open();

    return {
      'documents': _LauncherTile(
        icon: Icons.description_outlined,
        badgeColor: palette.osUbuntu,
        title: "Documents",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openFileExplorer(context, category: 'documents')),
      ),
      'files': _LauncherTile(
        icon: Icons.folder_open,
        badgeColor: palette.osKubuntu,
        title: "Files",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openFileExplorer(context)),
      ),
      'photos': _LauncherTile(
        icon: Icons.image_outlined,
        badgeColor: palette.osXubuntu,
        title: "Photos",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openFileExplorer(context, category: 'images')),
      ),
      'terminal': _LauncherTile(
        icon: Icons.terminal,
        badgeColor: palette.osDebian,
        title: "Terminal",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openTerminal(context)),
      ),
      'videos': _LauncherTile(
        icon: Icons.video_library_outlined,
        badgeColor: palette.osWindows,
        title: "Videos",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openFileExplorer(context, category: 'videos')),
      ),
      'monitor': _LauncherTile(
        icon: Icons.speed_outlined,
        badgeColor: palette.osUbuntu,
        title: "Monitor",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openResourceMonitor(context)),
      ),
      'network': _LauncherTile(
        icon: Icons.lan_outlined,
        badgeColor: palette.osXubuntu,
        title: "Network",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openNetwork(context)),
      ),
    };
  }

  bool get _appsEnabled =>
      (_connectionStatus == _DesktopConnectionStatus.routed || _connectionStatus == _DesktopConnectionStatus.p2p) &&
      !_openingTerminal;

  void _openRecents(BuildContext context) {
    final active = _activeMobileApp;
    if (active != null) _captureSnapshot(active.id);

    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (routeContext, _, _) => BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: ListenableBuilder(
            listenable: _windowManager,
            builder: (_, _) {
              final windows = _windowManager.windows.where((w) => _appNavigators.containsKey(w.id)).toList()
                ..sort((a, b) => a.zIndex.compareTo(b.zIndex));
              return RecentsView(
                apps: [
                  for (final w in windows)
                    RecentApp(
                      id: w.id,
                      title: w.title,
                      icon: w.icon,
                      iconColor: w.iconColor,
                      snapshot: _appSnapshots[w.id],
                    ),
                ],
                onOpen: (id) {
                  Navigator.pop(routeContext);
                  _showMobileApp(id);
                },
                onClose: (id) {
                  _closeMobileApp(id);
                  if (_appNavigators.isEmpty) Navigator.pop(routeContext);
                },
                onHome: () {
                  Navigator.pop(routeContext);
                  final active = _activeMobileApp;
                  if (active != null) _minimizeMobileApp(active.id);
                },
              );
            },
          ),
        ),
        transitionsBuilder: (_, animation, _, child) => fadeScaleTransition(animation, child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final terminalEnabled = _appsEnabled;

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
            bottomNavigationBar: _DesktopNavBar(
              onWallpaper: wallpaper != null,
              onMachineTap: _openMachines,
              onWindowsTap: () => _openRecents(context),
              onSettingsTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
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
                            final tiles = _launcherTiles(
                              context,
                              enabled: terminalEnabled,
                              onWallpaper: wallpaper != null,
                            );
                            final ids = _orderedLauncherIds(tiles.keys);
                            return Align(
                              alignment: Alignment.bottomCenter,
                              child: GridView.count(
                                shrinkWrap: true,
                                padding: const EdgeInsets.fromLTRB(12, 20, 12, 4),
                                crossAxisCount: 4,
                                crossAxisSpacing: 4,
                                mainAxisSpacing: 4,
                                childAspectRatio: 0.85,
                                children: [
                                  for (final id in ids)
                                    DragTarget<String>(
                                      key: ValueKey(id),
                                      onAcceptWithDetails: (details) => _moveLauncherTile(ids, details.data, id),
                                      builder: (context, candidates, _) => LongPressDraggable<String>(
                                        data: id,
                                        feedback: Material(
                                          type: MaterialType.transparency,
                                          child: SizedBox(width: 80, height: 94, child: tiles[id]),
                                        ),
                                        childWhenDragging: Opacity(opacity: 0.3, child: tiles[id]),
                                        child: Opacity(opacity: candidates.isEmpty ? 1 : 0.6, child: tiles[id]),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      _ConnectionStatusChip(
                        status: _connectionStatus,
                        name: widget.desktop['name']?.toString() ?? '',
                        onWallpaper: wallpaper != null,
                      ),
                    ],
                  ),
                ),
                for (final entry in _windowManager.windows)
                  if (_appNavigators.containsKey(entry.id))
                    Offstage(
                      key: ValueKey(entry.id),
                      offstage: entry.id != activeApp?.id,
                      child: TickerMode(
                        enabled: entry.id == activeApp?.id,
                        // Hidden apps can't hold focus, so a late autofocus (e.g. the terminal
                        // finishing its connect) never pops the keyboard over the desktop.
                        child: ExcludeFocus(
                          excluding: entry.id != activeApp?.id,
                          child: RepaintBoundary(
                            key: _appSnapshotKeys.putIfAbsent(entry.id, GlobalKey.new),
                            child: entry.content,
                          ),
                        ),
                      ),
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
                        case DesktopAppKind.vpn:
                          _openVpn(context);
                          break;
                        case DesktopAppKind.network:
                          _openNetwork(context);
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
      await DesktopConnectionManager.checkAgentOnline(session, const Duration(seconds: 3));
      return true;
    } catch (e) {
      if (e.toString().toLowerCase().contains('wamp.error.no_such_procedure')) {
        return false;
      }
      if (e is TimeoutException) return false;
      return false;
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
      _openMobileApp(
        DesktopAppKind.vpn,
        title: 'VPN',
        icon: Icons.vpn_lock_outlined,
        iconColor: DeskconnPalette.of(context).osMint,
        builder: (_, _) => VpnScreen(config: config),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open VPN: $e")));
      }
    }
  }

  Future<void> _openNetwork(BuildContext context) async {
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
      _openMobileApp(
        DesktopAppKind.network,
        title: 'Network',
        icon: Icons.lan_outlined,
        iconColor: DeskconnPalette.of(context).osXubuntu,
        builder: (_, _) => NetworkScreen(config: config),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open Network: $e")));
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
      final (title, icon, iconColor) = switch (category) {
        'documents' => ('Documents', Icons.description_outlined, palette.osUbuntu),
        'images' => ('Photos', Icons.image_outlined, palette.osXubuntu),
        'videos' => ('Videos', Icons.video_library_outlined, palette.osWindows),
        _ => ('Files', Icons.folder_open, palette.osKubuntu),
      };

      if (isDesktopLayout(context)) {
        late final VoidCallback closeFilesWindow;
        final entry = _windowManager.open(
          DesktopAppKind.fileExplorer,
          category: category,
          title: title,
          icon: icon,
          iconColor: iconColor,
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
        icon: icon,
        iconColor: iconColor,
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

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -300) onWindowsTap();
      },
      child: Container(
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
