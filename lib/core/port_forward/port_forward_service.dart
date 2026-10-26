import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as web_rtc;

import 'port_channel.dart';

void _log(String message) {
  debugPrint('[PortForward ${DateTime.now().toIso8601String()}] $message');
}

const String _opListen = 'listen';
const String _opConnect = 'connect';
const String _opClose = 'close';

Future<void> _pumpChunks(PortChannel channel, Uint8List bytes) async {
  for (var offset = 0; offset < bytes.length; offset += portChunkSize) {
    final end = offset + portChunkSize < bytes.length ? offset + portChunkSize : bytes.length;
    await channel.waitForSendReady();
    await channel.sendData(Uint8List.sublistView(bytes, offset, end));
  }
}

class PortForwardSession {
  PortForwardSession._(this._server, this._session, this.localPort, this.remotePort, this._onChanged, this._onError);

  final ServerSocket _server;
  final web_rtc.WebRTCSession _session;
  final int localPort;
  final int remotePort;
  final VoidCallback? _onChanged;
  final void Function(Object error)? _onError;

  final Set<Socket> _sockets = {};
  StreamSubscription<Socket>? _accepts;
  bool _stopped = false;

  int get connections => _sockets.length;

  static Future<PortForwardSession> start({
    required web_rtc.WebRTCSession session,
    required int localPort,
    required int remotePort,
    VoidCallback? onChanged,
    void Function(Object error)? onError,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, localPort);
    final forward = PortForwardSession._(server, session, localPort, remotePort, onChanged, onError);
    forward._accepts = server.listen(
      (socket) => unawaited(forward._accept(socket)),
      onError: (Object e) => onError?.call(e),
    );
    return forward;
  }

  Future<void> _accept(Socket socket) async {
    _log('accepted local connection on port $localPort, opening channel to remote $remotePort');
    if (_stopped) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
    _onChanged?.call();
    try {
      await _forward(socket);
    } catch (e) {
      _log('forward failed: $e');
      _onError?.call(e);
    } finally {
      _sockets.remove(socket);
      _onChanged?.call();
    }
  }

  Future<void> _forward(Socket socket) async {
    final PortChannel channel;
    try {
      channel = await PortChannel.open(_session, portForwardChannelLabel);
    } catch (e) {
      _log('opening portforward channel failed: $e');
      socket.destroy();
      rethrow;
    }

    final ack = Completer<void>();
    final done = Completer<void>();

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final channelEvents = channel.events.listen(
      (envelope) {
        if (envelope.kind == portMsgControl) {
          if (ack.isCompleted) return;
          try {
            final message = jsonDecode(utf8.decode(envelope.data)) as Map<String, dynamic>;
            final error = message['error'] as String?;
            if (error != null && error.isNotEmpty) {
              ack.completeError(PortStreamException(error));
            } else {
              ack.complete();
            }
          } catch (e) {
            ack.completeError(e);
          }
          return;
        }
        try {
          socket.add(envelope.data);
        } catch (_) {
          finish();
        }
      },
      onError: (Object e) {
        if (!ack.isCompleted) ack.completeError(e);
        finish();
      },
      onDone: () {
        if (!ack.isCompleted) {
          ack.completeError(PortStreamException('desktop closed the port forward channel'));
        }
        finish();
      },
    );

    Future<void> cleanup() async {
      await channelEvents.cancel();
      socket.destroy();
      await channel.close();
    }

    try {
      await channel.sendControl({'port': '$remotePort'});
      await ack.future.timeout(portRequestTimeout);
      _log('desktop dialed port $remotePort, relaying');
    } catch (e) {
      _log('dial ack for port $remotePort failed: $e');
      await cleanup();
      throw PortStreamException('could not reach port $remotePort on the desktop: $e');
    }

    late StreamSubscription<Uint8List> socketData;
    socketData = socket.listen(
      (bytes) => socketData.pause(_pumpChunks(channel, bytes).catchError((Object _) => finish())),
      onError: (Object _) => finish(),
      onDone: finish,
      cancelOnError: true,
    );

    channel.startPing();
    await done.future;
    await socketData.cancel();
    await cleanup();
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _accepts?.cancel();
    try {
      await _server.close();
    } catch (_) {}
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
  }
}

class PortReverseSession {
  PortReverseSession._(this._channel, this.remotePort, this.localPort, this._onChanged);

