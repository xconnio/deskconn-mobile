import 'package:deskconn_mobile_app/widgets/exit_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<MethodCall> calls;

  Future<GlobalKey<NavigatorState>> pumpApp(WidgetTester tester) async {
    calls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        onNavigationNotification: keepFrameworkHandlingBack,
        home: const Scaffold(body: Text('root')),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  Iterable<Object?> handlesBackArgs() =>
      calls.where((c) => c.method == 'SystemNavigator.setFrameworkHandlesBack').map((c) => c.arguments);

  bool popped() => calls.any((c) => c.method == 'SystemNavigator.pop');

  testWidgets('back on a pushed screen pops it without asking to close', (tester) async {
    final key = await pumpApp(tester);
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('terminal'))));
    await tester.pumpAndSettle();

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('root'), findsOneWidget);
    expect(find.text('terminal'), findsNothing);
    expect(find.text('Close Deskconn?'), findsNothing);
    expect(popped(), isFalse);
  });

  testWidgets('back on the root screen closes the app without asking', (tester) async {
    await pumpApp(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Close Deskconn?'), findsNothing);
    expect(popped(), isTrue);
  });

  testWidgets('framework always keeps handling back so Android never exits on its own', (tester) async {
    final key = await pumpApp(tester);
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('terminal'))));
    await tester.pumpAndSettle();
    key.currentState!.pop();
    await tester.pumpAndSettle();

    expect(handlesBackArgs(), isNotEmpty);
    expect(handlesBackArgs(), everyElement(isTrue));
  });

  testWidgets('handles-back is not sent while the app is detached', (tester) async {
    await pumpApp(tester);
    calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);

    keepFrameworkHandlingBack(const NavigationNotification(canHandlePop: false));

    expect(handlesBackArgs(), isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
