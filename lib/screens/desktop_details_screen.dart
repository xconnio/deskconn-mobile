import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:deskconn_mobile_app/core/responsive.dart';
import 'package:deskconn_mobile_app/core/wallpaper/wallpaper_cache.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/last_used_realm_store.dart';
import 'package:deskconn_mobile_app/core/wamp/machine_switcher.dart';
import 'package:deskconn_mobile_app/core/wamp/session_encryption.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/core/window_manager/desktop_window.dart';
import 'package:deskconn_mobile_app/screens/account_screen.dart';
import 'package:deskconn_mobile_app/screens/file_explorer_screen.dart';
import 'package:deskconn_mobile_app/screens/manifest_app_screen.dart';
import 'package:deskconn_mobile_app/screens/network_screen.dart';
import 'package:deskconn_mobile_app/screens/port_forward_screen.dart';
import 'package:deskconn_mobile_app/screens/text_editor_screen.dart';
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
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:deskconn_mobile_app/core/terminal/terminal_screen.dart';

import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';

enum DesktopConnectionStatus { checking, routed, p2p, offline }

const String _prefKeyLauncherOrder = 'launcher_order';

class DesktopPageHandle {
  VoidCallback? openRecents;
  VoidCallback? openMachines;
  final ValueNotifier<bool> appOpen = ValueNotifier(false);
  final ValueNotifier<DesktopConnectionStatus> status = ValueNotifier(DesktopConnectionStatus.checking);

  void dispose() {
    appOpen.dispose();
    status.dispose();
  }
}

class MachinePager extends StatefulWidget {
  final Map<String, dynamic> desktop;
  @visibleForTesting
  final Widget Function(Map<String, dynamic> desktop, DesktopPageHandle handle)? pageBuilder;

  const MachinePager({super.key, required this.desktop, this.pageBuilder});

  @override
  State<MachinePager> createState() => _MachinePagerState();
}

class _MachinePagerState extends State<MachinePager> {
  static const _indicatorLinger = Duration(milliseconds: 700);
  static const indicatorGap = 14.0;

  late final List<Map<String, dynamic>> _desktops;
  late final List<DesktopPageHandle> _handles;
  late final PageController _controller;
  late int _page;
  bool _showSettings = false;
  bool _showIndicator = false;
  Timer? _indicatorTimer;

  DesktopPageHandle get _current => _handles[_page];

  @override
  void initState() {
    super.initState();
    final all = context.read<SessionProvider>().desktops;
    final realm = widget.desktop['realm']?.toString();
    final index = all.indexWhere((d) => d['realm']?.toString() == realm);
    _desktops = index < 0 ? [widget.desktop] : List.of(all);
    _page = index < 0 ? 0 : index;
    _handles = [for (var i = 0; i < _desktops.length; i++) DesktopPageHandle()];
    for (final handle in _handles) {
      handle.appOpen.addListener(_refresh);
      handle.status.addListener(_refresh);
    }
    _controller = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _indicatorTimer?.cancel();
    for (final handle in _handles) {
      handle.dispose();
    }
    _controller.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _onPageChanged(int page) {
    setState(() => _page = page);
    final realm = _desktops[page]['realm']?.toString();
    if (realm != null) unawaited(LastUsedRealmStore.set(realm));
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || _desktops.length < 2) return false;
    if (notification is ScrollStartNotification || notification is ScrollUpdateNotification) {
      _indicatorTimer?.cancel();
      if (!_showIndicator) setState(() => _showIndicator = true);
    } else if (notification is ScrollEndNotification) {
      _indicatorTimer?.cancel();
      _indicatorTimer = Timer(_indicatorLinger, () {
        if (mounted) setState(() => _showIndicator = false);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (isDesktopLayout(context)) return DesktopDetailsScreen(desktop: _desktops[_page]);

    final current = _current;
    return PopScope(
      canPop: !_showSettings,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _showSettings = false);
      },
      child: Scaffold(
        bottomNavigationBar: _DesktopNavBar(
          onWallpaper: !_showSettings,
          settingsSelected: _showSettings,
          onMachineTap: () {
            setState(() => _showSettings = false);
            current.openMachines?.call();
          },
          onWindowsTap: () {
            if (_showSettings) {
              setState(() => _showSettings = false);
              return;
            }
            current.openRecents?.call();
          },
          onSettingsTap: () => setState(() => _showSettings = true),
        ),
        body: IndexedStack(
          index: _showSettings ? 1 : 0,
          children: [
            Stack(
              fit: StackFit.expand,
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: PageView.builder(
                    controller: _controller,
                    physics: current.appOpen.value ? const NeverScrollableScrollPhysics() : null,
                    onPageChanged: _onPageChanged,
                    itemCount: _desktops.length,
                    itemBuilder: (context, index) => GestureDetector(
                      key: ValueKey(_desktops[index]['realm']),
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragUpdate: (_) {},
                      child:
                          widget.pageBuilder?.call(_desktops[index], _handles[index]) ??
                          DesktopDetailsScreen(desktop: _desktops[index], handle: _handles[index]),
                    ),
                  ),
                ),
                if (!current.appOpen.value)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _ConnectionStatusChip(
                      status: current.status.value,
                      name: _desktops[_page]['name']?.toString() ?? '',
                      onWallpaper: true,
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 25 + MediaQuery.textScalerOf(context).scale(15),
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _showIndicator ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: _PageIndicator(count: _desktops.length, controller: _controller),
                    ),
                  ),
                ),
              ],
            ),
            const SettingsScreen(),
          ],
        ),
      ),
    );
  }
}

