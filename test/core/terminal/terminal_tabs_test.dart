import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_controller.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_registry.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTerminalController extends TerminalController {
  _FakeTerminalController(DesktopSessionLaunchConfig config) : super(config: config);

  bool disposed = false;

  @override
  bool get isActive => true;

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
}
