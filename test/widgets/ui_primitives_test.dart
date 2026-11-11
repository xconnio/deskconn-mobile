import 'package:deskconn_mobile_app/theme/app_theme.dart';
import 'package:deskconn_mobile_app/widgets/app_card.dart';
import 'package:deskconn_mobile_app/widgets/app_empty_state.dart';
import 'package:deskconn_mobile_app/widgets/app_error_view.dart';
import 'package:deskconn_mobile_app/widgets/app_loading.dart';
import 'package:deskconn_mobile_app/widgets/section_header.dart';
import 'package:deskconn_mobile_app/widgets/settings_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: DeskconnTheme.light(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('AppCard renders its child', (tester) async {
    await pump(tester, const AppCard(child: Text('inside')));
    expect(find.text('inside'), findsOneWidget);
  });

  testWidgets('SectionHeader shows its title and action', (tester) async {
    await pump(tester, const SectionHeader(title: 'Security', action: Icon(Icons.lock)));
    expect(find.text('Security'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);
  });

  testWidgets('SettingsTile shows title, subtitle and icon', (tester) async {
    await pump(tester, SettingsTile(icon: Icons.person_outline, title: 'Account', subtitle: 'Profile', onTap: () {}));
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });

  testWidgets('SettingsTile destructive variant uses the error colour', (tester) async {
    await pump(tester, SettingsTile(icon: Icons.logout, title: 'Logout', destructive: true, onTap: () {}));
    final label = tester.widget<Text>(find.text('Logout'));
    final context = tester.element(find.text('Logout'));
    expect(label.style?.color, Theme.of(context).colorScheme.error);
  });

  testWidgets('AppEmptyState shows title and subtitle', (tester) async {
    await pump(
      tester,
      const AppEmptyState(icon: Icons.desktop_windows_outlined, title: 'Nothing here', subtitle: 'Later'),
    );
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
  });

  testWidgets('AppLoading shows a spinner and optional message', (tester) async {
    await pump(tester, const AppLoading(message: 'Loading'));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('AppErrorView shows the message and retries', (tester) async {
    var retried = 0;
    await pump(tester, AppErrorView(message: 'Boom', onRetry: () => retried++));
    expect(find.text('Boom'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
  });
}
