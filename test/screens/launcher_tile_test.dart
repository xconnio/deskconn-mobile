import 'package:deskconn_mobile_app/screens/desktop_details_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a two line name keeps its icon in line with the others', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 80,
                  height: 110,
                  child: LauncherTile(icon: Icons.folder, badgeColor: Colors.orange, title: 'Files', onTap: () {}),
                ),
                SizedBox(
                  width: 80,
                  height: 110,
                  child: LauncherTile(
                    icon: Icons.speed,
                    badgeColor: Colors.blue,
                    title: 'Resource Monitor',
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.getTopLeft(find.byIcon(Icons.speed)).dy, tester.getTopLeft(find.byIcon(Icons.folder)).dy);
    expect(tester.takeException(), isNull);
  });
}
