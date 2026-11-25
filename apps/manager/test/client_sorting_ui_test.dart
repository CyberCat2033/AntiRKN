import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as fixtures;

class _Export implements ProfileExporter {
  @override
  Future<bool> save(String name, String source) async => true;
}

void main() {
  testWidgets(
    'UsersPage sorts clients by name and creation date with disabled clients at the end',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final store = fixtures.MemoryVpn();
      final c = fixtures.controller(store, {});
      addTearDown(c.dispose);

      final id1 = '1' * 32;
      final id2 = '2' * 32;
      final id3 = '3' * 32;

      await tester.runAsync(() async {
        await c.load();
        // 1. Charlie (enabled, created 1st)
        await c.saveUser(
          VpnUser(id: id1, login: 'charlie', name: 'Charlie', enabled: true),
        );
        // 2. Alice (enabled, created 2nd)
        await c.saveUser(
          VpnUser(id: id2, login: 'alice', name: 'Alice', enabled: true),
        );
        // 3. Bob (disabled, created 3rd)
        await c.saveUser(
          VpnUser(id: id3, login: 'bob', name: 'Bob', enabled: false),
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.create(Brightness.light),
          home: Scaffold(
            body: UsersPage(
              controller: c,
              serverName: (s) => s,
              exporter: _Export(),
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Verify sort controls exist
      expect(find.byKey(const ValueKey('vpn-sort-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('vpn-sort-date')), findsOneWidget);

      // 2. Verify disabled section header exists
      expect(find.text('Disabled clients'), findsOneWidget);
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);

      List<String> renderedUserNames() {
        final listTiles = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .where((tile) => tile.key.toString().contains('client-'))
            .toList();
        return listTiles
            .map((t) => (t.title! as Text).data!)
            .where((n) => {'Charlie', 'Alice', 'Bob'}.contains(n))
            .toList();
      }

      // Initial state: Creation date ascending (Charlie 1st, Alice 2nd, Bob disabled at end)
      expect(renderedUserNames(), equals(['Charlie', 'Alice', 'Bob']));

      // 3. Tap "Name" chip -> Sort by name ascending (Alice, Charlie, Bob at end)
      await tester.tap(find.byKey(const ValueKey('vpn-sort-name')));
      await tester.pumpAndSettle();
      expect(renderedUserNames(), equals(['Alice', 'Charlie', 'Bob']));

      // 4. Direction button -> Sort by name descending (Charlie, Alice, Bob at end)
      await tester.tap(find.byKey(const ValueKey('vpn-sort-direction')));
      await tester.pumpAndSettle();
      expect(renderedUserNames(), equals(['Charlie', 'Alice', 'Bob']));

      // 5. Tap "Date created" chip -> Switch back to date
      await tester.tap(find.byKey(const ValueKey('vpn-sort-date')));
      await tester.pumpAndSettle();
      // Date ascending: Charlie, Alice, Bob at end
      expect(renderedUserNames(), equals(['Charlie', 'Alice', 'Bob']));

      // 6. Direction button -> Date descending (Alice, Charlie, Bob at end)
      await tester.tap(find.byKey(const ValueKey('vpn-sort-direction')));
      await tester.pumpAndSettle();
      expect(renderedUserNames(), equals(['Alice', 'Charlie', 'Bob']));

      // 7. Enable Bob via switch -> Bob moves into active section in sorted order
      await tester.tap(find.byKey(ValueKey('client-toggle-$id3')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(c.workspace.users.firstWhere((u) => u.id == id3).enabled, isTrue);
      // All clients are enabled: no disabled section header rendered
      expect(find.text('Disabled clients'), findsNothing);
      expect(renderedUserNames(), equals(['Bob', 'Alice', 'Charlie']));

      // 8. Disable Charlie -> Charlie moves into disabled section at end
      await tester.tap(find.byKey(ValueKey('client-toggle-$id1')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Disabled clients'), findsOneWidget);
      expect(renderedUserNames(), equals(['Bob', 'Alice', 'Charlie']));
    },
  );
}
