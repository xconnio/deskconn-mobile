import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deskconn_mobile_app/core/app_engine/renderer.dart';
import 'package:deskconn_mobile_app/core/app_engine/runtime.dart';

import 'remote_control_fixture.dart';
import 'runtime_test.dart' show FakeCaller;

void main() {
  final app = ManifestApp(remoteControlManifest());

  Widget render(FakeCaller caller, Map<String, bool> capabilities) => MaterialApp(
    home: Scaffold(
      body: ManifestScreenView(
        app: app,
        screen: app.entryScreen!,
        context: {'capabilities': capabilities},
        caller: caller.call,
      ),
    ),
  );

  testWidgets('hidden blocks neither show nor call', (tester) async {
    final caller = FakeCaller();
    await tester.pumpWidget(render(caller, {'screen': true, 'audio': false}));

    expect(find.text('Lock screen'), findsOneWidget);
    expect(find.text('Mute'), findsNothing);
    expect(caller.calls, isEmpty);
  });

  testWidgets('buttons call their procedures and show their state', (tester) async {
    final caller = FakeCaller();
    await tester.pumpWidget(render(caller, {'screen': true, 'audio': true}));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    caller.answer('io.xconn.deskconn.deskconnd.audio.ismuted', result: false);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Mute'), findsOneWidget);

    await tester.tap(find.text('Mute'));
    caller.answer('io.xconn.deskconn.deskconnd.audio.togglemute', result: true);
    await tester.pump();
    expect(find.text('Unmute'), findsOneWidget);

    await tester.tap(find.text('Lock screen'));
    expect(caller.calls.last.procedure, 'io.xconn.deskconn.deskconnd.screen.lock');
  });
}
