import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../wamp/core_client.dart';
import '../wamp/rpc_stream.dart';

const String portForwardChannelLabel = 'portforward';
const String portReverseChannelLabel = 'portreverse';

const int portMsgControl = 0;
const int portMsgData = 1;

const Duration portRequestTimeout = Duration(seconds: 15);
const Duration portPingInterval = Duration(seconds: 10);

const int portChunkSize = 32 * 1024;

class PortStreamException implements Exception {
  PortStreamException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PortEnvelope {
  PortEnvelope(this.kind, this.data);

  final int kind;
  final Uint8List data;
}

Uint8List encodeConnData(int connId, List<int> payload) {
  final buffer = Uint8List(8 + payload.length);
  ByteData.view(buffer.buffer).setUint64(0, connId, Endian.big);
  buffer.setRange(8, buffer.length, payload);
  return buffer;
}

({int connId, Uint8List payload})? decodeConnData(Uint8List data) {
  if (data.length < 8) return null;
  final connId = ByteData.view(data.buffer, data.offsetInBytes, 8).getUint64(0, Endian.big);
  return (connId: connId, payload: Uint8List.sublistView(data, 8));
}

class PortChannel {
  PortChannel._(this._stream) {
    unawaited(_read());
  }

  final RPCFeatureStream _stream;
  final _events = StreamController<PortEnvelope>();
  Timer? _pingTimer;
  bool _closed = false;

  Stream<PortEnvelope> get events => _events.stream;

  bool get isClosed => _closed;

  static Future<PortChannel> open(Session session, String operation) async {
    final procedure = switch (operation) {
      portForwardChannelLabel => 'io.xconn.deskconn.port.forward.stream',
      portReverseChannelLabel => 'io.xconn.deskconn.port.reverse.stream',
      _ => throw ArgumentError.value(operation, 'operation'),
    };
    return PortChannel._(await RPCFeatureStream.open(session, procedure));
  }

  Future<void> _read() async {
    try {
      while (!_closed) {
        final envelope = await _stream.readEnvelope();
        if (!_closed) _events.add(PortEnvelope(envelope.kind, envelope.data));
      }
    } catch (error, stack) {
      if (!_closed) _events.addError(error, stack);
    } finally {
      await close();
    }
  }

  Future<void> sendControl(Map<String, dynamic> message) => _send(portMsgControl, utf8.encode(jsonEncode(message)));

  Future<void> sendData(List<int> payload) => _send(portMsgData, payload);

  Future<void> _send(int kind, List<int> payload) async {
    if (_closed) throw PortStreamException('Port stream is closed');
    await _stream.writeEnvelope(kind, payload);
  }

  void startPing() {
    _pingTimer ??= Timer.periodic(portPingInterval, (_) {
      if (!_closed) unawaited(sendControl(const {}).catchError((Object _) {}));
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel();
    try {
      await _stream.close();
    } finally {
      unawaited(_events.close());
    }
  }
}
