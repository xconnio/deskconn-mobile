import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as web_rtc;

import 'terminal_encryption.dart';

const int _kindControl = 0;
const int _kindData = 1;
const Duration _requestTimeout = Duration(seconds: 15);
const Duration _pingInterval = Duration(seconds: 10);
const Duration _closeTimeout = Duration(seconds: 5);
const int _maxFrameSize = 16 * 1024 * 1024;
const String shellChannelLabel = 'shell';

class ShellStreamException implements Exception {
  ShellStreamException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ShellChannelUnavailableException extends ShellStreamException {
  ShellChannelUnavailableException() : super('shell channel is not open');
}

class ShellHandle {
  ShellHandle({
    required this.shellId,
    required void Function(Uint8List bytes) send,
    required void Function(int cols, int rows) resize,
    required Future<void> Function() close,
  }) : _send = send,
       _resize = resize,
       _close = close;

  final String shellId;
  final void Function(Uint8List bytes) _send;
  final void Function(int cols, int rows) _resize;
  final Future<void> Function() _close;

  void send(Uint8List bytes) => _send(bytes);
  void resize(int cols, int rows) => _resize(cols, rows);
  Future<void> close() => _close();
}

Future<ShellHandle> openShell(
  web_rtc.WebRTCSession session,
  int cols,
  int rows,
  void Function(Uint8List data) onData,
  void Function() onClose,
) async {
  final channel = await session.extraChannel(shellChannelLabel);
  if (channel.state != ChannelState.open) {
    throw ShellChannelUnavailableException();
  }
  final enc = await Encryption.create();
  final peerKeyCompleter = Completer<Uint8List>();
  final ackCompleter = Completer<Map<String, dynamic>>();
  var closedByUs = false;
  Timer? pingTimer;

  Uint8List envelope(int kind, List<int> plaintext) {
    return Uint8List.fromList([kind, ...enc.encrypt(plaintext)]);
  }

  void sendControl(Map<String, dynamic> msg) {
    try {
      channel.send(ChannelMessage.fromBinary(envelope(_kindControl, utf8.encode(jsonEncode(msg)))));
    } catch (_) {}
  }

  Future<void> closeChannel() async {
    if (closedByUs) return;
    closedByUs = true;
    pingTimer?.cancel();
    try {
      await channel.close();
    } catch (_) {}
  }

  channel.onMessage = (ChannelMessage msg) {
    if (!peerKeyCompleter.isCompleted) {
      if (msg.isBinary) {
        peerKeyCompleter.completeError(ShellStreamException('expected plaintext key-exchange frame first'));
        return;
      }
      try {
        final peerKeyB64 = (jsonDecode(msg.text) as Map<String, dynamic>)['public_key'] as String;
        peerKeyCompleter.complete(base64Decode(peerKeyB64));
      } catch (e) {
        peerKeyCompleter.completeError(e);
      }
      return;
    }

    if (!msg.isBinary || msg.binary.isEmpty) return;
    final kind = msg.binary[0];
    final Uint8List plaintext;
    try {
      plaintext = enc.decrypt(msg.binary.sublist(1));
    } catch (_) {
      return;
    }

    if (kind == _kindControl) {
      if (!ackCompleter.isCompleted) {
        ackCompleter.complete(jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>);
      }
      return;
    }
    if (kind == _kindData) onData(plaintext);
  };

  channel.onDataChannelState = (state) {
    if (state == ChannelState.closing || state == ChannelState.closed) {
      pingTimer?.cancel();
      if (!peerKeyCompleter.isCompleted) {
        peerKeyCompleter.completeError(ShellStreamException('shell channel closed before key exchange'));
      }
      if (!ackCompleter.isCompleted) {
        ackCompleter.completeError(ShellStreamException('shell channel closed before it started'));
      }
      if (closedByUs) return;
      closedByUs = true;
      onClose();
    }
  };

  await channel.send(ChannelMessage(jsonEncode({'public_key': base64Encode(enc.clientPublicKey)})));
  final peerKey = await peerKeyCompleter.future.timeout(_requestTimeout);
  await enc.acceptServerKey(Uint8List.fromList([...utf8.encode('KEY:'), ...peerKey]));

  sendControl({'op': 'size', 'cols': cols, 'rows': rows});

  final ack = await ackCompleter.future.timeout(_requestTimeout);
  final error = ack['error'] as String?;
  if (error != null) {
    await closeChannel();
    throw ShellStreamException(error);
  }

  pingTimer = Timer.periodic(_pingInterval, (_) => sendControl({'op': 'ping'}));

  return ShellHandle(
    shellId: ack['shell_id'] as String? ?? '',
    send: (bytes) {
      try {
        channel.send(ChannelMessage.fromBinary(envelope(_kindData, bytes)));
      } catch (_) {}
    },
    resize: (c, r) => sendControl({'op': 'size', 'cols': c, 'rows': r}),
    close: closeChannel,
  );
}

// The routed counterpart to openShell, for a desktop with no P2P connection:
// the same envelopes, but length-prefixed on a raw QUIC stream the router
// relays to the desktop. Takes ownership of session (a connection dialled
// into the desktop's realm for this shell alone) and closes it with the shell.
Future<ShellHandle> openRoutedShell(
  QUICSession session,
  String realm,
  int cols,
  int rows,
  void Function(Uint8List data) onData,
  void Function() onClose,
) async {
  final stream = await session.openStream();
  final enc = await Encryption.create();
  var closed = false;
  Timer? pingTimer;
  Future<void> pendingWrite = Future.value();

  Uint8List frame(List<int> payload) {
    final framed = Uint8List(4 + payload.length);
    ByteData.sublistView(framed).setUint32(0, payload.length);
    framed.setRange(4, framed.length, payload);
    return framed;
  }

  Future<Uint8List> readFrame() async {
    final header = await stream.readExact(4);
    if (header.length != 4) throw ShellStreamException('shell stream closed');
    final length = ByteData.sublistView(header).getUint32(0);
    if (length > _maxFrameSize) throw ShellStreamException('shell frame too large: $length bytes');
    if (length == 0) return Uint8List(0);
    return stream.readExact(length);
  }

  Uint8List envelope(int kind, List<int> plaintext) {
    return frame([kind, ...enc.encrypt(plaintext)]);
  }

  // Typing, resizes and pings all write to the one stream; chaining keeps
  // their frames from interleaving.
  void send(Uint8List framed) {
    if (closed) return;
    pendingWrite = pendingWrite.then((_) => stream.writeAll(framed)).catchError((Object _) {});
  }

  void sendControl(Map<String, dynamic> msg) => send(envelope(_kindControl, utf8.encode(jsonEncode(msg))));

  Future<void> closeStream() async {
    if (closed) return;
    closed = true;
    pingTimer?.cancel();
    try {
      await stream.close();
    } catch (_) {}
    try {
      await session.close().timeout(_closeTimeout);
    } catch (_) {}
  }

  final Map<String, dynamic> ack;
  try {
    await stream.writeAll(frame(utf8.encode(jsonEncode({'realm': realm, 'op': 'shell', 'path': ''}))));
    await stream.writeAll(frame(utf8.encode(jsonEncode({'public_key': base64Encode(enc.clientPublicKey)}))));

    // The router answers in the device's place when it can't relay the stream.
    final reply = jsonDecode(utf8.decode(await readFrame().timeout(_requestTimeout))) as Map<String, dynamic>;
    final relayError = reply['error'] as String?;
    if (relayError != null && relayError.isNotEmpty) throw ShellStreamException(relayError);
    await enc.acceptServerKey([...utf8.encode('KEY:'), ...base64Decode(reply['public_key'] as String)]);

    await stream.writeAll(envelope(_kindControl, utf8.encode(jsonEncode({'op': 'size', 'cols': cols, 'rows': rows}))));
    final ackFrame = await readFrame().timeout(_requestTimeout);
    if (ackFrame.isEmpty || ackFrame[0] != _kindControl) throw ShellStreamException('unexpected shell response');
    ack = jsonDecode(utf8.decode(enc.decrypt(ackFrame.sublist(1)))) as Map<String, dynamic>;
    final error = ack['error'] as String?;
    if (error != null && error.isNotEmpty) throw ShellStreamException(error);
  } catch (_) {
    await closeStream();
    rethrow;
  }

  unawaited(() async {
    try {
      while (true) {
        final message = await readFrame();
        if (message.isEmpty) continue;
        final Uint8List plaintext;
        try {
          plaintext = enc.decrypt(message.sublist(1));
        } catch (_) {
          continue;
        }
        if (message[0] == _kindData) onData(plaintext);
      }
    } catch (_) {
      // The desktop closes the stream once the PTY exits, which is how a
      // session normally ends.
    }
    if (closed) return;
    await closeStream();
    onClose();
  }());

  pingTimer = Timer.periodic(_pingInterval, (_) => sendControl({'op': 'ping'}));

  return ShellHandle(
    shellId: ack['shell_id'] as String? ?? '',
    send: (bytes) => send(envelope(_kindData, bytes)),
    resize: (c, r) => sendControl({'op': 'size', 'cols': c, 'rows': r}),
    close: closeStream,
  );
}
