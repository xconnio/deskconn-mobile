import 'package:deskconn_mobile_app/screens/manifest_app_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lists every app as a capability and only enabled manifest apps as tiles', () {
    final apps = parseDesktopApps([
      {'id': 'terminal', 'name': 'Terminal', 'enabled': true},
      {'id': 'printer', 'name': 'Printer', 'enabled': true, 'manifest': true},
      {'id': 'camera', 'name': 'Camera', 'enabled': false, 'manifest': true},
      {'id': 'notes', 'enabled': true, 'manifest': true},
    ]);

    expect(apps.capabilities, {'terminal': true, 'printer': true, 'camera': false, 'notes': true});
    expect([for (final app in apps.manifestApps) (app.id, app.name)], [('printer', 'Printer'), ('notes', 'notes')]);
  });

  test('skips entries that are not maps', () {
    final apps = parseDesktopApps([
      'garbage',
      42,
      {'id': 'files', 'enabled': true},
    ]);

    expect(apps.capabilities, {'files': true});
    expect(apps.manifestApps, isEmpty);
  });

  test('treats a missing or non-true enabled flag as disabled', () {
    final apps = parseDesktopApps([
      {'id': 'vpn'},
      {'id': 'ports', 'enabled': 'yes', 'manifest': true},
    ]);

    expect(apps.capabilities, {'vpn': false, 'ports': false});
    expect(apps.manifestApps, isEmpty);
  });
}
