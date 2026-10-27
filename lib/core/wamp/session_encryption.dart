import 'dart:convert';
import 'dart:typed_data';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_encryption.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';

Uint8List coerceBytes(dynamic raw) {
  if (raw is Uint8List) return raw;
  if (raw is List<int>) return Uint8List.fromList(raw);
  if (raw is List) return Uint8List.fromList(raw.map((v) => (v as num).toInt()).toList());
  if (raw is String) return Uint8List.fromList(base64.decode(raw));
  throw FormatException('Unsupported payload type: ${raw.runtimeType}');
}

bool isKeysRejectedError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('no session keys found') || text.contains('failed to decrypt');
}

class SessionEncryption {
  SessionEncryption._(this.session, this.keyExchangeProcedure);

  static final Expando<SessionEncryption> _deskconnd = Expando();

  static final Expando<SessionEncryption> _remoteControl = Expando();

  static final Expando<SessionEncryption> _media = Expando();

  static SessionEncryption deskconnd(Session session) =>
      _deskconnd[session] ??= SessionEncryption._(session, DeskconnProcedures.deskconndKeyExchange);

  static SessionEncryption remoteControl(Session session) =>
      _remoteControl[session] ??= SessionEncryption._(session, DeskconnProcedures.deskconndRemoteControlKeyExchange);

  /// media-app's keys, for its index query (Pictures, Videos, Documents).
  static SessionEncryption media(Session session) =>
      _media[session] ??= SessionEncryption._(session, DeskconnProcedures.deskconndMediaKeyExchange);

  final Session session;
  final String keyExchangeProcedure;
  Future<Encryption>? _keys;
  Encryption? _current;

  Future<Encryption> keys() => _keys ??= _exchange();

  void invalidate(Encryption stale) {
    if (!identical(_current, stale)) return;
    _current = null;
    _keys = null;
  }

  Future<Encryption> _exchange() async {
    try {
      final encryption = await Encryption.create();
      final res = await session
          .call(keyExchangeProcedure, args: [encryption.clientPublicKey])
          .timeout(DeskconnConfig.callTimeout);
      if (res.args.isEmpty) throw Exception('Key exchange failed: empty response');
      final serverKey = coerceBytes(res.args[0]);
      final keyPayload = serverKey.length == 32
          ? Uint8List.fromList([...utf8.encode('KEY:'), ...serverKey])
          : serverKey;
      await encryption.acceptServerKey(keyPayload);
      return _current = encryption;
    } catch (_) {
      _keys = null;
      rethrow;
    }
  }

  Future<dynamic> call(String procedure, {Object? arg, Duration timeout = DeskconnConfig.callTimeout}) async {
    for (var attempt = 0; ; attempt++) {
      final encryption = await keys();
      final args = arg == null ? <Object>[] : <Object>[encryption.encrypt(utf8.encode(jsonEncode(arg)))];
      try {
        final res = await session.call(procedure, args: args).timeout(timeout);
        if (res.args.isEmpty) throw Exception('Empty response from $procedure');
        return jsonDecode(utf8.decode(encryption.decrypt(coerceBytes(res.args[0]))));
      } catch (e) {
        if (attempt == 0 && isKeysRejectedError(e)) {
          invalidate(encryption);
          continue;
        }
        rethrow;
      }
    }
  }
}