  final PortChannel _channel;
  final int remotePort;
  final int localPort;
  final VoidCallback? _onChanged;

  final Map<int, Socket> _sockets = {};
  StreamSubscription<PortEnvelope>? _events;
  Future<void> _handling = Future<void>.value();
  bool _stopped = false;

  int get connections => _sockets.length;

  static Future<PortReverseSession> start({
    required web_rtc.WebRTCSession session,
    required int remotePort,
    required int localPort,
    VoidCallback? onChanged,
    void Function(Object error)? onError,
    VoidCallback? onClosed,
  }) async {
    final channel = await PortChannel.open(session, portReverseChannelLabel);
    final reverse = PortReverseSession._(channel, remotePort, localPort, onChanged);
    final ack = Completer<void>();

    reverse._events = channel.events.listen(
      (envelope) {
        reverse._handling = reverse._handling
            .then((_) => reverse._handle(envelope, ack, onError))
            .catchError((Object _) {});
      },
      onError: (Object e) {
        if (!ack.isCompleted) ack.completeError(e);
        unawaited(reverse.stop());
        onClosed?.call();
      },
      onDone: () {
        if (!ack.isCompleted) {
          ack.completeError(PortStreamException('desktop closed the port reverse channel'));
        }
        unawaited(reverse.stop());
        onClosed?.call();
      },
    );

    try {
      await channel.sendControl({'op': _opListen, 'remote_port': '$remotePort'});
      await ack.future.timeout(portRequestTimeout);
    } catch (e) {
      await reverse.stop();
      throw PortStreamException('desktop could not listen on port $remotePort: $e');
    }

    channel.startPing();
    return reverse;
  }

  Future<void> _handle(PortEnvelope envelope, Completer<void> ack, void Function(Object error)? onError) async {
    if (envelope.kind == portMsgData) {
      final decoded = decodeConnData(envelope.data);
      if (decoded == null) return;
      try {
        _sockets[decoded.connId]?.add(decoded.payload);
      } catch (_) {}
      return;
    }

    final Map<String, dynamic> message;
    try {
      message = jsonDecode(utf8.decode(envelope.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final op = message['op'] as String?;
    final error = message['error'] as String?;

    if (!ack.isCompleted) {
      if (error != null && error.isNotEmpty) {
        ack.completeError(PortStreamException(error));
      } else {
        ack.complete();
      }
      return;
    }

    final connId = (message['conn_id'] as num?)?.toInt() ?? 0;
    switch (op) {
      case _opConnect:
        await _dialLocal(connId, onError);
      case _opClose:
        final socket = _sockets.remove(connId);
        socket?.destroy();
        _onChanged?.call();
    }
  }

  Future<void> _dialLocal(int connId, void Function(Object error)? onError) async {
    if (_stopped) return;
    final Socket socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, localPort);
    } catch (e) {
      onError?.call(PortStreamException('nothing is listening on local port $localPort: $e'));
      unawaited(_channel.sendControl({'op': _opClose, 'conn_id': connId}).catchError((Object _) {}));
      return;
    }

    if (_stopped) {
      socket.destroy();
      return;
    }

    _sockets[connId] = socket;
    _onChanged?.call();

    late StreamSubscription<Uint8List> data;
    data = socket.listen(
      (bytes) => data.pause(_pumpTagged(connId, bytes).catchError((Object _) => _dropLocal(connId))),
      onError: (Object _) => _dropLocal(connId),
      onDone: () => _dropLocal(connId),
      cancelOnError: true,
    );
  }

  Future<void> _pumpTagged(int connId, Uint8List bytes) async {
    for (var offset = 0; offset < bytes.length; offset += portChunkSize) {
      final end = offset + portChunkSize < bytes.length ? offset + portChunkSize : bytes.length;
      await _channel.waitForSendReady();
      await _channel.sendData(encodeConnData(connId, Uint8List.sublistView(bytes, offset, end)));
    }
  }

  void _dropLocal(int connId) {
    final socket = _sockets.remove(connId);
    if (socket == null) return;
    socket.destroy();
    _onChanged?.call();
    if (_stopped) return;
    unawaited(_channel.sendControl({'op': _opClose, 'conn_id': connId}).catchError((Object _) {}));
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _events?.cancel();
    for (final socket in _sockets.values) {
      socket.destroy();
    }
    _sockets.clear();
    await _channel.close();
  }
}
