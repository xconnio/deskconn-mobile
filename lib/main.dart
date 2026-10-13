import 'dart:async';
import 'dart:ui';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:deskconn_mobile_app/core/share/share_service.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_registry.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_screen.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/last_used_realm_store.dart';
import 'package:deskconn_mobile_app/core/wamp/machine_switcher.dart';
import 'package:deskconn_mobile_app/providers/auth_provider.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/providers/theme_provider.dart';
import 'package:deskconn_mobile_app/screens/desktop_details_screen.dart';
import 'package:deskconn_mobile_app/screens/desktop_list_screen.dart';
import 'package:deskconn_mobile_app/screens/share_upload_screen.dart';
import 'package:deskconn_mobile_app/screens/sign_in_screen.dart';
import 'package:deskconn_mobile_app/theme/app_theme.dart';
import 'package:deskconn_mobile_app/theme/system_ui.dart';
import 'package:deskconn_mobile_app/theme/typography.dart';
import 'package:deskconn_mobile_app/widgets/exit_guard.dart';
import 'package:deskconn_mobile_app/widgets/logo.dart';
import 'package:deskconn_mobile_app/widgets/offline_dialog.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:deskconn_mobile_app/core/update/update_service.dart';
import 'package:deskconn_mobile_app/firebase_options.dart';
import 'package:deskconn_mobile_app/widgets/update_dialog.dart';
import 'package:provider/provider.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // firebase_core/firebase_crashlytics have no Linux/Windows implementation
  // (DefaultFirebaseOptions.currentPlatform only covers android/iOS) — skip
  // Firebase entirely on desktop platforms that lack it rather than crash.
  final firebaseSupported =
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  if (firebaseSupported) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } else {
    // No Crashlytics here, but still need a handler — without one, an
    // uncaught error outside the widget build phase (e.g. an async frame
    // callback) takes the whole process down instead of just logging.
    FlutterError.onError = FlutterError.presentError;
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught error: $error\n$stack');
      return true;
    };
  }

  const MethodChannel('deskconn/shell_notification').setMethodCallHandler((call) async {
    final realm = (call.arguments as Map?)?.entries
        .firstWhere((e) => e.key == 'realm', orElse: () => const MapEntry('realm', null))
        .value
        ?.toString();

    switch (call.method) {
      case 'closeTerminal':
        if (realm != null) TerminalRegistry().closeTerminal(realm);
      case 'openTerminal':
        if (realm != null) {
          final group = TerminalRegistry().getActive(realm);
          if (group != null) {
            final sample = group.tabs.first.controller.config;
            navigatorKey.currentState?.push(
              MaterialPageRoute(
                builder: (_) =>
                    TerminalScreen(realm: realm, desktopName: sample.desktopName, webRtcEnabled: sample.webRtcEnabled),
              ),
            );
          }
        }
    }
  });

  runApp(const DeskconnApp());

  unawaited(_initializeAppServices());
}

Future<void> _initializeAppServices() async {
  try {
    await initializeDesktopSessionBackgroundService();
    await ShareService.instance.initialize();
    if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      await FlutterBackgroundService().startService();
      unawaited(promoteBackgroundService());
    }
  } catch (e) {
    debugPrint('App service initialization failed: $e');
  }
}

class DeskconnApp extends StatelessWidget {
  const DeskconnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => SessionProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) {
          return MaterialApp(
            navigatorKey: navigatorKey,
            debugShowCheckedModeBanner: false,
            theme: DeskconnTheme.light(),
            darkTheme: DeskconnTheme.dark(),
            themeMode: theme.mode,
            onNavigationNotification: keepFrameworkHandlingBack,
            builder: (context, child) {
              final brightness = Theme.of(context).brightness;

              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: DeskconnSystemUi.overlayStyle(brightness),
                child: _ReconnectingOverlay(child: child ?? const SizedBox.shrink()),
              );
            },
            home: const AppBootstrap(),
          );
        },
      ),
    );
  }
}

class _ReconnectingOverlay extends StatefulWidget {
  final Widget child;

  const _ReconnectingOverlay({required this.child});

