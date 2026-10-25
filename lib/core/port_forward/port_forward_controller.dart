import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as web_rtc;

import 'package:deskconn_mobile_app/core/port_forward/port_channel.dart';
import 'package:deskconn_mobile_app/core/port_forward/port_forward_service.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';

enum PortForwardDirection { local, remote }

enum PortForwardStatus { stopped, starting, active, failed }

class PortForwardRule {
  PortForwardRule({required this.id, required this.direction, required this.localPort, required this.remotePort});

  final String id;
  final PortForwardDirection direction;
  final int localPort;
  final int remotePort;

  PortForwardStatus status = PortForwardStatus.stopped;
  String? error;
  int connections = 0;

  bool get isRunning => status == PortForwardStatus.starting || status == PortForwardStatus.active;

  Map<String, dynamic> toJson() => {
    'id': id,
    'direction': direction.name,
    'local_port': localPort,
    'remote_port': remotePort,
  };

  static PortForwardRule? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final localPort = (json['local_port'] as num?)?.toInt();
    final remotePort = (json['remote_port'] as num?)?.toInt();
    if (id == null || localPort == null || remotePort == null) return null;
    final direction = PortForwardDirection.values.firstWhere(
      (d) => d.name == json['direction'],
      orElse: () => PortForwardDirection.local,
    );
    return PortForwardRule(id: id, direction: direction, localPort: localPort, remotePort: remotePort);
  }
}

class PortForwardController extends ChangeNotifier {
  PortForwardController._(this.realm);

  static final Map<String, PortForwardController> _controllers = {};

  factory PortForwardController.forRealm(String realm) {
    return _controllers.putIfAbsent(realm, () => PortForwardController._(realm));
  }

  final String realm;

  final List<PortForwardRule> _rules = [];
  final Map<String, PortForwardSession> _forwards = {};
  final Map<String, PortReverseSession> _reverses = {};

  bool _loaded = false;
  var _nextId = 0;

  List<PortForwardRule> get rules => List.unmodifiable(_rules);

  String get _prefsKey => 'port_forward_rules_$realm';

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? const [];
    for (final entry in stored) {
      try {
        final rule = PortForwardRule.fromJson(jsonDecode(entry) as Map<String, dynamic>);
        if (rule != null) _rules.add(rule);
      } catch (_) {}
    }
    _nextId = _rules.length;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _rules.map((rule) => jsonEncode(rule.toJson())).toList());
  }

  bool hasRule(PortForwardDirection direction, int localPort, int remotePort) {
    return _rules.any((r) => r.direction == direction && r.localPort == localPort && r.remotePort == remotePort);
  }

  Future<PortForwardRule> add({
    required PortForwardDirection direction,
    required int localPort,
    required int remotePort,
  }) async {
    final rule = PortForwardRule(
      id: 'pf${_nextId++}-${DateTime.now().microsecondsSinceEpoch}',
      direction: direction,
      localPort: localPort,
      remotePort: remotePort,
    );
    _rules.add(rule);
    notifyListeners();
    await _persist();
    return rule;
  }

  Future<void> remove(PortForwardRule rule) async {
    await stop(rule);
    _rules.removeWhere((r) => r.id == rule.id);
    notifyListeners();
    await _persist();
  }

  Future<void> start(PortForwardRule rule, DesktopSessionLaunchConfig config) async {
    if (rule.isRunning) return;
    rule.status = PortForwardStatus.starting;
    rule.error = null;
    rule.connections = 0;
    notifyListeners();

    try {
      final session = await _webRtcSession(config);
      if (rule.direction == PortForwardDirection.local) {
        _forwards[rule.id] = await PortForwardSession.start(
          session: session,
          localPort: rule.localPort,
          remotePort: rule.remotePort,
          onChanged: () => _syncConnections(rule),
          onError: (error) => _recordError(rule, error),
        );
      } else {
        _reverses[rule.id] = await PortReverseSession.start(
          session: session,
          remotePort: rule.remotePort,
          localPort: rule.localPort,
          onChanged: () => _syncConnections(rule),
          onError: (error) => _recordError(rule, error),
          onClosed: () => _handleClosed(rule),
        );
      }
      rule.status = PortForwardStatus.active;
    } catch (e) {
      rule.status = PortForwardStatus.failed;
      rule.error = _friendlyError(e);
    }
    notifyListeners();
  }

  Future<void> stop(PortForwardRule rule) async {
    final forward = _forwards.remove(rule.id);
    final reverse = _reverses.remove(rule.id);
    await forward?.stop();
    await reverse?.stop();
    rule.connections = 0;
    if (rule.status != PortForwardStatus.failed) rule.status = PortForwardStatus.stopped;
    notifyListeners();
  }

  Future<void> stopAll() async {
    for (final rule in _rules.toList()) {
      await stop(rule);
    }
  }

  Future<web_rtc.WebRTCSession> _webRtcSession(DesktopSessionLaunchConfig config) async {
    final manager = DesktopConnectionManager();
    final connection =
        manager.get(realm) ??
        await manager.connect(
          realm: realm,
          authId: config.authId,
          privateKey: config.privateKey,
          webRtcEnabled: config.webRtcEnabled,
        );
    final session = connection.webRtcSession;
    if (session == null) {
      throw PortStreamException('Port forwarding needs a direct (P2P) connection to this desktop.');
    }
    return session;
  }

  void _syncConnections(PortForwardRule rule) {
    final count = _forwards[rule.id]?.connections ?? _reverses[rule.id]?.connections ?? 0;
    if (rule.connections == count) return;
    rule.connections = count;
    notifyListeners();
  }

  void _recordError(PortForwardRule rule, Object error) {
    rule.error = _friendlyError(error);
    notifyListeners();
  }

  void _handleClosed(PortForwardRule rule) {
    if (!_reverses.containsKey(rule.id)) return;
    _reverses.remove(rule.id);
    rule.connections = 0;
    rule.status = PortForwardStatus.failed;
    rule.error ??= 'The desktop closed this forward.';
    notifyListeners();
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (error is TimeoutException) return 'Timed out talking to the desktop.';
    return text.replaceFirst(RegExp(r'^(Exception|SocketException): '), '');
  }
}
