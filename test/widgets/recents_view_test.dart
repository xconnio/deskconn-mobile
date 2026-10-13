import 'package:deskconn_mobile_app/widgets/recents_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> pumpRecents(
    WidgetTester tester, {
    List<RecentApp> apps = const [
      RecentApp(id: 'files', title: 'Files', icon: Icons.folder_open, iconColor: Colors.blue),
    ],
  }) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RecentsView(apps: apps, onOpen: opened.add, onClose: (_) {}, onHome: () {}),
      ),
    );
    await tester.pumpAndSettle();
    return opened;
  }

  testWidgets('tapping the card title opens the app', (tester) async {
    final opened = await pumpRecents(tester);

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();

    expect(opened, ['files']);
  });

  testWidgets('tapping the card snapshot opens the app', (tester) async {
    final opened = await pumpRecents(tester);

    await tester.tap(find.byIcon(Icons.folder_open).last);
    await tester.pumpAndSettle();

    expect(opened, ['files']);
  });

  testWidgets('tapping a card while the carousel is still moving opens that card', (tester) async {
    final opened = await pumpRecents(
      tester,
      apps: const [
        RecentApp(id: 'files', title: 'Files', icon: Icons.folder_open, iconColor: Colors.blue),
        RecentApp(id: 'terminal', title: 'Terminal', icon: Icons.terminal, iconColor: Colors.green),
        RecentApp(id: 'monitor', title: 'Monitor', icon: Icons.speed, iconColor: Colors.red),
      ],
    );

    final scrollable = find.descendant(of: find.byType(PageView), matching: find.byType(Scrollable));
    final gesture = await tester.startGesture(tester.getCenter(find.byType(PageView)));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final position = tester.state<ScrollableState>(scrollable.first).position;
    expect(position.isScrollingNotifier.value, isTrue);

    final center = tester.getCenter(find.byType(PageView));
    await tester.tapAt(center);
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
  });
}
