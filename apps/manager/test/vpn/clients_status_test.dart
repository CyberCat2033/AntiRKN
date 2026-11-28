import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../publication_test.dart' as p;
import '../vpn_controller_test.dart' as f;

class _Export implements ProfileExporter {
  @override
  Future<bool> save(String name, String source) async => true;
}

void main() {
  Widget app(Widget child) => MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    theme: AppTheme.create(Brightness.light),
    home: Scaffold(body: child),
  );

  testWidgets('a switch says what it did and can be undone', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = f.controller(f.MemoryVpn(), {});
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
    });
    await tester.pumpWidget(
      app(
        UsersPage(
          controller: c,
          serverName: (s) => s,
          exporter: _Export(),
          motion: MotionPreference.off,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('client-toggle-${f.alice}')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Durations.short2));
    await tester.pumpAndSettle();
    expect(c.workspace.userById(f.alice)!.enabled, isFalse);
    expect(find.text('Access for “Alice” is off'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('client-toggle-undo-${f.alice}')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Durations.short2));
    await tester.pumpAndSettle();
    expect(c.workspace.userById(f.alice)!.enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a Drive issue is said once; a client issue is on its row and filterable',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final vpn = f.controller(f.MemoryVpn(), {});
      addTearDown(vpn.dispose);
      final pub = PublicationController(
        repository: p.Repository(),
        account: p.Account()..publicationAuthorized = true,
        remote: p.Remote.new,
        vpn: vpn,
        canPublish: () => false,
      );
      addTearDown(pub.dispose);
      await pub.ready;
      await tester.runAsync(() async {
        await vpn.load();
        await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
        await vpn.saveUser(VpnUser(id: f.bob, login: 'bob', name: 'Bob'));
        await pub.configure(PublicationAccess.link);
      });
      await tester.pumpWidget(
        app(
          UsersPage(
            controller: vpn,
            publications: pub,
            serverName: (s) => s,
            exporter: _Export(),
            motion: MotionPreference.off,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)));

      // Drive unavailable for everyone: one summary, no row repeats it.
      pub.queues[f.alice] = {'status': 'error', 'issue': 'network'};
      pub.queues[f.bob] = {'status': 'error', 'issue': 'network'};
      pub.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(l.publicationClientsFailed(2)), findsOneWidget);
      expect(find.textContaining(l.publicationNetwork), findsOneWidget);

      // Alice's file is gone: her row says so, and the list can narrow to her.
      pub.queues[f.alice] = {'status': 'error', 'issue': 'missing'};
      pub.queues.remove(f.bob);
      pub.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(l.publicationMissing), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('publication-failures-show')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clients-only-failed')), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsNothing);

      // Fixed: the filter ends by itself.
      pub.queues.remove(f.alice);
      pub.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clients-only-failed')), findsNothing);
      expect(find.text('Bob'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await pub.suspend();
    },
  );
}
