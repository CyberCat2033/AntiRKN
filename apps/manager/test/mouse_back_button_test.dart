import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mouse back button (kBackMouseButton) pops pushed route', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            if ((event.buttons & kBackMouseButton) != 0) {
              navigatorKey.currentState?.maybePop();
            }
          },
          child: child ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(body: Center(child: Text('Home'))),
      ),
    );

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Detail'), findsNothing);

    // Push detail route
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) =>
            const Scaffold(body: Center(child: Text('Detail'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Detail'), findsOneWidget);

    // Send mouse back button click
    await tester.sendEventToBinding(
      const PointerDownEvent(
        position: Offset(100, 100),
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      ),
    );
    await tester.pumpAndSettle();

    // Verify detail route popped and we are back on Home
    expect(find.text('Detail'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('mouse back button invokes PopScope when canPop is false', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    var backInvoked = false;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            if ((event.buttons & kBackMouseButton) != 0) {
              navigatorKey.currentState?.maybePop();
            }
          },
          child: child ?? const SizedBox.shrink(),
        ),
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) backInvoked = true;
          },
          child: const Scaffold(
            body: Center(child: Text('Home With PopScope')),
          ),
        ),
      ),
    );

    expect(find.text('Home With PopScope'), findsOneWidget);
    expect(backInvoked, isFalse);

    // Send mouse back button click
    await tester.sendEventToBinding(
      const PointerDownEvent(
        position: Offset(100, 100),
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      ),
    );
    await tester.pumpAndSettle();

    // Verify PopScope intercepted back button
    expect(backInvoked, isTrue);
    expect(find.text('Home With PopScope'), findsOneWidget);
  });
}
