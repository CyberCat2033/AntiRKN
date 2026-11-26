import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' as f;
import 'vpn_widgets_test.dart' as widgets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'disabled client with an offline pending job does not toggle busy on every poll',
    () async {
      final store = f.MemoryVpn();
      final remote = f.Remote(store);
      final remotes = {'one': remote};
      final c = f.controller(store, remotes);
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      await c.saveInbound(f.inbound('one', '1' * 32));
      await c.prepareAndApply();
      remote.running = true;
      await c.saveUser(
        VpnUser(id: f.alice, login: 'alice', name: 'Alice', enabled: false),
      );
      await c.prepareAndApply();
      remotes.clear();
      final saved = store.raw;
      final busy = <bool>[];
      c.addListener(() => busy.add(c.busy));
      for (var i = 0; i < 4; i++) {
        await c.reconcile();
      }
      expect(busy, isEmpty);
      expect(store.raw, saved);
      expect(c.workspace.servers['one']!['pending'], isNotNull);
    },
  );

  test(
    'a manual client save waits for the background poll and is not lost',
    () async {
      final store = f.MemoryVpn();
      final remote = f.Remote(store)..running = true;
      final remotes = <String, f.Remote>{'one': remote};
      final c = f.controller(store, remotes);
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(
        VpnUser(id: f.alice, login: 'alice', name: 'Alice', enabled: false),
      );
      await c.saveInbound(f.inbound('one', '1' * 32));
      await c.prepareAndApply();
      final held = f.DelayedStatusRemote(store)
        ..state = remote.state
        ..jobs.addAll(remote.jobs);
      remotes['one'] = held;
      final polling = c.reconcile();
      await held.started.future;
      expect(c.busy, isTrue);
      expect(c.foregroundBusy, isFalse);
      var saved = false;
      final saving = c
          .saveUser(
            VpnUser(
              id: f.alice,
              login: 'alice',
              name: 'Updated',
              enabled: false,
            ),
          )
          .then((_) => saved = true);
      try {
        await Future<void>.delayed(Duration.zero);
        expect(saved, isFalse);
      } finally {
        held.release.complete();
        await polling;
        await saving;
      }
      expect(saved, isTrue);
      expect(c.workspace.users.single.name, 'Updated');
      expect(c.error, isNull);
    },
  );

  testWidgets(
    'background polling keeps the publish button enabled and the global progress hidden',
    (tester) async {
      final setup = (await tester.runAsync(() async {
        final store = f.MemoryVpn();
        final remote = f.Remote(store)..running = true;
        final remotes = <String, f.Remote>{'one': remote};
        final c = f.controller(store, remotes);
        await c.load();
        await c.saveUser(
          VpnUser(id: f.alice, login: 'alice', name: 'Alice', enabled: false),
        );
        await c.saveInbound(f.inbound('one', '1' * 32));
        await c.prepareAndApply();
        final held = f.DelayedStatusRemote(store)
          ..state = remote.state
          ..jobs.addAll(remote.jobs);
        remotes['one'] = held;
        return (c, held);
      }))!;
      final c = setup.$1, held = setup.$2;
      addTearDown(c.dispose);
      // A running server job has its own bar in the operations summary;
      // background polling itself must add no other progress indicator.
      int globalProgress() =>
          find.byType(LinearProgressIndicator).evaluate().length -
          find
              .descendant(
                of: find.byKey(const ValueKey('server-operations-banner')),
                matching: find.byType(LinearProgressIndicator),
              )
              .evaluate()
              .length;
      Widget page() => MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: UsersPage(
            controller: c,
            serverName: (id) => id,
            exporter: widgets.Export(),
            motion: MotionPreference.off,
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pump();
      final button = find.byKey(const ValueKey('vpn-sync-and-publish'));
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      Future<void>? polling;
      try {
        await tester.runAsync(() async {
          polling = c.reconcile();
          await held.started.future;
        });
        await tester.pumpWidget(page());
        expect(c.busy, isTrue);
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        expect(globalProgress(), 0);
      } finally {
        held.release.complete();
        await tester.runAsync(() => polling!);
      }
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(globalProgress(), 0);
      expect(tester.takeException(), isNull);
    },
  );
}
