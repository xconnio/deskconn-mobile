import 'package:deskconn_mobile_app/core/window_manager/desktop_window.dart';
import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/widgets/app_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpDock(WidgetTester tester) async {
    final manager = DesktopWindowManager();
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [DeskconnPalette.light]),
        home: Scaffold(
          body: AppDock(
            manager: manager,
            realm: 'reorder-test',
            machineName: 'Desktop',
            appsEnabled: true,
            connectionStatusLabel: 'Connected',
            connectionStatusColor: Colors.green,
            onMachineTap: () {},
            onProfileTap: () {},
            onOpen: (kind, {category}) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('moving the first pinned app to the final index persists its order', (tester) async {
    await pumpDock(tester);
    final list = tester.widget<ReorderableListView>(find.byType(ReorderableListView));

    list.onReorderItem!(0, 3);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('dock_pinned_order_reorder-test'), [
      'terminal',
      'resourceMonitor',
      'portForward',
      'fileExplorer',
    ]);
  });

  testWidgets('moving a pinned app backward persists its intended position', (tester) async {
    await pumpDock(tester);
    final list = tester.widget<ReorderableListView>(find.byType(ReorderableListView));

    list.onReorderItem!(3, 0);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('dock_pinned_order_reorder-test'), [
      'portForward',
      'fileExplorer',
      'terminal',
      'resourceMonitor',
    ]);
  });
}
