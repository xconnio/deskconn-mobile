import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:xconn/xconn.dart';
import 'package:xconn_webrtc_dart/xconn_webrtc_dart.dart' as web_rtc;
import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/file_explorer/file_explorer_controller.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:deskconn_mobile_app/core/vpn/vpn_tunnel.dart';
import 'package:deskconn_mobile_app/core/wamp/file_stream_server.dart';
import 'package:deskconn_mobile_app/core/wamp/file_stream_service.dart';
import 'package:deskconn_mobile_app/core/wamp/wamp_client.dart';
import 'package:deskconn_mobile_app/core/wamp/webrtc_close_peer.dart';

const bool kForceWebRtcOnly = false;

class DesktopConnection {
  final Session session;
  final bool isP2P;
  final web_rtc.WebRTCSession? webRtcSession;
  bool isAgentOnline = false;

  FileExplorerController? explorerController;

  void Function()? onDisconnected;

  FileStreamServer? _fileStreamServer;

  FileStreamServer? get fileStreamServer {
    final rtc = webRtcSession;
    if (rtc == null) return null;
    return _fileStreamServer ??= FileStreamServer(FileStreamService(rtc));
  }

  FileStreamService? get fileStreamService => fileStreamServer?.service;

  DesktopConnection({required this.session, required this.isP2P, this.webRtcSession});

  Future<void> dispose() async {
    try {
      await session.close();
    } catch (_) {}
    try {
      await webRtcSession?.connection.dispose();
    } catch (_) {}
    try {
      await _fileStreamServer?.dispose();
    } catch (_) {}
  }
}