class _PageIndicator extends StatelessWidget {
  final int count;
  final PageController controller;

  const _PageIndicator({required this.count, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final page = controller.hasClients && controller.position.haveDimensions
            ? controller.page ?? controller.initialPage.toDouble()
            : controller.initialPage.toDouble();
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.35 + 0.65 * (1 - (page - i).abs().clamp(0.0, 1.0))),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 3)],
                ),
              ),
          ],
        );
      },
    );
  }
}

class DesktopDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> desktop;
  final DesktopPageHandle? handle;

  const DesktopDetailsScreen({super.key, required this.desktop, this.handle});

  @override
  State<DesktopDetailsScreen> createState() => _DesktopDetailsScreenState();
}

class _DesktopDetailsScreenState extends State<DesktopDetailsScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => widget.handle != null;

  bool _openingTerminal = false;
  DesktopConnectionStatus _connectionStatus = DesktopConnectionStatus.checking;
  Uint8List? _wallpaperBytes;
  final DesktopWindowManager _windowManager = DesktopWindowManager();
  bool _dockAutoHide = false;
  final Map<String, GlobalKey<NavigatorState>> _appNavigators = {};
  final Map<String, GlobalKey> _appSnapshotKeys = {};
  final Map<String, ui.Image> _appSnapshots = {};
  List<String> _launcherOrder = [];
  List<ManifestAppEntry> _manifestApps = [];
  Map<String, bool> _capabilities = const {};
  Session? _appsWatchSession;

  String? get _realm => widget.desktop['realm']?.toString();

  @override
  void initState() {
    super.initState();
    unawaited(_probeDesktopConnection());
    unawaited(_loadCachedWallpaper());
    unawaited(_loadDockAutoHide());
    unawaited(_loadLauncherOrder());
    ConnectivityService().addListener(_handleConnectivityChanged);
    WidgetsBinding.instance.addObserver(this);
    final handle = widget.handle;
    if (handle != null) {
      handle.openRecents = () => _openRecents(context);
      handle.openMachines = _openMachines;
      _windowManager.addListener(_syncHandle);
    }
  }

  void _syncHandle() {
    final handle = widget.handle;
    if (handle == null) return;
    handle.appOpen.value = _activeMobileApp != null;
    handle.status.value = _connectionStatus;
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _connectionStatus != DesktopConnectionStatus.offline) return;
    unawaited(_probeDesktopConnection());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      if (_connectionStatus != DesktopConnectionStatus.offline) {
        setState(() => _connectionStatus = DesktopConnectionStatus.offline);
      }
      return;
    }
    if (_connectionStatus == DesktopConnectionStatus.offline) {
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

  /// Follows the desktop's manifest apps live while [session] is connected, so enabling or
  /// disabling one shows or hides its tile right away.
  Future<void> _refreshManifestApps(Session session) async {
    if (identical(_appsWatchSession, session)) return;
    _appsWatchSession = session;
    bool current() => mounted && identical(_appsWatchSession, session) && session.isConnected();
    void update(DesktopApps apps) {
      if (current()) {
        setState(() {
          _manifestApps = apps.manifestApps;
          _capabilities = apps.capabilities;
        });
      }
    }

    while (current()) {
      try {
        await watchDesktopApps(session, update);
      } catch (e) {
        if (e.toString().contains('wamp.error.no_such_procedure')) {
          // The desktop's userd predates capabilities.watch: list the apps once.
          try {
            update(await listDesktopApps(session));
          } catch (e) {
            debugPrint('Manifest apps refresh failed: $e');
          }
          break;
        }
        debugPrint('Watching the desktop\'s apps failed: $e');
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    if (identical(_appsWatchSession, session)) _appsWatchSession = null;
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
      'files': LauncherTile(
        icon: Icons.folder_open,
        badgeColor: palette.osKubuntu,
        title: "Files",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openFileExplorer(context)),
      ),
      'terminal': LauncherTile(
        icon: Icons.terminal,
        badgeColor: palette.osDebian,
        title: "Terminal",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openTerminal(context)),
      ),
      'editor': LauncherTile(
        icon: Icons.edit_note,
        badgeColor: palette.osWindows,
        title: "Text Editor",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openTextEditor(context)),
      ),
      'monitor': LauncherTile(
        icon: Icons.speed_outlined,
        badgeColor: palette.osUbuntu,
        title: "Resource Monitor",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openResourceMonitor(context)),
      ),
      'network': LauncherTile(
        icon: Icons.lan_outlined,
        badgeColor: palette.osXubuntu,
        title: "Network",
        enabled: enabled,
        onWallpaper: onWallpaper,
        onTap: () => launch(() => _openNetwork(context)),
      ),
      for (final app in _manifestApps)
        'manifest:${app.id}': LauncherTile(
          icon: Icons.widgets_outlined,
          badgeColor: palette.osMint,
          title: app.name,
          enabled: enabled,
          onWallpaper: onWallpaper,
          onTap: () => launch(() => _openManifestApp(context, app)),
        ),
    };
  }

  bool get _appsEnabled =>
      (_connectionStatus == DesktopConnectionStatus.routed || _connectionStatus == DesktopConnectionStatus.p2p) &&
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
    super.build(context);
    final terminalEnabled = _appsEnabled;

    final wallpaper = _wallpaperBytes;
    final handle = widget.handle;
    if (handle != null && handle.status.value != _connectionStatus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncHandle());
    }

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
            bottomNavigationBar: widget.handle != null
                ? null
                : _DesktopNavBar(
                    onWallpaper: true,
                    onMachineTap: _openMachines,
                    onWindowsTap: () => _openRecents(context),
                    onSettingsTap: () =>
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                  ),
            body: Stack(
              fit: StackFit.expand,
              children: [
                wallpaper != null
                    ? Image.memory(wallpaper, fit: BoxFit.cover, errorBuilder: (_, _, _) => const _DefaultWallpaper())
                    : const _DefaultWallpaper(),
                if (wallpaper != null) Container(color: Colors.black.withValues(alpha: 0.25)),
                SafeArea(
                  bottom: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            final tiles = _launcherTiles(context, enabled: terminalEnabled, onWallpaper: true);
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
                      if (widget.handle != null) const SizedBox(height: _MachinePagerState.indicatorGap),
                      Visibility(
                        visible: widget.handle == null,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: _ConnectionStatusChip(
                          status: _connectionStatus,
                          name: widget.desktop['name']?.toString() ?? '',
                          onWallpaper: true,
                        ),
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
              ? Image.memory(wallpaper, fit: BoxFit.cover, errorBuilder: (_, _, _) => const _DefaultWallpaper())
              : const _DefaultWallpaper(),
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
                        case DesktopAppKind.textEditor:
                          _openTextEditor(context);
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
                        case DesktopAppKind.manifest:
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
    DesktopConnectionStatus.checking => 'Connecting',
    DesktopConnectionStatus.p2p => 'P2P',
    DesktopConnectionStatus.routed => 'Routed',
    DesktopConnectionStatus.offline => 'Offline',
  };

  Color _connectionStatusColor(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    return switch (_connectionStatus) {
      DesktopConnectionStatus.checking => palette.subtle,
      DesktopConnectionStatus.p2p => palette.statusOnline,
      DesktopConnectionStatus.routed => palette.statusRouted,
      DesktopConnectionStatus.offline => palette.statusOffline,
    };
  }

  Future<void> _probeDesktopConnection() async {
    final realm = _realm;

    final cached = realm == null ? null : DesktopConnectionManager().get(realm);
    if (cached != null && cached.isAgentOnline) {
      cached.onDisconnected = _handleConnectionDisconnected;
      if (mounted) {
        setState(() => _connectionStatus = cached.isP2P ? DesktopConnectionStatus.p2p : DesktopConnectionStatus.routed);
      }
      unawaited(_refreshWallpaper(cached.session));
      unawaited(_refreshManifestApps(cached.session));
      return;
    }

    if (!ConnectivityService().hasConnection) {
      if (mounted) {
        setState(() => _connectionStatus = DesktopConnectionStatus.offline);
      }
      return;
    }

    if (mounted) {
      setState(() => _connectionStatus = DesktopConnectionStatus.checking);
    }

    final authId = await DeviceIdentity.desktopAuthId();
    final privateKey = await DeviceIdentity.desktopPrivateKey();
    final prefs = await SharedPreferences.getInstance();
    final webRtcEnabled = prefs.getBool(prefKeyWebRtcEnabled) ?? defaultWebRtcEnabled;

    if (authId == null || privateKey == null || realm == null) {
      if (mounted) {
        setState(() => _connectionStatus = DesktopConnectionStatus.offline);
      }
      return;
    }

    final status = await _attemptConnection(realm, authId, privateKey, webRtcEnabled);
    if (mounted) {
      setState(() => _connectionStatus = status ?? DesktopConnectionStatus.offline);
    }
    if (status != null) {
      final session = DesktopConnectionManager().get(realm)?.session;
      if (session != null) {
        unawaited(_refreshWallpaper(session));
        unawaited(_refreshManifestApps(session));
      }
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
      if (session != null) {
        unawaited(_refreshWallpaper(session));
        unawaited(_refreshManifestApps(session));
      }
    }
  }

  Future<DesktopConnectionStatus?> _attemptConnection(
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
        return connection.isP2P ? DesktopConnectionStatus.p2p : DesktopConnectionStatus.routed;
      }

      final desktopOnline = await _isDesktopAgentOnline(connection.session);
      if (desktopOnline) {
        connection.isAgentOnline = true;
        return connection.isP2P ? DesktopConnectionStatus.p2p : DesktopConnectionStatus.routed;
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
    setState(() => _connectionStatus = DesktopConnectionStatus.checking);
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

  Future<void> _openManifestApp(BuildContext context, ManifestAppEntry app) async {
    final realm = _realm;
    if (realm == null ||
        (_connectionStatus != DesktopConnectionStatus.routed && _connectionStatus != DesktopConnectionStatus.p2p)) {
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
      final iconColor = DeskconnPalette.of(context).osMint;

      if (isDesktopLayout(context)) {
        _windowManager.open(
          DesktopAppKind.manifest,
          category: app.id,
          title: app.name,
          icon: Icons.widgets_outlined,
          iconColor: iconColor,
          content: ManifestAppView(config: config, appId: app.id, capabilities: _capabilities),
          workspaceSize: MediaQuery.sizeOf(context),
          width: 480,
          height: 420,
        );
        return;
      }

      _openMobileApp(
        DesktopAppKind.manifest,
        category: app.id,
        title: app.name,
        icon: Icons.widgets_outlined,
        iconColor: iconColor,
        builder: (_, _) => ManifestAppScreen(config: config, app: app, capabilities: _capabilities),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open ${app.name}: $e")));
      }
    }
  }

  Future<void> _openResourceMonitor(BuildContext context) async {
    final realm = _realm;
    if (realm == null ||
        (_connectionStatus != DesktopConnectionStatus.routed && _connectionStatus != DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.desktopAuthId();
      final privateKey = await DeviceIdentity.desktopPrivateKey();
      if (authId == null || privateKey == null) {
        throw Exception("Missing credentials.");
      }

      if (!context.mounted) return;

      final config = _terminalConfig(realm: realm, authId: authId, privateKey: privateKey, status: _connectionStatus);

      if (isDesktopLayout(context)) {
        final palette = DeskconnPalette.of(context);
        _windowManager.open(
          DesktopAppKind.resourceMonitor,
          title: 'Resource Monitor',
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
        title: 'Resource Monitor',
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
        (_connectionStatus != DesktopConnectionStatus.routed && _connectionStatus != DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.desktopAuthId();
      final privateKey = await DeviceIdentity.desktopPrivateKey();
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
        (_connectionStatus != DesktopConnectionStatus.routed && _connectionStatus != DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.desktopAuthId();
      final privateKey = await DeviceIdentity.desktopPrivateKey();
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
        (_connectionStatus != DesktopConnectionStatus.routed && _connectionStatus != DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.desktopAuthId();
      final privateKey = await DeviceIdentity.desktopPrivateKey();
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
        (_connectionStatus != DesktopConnectionStatus.routed && _connectionStatus != DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.desktopAuthId();
      final privateKey = await DeviceIdentity.desktopPrivateKey();
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

  Future<void> _openTextEditor(BuildContext context) async {
    final realm = _realm;
    if (realm == null ||
        (_connectionStatus != DesktopConnectionStatus.routed && _connectionStatus != DesktopConnectionStatus.p2p)) {
      return;
    }

    try {
      final authId = await DeviceIdentity.desktopAuthId();
      final privateKey = await DeviceIdentity.desktopPrivateKey();
      if (authId == null || privateKey == null) {
        throw Exception("Missing credentials.");
      }
      if (!context.mounted) return;

      final config = _terminalConfig(realm: realm, authId: authId, privateKey: privateKey, status: _connectionStatus);
      final iconColor = DeskconnPalette.of(context).osWindows;

      if (isDesktopLayout(context)) {
        late final VoidCallback closeEditorWindow;
        final entry = _windowManager.open(
          DesktopAppKind.textEditor,
          title: 'Text Editor',
          icon: Icons.edit_note,
          iconColor: iconColor,
          content: TextEditorScreen(config: config, onRequestClose: () => closeEditorWindow()),
          workspaceSize: MediaQuery.sizeOf(context),
          width: 860,
          height: 600,
        );
        closeEditorWindow = () => _windowManager.close(entry.id);
        return;
      }

      _openMobileApp(
        DesktopAppKind.textEditor,
        title: 'Text Editor',
        icon: Icons.edit_note,
        iconColor: iconColor,
        builder: (_, close) => TextEditorScreen(config: config, onRequestClose: close),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to open Text Editor: $e")));
      }
    }
  }

  Future<void> _openTerminal(BuildContext context) async {
    final realm = _realm;
    if (_openingTerminal ||
        realm == null ||
        (_connectionStatus != DesktopConnectionStatus.routed && _connectionStatus != DesktopConnectionStatus.p2p)) {
      return;
    }

    setState(() => _openingTerminal = true);
    _appendTerminalLog("Starting terminal connection");

    try {
      final desktopName = widget.desktop['name']?.toString() ?? 'Desktop';
      final webRtcEnabled = _connectionStatus == DesktopConnectionStatus.p2p;

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
    required DesktopConnectionStatus status,
  }) {
    return DesktopSessionLaunchConfig(
      sessionKey: 'terminal:$realm',
      desktopName: widget.desktop['name']?.toString() ?? 'Desktop',
      realm: realm,
      authId: authId,
      privateKey: privateKey,
      webRtcEnabled: status == DesktopConnectionStatus.p2p,
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

class LauncherTile extends StatelessWidget {
  static const _labelFontSize = 13.0;
  static const _labelLineHeight = 1.2;

  final IconData icon;
  final Color badgeColor;
  final String title;
  final VoidCallback onTap;
  final bool enabled;
  final bool onWallpaper;

  const LauncherTile({
    super.key,
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
          SizedBox(
            height: MediaQuery.textScalerOf(context).scale(_labelFontSize) * _labelLineHeight,
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w500,
                fontSize: _labelFontSize,
                height: _labelLineHeight,
                shadows: textShadows,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionStatusChip extends StatelessWidget {
  final DesktopConnectionStatus status;
  final String name;
  final bool onWallpaper;

  const _ConnectionStatusChip({required this.status, required this.name, required this.onWallpaper});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = DeskconnPalette.of(context);
    final (dotColor, label) = switch (status) {
      DesktopConnectionStatus.checking => (palette.subtle, 'Connecting'),
      DesktopConnectionStatus.p2p => (palette.statusOnline, 'P2P'),
      DesktopConnectionStatus.routed => (palette.statusRouted, 'Routed'),
      DesktopConnectionStatus.offline => (palette.statusOffline, 'Offline'),
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

class _DefaultWallpaper extends StatelessWidget {
  const _DefaultWallpaper();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
        ),
      ),
    );
  }
}

class _DesktopNavBar extends StatefulWidget {
  final bool onWallpaper;
  final bool settingsSelected;
  final VoidCallback onMachineTap;
  final VoidCallback onWindowsTap;
  final VoidCallback onSettingsTap;

  const _DesktopNavBar({
    required this.onMachineTap,
    required this.onWindowsTap,
    required this.onSettingsTap,
    this.onWallpaper = false,
    this.settingsSelected = false,
  });

  @override
  State<_DesktopNavBar> createState() => _DesktopNavBarState();
}

class _DesktopNavBarState extends State<_DesktopNavBar> {
  bool _fromSystemEdge = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = widget.onWallpaper ? Colors.black.withValues(alpha: 0.86) : colorScheme.surface;
    final dividerColor = widget.onWallpaper ? Colors.white.withValues(alpha: 0.14) : colorScheme.outlineVariant;
    final selectedColor = widget.onWallpaper ? Colors.white : colorScheme.primary;
    final unselectedColor = widget.onWallpaper
        ? Colors.white.withValues(alpha: 0.6)
        : colorScheme.onSurface.withValues(alpha: 0.55);

    return GestureDetector(
      onVerticalDragStart: (details) {
        final screenHeight = MediaQuery.sizeOf(context).height;
        _fromSystemEdge = details.globalPosition.dy >= screenHeight - MediaQuery.systemGestureInsetsOf(context).bottom;
      },
      onVerticalDragEnd: (details) {
        if (!_fromSystemEdge && (details.primaryVelocity ?? 0) < -300) widget.onWindowsTap();
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
                  label: 'Machines',
                  color: unselectedColor,
                  onTap: widget.onMachineTap,
                ),
                _DesktopNavBarItem(
                  icon: Icons.grid_view_rounded,
                  label: 'Apps',
                  color: widget.settingsSelected ? unselectedColor : selectedColor,
                  onTap: widget.onWindowsTap,
                  selected: !widget.settingsSelected,
                ),
                _DesktopNavBarItem(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  color: widget.settingsSelected ? selectedColor : unselectedColor,
                  onTap: widget.onSettingsTap,
                  selected: widget.settingsSelected,
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
