import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/client_traffic_view.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../client_traffic_test.dart' as traffic;
import '../vpn_controller_test.dart' as fixtures;

class _Export implements ProfileExporter {
  @override
  Future<bool> save(String name, String source) async => true;
}

void main() {
  final bob = 'e' * 32, carol = 'f' * 32;

  for (final width in [390.0, 700.0, 1000.0, 1400.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('clients page at $width dp, text x$scale', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = fixtures.controller(fixtures.MemoryVpn(), {});
        addTearDown(c.dispose);
        await tester.runAsync(() async {
          await c.load();
          await c.saveUser(
            VpnUser(id: traffic.alice, login: 'alice', name: 'Alice'),
          );
          await c.saveUser(VpnUser(id: bob, login: 'bob', name: 'Bob'));
          await c.saveUser(
            VpnUser(id: carol, login: 'carol', name: 'Carol', enabled: false),
          );
        });
        final t = traffic.controller();
        addTearDown(t.dispose);
        await tester.runAsync(t.load);
        t.readings = {
          's1': ServerTrafficReading.fromRunner(traffic.runnerAnswer()),
        };
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: AppTheme.create(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: UsersPage(
                controller: c,
                traffic: t,
                serverName: (s) => s,
                exporter: _Export(),
                motion: MotionPreference.off,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // One title, no intro and no second heading.
        expect(find.text('Clients'), findsOneWidget);

        // The add action: in the header where it fits, else floating.
        final inHeader = width >= AppLayout.compact && scale == 1;
        expect(
          find.byType(FloatingActionButton),
          inHeader ? findsNothing : findsOneWidget,
        );
        expect(find.byKey(const ValueKey('vpn-user-add')), findsOneWidget);

        // No protocol for clients yet: said once, above the list.
        expect(
          find.byKey(const ValueKey('vpn-clients-no-access')),
          findsOneWidget,
        );

        // Only a client with counted traffic shows it under the name.
        expect(find.byType(TrafficUsageText), findsOneWidget);
        expect(find.textContaining('Traffic for'), findsOneWidget);

        // Disabled clients start folded; with large text the header is
        // below the fold of the lazy list.
        final header = find.byKey(
          const ValueKey('vpn-disabled-section-header'),
        );
        final list = find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(header, 200, scrollable: list);
        expect(find.text('Disabled clients'), findsOneWidget);
        expect(find.text('Carol'), findsNothing);
        // To the end of the list: its bottom padding lifts the last row
        // clear of the floating button.
        await tester.drag(list, const Offset(0, -2000));
        await tester.pumpAndSettle();
        await tester.tap(header);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Carol'),
          200,
          scrollable: list,
        );
        expect(find.text('Carol'), findsOneWidget);

        // Publishing is a header button; the full check is in the menu.
        expect(find.byKey(const ValueKey('vpn-sync-and-publish')), findsOne);
        await tester.tap(find.byKey(const ValueKey('vpn-clients-menu')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('vpn-sync-force')), findsOne);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
