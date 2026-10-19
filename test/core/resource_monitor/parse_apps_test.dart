import 'package:deskconn_mobile_app/core/resource_monitor/resource_monitor_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('system processes are left out of the app list', () {
    final apps = parseApps([
      {
        'id': 'firefox',
        'name': 'Firefox',
        'pids': [10, 11],
        'cpu_percent': 2.5,
        'mem_rss': 1024,
      },
      {
        'id': 'system',
        'name': 'System Processes',
        'pids': [1, 2, 3],
        'cpu_percent': 1.0,
        'mem_rss': 2048,
      },
      {
        'id': 'code',
        'name': 'Code',
        'pids': [20],
        'cpu_percent': 0.5,
        'mem_rss': 512,
      },
    ]);

    expect(apps.map((a) => a.name), ['Firefox', 'Code']);
  });
}
