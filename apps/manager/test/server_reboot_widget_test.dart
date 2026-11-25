import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/ssh/server_reboot_view.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'ssh_support.dart';

void main() {
  for (final language in ['ru', 'en']) {
    testWidgets(
      'reboot confirmation fits 390px x2 and cancel has no effect $language',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final connector = FakeConnector();
        final c = controller(FakeVault(), connector);
        await prepare(c);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(body: ServerRebootView(controller: c)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('server-reboot')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('server-reboot-confirm')),
          findsOneWidget,
        );
        expect(connector.authentications, 0);
        expect(c.runner.pending, isNull);
        await tester.tap(
          find.descendant(
            of: find.byType(AppFormDialog),
            matching: find.byType(TextButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppFormDialog), findsNothing);
        expect(connector.authentications, 0);
        expect(c.runner.pending, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}
