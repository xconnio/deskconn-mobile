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
import 'package:deskconn_mobile_app/providers/auth_provider.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/providers/theme_provider.dart';
import 'package:deskconn_mobile_app/screens/desktop_details_screen.dart';
import 'package:deskconn_mobile_app/screens/desktop_list_screen.dart';
import 'package:deskconn_mobile_app/screens/share_upload_screen.dart';
import 'package:deskconn_mobile_app/screens/sign_in_screen.dart';
import 'package:deskconn_mobile_app/theme/app_theme.dart';
import 'package:deskconn_mobile_app/theme/motion.dart';
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
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: const AppBootstrap(),
          );
        },
      ),
    );
  }
}

class _SplashContent extends StatelessWidget {
  const _SplashContent();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: DeskconnMotion.reduce(context) ? Duration.zero : DeskconnMotion.normal,
      curve: DeskconnMotion.standard,
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
    if (state != AppLifecycleState.resumed) return;
    unawaited(ConnectivityService().refresh());
    unawaited(DesktopConnectionManager().verifyConnections());
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
