import 'package:deskconn_mobile_app/widgets/recents_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> pumpRecents(WidgetTester tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RecentsView(
          apps: const [RecentApp(id: 'files', title: 'Files', icon: Icons.folder_open, iconColor: Colors.blue)],
          onOpen: opened.add,
          onClose: (_) {},
          onHome: () {},
        ),
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
}
