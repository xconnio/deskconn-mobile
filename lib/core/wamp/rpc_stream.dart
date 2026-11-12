import 'dart:convert';
import 'dart:typed_data';

import '../terminal/terminal_encryption.dart';
import 'core_client.dart';

/// DeskConn encryption and framing inside a WAMP-authorized byte stream.
class RPCFeatureStream {
  RPCFeatureStream._(this._stream, this._encryption);

  final RPCByteStream _stream;
  final Encryption _encryption;
  Future<void> _writes = Future.value();

  static Future<RPCFeatureStream> open(Session session, String procedure, {bool input = false}) async {
    final stream = await session.openRPCStream(procedure, input: input);
    final result = RPCFeatureStream._(stream, await Encryption.create());
    try {
      await result.writeFrame(
        utf8.encode(jsonEncode({'public_key': base64Encode(result._encryption.clientPublicKey)})),
      );
      final key =
          jsonDecode(utf8.decode(await result.readFrame().timeout(const Duration(seconds: 15))))
              as Map<String, dynamic>;
      await result._encryption.acceptServerKey([...utf8.encode('KEY:'), ...base64Decode(key['public_key'] as String)]);
      return result;
    } catch (_) {
      await stream.close();
      rethrow;
    }
  }

  Future<Uint8List> readFrame() async {
    final header = await _stream.readExact(4);
    final length = ByteData.sublistView(header).getUint32(0);
    if (length > 16 * 1024 * 1024) throw StateError('RPC feature frame exceeds 16 MiB');
    return _stream.readExact(length);
  }

  Future<void> writeFrame(List<int> payload) {
    final frame = Uint8List(4 + payload.length);
    ByteData.sublistView(frame).setUint32(0, payload.length);
    frame.setRange(4, frame.length, payload);
    return _writes = _writes.then((_) => _stream.writeAll(frame));
  }

  Future<Uint8List> readEncrypted() async => _encryption.decrypt(await readFrame());

  Future<void> writeEncrypted(List<int> payload) => writeFrame(_encryption.encrypt(payload));

  Future<({int kind, Uint8List data})> readEnvelope() async {
    final frame = await readFrame();
    if (frame.isEmpty) throw StateError('Empty feature envelope');
    return (kind: frame[0], data: _encryption.decrypt(frame.sublist(1)));
  }

  Future<void> writeEnvelope(int kind, List<int> payload) => writeFrame([kind, ..._encryption.encrypt(payload)]);

  Future<void> close() => _stream.close();
}
