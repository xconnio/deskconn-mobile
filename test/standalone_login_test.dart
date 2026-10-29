import 'package:deskconn_mobile_app/core/auth/standalone_login.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseAddress', () {
    test('accepts quic URLs and bare host:port', () {
      expect(StandaloneLogin.parseAddress('quic://192.168.1.10:18080'), '192.168.1.10:18080');
      expect(StandaloneLogin.parseAddress(' office.local:18080 '), 'office.local:18080');
      expect(StandaloneLogin.parseAddress('quic://[fe80::1]:18080'), '[fe80::1]:18080');
    });

    test('rejects other schemes and missing ports', () {
      expect(() => StandaloneLogin.parseAddress('https://host:18081'), throwsFormatException);
      expect(() => StandaloneLogin.parseAddress('quic://host'), throwsFormatException);
    });
  });

  group('parseFingerprint', () {
    const hex = '3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b';

    test('normalizes case and colons', () {
      final colons = [for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)].join(':').toUpperCase();
      expect(StandaloneLogin.parseFingerprint(colons), hex);
    });

    test('rejects anything but a SHA-256', () {
      expect(() => StandaloneLogin.parseFingerprint('  '), throwsFormatException);
      expect(() => StandaloneLogin.parseFingerprint('abc'), throwsFormatException);
      expect(() => StandaloneLogin.parseFingerprint('${hex}00'), throwsFormatException);
    });
  });

  test('round-trips through json', () {
    const login = StandaloneLogin(
      address: 'host:18080',
      authId: 'asim',
      password: 'secret',
      certificateFingerprint: 'ab',
    );
    final restored = StandaloneLogin.fromJson(login.toJson());
    expect(restored.address, 'host:18080');
    expect(restored.authId, 'asim');
    expect(restored.password, 'secret');
    expect(restored.privateKey, isNull);
    expect(restored.certificateFingerprint, 'ab');
    expect(restored.host, 'host');
  });
}
