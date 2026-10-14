import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_controller.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_registry.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' show TerminalView, TerminalViewState;

class _FakeTerminalController extends TerminalController {
  _FakeTerminalController(DesktopSessionLaunchConfig config) : super(config: config);

  bool disposed = false;

  @override
  bool get isActive => true;

  @override
  bool get isReady => true;

  @override
  void dispose() => disposed = true;
}

void main() {
  testWidgets('closing a tab keeps the other tabs running', (tester) async {
    const realm = 'tabs-test-realm';
    final config = DesktopSessionLaunchConfig(
      sessionKey: 'tabs-test',
      desktopName: 'Desktop',
      realm: realm,
      authId: 'user',
      privateKey: 'key',
      webRtcEnabled: false,
    );
    final group = TerminalRegistry().groupFor(realm);
    final controllers = [for (var i = 0; i < 3; i++) _FakeTerminalController(config)];
    for (final controller in controllers) {
      group.addTab(controller);
    }
    group.selectTab(group.tabs.first.id);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabsView(realm: realm, desktopName: 'Desktop', webRtcEnabled: false, embedded: true),
        ),
      ),
    );
    await tester.pump();

    group.closeTab(group.tabs.first.id);
    await tester.pump();

    expect(controllers[0].disposed, isTrue);
    expect(controllers[1].disposed, isFalse);
    expect(controllers[2].disposed, isFalse);
  });

  Future<TerminalGroup> pumpTabs(WidgetTester tester, String realm) async {
    final config = DesktopSessionLaunchConfig(
      sessionKey: realm,
      desktopName: 'Desktop',
      realm: realm,
      authId: 'user',
      privateKey: 'key',
      webRtcEnabled: false,
    );
    final group = TerminalRegistry().groupFor(realm);
    for (var i = 0; i < 3; i++) {
      group.addTab(_FakeTerminalController(config));
    }
    group.selectTab(group.tabs.first.id);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabsView(realm: realm, desktopName: 'Desktop', webRtcEnabled: false, embedded: true),
        ),
      ),
    );
    await tester.pump();
    return group;
  }

  Future<void> switchTo(WidgetTester tester, String title) async {
    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).last);
    await tester.pumpAndSettle();
  }

  BuildContext? focusedContext() => FocusManager.instance.primaryFocus?.context;

  bool keyboardOpenIn(WidgetTester tester, String tabId) => tester
      .state<TerminalViewState>(find.descendant(of: find.byKey(ValueKey(tabId)), matching: find.byType(TerminalView)))
      .hasInputConnection;

  testWidgets('switching tabs with the keyboard closed keeps it closed and taps reach the new tab', (tester) async {
    final group = await pumpTabs(tester, 'tabs-closed-keyboard');
    final target = group.tabs[1];

    await switchTo(tester, target.title);

    expect(group.activeId, target.id);
    expect(
      find.descendant(of: find.byKey(ValueKey(target.id)), matching: find.byType(TerminalView)).hitTestable(),
      findsOneWidget,
    );
    expect(find.byType(TerminalView).hitTestable(), findsOneWidget);
    for (final tab in group.tabs) {
      expect(keyboardOpenIn(tester, tab.id), isFalse);
    }

    await tester.tap(find.descendant(of: find.byKey(ValueKey(target.id)), matching: find.byType(TerminalView)));
    await tester.pumpAndSettle();
    expect(keyboardOpenIn(tester, target.id), isTrue);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('switching tabs with the keyboard open moves the cursor to the new tab', (tester) async {
    final group = await pumpTabs(tester, 'tabs-open-keyboard');
    final target = group.tabs[1];
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    addTearDown(tester.view.resetViewInsets);

    await switchTo(tester, target.title);

    expect(group.activeId, target.id);
    expect(focusedContext()?.findAncestorWidgetOfExactType<Visibility>()?.key, ValueKey(target.id));
    expect(keyboardOpenIn(tester, target.id), isTrue);
  });
}