  @override
  State<_ReconnectingOverlay> createState() => _ReconnectingOverlayState();
}

class _ReconnectingOverlayState extends State<_ReconnectingOverlay> {
  static const _bannerDelay = Duration(seconds: 6);

  OverlayEntry? _entry;
  bool _visible = false;
  Timer? _bannerTimer;
  StreamSubscription<bool>? _transportSubscription;

  @override
  void initState() {
    super.initState();
    DesktopConnectionManager().isReconnecting.addListener(_sync);
    ConnectivityService().addListener(_sync);
    _transportSubscription = DesktopConnectionManager().onTransportChanged.listen(_notifyTransportChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    DesktopConnectionManager().isReconnecting.removeListener(_sync);
    ConnectivityService().removeListener(_sync);
    _transportSubscription?.cancel();
    _bannerTimer?.cancel();
    _entry?.remove();
    super.dispose();
  }

  bool get _reconnecting => DesktopConnectionManager().isReconnecting.value && ConnectivityService().hasConnection;

  void _sync() {
    if (!_reconnecting) {
      _bannerTimer?.cancel();
      _bannerTimer = null;
      _apply(false);
      return;
    }
    if (_visible || _bannerTimer != null) return;
    _bannerTimer = Timer(_bannerDelay, () {
      _bannerTimer = null;
      if (_reconnecting) _apply(true);
    });
  }

  void _notifyTransportChanged(bool isP2P) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(isP2P ? 'Connected directly (P2P)' : 'Connected through relay'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _apply(bool show) {
    if (show == _visible) return;
    _visible = show;

    if (show) {
      final overlay = navigatorKey.currentState?.overlay;
      if (overlay == null) return;
      _entry = OverlayEntry(builder: (_) => _ReconnectingBanner(onSwitchMachine: _openSwitcher));
      overlay.insert(_entry!);
    } else {
      _entry?.remove();
      _entry = null;
    }
  }

  Future<void> _openSwitcher() async {
    _apply(false);
    final ctx = navigatorKey.currentContext;
    if (ctx != null) await switchMachine(ctx);
    _sync();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ReconnectingBanner extends StatelessWidget {
  final VoidCallback onSwitchMachine;

  const _ReconnectingBanner({required this.onSwitchMachine});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(child: Container(color: Colors.black.withValues(alpha: 0.35))),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Material(
              color: colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: colorScheme.onSecondaryContainer),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Reconnecting…',
                        style: TextStyle(color: colorScheme.onSecondaryContainer, fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: onSwitchMachine,
                      child: Text(
                        'Switch Machine',
                        style: TextStyle(color: colorScheme.onSecondaryContainer, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SplashContent extends StatelessWidget {
  const _SplashContent();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const DeskconnLogo(size: 44),
          const SizedBox(height: 16),
          Text('Deskconn', style: DeskconnTypography.title(context)),
          const SizedBox(height: 40),
          const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
        ],
      ),
    );
  }
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> with WidgetsBindingObserver {
  late final Future<void> _initialization;
  bool _notificationActive = false;
  bool _wasOffline = false;
  bool _handlingSharedFiles = false;
  Map<String, dynamic>? _autoOpenDesktop;

  @override
  void initState() {
    super.initState();
    _wasOffline = !ConnectivityService().hasConnection;
    ConnectivityService().addListener(_handleConnectivityChange);
    WidgetsBinding.instance.addObserver(this);
    ShareService.instance.pendingFiles.addListener(_handlePendingSharedFiles);

    final completer = Completer<void>();
    _initialization = completer.future;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        if (!completer.isCompleted) completer.complete();
        return;
      }
      try {
        final session = context.read<SessionProvider>();
        await session.initialize().timeout(DeskconnConfig.callTimeout);
        await _resolveAutoOpenDesktop(session);
        if (!completer.isCompleted) completer.complete();
      } catch (e) {
        debugPrint('Session initialization failed: $e');
        if (!completer.isCompleted) completer.complete();
      }
      unawaited(_checkForUpdate());
    });
  }

  // Mirrors the web app: skip the machine picker on launch when a
  // previously-used desktop is known, and land directly on it instead.
  // The list stays reachable afterwards via the status pill's "switch
  // machine" action, which forgets this value.
  Future<void> _resolveAutoOpenDesktop(SessionProvider session) async {
    if (!session.loggedIn || session.desktops.isEmpty) return;

    final lastRealm = await LastUsedRealmStore.get();
    if (lastRealm == null) return;

    for (final desktop in session.desktops) {
      if (desktop['realm']?.toString() == lastRealm) {
        _autoOpenDesktop = desktop;
        return;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(ConnectivityService().refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ConnectivityService().removeListener(_handleConnectivityChange);
    ShareService.instance.pendingFiles.removeListener(_handlePendingSharedFiles);
    super.dispose();
  }

  // Nothing previously told the user the device had no connectivity at all,
  // let alone offered a way to fix it, and nothing refreshed after a drop —
  // the user had to manually pull-to-refresh or reopen a screen. This shows
  // a dialog (with a shortcut to Wi-Fi settings) on loss, and on restore
  // re-triggers desktop list loading, which itself reconnects the account
  // session (see SessionProvider._ensureSession).
  void _handleConnectivityChange() {
    final hasConnection = ConnectivityService().hasConnection;
    if (!hasConnection && !_wasOffline) {
      _showOfflineDialog();
    } else if (hasConnection && _wasOffline && mounted) {
      final session = context.read<SessionProvider>();
      if (session.loggedIn) unawaited(session.loadDesktops());
    }
    _wasOffline = !hasConnection;
  }

  void _showOfflineDialog() {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    unawaited(
      showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => OfflineDialog(
          connectivity: ConnectivityService(),
          isOnline: () => ConnectivityService().hasConnection,
          recheck: ConnectivityService().refresh,
        ),
      ),
    );
  }

  Future<void> _checkForUpdate() async {
    final release = await UpdateService().checkForUpdate();
    if (release != null && mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (_) => UpdateDialog(release: release),
      );
    }
  }

  void _syncNotification(bool loggedIn) {
    if (loggedIn && !_notificationActive) {
      _notificationActive = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(showAppNotification()));
    } else if (!loggedIn && _notificationActive) {
      _notificationActive = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(hideAppNotification()));
    }
  }

  void _handlePendingSharedFiles() {
    if (!mounted || _handlingSharedFiles) return;
    final session = context.read<SessionProvider>();
    if (!session.loggedIn || ShareService.instance.pendingFiles.value.isEmpty) {
      return;
    }
    // Set synchronously (not via setState) so a call made from build() itself
    // is reflected in that same build pass without violating Flutter's
    // no-setState-during-build rule; the deferred setState below only
    // matters for calls triggered outside of build (e.g. the pendingFiles
    // listener) and for reverting the flag once the dialog closes.
    _handlingSharedFiles = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() {});
      final files = ShareService.instance.takePendingFiles();
      if (files.isEmpty) {
        _handlingSharedFiles = false;
        if (mounted) setState(() {});
        return;
      }
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        await showDialog<void>(
          context: ctx,
          barrierDismissible: false,
          builder: (_) => ShareUploadScreen(files: files),
        );
      }
      if (ShareService.instance.pendingFiles.value.isEmpty) {
        await ShareService.instance.finishIfShareOnly();
      }
      _handlingSharedFiles = false;
      if (mounted) setState(() {});
      if (ShareService.instance.pendingFiles.value.isNotEmpty) {
        _handlePendingSharedFiles();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initialization,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: _SplashContent()));
        }

        final session = context.watch<SessionProvider>();
        _syncNotification(session.loggedIn);
        if (session.loggedIn) _handlePendingSharedFiles();
        if (_handlingSharedFiles) {
          return const Scaffold(body: Center(child: _SplashContent()));
        }
        if (!session.loggedIn) return const SignInScreen();
        final autoOpen = _autoOpenDesktop;
        return autoOpen != null ? MachinePager(desktop: autoOpen) : const DesktopListScreen();
      },
    );
  }
}
