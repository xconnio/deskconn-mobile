import 'dart:async';
import 'dart:convert';

import 'package:app_engine/app_engine.dart';
import 'package:flutter/material.dart';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/session_encryption.dart';

/// A manifest app the desktop lists in capabilities.list, enabled and with a manifest.
class ManifestAppEntry {
  const ManifestAppEntry({required this.id, required this.name});

  final String id;
  final String name;
}

/// Converts a WAMP result to plain JSON types, so maps are `Map<String, dynamic>`.
dynamic _plain(dynamic value) => jsonDecode(jsonEncode(value));

typedef DesktopApps = ({Map<String, bool> capabilities, List<ManifestAppEntry> manifestApps});

/// Reads capabilities.list's result: each app id with whether it's enabled, and the enabled
/// manifest apps.
DesktopApps _desktopApps(dynamic list) {
  final apps = (_plain(list) as List).whereType<Map<String, dynamic>>();
  return (
    capabilities: {for (final app in apps) app['id'].toString(): app['enabled'] == true},
    manifestApps: [
      for (final app in apps)
        if (app['manifest'] == true && app['enabled'] == true)
          ManifestAppEntry(id: app['id'].toString(), name: app['name']?.toString() ?? app['id'].toString()),
    ],
  );
}

/// Lists the desktop's apps once.
Future<DesktopApps> listDesktopApps(Session session) async {
  final result = await session.call(DeskconnProcedures.deskconndCapabilitiesList).timeout(DeskconnConfig.callTimeout);
  return _desktopApps(result.args.first);
}

/// Calls [onChange] with the desktop's apps now and whenever they change, until the desktop
/// ends the watch (it does after a while, or when [session] goes away).
Future<void> watchDesktopApps(Session session, void Function(DesktopApps apps) onChange) async {
  await session.callProgress(DeskconnProcedures.deskconndCapabilitiesWatch, (result) {
    if (result.args.isNotEmpty) onChange(_desktopApps(result.args.first));
  });
}

class ManifestAppScreen extends StatelessWidget {
  const ManifestAppScreen({super.key, required this.config, required this.app});

  final DesktopSessionLaunchConfig config;
  final ManifestAppEntry app;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(app.name)),
      body: ManifestAppView(config: config, appId: app.id),
    );
  }
}

/// Fetches manifest app [appId] from the desktop and renders its entry screen.
class ManifestAppView extends StatefulWidget {
  const ManifestAppView({super.key, required this.config, required this.appId});

  final DesktopSessionLaunchConfig config;
  final String appId;

  @override
  State<ManifestAppView> createState() => _ManifestAppViewState();
}

class _ManifestAppViewState extends State<ManifestAppView> {
  ManifestApp? _app;
  Map<String, dynamic> _context = const {};
  ManifestCaller? _caller;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final connection =
          DesktopConnectionManager().get(widget.config.realm) ??
          await DesktopConnectionManager().acquire(
            realm: widget.config.realm,
            authId: widget.config.authId,
            privateKey: widget.config.privateKey,
            webRtcEnabled: widget.config.webRtcEnabled,
          );
      final session = connection.session;
      final result = await session
          .call(DeskconnProcedures.deskconndManifestGet, args: [widget.appId])
          .timeout(DeskconnConfig.callTimeout);
      final app = ManifestApp(_plain(result.args.first) as Map<String, dynamic>);
      final apps = await listDesktopApps(session);
      final encryption = SessionEncryption.forKeyExchange(session, app.keyExchange);
      if (!mounted) return;
      setState(() {
        _app = app;
        _context = {'capabilities': apps.capabilities};
        _caller = (procedure, arg) => encryption.call(procedure, arg: arg);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final app = _app;
    final caller = _caller;
    if (app == null || caller == null) return const Center(child: CircularProgressIndicator());

    final screen = app.entryScreen;
    if (screen == null) return const Center(child: Text('The app has no entry screen'));
    return ManifestScreenView(
      app: app,
      screen: screen,
      context: _context,
      caller: caller,
      errorUri: (e) => e is ApplicationError ? e.message : e.toString(),
    );
  }
}
