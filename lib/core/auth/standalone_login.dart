import 'dart:async';
import 'dart:convert';

import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StandaloneLogin {
  const StandaloneLogin({
    required this.address,
    required this.authId,
    this.password,
    this.privateKey,
    required this.certificateFingerprint,
  });

  final String address;
  final String authId;
  final String? password;
  final String? privateKey;
  final String certificateFingerprint;

  static const _storageKey = 'standalone_credentials';
  static const _secure = FlutterSecureStorage();

  static StandaloneLogin? active;

  String get host => Uri.parse('quic://$address').host;

  IClientAuthenticator get authenticator =>
      privateKey != null ? CryptoSignAuthenticator(authId, privateKey!) : WAMPCRAAuthenticator(authId, password ?? '');

  Future<QUICSession> connect(String realm) {
    return connectQUIC(
      address,
      realm,
      QUICDialerConfig(authenticator: authenticator, serializer: CBORSerializer()),
      certificateFingerprint: certificateFingerprint,
    ).timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('QUIC connect did not complete', const Duration(seconds: 15)),
    );
  }

  static String parseAddress(String raw) {
    final input = raw.trim();
    final uri = Uri.tryParse(input.contains('://') ? input : 'quic://$input');
    if (uri == null || uri.scheme != 'quic') {
      throw const FormatException('Use a quic://host:port URL.');
    }
    if (uri.host.isEmpty || !uri.hasPort) {
      throw const FormatException('The URL needs a host and a port, e.g. quic://192.168.1.10:18080.');
    }
    return uri.host.contains(':') ? '[${uri.host}]:${uri.port}' : '${uri.host}:${uri.port}';
  }

  static String parseFingerprint(String raw) {
    final fingerprint = raw.trim().replaceAll(':', '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('The fingerprint must be a hex SHA-256 (64 characters, colons allowed).');
    }
    return fingerprint;
  }

  Map<String, String> toJson() => {
    'address': address,
    'authId': authId,
    'password': ?password,
    'privateKey': ?privateKey,
    'certificateFingerprint': certificateFingerprint,
  };

  static StandaloneLogin fromJson(Map<String, dynamic> json) => StandaloneLogin(
    address: json['address'] as String,
    authId: json['authId'] as String,
    password: json['password'] as String?,
    privateKey: json['privateKey'] as String?,
    certificateFingerprint: json['certificateFingerprint'] as String,
  );

  Future<void> save() => _secure.write(key: _storageKey, value: jsonEncode(toJson()));

  static Future<StandaloneLogin?> load() async {
    final raw = await _secure.read(key: _storageKey);
    if (raw == null) return null;
    try {
      return fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      await clear();
      return null;
    }
  }

  static Future<void> clear() => _secure.delete(key: _storageKey);
}
