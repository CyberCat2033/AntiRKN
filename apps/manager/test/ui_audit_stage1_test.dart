// Regression tests for stage 1 of UI_AUDIT_REPORT.md (functional bugs).
import 'dart:async';
import 'dart:convert';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/desktop_back_gesture.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/runner/component_updates_controller.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:antirkn_manager/settings_hub.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:antirkn_manager/ssh/server_inventory_panel.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:antirkn_manager/vpn/connection_check_view.dart';
import 'package:antirkn_manager/vpn/connection_checks.dart' show ConnectionTarget;
import 'package:antirkn_manager/vpn/observed_inbound_dialog.dart';
import 'package:antirkn_manager/vpn/tt_panel.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'network_support.dart';
import 'component_updates_test.dart' as updates;
import 'publication_test.dart' as p;
import 'runner_support.dart';
import 'ssh_support.dart' as ssh;
import 'vpn_controller_test.dart' as f;

Widget _app(Widget child, {bool disableAnimations = false}) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: home!,
  ),
  home: Scaffold(body: child),
);

/// Marks a connection check as running without a probe engine.
void _checkRunning(VpnController c) =>
    c.connections.current = (target: 'one', resource: 'x' * 32);

void main() {
  group('UI-01 one mutation predicate', () {
    test(
      'a save during connection checks interrupts them and is stored',
      () async {
        final store = f.MemoryVpn();
        final c = f.controller(store, {});
        addTearDown(c.dispose);
        await c.load();
        _checkRunning(c);
        expect(c.connections.busy, isTrue);
        expect(c.canMutate, isTrue);
        await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
        expect(c.error, isNull);
        expect(c.workspace.userById(f.alice), isNotNull);
        expect(c.connections.busy, isFalse);
      },
    );

    test('a change rejected by a running change reports vpn_busy', () async {
      final c = f.controller(f.MemoryVpn(), {});
      addTearDown(c.dispose);
      await c.load();
      c.busy = true;
      expect(c.canMutate, isFalse);
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      expect(c.error, 'vpn_busy');
      expect(c.workspace.userById(f.alice), isNull);
      c.busy = false;
    });

    Future<void> openForm(WidgetTester tester, VpnController c) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => UsersPage.edit(context, c, MotionPreference.off),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('vpn-user-name')),
        'Alice',
      );
      await tester.tap(find.byKey(const ValueKey('vpn-user-save')));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
        if (!c.workspaceBusy) break;
      }
      await tester.pumpAndSettle();
    }

    testWidgets('the client form saves while checks run, then closes', (
      tester,
    ) async {
      final c = f.controller(f.MemoryVpn(), {});
      addTearDown(c.dispose);
      await tester.runAsync(c.load);
      _checkRunning(c);
      await openForm(tester, c);
      expect(c.workspace.users.where((u) => u.name == 'Alice'), hasLength(1));
      expect(find.byKey(const ValueKey('vpn-user-save')), findsNothing);
    });

    testWidgets('a rejected save keeps the form open with an error', (
      tester,
    ) async {
      final c = f.controller(f.MemoryVpn(), {});
      addTearDown(c.dispose);
      await tester.runAsync(c.load);
      c.busy = true;
      await openForm(tester, c);
      expect(c.workspace.users, isEmpty);
      expect(find.byKey(const ValueKey('vpn-user-save')), findsOneWidget);
      expect(find.byKey(const ValueKey('vpn-user-save-error')), findsOneWidget);
      c.busy = false;
    });
  });

  group('UI-02 and UI-20 pure readers, stale pending cleared by reconcile', () {
    test(
      'readers neither notify nor write; reconcile clears storage',
      () async {
        final store = f.MemoryVpn();
        final c = f.controller(store, {});
        addTearDown(c.dispose);
        await c.load();
        final stale = {
          // Older than five minutes: stale even without a finished job.
          'pending': {
            'kind': 'vless_apply',
            'id': 'job',
            'startedAt': DateTime.now()
                .subtract(const Duration(minutes: 10))
                .toUtc()
                .toIso8601String(),
          },
          'observed': [
            {'id': 'r' * 32, 'confirmed': true},
          ],
        };
        c.workspace = c.workspace.copy(
          servers: {...c.workspace.servers, 'one': stale},
        );
        var notifications = 0;
        void count() => notifications++;
        c.addListener(count);
        final writes = store.revision;
        expect(c.adoptionConfirmed('one', 'r' * 32), isTrue);
        c.connections.evaluateReadiness((target: 'one', resource: 'r' * 32));
        expect(notifications, 0);
        expect(store.revision, writes);
        expect(c.workspace.servers['one']!['pending'], isNotNull);

        // A background run keeps an error the person has not dismissed.
        c.error = 'vpn_connection';
        await c.reconcile();
        c.removeListener(count);
        expect(c.workspace.servers['one']!['pending'], isNull);
        expect(store.revision, greaterThan(writes));
        expect(
          (jsonDecode(store.raw!) as Map)['servers']['one']['pending'],
          isNull,
        );
        expect(c.error, 'vpn_connection');
      },
    );
  });

  group('UI-03 AppPageSwitch keeps page state', () {
    Widget pages(int index, int? depth, {bool reduced = false}) => _app(
      AppPageSwitch(
        index: index,
        depth: depth,
        children: const [
          Text('root'),
          TextField(key: ValueKey('draft')),
          TextField(key: ValueKey('other')),
        ],
      ),
      disableAnimations: reduced,
    );

    String draft(WidgetTester tester) => tester
        .widget<EditableText>(
          find.descendant(
            of: find.byKey(const ValueKey('draft'), skipOffstage: false),
            matching: find.byType(EditableText, skipOffstage: false),
          ),
        )
        .controller
        .text;

    testWidgets('across depth 0→1→0, 1→1 and reduced motion', (tester) async {
      await tester.pumpWidget(pages(1, 1));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('draft')), 'kept');
      for (final (index, depth, reduced) in [
        (0, 0, false),
        (1, 1, false),
        (2, 1, false),
        (1, 1, false),
        (0, 0, true),
        (1, 1, true),
        (1, 1, false),
        (0, 0, false),
      ]) {
        await tester.pumpWidget(pages(index, depth, reduced: reduced));
        await tester.pumpAndSettle();
        expect(draft(tester), 'kept', reason: 'after $index/$depth/$reduced');
      }
    });
  });

  testWidgets('UI-03 removing the open last page returns without errors', (
    tester,
  ) async {
    Widget pages(List<Widget> children, int index, int depth) =>
        _app(AppPageSwitch(index: index, depth: depth, children: children));
    await tester.pumpWidget(
      pages(const [Text('root'), Text('one'), Text('two')], 2, 1),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(pages(const [Text('root'), Text('one')], 0, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('UI-04 a vault failure shows back and retry, not a spinner', (
    tester,
  ) async {
    var opens = 0;
    final c = SshController(
      openVault: () async {
        opens++;
        throw const VaultFailure(VaultIssue.corrupt);
      },
      connector: ssh.FakeConnector(),
      picker: ssh.FakeKeyPicker(),
      network: NetworkController(
        reader: TestInventoryReader(() async => testInventory()),
      ),
    );
    await c.initialise();
    var back = 0;
    await tester.pumpWidget(
      _app(
        ServerDetailView(
          session: c,
          motion: MotionPreference.off,
          onBack: () => back++,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('server-vault-error')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('server-list-back')));
    expect(back, 1);
    await tester.tap(find.byKey(const ValueKey('server-vault-retry')));
    await tester.pump();
    expect(opens, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('UI-05 resetting the job queue asks first', (tester) async {
    final store = MemoryRunnerJournal();
    final remote = FakeRunnerTransport(store)..installed = true;
    final c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture|key',
      password: () => null,
      accessFailure: (_) {},
      store: store,
    );
    await tester.runAsync(c.refresh);
    c.selected = runnerJob('1' * 32, kind: 'diagnostic', status: 'running');
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: RunnerPanel(controller: c, motion: MotionPreference.off),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('runner-reset-queue')), findsOneWidget);
    expect(find.byType(RunnerResetQueueButton), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('runner-reset-queue')));
    await tester.pumpAndSettle();
    expect(find.byType(AppDangerButton), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.selected, isNotNull, reason: 'dismissing must not reset');
    await tester.tap(find.byKey(const ValueKey('runner-reset-queue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('runner-reset-queue-confirm')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(c.selected, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  test('UI-06 a non-numeric memory value is shown as unrecognized', () async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      factValue(l, ServerFact.memoryKiB, const InventoryValue.ok('n/a')),
      l.inventoryInvalid,
    );
    expect(
      factValue(l, ServerFact.memoryKiB, const InventoryValue.ok('2048')),
      l.inventoryMiB('2'),
    );
  });

  testWidgets('UI-07 a retry runs one open at a time and shows progress', (
    tester,
  ) async {
    var opens = 0;
    final never = Completer<WorkspaceDatabase>();
    await tester.pumpWidget(
      WorkspaceLauncher(
        openWorkspace: () {
          opens++;
          if (opens == 1) return Future.error(StateError('closed'));
          return never.future;
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    final retry = find.byKey(const ValueKey('database-open-retry'));
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.pump();
    expect(retry, findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(opens, 2);
  });

  testWidgets('UI-08 a failing target list never leaves "checking" on', (
    tester,
  ) async {
    final c = f.controller(f.MemoryVpn(), {});
    await tester.runAsync(c.load);
    await tester.pumpWidget(
      _app(
        ConnectionCheckAll(
          controller: c,
          targets: const [],
          others: 2,
          readOthers: () async => throw TypeError(),
        ),
      ),
    );
    await tester.tap(find.text('Check all'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Check all'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('connection-check-all-failed')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('"Check all" appears only from two connections', (tester) async {
    final c = f.controller(f.MemoryVpn(), {});
    await tester.runAsync(c.load);
    const one = (target: 'one', resource: 'a');
    for (final (targets, others, shown) in [
      (const <ConnectionTarget>[], 0, false),
      (const [one], 0, false),
      (const <ConnectionTarget>[], 1, false),
      (const [one], 1, true),
      (const [one, (target: 'one', resource: 'b')], 0, true),
    ]) {
      await tester.pumpWidget(
        _app(
          ConnectionCheckAll(
            controller: c,
            targets: targets,
            others: others,
            readOthers: others == 0 ? null : () async => const [],
          ),
        ),
      );
      expect(find.text('Check all'), shown ? findsOneWidget : findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('UI-09 transport JSON and fields never overwrite each other', (
    tester,
  ) async {
    final store = MemoryRunnerJournal();
    final runner = _InboundRunner(FakeRunnerTransport(store), store);
    final network = NetworkController(
      reader: TestInventoryReader(() async => testInventory()),
    );
    await tester.pumpWidget(
      _app(
        ObservedInboundDialog(
          controller: runner,
          network: network,
          inboundId: 7,
          port: 2053,
          motion: MotionPreference.off,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    TextField field(String key) =>
        tester.widget<TextField>(find.byKey(ValueKey('observed-$key')));
    expect(field('sni').enabled, isTrue);
    await tester.ensureVisible(find.text('Transport settings (JSON)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transport settings (JSON)'));
    await tester.pumpAndSettle();
    expect(field('sni').enabled, isFalse, reason: 'JSON mode owns the data');
    final json = find.byKey(const ValueKey('observed-stream-json'));
    final edited = (jsonDecode(field('stream-json').controller!.text) as Map)
      ..['realitySettings'] = {
        ...(jsonDecode(field('stream-json').controller!.text)
                as Map)['realitySettings']
            as Map,
        'serverNames': ['edited.example'],
      };
    await tester.ensureVisible(json);
    await tester.enterText(json, jsonEncode(edited));
    await tester.pump();
    await tester.ensureVisible(find.text('Transport settings (JSON)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transport settings (JSON)'));
    await tester.pumpAndSettle();
    expect(field('sni').enabled, isTrue);
    expect(field('sni').controller!.text, 'edited.example');
    await tester.pumpWidget(const SizedBox.shrink());
    runner.dispose();
    network.dispose();
  });

  group('UI-10 TrustTunnel certificate default', () {
    test('is applied by the owner, not by build', () {
      final fields = {'domain': TextEditingController()};
      addTearDown(fields['domain']!.dispose);
      final spec = <String, Object?>{'certificateId': ''};
      final certificates = <Map>[
        {'id': 'c1', 'domain': 'vpn.example'},
      ];
      expect(applyDefaultTtCertificate(spec, fields, certificates), isTrue);
      expect(spec['certificateId'], 'c1');
      expect(fields['domain']!.text, 'vpn.example');
      expect(applyDefaultTtCertificate(spec, fields, certificates), isFalse);
    });

    testWidgets('building the editor does not change the spec', (tester) async {
      final fields = {
        for (final k in ['name', 'listen', 'port', 'domain', 'socksAddress'])
          k: TextEditingController(),
      };
      addTearDown(() {
        for (final field in fields.values) {
          field.dispose();
        }
      });
      final spec = <String, Object?>{'certificateId': ''};
      final network = NetworkController(
        reader: TestInventoryReader(() async => testInventory()),
      );
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: TtSettingsEditor(
              fields: fields,
              spec: spec,
              certificates: const [
                {'id': 'c1', 'domain': 'vpn.example'},
              ],
              network: network,
              motion: MotionPreference.off,
              onChanged: () {},
            ),
          ),
        ),
      );
      expect(spec['certificateId'], '');
      expect(fields['domain']!.text, '');
    });
  });

  group('publication', () {
    Future<(f_vpn, PublicationController, p.Repository)> setUpPublication(
      p.Remote remote,
      List<(String, String)> users,
    ) async {
      final vpn = f.controller(f.MemoryVpn(), {});
      final repo = p.Repository();
      final c = PublicationController(
        repository: repo,
        account: p.Account()..publicationAuthorized = true,
        remote: () => remote,
        vpn: vpn,
      );
      await c.ready;
      await vpn.load();
      for (final (id, name) in users) {
        await vpn.saveUser(
          VpnUser(id: id, login: name.toLowerCase(), name: name),
        );
        final profile = vpn.workspace.profiles[id]!;
        repo.drafts[id] = PublicationDraft(
          workspaceId: vpn.workspace.id,
          deviceId: 'b' * 32,
          userId: id,
          name: name,
          headId: 'head-$id',
          hash: profile['hash'] as String,
          stamp: 'stamp-$id',
          bytes: Uint8List.fromList(utf8.encode(profile['yaml'] as String)),
          ancestors: {},
        );
      }
      await c.configure(PublicationAccess.private);
      await c.setEnabled(true);
      final folderId = c.settings!.folderId;
      remote.folders[folderId] = PublicationFile(
        id: folderId,
        name: 'Profiles',
        mimeType: 'application/vnd.google-apps.folder',
        version: '1',
        etag: 'folder-etag',
        editable: true,
        properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
      );
      final registryBytes = Uint8List.fromList(
        utf8.encode(
          canonicalJson({
            'version': 2,
            'workspaceId': vpn.workspace.id,
            'users': <String, dynamic>{},
          }),
        ),
      );
      remote.folders['registry-1'] = PublicationFile(
        id: 'registry-1',
        name: 'registry.json',
        mimeType: 'application/json',
        version: '1',
        etag: 'registry-etag',
        editable: true,
        properties: {
          'antirknWorkspace': vpn.workspace.id,
          'antirknUser': 'registry',
          'antirknHash': sha256.convert(registryBytes).toString(),
        },
      );
      remote.contents['registry-1'] = registryBytes;
      return (vpn, c, repo);
    }

    test(
      'UI-11 publishing one client requeues the interrupted batch',
      () async {
        const third = 'cccccccccccccccccccccccccccccccc';
        final remote = p.BlockingRemote();
        final (vpn, c, _) = await setUpPublication(remote, [
          (f.alice, 'Alice'),
          (f.bob, 'Bob'),
          (third, 'Charlie'),
        ]);
        addTearDown(() {
          c.dispose();
          vpn.dispose();
        });
        c.request(force: true);
        await remote.entered.future.timeout(const Duration(seconds: 5));
        final single = c.publishUser(third, force: true);
        // The requested client is shown in flight while the batch stops.
        expect(c.isUserInFlight(third), isTrue);
        remote.release.complete();
        await single.timeout(const Duration(seconds: 5));
        for (
          var i = 0;
          i < 200 &&
              [
                f.alice,
                f.bob,
                third,
              ].any((id) => c.queues[id]?['status'] != 'published');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        for (final id in [f.alice, f.bob, third]) {
          expect(c.queues[id]?['status'], 'published', reason: id);
        }
      },
    );

    test('UI-12 the switch edit is marked before the batch stops', () async {
      final remote = p.Remote();
      final (vpn, c, _) = await setUpPublication(remote, []);
      addTearDown(() {
        c.dispose();
        vpn.dispose();
      });
      final change = c.setEnabled(false);
      expect(c.editing, isTrue);
      expect(c.enabling, isFalse);
      await change;
      expect(c.editing, isFalse);
      expect(c.enabling, isNull);
      expect(c.settings?.enabled, isFalse);
    });

    test(
      'UI-13 picking a file blocks nothing; a binding blocks one client',
      () async {
        final remote = p.Remote();
        final (vpn, c, _) = await setUpPublication(remote, [
          (f.alice, 'Alice'),
          (f.bob, 'Bob'),
        ]);
        addTearDown(() {
          c.dispose();
          vpn.dispose();
        });
        c.bindingUserId = f.alice;
        expect(c.isUserBusy(f.alice), isTrue);
        expect(c.isUserBusy(f.bob), isFalse);
        c.bindingUserId = null;
        // Cancelling an inspection that waits on Drive returns at once.
        final gate = Completer<void>();
        final slow = _GatedRemote(gate);
        final (vpn2, c2, _) = await setUpPublication(slow, [
          (f.alice, 'Alice'),
        ]);
        addTearDown(() {
          c2.dispose();
          vpn2.dispose();
        });
        slow.armed = true;
        final inspection = c2.inspectFile(f.alice, PublicationTarget('file-1'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(c2.bindingUserId, f.alice);
        c2.cancelBinding();
        await expectLater(
          inspection.timeout(const Duration(seconds: 2)),
          throwsA(isA<SyncTransportFailure>()),
        );
        expect(c2.editing, isFalse);
        gate.complete();
      },
    );

    test(
      'UI-21 one unreadable document does not fail the whole state',
      () async {
        final remote = p.Remote();
        final (vpn, c, repo) = await setUpPublication(remote, [
          (f.alice, 'Alice'),
          (f.bob, 'Bob'),
        ]);
        addTearDown(() {
          c.dispose();
          vpn.dispose();
        });
        repo.queues[f.alice] = '{not json';
        repo.queues[f.bob] = '{"status":"waiting"}';
        await c.reload();
        expect(c.error, isNull);
        expect(c.queues[f.alice], isNull);
        expect(c.queues[f.bob]?['status'], 'waiting');
      },
    );
  });

  testWidgets('UI-15 back gesture ignores sideways content and dialogs', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    var backs = 0;
    await tester.pumpWidget(
      _app(
        DesktopBackGesture(
          canGoBack: () => true,
          onBack: () => backs++,
          child: Column(
            children: [
              SizedBox(
                height: 100,
                child: ListView(
                  key: const ValueKey('sideways'),
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var i = 0; i < 30; i++)
                      SizedBox(width: 100, child: Text('$i')),
                  ],
                ),
              ),
              const Expanded(child: SizedBox.expand(key: ValueKey('plain'))),
            ],
          ),
        ),
      ),
    );
    var clock = const Duration(seconds: 1);
    Future<void> swipe(Finder target) async {
      clock += const Duration(seconds: 2);
      final at = tester.getCenter(target);
      for (var i = 0; i < 4; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: at,
            scrollDelta: const Offset(60, 0),
            timeStamp: clock + Duration(milliseconds: 10 * i),
          ),
        );
      }
      await tester.pump(const Duration(milliseconds: 700));
    }

    await swipe(find.byKey(const ValueKey('plain')));
    expect(backs, 1);
    await swipe(find.byKey(const ValueKey('sideways')));
    expect(backs, 1, reason: 'horizontal list scroll is not Back');
    showDialog<void>(
      context: tester.element(find.byKey(const ValueKey('plain'))),
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();
    await swipe(find.text('dialog'));
    expect(backs, 1, reason: 'a dialog on top owns the gesture');
    expect(find.text('dialog'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  test('UI-17 an explicit refresh waits for the background poll', () async {
    final store = _GatedJournal();
    final remote = FakeRunnerTransport(store)..installed = true;
    final c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture|key',
      password: () => null,
      accessFailure: (_) {},
      store: store,
    );
    addTearDown(c.dispose);
    store.gate = Completer<void>();
    final poll = c.pollActiveJob();
    expect(c.backgroundBusy, isTrue);
    final before = remote.inspections;
    final refresh = c.refresh();
    store.gate!.complete();
    store.gate = null;
    await poll;
    await refresh;
    expect(remote.inspections, before + 1);
  });

  test('UI-18 a repeated update check says it was just checked', () async {
    final source = updates.Source();
    final c = ComponentUpdatesController(source: source);
    addTearDown(c.dispose);
    await c.check();
    expect(source.calls, 1);
    expect(c.throttled, isFalse);
    await c.check();
    expect(source.calls, 1);
    expect(c.throttled, isTrue);
  });

  testWidgets('UI-19 a failed client switch is reported', (tester) async {
    final store = f.MemoryVpn();
    final c = f.controller(store, {});
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
    });
    await tester.pumpWidget(
      _app(
        UsersPage(
          controller: c,
          serverName: (s) => s,
          exporter: _Export(),
          motion: MotionPreference.off,
        ),
      ),
    );
    await tester.pumpAndSettle();
    store.fail = true;
    await tester.tap(find.byKey(ValueKey('client-toggle-${f.alice}')));
    for (var i = 0; i < 20 && c.error == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    await tester.pump();
    expect(c.error, 'vpn_storage');
    expect(find.byType(SnackBar), findsOneWidget);
    expect(c.workspace.userById(f.alice)!.enabled, isTrue);
  });

  testWidgets('UI-24 settings pages follow destination ids', (tester) async {
    final hub = GlobalKey<SettingsHubState>();
    SettingsDestination page(String id) => SettingsDestination(
      id: id,
      title: 'Title $id',
      subtitle: '',
      icon: Icons.settings,
      content: TextField(key: ValueKey('field-$id')),
    );
    Widget build(List<String> ids) => _app(
      SettingsHub(
        key: hub,
        motion: MotionPreference.off,
        status: const Text('status'),
        statusDestinationId: 'sync',
        destinations: [for (final id in ids) page(id)],
      ),
    );
    await tester.pumpWidget(build(['interface', 'sync']));
    await tester.tap(find.text('status'));
    await tester.pumpAndSettle();
    expect(hub.currentState!.selectedId, 'sync');
    await tester.enterText(find.byKey(const ValueKey('field-sync')), 'draft');
    // A destination appears before the open one: the open page and its
    // draft stay.
    await tester.pumpWidget(build(['interface', 'backup', 'sync']));
    await tester.pumpAndSettle();
    expect(hub.currentState!.selectedId, 'sync');
    expect(find.text('draft'), findsOneWidget);
    // The open destination disappears: back to the menu, nothing else.
    await tester.pumpWidget(build(['interface', 'backup']));
    await tester.pumpAndSettle();
    expect(hub.currentState!.selected, 0);
  });
}

// ignore: camel_case_types
typedef f_vpn = VpnController;

class _Export implements ProfileExporter {
  @override
  Future<bool> save(String name, String source) async => true;
}

class _InboundRunner extends RunnerController {
  _InboundRunner(FakeRunnerTransport remote, MemoryRunnerJournal store)
    : super(
        serverId: 'fixture',
        transport: () => remote,
        identity: () => 'fixture|key',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
  @override
  PanelAccess? get panelAccess => PanelAccess.fromJson({
    'id': 'a' * 32,
    'port': 2053,
    'managed': false,
    'username': 'admin',
    'password': 'fixture',
    'panelVersion': '2.6.0',
    'xrayVersion': '25.1.1',
  });
  @override
  Future<Map<String, dynamic>?> readInbound(int id) async => {
    'row': {
      'id': id,
      'remark': 'Existing',
      'listen': '0.0.0.0',
      'port': 443,
      'protocol': 'vless',
      'enable': true,
      'streamSettings': jsonEncode({
        'network': 'tcp',
        'security': 'reality',
        'realitySettings': {
          'target': 'origin.example:443',
          'serverNames': ['original.example'],
        },
      }),
    },
  };
}

class _GatedJournal extends MemoryRunnerJournal {
  Completer<void>? gate;
  @override
  Future<String?> readRunnerJournal(String id) async {
    await gate?.future;
    return super.readRunnerJournal(id);
  }
}

class _GatedRemote extends p.Remote {
  _GatedRemote(this.gate);
  final Completer<void> gate;
  bool armed = false;
  @override
  Future<PublicationFile> getFile(String id) async {
    if (armed) await gate.future;
    return super.getFile(id);
  }
}
