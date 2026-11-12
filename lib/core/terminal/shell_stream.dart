import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:deskconn_mobile_app/core/wamp/core_client.dart';

import 'terminal_encryption.dart';

const int _kindControl = 0;
const int _kindData = 1;
const Duration _requestTimeout = Duration(seconds: 15);
const Duration _pingInterval = Duration(seconds: 10);
const Duration _closeTimeout = Duration(seconds: 5);
const int _maxFrameSize = 16 * 1024 * 1024;

class ShellStreamException implements Exception {
  ShellStreamException(this.message);

  final String message;

  @override
  String toString() => message;
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

// Each shell owns its RPC stream, while the WAMP session may be shared by tabs.
Future<ShellHandle> openShell(
  Session session,
  int cols,
  int rows,
  void Function(Uint8List data) onData,
  void Function() onClose, {
  bool closeSession = false,
}) async {
  final stream = await session.openRPCStream('io.xconn.deskconn.shell.stream');
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
      if (closeSession) await session.close().timeout(_closeTimeout);
    } catch (_) {}
  }

  final Map<String, dynamic> ack;
  try {
    await stream.writeAll(frame(utf8.encode(jsonEncode({'public_key': base64Encode(enc.clientPublicKey)}))));

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
