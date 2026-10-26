import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as web_rtc;

import 'package:deskconn_mobile_app/core/terminal/terminal_encryption.dart';

void _log(String message) {
  debugPrint('[PortChannel ${DateTime.now().toIso8601String()}] $message');
}

const String portForwardChannelLabel = 'portforward';
const String portReverseChannelLabel = 'portreverse';

const int portMsgControl = 0;
const int portMsgData = 1;

const Duration portRequestTimeout = Duration(seconds: 15);
const Duration portPingInterval = Duration(seconds: 10);

const int portChunkSize = 32 * 1024;

const int _sendBufferHighWater = 512 * 1024;
const int _sendBufferLowWater = 256 * 1024;

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
  PortChannel._(this._channel, this._enc, this._events);

  final AppDataChannel _channel;
  final Encryption _enc;
  final StreamController<PortEnvelope> _events;

  Timer? _pingTimer;
  bool _closed = false;

  Stream<PortEnvelope> get events => _events.stream;

  bool get isClosed => _closed;

  static Future<PortChannel> open(web_rtc.WebRTCSession session, String label) async {
    _log("opening '$label' channel");
    final channel = await _createChannel(session, label);
    _log("'$label' channel open, starting key exchange");
    final enc = await Encryption.create();
    final peerKeyCompleter = Completer<Uint8List>();
    final events = StreamController<PortEnvelope>();

    channel.onMessage = (ChannelMessage msg) {
      if (!peerKeyCompleter.isCompleted) {
        if (msg.isBinary) {
          peerKeyCompleter.completeError(PortStreamException('expected plaintext key-exchange frame first'));
          return;
        }
        try {
          final encoded = (jsonDecode(msg.text) as Map<String, dynamic>)['public_key'] as String;
          peerKeyCompleter.complete(base64Decode(encoded));
        } catch (e) {
          peerKeyCompleter.completeError(e);
        }
        return;
      }

      if (!msg.isBinary || msg.binary.isEmpty) return;
      try {
        final plaintext = enc.decrypt(msg.binary.sublist(1));
        if (!events.isClosed) events.add(PortEnvelope(msg.binary[0], plaintext));
      } catch (_) {}
    };

    channel.onDataChannelState = (state) {
      if (state != ChannelState.closing && state != ChannelState.closed) {
        return;
      }
      if (!peerKeyCompleter.isCompleted) {
        peerKeyCompleter.completeError(PortStreamException("'$label' channel closed before key exchange"));
      }
      if (!events.isClosed) unawaited(events.close());
    };

    try {
      await channel.send(ChannelMessage(jsonEncode({'public_key': base64Encode(enc.clientPublicKey)})));
      final peerKey = await peerKeyCompleter.future.timeout(portRequestTimeout);
      await enc.acceptServerKey(Uint8List.fromList([...utf8.encode('KEY:'), ...peerKey]));
      _log("'$label' key exchange done");
    } catch (e) {
      _log("'$label' key exchange failed: $e");
      try {
        await channel.close();
      } catch (_) {}
      if (!events.isClosed) unawaited(events.close());
      rethrow;
    }

    return PortChannel._(channel, enc, events);
  }

  static Future<AppDataChannel> _createChannel(web_rtc.WebRTCSession session, String label) async {
    final channel = await session.openChannel(label, ChannelOptions()..ordered = true);
    _log("'$label' createDataChannel returned, initial state=${channel.state}");

    channel.onDataChannelState = (state) {
      _log("'$label' state event: $state");
    };

    return channel;
  }

  Future<void> sendControl(Map<String, dynamic> message) {
    return _send(portMsgControl, utf8.encode(jsonEncode(message)));
  }

  Future<void> sendData(List<int> payload) {
    return _send(portMsgData, payload);
  }

  Future<void> _send(int kind, List<int> plaintext) async {
    if (_closed) throw PortStreamException('channel is closed');
    await _channel.send(ChannelMessage.fromBinary(Uint8List.fromList([kind, ..._enc.encrypt(plaintext)])));
  }

  void startPing() {
    _pingTimer ??= Timer.periodic(portPingInterval, (_) {
      if (_closed) return;
      unawaited(sendControl(const {}).catchError((_) {}));
    });
  }

  Future<void> waitForSendReady() async {
    if ((_channel.bufferedAmount ?? 0) <= _sendBufferHighWater) return;
    await _channel.waitBufferedBelow(_sendBufferLowWater).timeout(portRequestTimeout);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel();
    try {
      await _channel.close();
    } catch (_) {}
    if (!_events.isClosed) unawaited(_events.close());
  }
}
