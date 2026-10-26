import 'package:deskconn_mobile_app/core/wamp/quic_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';

class WampClient {
  Session? _session;

  Session get session => _session!;

  Future<Session> connectCra({required String email, required String password, required String realm}) async {
    _session = await QUICConnectionManager().openSession(
      realm,
      QUICDialerConfig(authenticator: WAMPCRAAuthenticator(email, password), serializer: CBORSerializer()),
    );
    return _session!;
  }

  Future<Session> connectCryptoSign({required String authId, required String privateKey, required String realm}) async {
    _session = await QUICConnectionManager().openSession(
      realm,
      QUICDialerConfig(authenticator: CryptoSignAuthenticator(authId, privateKey), serializer: CBORSerializer()),
    );
    return _session!;
  }

  Future<Session> connectCryptoSignWithSerializer({
    required String authId,
    required String privateKey,
    required String realm,
    required Serializer serializer,
  }) async {
    _session = await QUICConnectionManager().openSession(
      realm,
      QUICDialerConfig(authenticator: CryptoSignAuthenticator(authId, privateKey), serializer: serializer),
    );
    return _session!;
  }

  Future<void> disconnect() async {
    await _session?.close();
    _session = null;
  }
}
