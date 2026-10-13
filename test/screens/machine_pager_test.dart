import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/providers/theme_provider.dart';
import 'package:deskconn_mobile_app/screens/desktop_details_screen.dart';
import 'package:deskconn_mobile_app/screens/settings_screen.dart';
import 'package:deskconn_mobile_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _desktops = [
  {'realm': 'r1', 'name': 'One'},
  {'realm': 'r2', 'name': 'Two'},
  {'realm': 'r3', 'name': 'Three'},
];

class _Harness {
  final handles = <String, DesktopPageHandle>{};
  var recentsOpened = <String>[];

  Future<void> pump(WidgetTester tester, {String realm = 'r1'}) async {
    SharedPreferences.setMockInitialValues({});
    final session = SessionProvider()..desktops = List.of(_desktops);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SessionProvider>.value(value: session),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          theme: DeskconnTheme.light(),
          home: MachinePager(
            desktop: _desktops.firstWhere((d) => d['realm'] == realm),
            pageBuilder: (desktop, handle) {
              final realm = desktop['realm'] as String;
              handles[realm] = handle;
              handle.openRecents = () => recentsOpened.add(realm);
              return ColoredBox(
                color: Colors.blueGrey,
                child: Center(child: Text('page ${desktop['name']}')),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Finder _visible(String name) => find.text('page $name').hitTestable();

Finder _chip(String name) => find.textContaining(RegExp('^$name '), findRichText: true);

double _indicatorOpacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first).opacity;

void main() {
  testWidgets('swiping left opens the next machine', (tester) async {
    await _Harness().pump(tester);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(_visible('Two'), findsOneWidget);
  });

  testWidgets('swiping right opens the previous machine', (tester) async {
    await _Harness().pump(tester, realm: 'r2');

    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(_visible('One'), findsOneWidget);
  });

  testWidgets('stops at the last machine instead of wrapping around', (tester) async {
    await _Harness().pump(tester, realm: 'r3');

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(_visible('Three'), findsOneWidget);
    expect(_visible('One'), findsNothing);
  });

  testWidgets('an up or down swipe does not switch machines', (tester) async {
    await _Harness().pump(tester);

    final gesture = await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await gesture.moveBy(const Offset(-4, -30));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-50, -20));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_visible('One'), findsOneWidget);
  });

  testWidgets('machine dots show only while swiping', (tester) async {
    await _Harness().pump(tester);
    expect(_indicatorOpacity(tester), 0);

    final gesture = await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(_indicatorOpacity(tester), 1);

    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(_indicatorOpacity(tester), 0);
  });

  testWidgets('an open app keeps the machine from switching', (tester) async {
    final harness = _Harness();
    await harness.pump(tester);
    harness.handles['r1']!.appOpen.value = true;
    await tester.pump();

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(_visible('One'), findsOneWidget);
  });

  testWidgets('the bottom bar stays in place while swiping', (tester) async {
    await _Harness().pump(tester);
    final before = tester.getRect(find.text('Apps'));

    final gesture = await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-200, 0));
    await tester.pump();

    expect(tester.getRect(find.text('Apps')), before);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('settings opens above the bar and apps goes back', (tester) async {
    await _Harness().pump(tester);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen).hitTestable(), findsOneWidget);
    expect(find.text('Apps'), findsOneWidget);

    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen).hitTestable(), findsNothing);
    expect(_visible('One'), findsOneWidget);
  });

  testWidgets('apps opens recents for the machine on screen', (tester) async {
    final harness = _Harness();
    await harness.pump(tester);
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Apps'));
    await tester.pump();

    expect(harness.recentsOpened, ['r2']);
  });

  testWidgets('the status chip stays in place and shows the new machine after a switch', (tester) async {
    await _Harness().pump(tester);
    expect(_chip('One'), findsOneWidget);
    final before = tester.getRect(_chip('One'));

    final gesture = await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-150, 0));
    await tester.pump();
    expect(tester.getRect(_chip('One')), before);

    await gesture.moveBy(const Offset(-300, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_chip('Two'), findsOneWidget);
    expect(_chip('One'), findsNothing);
    expect(tester.getRect(_chip('Two')).center.dy, before.center.dy);
  });

  testWidgets('the status chip hides while an app is open', (tester) async {
    final harness = _Harness();
    await harness.pump(tester);

    harness.handles['r1']!.appOpen.value = true;
    await tester.pump();

    expect(_chip('One'), findsNothing);
  });
}