/// An error whose text is already user-facing: screens that render
/// `error.toString()` show it as-is instead of "Exception: ..." noise.
class TerminalTabException implements Exception {
  const TerminalTabException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DesktopConnectionManager {
  static final DesktopConnectionManager _instance = DesktopConnectionManager._();
  factory DesktopConnectionManager() => _instance;
  DesktopConnectionManager._() {
    ConnectivityService().onNetworkChanged.listen((_) => _handleNetworkChanged());
    ConnectivityService().onConnectivityProbe.listen((_) => unawaited(_runHeartbeat()));
    Timer.periodic(_heartbeatInterval, (_) => unawaited(_runHeartbeat()));
  }

  final Map<String, DesktopConnection> _connections = {};
  final Map<String, Future<DesktopConnection>> _pendingConnections = {};
  final Set<String> _noWebRtcSupportRealms = {};
  final Set<String> _everConnectedRealms = {};
  final Map<String, int> _webRtcFailureCount = {};
  final Set<DesktopConnection> _standaloneConnections = {};
  final Expando<String> _standaloneRealms = Expando();

  final ValueNotifier<bool> isReconnecting = ValueNotifier(false);
  final Map<String, bool> _lastTransportIsP2P = {};
  final StreamController<bool> _transportChanges = StreamController.broadcast();

  Stream<bool> get onTransportChanged => _transportChanges.stream;

  static const _webRtcFailureFallbackThreshold = 2;
  static const _heartbeatInterval = Duration(seconds: 8);
  static const _heartbeatTimeout = Duration(seconds: 5);
  static const heartbeatMaxMisses = 3;

  @visibleForTesting
  static bool shouldDropAfterHeartbeatFailure({required bool strict, required bool connected, required int misses}) {
    return strict || !connected || misses >= heartbeatMaxMisses;
  }

  void _recomputeReconnecting() {
    isReconnecting.value = _pendingConnections.keys.any(_everConnectedRealms.contains);
  }

  static const _webRtcDisposeCooldown = Duration(seconds: 3);
  final Map<String, DateTime> _lastWebRtcDisposeAt = {};
  final Map<String, Future<void>> _pendingWebRtcDispose = {};

  void _markWebRtcDisposed(String realm, Future<void> disposeFuture) {
    _lastWebRtcDisposeAt[realm] = DateTime.now();
    _pendingWebRtcDispose[realm] = disposeFuture;
  }

  Future<void> _awaitWebRtcDisposeCooldown(String realm) async {
    final pending = _pendingWebRtcDispose[realm];
    if (pending != null) {
      await pending.catchError((_) {});
    }
    final lastDispose = _lastWebRtcDisposeAt[realm];
    if (lastDispose == null) return;
    final remaining = _webRtcDisposeCooldown - DateTime.now().difference(lastDispose);
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
  }

  void _log(String message) {
    debugPrint('[DesktopSession ${DateTime.now().toIso8601String()}] $message');
  }

  DesktopConnection? get(String realm) {
    final key = 'session:$realm';
    final connection = _connections[key];
    if (connection != null && connection.session.isConnected()) {
      _log('cache hit realm=$realm p2p=${connection.isP2P} active=${_connections.length}');
      return connection;
    }
    if (connection != null) {
      _log('cache stale realm=$realm removing disconnected session');
    }
    _connections.remove(key);
    return null;
  }

  Future<DesktopConnection> acquire({
    required String realm,
    required String authId,
    required bool webRtcEnabled,
    required String privateKey,
  }) {
    _log('acquire realm=$realm webrtc=$webRtcEnabled');
    return connect(realm: realm, authId: authId, webRtcEnabled: webRtcEnabled, privateKey: privateKey);
  }

  Future<DesktopConnection> connect({
    required String realm,
    required String authId,
    required bool webRtcEnabled,
    required String privateKey,
  }) async {
    final pendingKey = 'session:$realm';
    final pending = _pendingConnections[pendingKey];
    if (pending != null) {
      _log('join pending connect realm=$realm webrtc=$webRtcEnabled');
      return pending;
    }

    final future = _connectInternal(realm: realm, authId: authId, webRtcEnabled: webRtcEnabled, privateKey: privateKey);
    _pendingConnections[pendingKey] = future;
    _recomputeReconnecting();

    try {
      return await future;
    } finally {
      if (_pendingConnections[pendingKey] == future) {
        _pendingConnections.remove(pendingKey);
        _recomputeReconnecting();
      }
    }
  }

  Future<DesktopConnection> _connectInternal({
    required String realm,
    required String authId,
    required bool webRtcEnabled,
    required String privateKey,
  }) async {
    final key = 'session:$realm';
    final existing = _connections[key];
    if (existing != null) {
      try {
        if (existing.session.isConnected()) {
          _log('reuse realm=$realm p2p=${existing.isP2P}');
          return existing;
        }
      } catch (_) {}
      _log('dropping disconnected cached session realm=$realm');
      await release(realm);
    }

    DesktopConnection connection;
    try {
      connection = await _negotiateConnection(
        realm: realm,
        authId: authId,
        webRtcEnabled: webRtcEnabled,
        privateKey: privateKey,
      );
    } catch (e) {
      if (webRtcEnabled && !kForceWebRtcOnly) {
        final failures = (_webRtcFailureCount[realm] ?? 0) + 1;
        _webRtcFailureCount[realm] = failures;
        if (failures >= _webRtcFailureFallbackThreshold) {
          _log('falling back to routed realm=$realm after $failures consecutive webrtc failures');
          return _connectInternal(realm: realm, authId: authId, webRtcEnabled: false, privateKey: privateKey);
        }
      }
      rethrow;
    }

    _connections[key] = connection;
    _everConnectedRealms.add(key);
    final previousIsP2P = _lastTransportIsP2P[realm];
    _lastTransportIsP2P[realm] = connection.isP2P;
    if (previousIsP2P != null && previousIsP2P != connection.isP2P) _transportChanges.add(connection.isP2P);
    _log('session cached realm=$realm p2p=${connection.isP2P} active=${_connections.length}');

    connection.session.onDisconnect(() {
      unawaited(_dropConnection(key, connection, reason: 'session disconnected'));
    });

    return connection;
  }

  Future<DesktopConnection> connectStandalone({
    required String realm,
    required String authId,
    required bool webRtcEnabled,
    required String privateKey,
  }) async {
    final connection = await _negotiateConnection(
      realm: realm,
      authId: authId,
      webRtcEnabled: webRtcEnabled,
      privateKey: privateKey,
    );
    _standaloneConnections.add(connection);
    _standaloneRealms[connection] = realm;
    return connection;
  }

  Future<void> releaseStandalone(DesktopConnection connection) async {
    _standaloneConnections.remove(connection);
    final disposeFuture = connection.dispose();
    final realm = _standaloneRealms[connection];
    if (connection.isP2P && realm != null) _markWebRtcDisposed(realm, disposeFuture);
    await disposeFuture;
  }

  Future<DesktopConnection> _negotiateConnection({
    required String realm,
    required String authId,
    required bool webRtcEnabled,
    required String privateKey,
  }) async {
    final willUseWebRtc = webRtcEnabled || kForceWebRtcOnly;

    if (willUseWebRtc && kForceWebRtcOnly && _noWebRtcSupportRealms.contains(realm)) {
      _log('connect skipped realm=$realm reason=known_no_webrtc_support');
      throw Exception('wamp.error.no_such_procedure (cached: desktop agent does not support WebRTC)');
    }

    _log('connect start realm=$realm webrtcPreferred=$webRtcEnabled');

    final client = WampClient();
    final signalingSession = await client.connectCryptoSignWithSerializer(
      authId: authId,
      privateKey: privateKey,
      realm: realm,
      serializer: CBORSerializer(),
    );

    if (!willUseWebRtc) {
      return DesktopConnection(session: signalingSession, isP2P: false);
    }

    await _awaitWebRtcDisposeCooldown(realm);
    if (!kIsWeb) {
      try {
        if (Platform.isAndroid) {
          await Helper.setAndroidAudioConfiguration(
            AndroidAudioConfiguration(manageAudioFocus: false, androidAudioMode: AndroidAudioMode.normal),
          );
        } else if (Platform.isIOS) {
          await Helper.setAppleAudioConfiguration(
            AppleAudioConfiguration(
              appleAudioCategory: AppleAudioCategory.playback,
              appleAudioCategoryOptions: {AppleAudioCategoryOption.mixWithOthers},
            ),
          );
        }
      } catch (e) {
        debugPrint('Failed to configure WebRTC audio: $e');
      }
    }

    try {
      final config = web_rtc.ClientConfig(
        realm: realm,
        procedureWebRTCOffer: DeskconnProcedures.webrtcOffer,
        topicAnswererOnCandidate: DeskconnProcedures.webrtcAnswererOnCandidate,
        topicOffererOnCandidate: DeskconnProcedures.webrtcOffererOnCandidate,
        iceServers: [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
        serializer: CBORSerializer(),
        session: signalingSession,
        authenticator: CryptoSignAuthenticator(authId, privateKey),
      );

      final connection = await _connectWampWithWebRTC(config);
      _webRtcFailureCount.remove(realm);
      _log('connect success realm=$realm transport=webrtc');
      return DesktopConnection(session: connection.session, isP2P: true, webRtcSession: connection.webRtcSession);
    } catch (e) {
      _log('connect failed realm=$realm webrtc_failed=$e');
      _markWebRtcDisposed(realm, Future<void>.value());
      try {
        await signalingSession.close();
      } catch (_) {}
      if (e.toString().contains('wamp.error.no_such_procedure')) {
        _noWebRtcSupportRealms.add(realm);
      }
      rethrow;
    }
  }

  Future<void> _handleNetworkChanged() async {
    _webRtcFailureCount.clear();
    await _runHeartbeat(strict: true);
  }

  bool _heartbeatRunning = false;
  bool _strictHeartbeatPending = false;
  final Expando<int> _heartbeatMisses = Expando();

  Future<void> _runHeartbeat({bool strict = false}) async {
    if (_heartbeatRunning) {
      if (strict) _strictHeartbeatPending = true;
      return;
    }
    _heartbeatRunning = true;
    try {
      final entries = _connections.entries.toList(growable: false);
      for (final entry in entries) {
        final key = entry.key;
        final connection = entry.value;
        if (_connections[key] != connection) continue;
        try {
          await connection.session.call(DeskconnProcedures.deskconndPing).timeout(_heartbeatTimeout);
          _heartbeatMisses[connection] = null;
        } catch (e) {
          if (_connections[key] != connection) continue;
          final misses = (_heartbeatMisses[connection] ?? 0) + 1;
          _heartbeatMisses[connection] = misses;
          final connected = connection.session.isConnected();
          _log('heartbeat failed key=$key strict=$strict connected=$connected misses=$misses error=$e');
          if (shouldDropAfterHeartbeatFailure(strict: strict, connected: connected, misses: misses)) {
            await _dropConnection(key, connection, reason: strict ? 'network changed' : 'heartbeat failed');
          }
        }
      }
    } finally {
      _heartbeatRunning = false;
      if (_strictHeartbeatPending) {
        _strictHeartbeatPending = false;
        unawaited(_runHeartbeat(strict: true));
      }
    }
  }

  Future<void> _dropConnection(String key, DesktopConnection connection, {required String reason}) async {
    if (_connections[key] != connection) return;
    _connections.remove(key);
    final realm = key.startsWith('session:') ? key.substring('session:'.length) : key;
    _log('$reason realm=$realm p2p=${connection.isP2P} active=${_connections.length}');
    connection.isAgentOnline = false;
    final disposeFuture = connection.dispose();
    if (connection.isP2P) _markWebRtcDisposed(realm, disposeFuture);
    unawaited(disposeFuture);
    connection.onDisconnected?.call();
  }

  Future<void> release(String realm) async {
    final key = 'session:$realm';
    final connection = _connections.remove(key);
    if (connection != null) {
      _log('release realm=$realm p2p=${connection.isP2P} remaining=${_connections.length}');
      final disposeFuture = connection.dispose();
      if (connection.isP2P) _markWebRtcDisposed(realm, disposeFuture);
      unawaited(disposeFuture);
      return;
    }

    final pending = _pendingConnections[key];
    if (pending != null) {
      _log('release realm=$realm pending=true');
      unawaited(
        pending.then((pendingConnection) async {
          if (_connections[key] == pendingConnection) _connections.remove(key);
          final disposeFuture = pendingConnection.dispose();
          if (pendingConnection.isP2P) _markWebRtcDisposed(realm, disposeFuture);
          unawaited(disposeFuture);
        }, onError: (_) {}),
      );
      return;
    }

    _log('release realm=$realm skipped=no_session');
  }

  bool isDeadSessionError(Session session, Object error) {
    return !(session.isConnected() && error is! TimeoutException);
  }

  Future<DesktopConnection> reacquire({
    required String realm,
    required String authId,
    required String privateKey,
    required bool webRtcEnabled,
  }) async {
    await release(realm);
    return acquire(realm: realm, authId: authId, privateKey: privateKey, webRtcEnabled: webRtcEnabled);
  }

  Future<void> invalidateAll() async {
    final realms = _connections.keys
        .map((key) => key.startsWith('session:') ? key.substring('session:'.length) : key)
        .toList(growable: false);
    for (final realm in realms) {
      await release(realm);
    }
    final standalones = List<DesktopConnection>.of(_standaloneConnections);
    _standaloneConnections.clear();
    for (final connection in standalones) {
      await connection.dispose();
    }
    _noWebRtcSupportRealms.clear();
    _webRtcFailureCount.clear();
    _everConnectedRealms.clear();
  }
}

class _WampWebRTCConnection {
  final Session session;
  final web_rtc.WebRTCSession webRtcSession;

  const _WampWebRTCConnection({required this.session, required this.webRtcSession});
}

class _PendingRemoteCandidate {
  final String requestID;
  final RTCIceCandidate candidate;

  const _PendingRemoteCandidate(this.requestID, this.candidate);
}

// flutter_webrtc's desktop plugin (Windows and Linux) never passes a data
// channel's protocol on -- every channel goes out as "sctp" -- so the agent
// can't recognise the WAMP channel by its subprotocol the way it does for
// mobile, and treats it as a raw file-stream channel instead. There the
// channel has to announce itself with a RawSocket-style handshake.
bool get _wampChannelNeedsHandshake => !kIsWeb && (Platform.isWindows || Platform.isLinux);

const int _rawSocketMagic = 0x7F;
const int _rawSocketCborSerializer = 3;
// Magic, then max message size (2^20, as an exponent above 2^9) and serializer.
const List<int> _wampChannelHandshakeBytes = [_rawSocketMagic, (11 << 4) | _rawSocketCborSerializer, 0, 0];

Future<void> _wampChannelHandshake(RTCDataChannel channel) async {
  final response = Completer<Uint8List>();
  channel.onMessage = (RTCDataChannelMessage message) {
    if (!response.isCompleted) response.complete(message.binary);
  };
  await channel.send(RTCDataChannelMessage.fromBinary(Uint8List.fromList(_wampChannelHandshakeBytes)));

  const timeout = Duration(seconds: 10);
  final reply = await response.future.timeout(
    timeout,
    onTimeout: () => throw TimeoutException('WAMP channel handshake did not complete', timeout),
  );
  if (reply.length != 4 || reply[0] != _rawSocketMagic || reply[1] & 0x0F != _rawSocketCborSerializer) {
    throw Exception('invalid WAMP channel handshake response');
  }
}

Future<_WampWebRTCConnection> _connectWampWithWebRTC(web_rtc.ClientConfig config) async {
  config.validate();

  final offerer = web_rtc.Offerer();
  var requestID = '';
  final pendingCandidates = <_PendingRemoteCandidate>[];

  final offerConfig = web_rtc.OfferConfig(
    protocol: 'wamp.2.cbor',
    iceServers: config.iceServers!,
    ordered: true,
    id: 0,
    topicAnswererOnCandidate: config.topicAnswererOnCandidate,
    additionalChannels: ['shell', kVpnChannelLabel, ...fileStreamChannelLabels()],
    channelOptions: {
      kVpnChannelLabel: RTCDataChannelInit()
        ..ordered = false
        ..maxRetransmits = 2,
    },
  );

  offerer.waitReady().ignore();
  for (final label in offerConfig.additionalChannels) {
    offerer.extraChannel(label).ignore();
  }

  final offerFuture = offerer.offer(offerConfig);
  offerFuture.ignore();
  final subscription = await config.session.subscribe(config.topicOffererOnCandidate, (Event event) async {
    if (event.args.length < 2) return;

    final candidateRequestID = event.args[0] as String?;
    if (candidateRequestID == null) return;

    final candidateMap = jsonDecode(event.args[1] as String) as Map<String, dynamic>;
    final candidate = RTCIceCandidate(
      candidateMap['candidate'] as String?,
      candidateMap['sdpMid'] as String?,
      candidateMap['sdpMLineIndex'] as int?,
    );

    if (requestID.isEmpty) {
      pendingCandidates.add(_PendingRemoteCandidate(candidateRequestID, candidate));
      return;
    }
    if (candidateRequestID != requestID) return;

    try {
      await offerer.addICECandidate(candidate);
    } catch (e) {
      debugPrint('Failed to add WebRTC ICE candidate: $e');
    }
  });

  Future<_WampWebRTCConnection> negotiate() async {
    final offer = await offerFuture;
    final callResponse = await config.session.call(config.procedureWebRTCOffer, args: [jsonEncode(offer)]);
    final offerResponse = web_rtc.OfferResponse.fromJson(jsonDecode(callResponse.args[0] as String));

    if (offerResponse.requestID.isEmpty) {
      throw Exception('offer response request ID must not be empty');
    }
    requestID = offerResponse.requestID;

    final buffered = List<_PendingRemoteCandidate>.from(pendingCandidates);
    pendingCandidates.clear();
    for (final pending in buffered) {
      if (pending.requestID != requestID) continue;
      try {
        await offerer.addICECandidate(pending.candidate);
      } catch (e) {
        debugPrint('Failed to add buffered WebRTC ICE candidate: $e');
      }
    }

    offerer.startICETrickle(config.session, offerConfig.topicAnswererOnCandidate, requestID);
    await offerer.handleAnswer(offerResponse.answer);
    final channel = await offerer.waitReady();
    if (_wampChannelNeedsHandshake) await _wampChannelHandshake(channel);

    final webRtcSession = web_rtc.WebRTCSession(
      connection: offerer.connection!,
      channel: channel,
      incomingChannels: offerer.incomingChannels,
      extraChannel: offerer.extraChannel,
    );
    final base = await joinPeer(
      WebRTCClosePeer(web_rtc.WebRTCPeer(channel)),
      config.realm,
      config.serializer!,
      config.authenticator!,
    );
    return _WampWebRTCConnection(session: Session(base), webRtcSession: webRtcSession);
  }

  try {
    return await negotiate().timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw TimeoutException('WebRTC connect did not complete', const Duration(seconds: 20)),
    );
  } catch (_) {
    await offerer.connection?.dispose();
    rethrow;
  } finally {
    unawaited(subscription.unsubscribe().catchError((_) {}));
  }
}
