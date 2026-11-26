import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart'
    show ShareLinkKind;
import 'package:flutter_test/flutter_test.dart';
import 'awg_test.dart' as awg;
import 'vpn_controller_test.dart' as f;

const carol = 'cccccccccccccccccccccccccccccccc';
const deviceA = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1',
    deviceB = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2';

VpnUser client(String id, {bool enabled = true}) => VpnUser(
  id: id,
  login: {f.alice: 'alice', f.bob: 'bob', carol: 'carol'}[id]!,
  name: {f.alice: 'Alice', f.bob: 'Bob', carol: 'Carol'}[id]!,
  enabled: enabled,
);

/// A store whose device identity can change, as when a synced document is
/// read on another device.
class Devices extends f.MemoryVpn implements WorkspaceIdentityStore {
  String device = deviceA;
  @override
  Future<WorkspaceIdentity> readWorkspaceIdentity() async =>
      WorkspaceIdentity(workspaceId: '0' * 32, deviceId: device);
}

List<Object?> sentUsers(f.Remote remote) =>
    remote.submissions.values.last['users'] as List;

/// The last users sent to [remote] but the test client of [target]'s
/// service mode.
List<Object?> realUsers(
  VpnController c,
  f.Remote remote, [
  String target = 'two',
]) => [
  for (final u in sentUsers(remote))
    if ((u as Map)['id'] != c.serviceTestClient(target)?.id) u,
];

Iterable<String> proxyNames(VpnController c, String user, String server) =>
    RegExp(
      'VLESS-[A-Za-z]+_Server $server[^\\s"\',}]*',
    ).allMatches(c.results[user]!.yaml!).map((m) => m.group(0)!);

Future<(VpnController, f.MemoryVpn, Map<String, f.Remote>)> applied({
  f.MemoryVpn? store,
  String Function()? source,
  Future<bool?> Function(String)? connectForDeletion,
  bool withAwg = false,
}) async {
  store ??= f.MemoryVpn();
  final remotes = <String, f.Remote>{
    'one': f.Remote(store),
    'two': f.Remote(store),
    if (withAwg) awgTarget('two'): awg.AwgRemote(store)..busyOnce = false,
  };
  final c = f.controller(
    store,
    remotes,
    source: source,
    connectForDeletion: connectForDeletion,
  );
  addTearDown(c.dispose);
  await f.setup(c);
  if (withAwg) {
    await c.saveAwg(AwgInterface(serverId: 'two', spec: awg.spec()));
  }
  await c.prepareAndApply();
  expect(c.error, isNull);
  return (c, store, remotes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the way back has one executor', () {
    test(
      'only it resumes; another device shows it and may take over',
      () async {
        // One synced document; the device reading it changes.
        final store = Devices();
        final (a, _, remotes) = await applied(store: store);
        final two = remotes.remove('two')!;
        await a.enterServiceMode('two');
        await a.saveUser(client(carol));
        await a.prepareAndApply();
        await a.exitServiceMode('two');
        expect(a.serviceModeOf('two')?.executor, deviceA);
        expect(a.serviceModeExiting('two'), isTrue);

        // Device B receives the synced document, server two reachable.
        remotes['two'] = two;
        final submitted = two.submissions.length;
        store.device = deviceB;
        final b = f.controller(store, remotes);
        addTearDown(b.dispose);
        await b.load();
        expect(b.serviceModeExiting('two'), isFalse);
        expect(b.serviceModeExitElsewhere('two'), isTrue);
        expect(b.serviceModeExitIssue('two'), 'vpn_service_mode_other_device');
        await b.reconcile();
        expect(two.submissions, hasLength(submitted));
        expect(b.serviceModeOf('two')?.state, ServerServiceState.returning);

        // An explicit retry on B takes it over and finishes it.
        await b.exitServiceMode('two');
        expect(b.error, isNull);
        expect(two.submissions, hasLength(submitted + 1));
        expect(
          sentUsers(two),
          contains(equals({'id': carol, 'enabled': true})),
        );
        expect(b.serviceModeOf('two'), isNull);

        // A, reloaded from a document where B executes, does not resume.
        await store.writeVpn(
          jsonEncode({
            ...jsonDecode(store.raw!) as Map,
            'version': 6,
            'serviceMode': {
              'two': {
                'version': 1,
                'state': 'returning',
                'since': DateTime.utc(2026).toIso8601String(),
                'executor': deviceB,
              },
            },
          }),
          expectedRevision: store.revision,
        );
        store.device = deviceA;
        final reloaded = f.controller(store, remotes);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(reloaded.serviceModeExiting('two'), isFalse);
        expect(reloaded.serviceModeExitElsewhere('two'), isTrue);
        final before = two.submissions.length;
        await reloaded.reconcile();
        expect(two.submissions, hasLength(before));
      },
    );
  });

  group('access changes from a readback', () {
    Map<String, dynamic> row(
      f.Remote remote,
      String id, {
      List<Map<String, dynamic>>? clients,
      Map<String, dynamic> extra = const {},
    }) {
      final base = remote.state.singleWhere((r) => r['id'] == id);
      return {...base, 'clients': ?clients, ...extra};
    }

    Map<String, dynamic> user(String id, bool enabled) => {
      'id': id,
      'enabled': enabled,
      'uuid': '${id.substring(0, 8)}-0000-4000-8000-000000000000',
    };

    test('never create again a resource the server no longer has', () async {
      final (c, _, remotes) = await applied();
      final two = remotes['two']!;
      await c.enterServiceMode('two');
      two.customState = [
        row(two, '3' * 32),
        // Removed outside the app: the runner keeps its last spec.
        row(two, '4' * 32, extra: {'deleted': true, 'exists': false}),
      ];
      final submitted = two.submissions.length;

      await c.saveUser(client(f.alice, enabled: false));
      await c.prepareAndApply();
      await c.reconcile();

      expect(two.submissions, hasLength(submitted + 1));
      final sent = two.submissions.values.last;
      final gone = (sent['resources'] as List).singleWhere(
        (r) => r['id'] == '4' * 32,
      );
      expect(gone['deleted'], isTrue);
      expect(gone['enabled'], isFalse);
      final kept = (sent['resources'] as List).singleWhere(
        (r) => r['id'] == '3' * 32,
      );
      expect(kept['deleted'], isFalse);
      expect(realUsers(c, two), [
        {'id': f.alice, 'enabled': false},
        {'id': f.bob, 'enabled': true},
      ]);
    });

    test(
      'a disabled record one resource lacks does not block a disable',
      () async {
        final (c, _, remotes) = await applied();
        final two = remotes['two']!;
        await c.enterServiceMode('two');
        // An AmneziaWG-like history: the first resource keeps a disabled
        // record of a removed client, a newer one never had it.
        const removed = 'dddddddddddddddddddddddddddddddd';
        two.customState = [
          row(
            two,
            '3' * 32,
            clients: [
              user(f.alice, true),
              user(f.bob, true),
              user(removed, false),
            ],
          ),
          row(two, '4' * 32, clients: [user(f.alice, true), user(f.bob, true)]),
        ];
        final submitted = two.submissions.length;

        await c.saveUser(client(f.alice, enabled: false));
        await c.prepareAndApply();
        await c.reconcile();

        expect(two.submissions, hasLength(submitted + 1));
        expect(realUsers(c, two), [
          {'id': f.alice, 'enabled': false},
          {'id': f.bob, 'enabled': true},
          {'id': removed, 'enabled': false},
        ]);

        // Enabled on one resource only: that would broaden access.
        two.customState = [
          row(
            two,
            '3' * 32,
            clients: [
              user(f.alice, true),
              user(f.bob, true),
              user(removed, true),
            ],
          ),
          row(two, '4' * 32, clients: [user(f.alice, true), user(f.bob, true)]),
        ];
        await c.retryServiceAccess('two');
        expect(c.serviceAccessIssue('two'), 'vpn_conflict');
        expect(two.submissions, hasLength(submitted + 1));
      },
    );
  });

  group('the test client of the mode', () {
    test(
      'lands on every protocol, gives links, leaves on the way back',
      () async {
        final (c, _, remotes) = await applied(withAwg: true);
        final two = remotes['two']!, awgRemote = remotes[awgTarget('two')]!;
        expect(c.serviceTestClient('two'), isNull);
        await c.enterServiceMode('two');
        final probe = c.serviceTestClient('two')!;
        expect(c.serviceTestClient(awgTarget('two'))!.id, probe.id);
        expect(
          c.serviceTestClient(ttTarget('two'))!.login,
          startsWith('antirkn-test-'),
        );
        expect(c.workspace.userById(probe.id), isNull);
        final vlessKey = (target: 'two', resource: '3' * 32);
        final awgKey = (target: awgTarget('two'), resource: 'd' * 32);
        // Not on the server yet: no link.
        expect(c.connections.serviceTestLink(vlessKey), isNull);

        await c.reconcile();

        expect(c.error, isNull);
        Matcher hasProbe() =>
            contains(equals({'id': probe.id, 'enabled': true}));
        expect(sentUsers(two), hasProbe());
        expect(sentUsers(awgRemote), hasProbe());
        final vless = c.connections.serviceTestLink(vlessKey)!;
        expect(vless.kind, ShareLinkKind.vless);
        expect(vless.text, startsWith('vless://'));
        expect(
          c.connections.serviceTestLink((target: 'two', resource: '4' * 32)),
          isNotNull,
        );
        final awgLink = c.connections.serviceTestLink(awgKey)!;
        expect(awgLink.kind, ShareLinkKind.awg);
        expect(awgLink.text, contains('[Interface]'));
        // Not a client: no profile, no count, nothing waits for it.
        expect(c.results.containsKey(probe.id), isFalse);
        expect(c.serviceAccessWaiting('two'), 0);
        expect(c.serviceModeExitNewClients('two'), 0);
        final submitted = two.submissions.length;
        await c.reconcile();
        expect(two.submissions, hasLength(submitted));

        await c.exitServiceMode('two');

        expect(c.error, isNull);
        expect(c.serviceModeOf('two'), isNull);
        expect(c.serviceTestClient('two'), isNull);
        Iterable<Object?> ids(f.Remote r) =>
            sentUsers(r).map((u) => (u as Map)['id']);
        expect(ids(two), isNot(contains(probe.id)));
        expect(ids(awgRemote), isNot(contains(probe.id)));
        expect(
          two.state.expand((r) => r['clients'] as List).map((u) => u['id']),
          isNot(contains(probe.id)),
        );
        expect(c.connections.serviceTestLink(vlessKey), isNull);

        // Each entry gets a new test client, so an old link stays dead.
        await c.enterServiceMode('two');
        expect(c.serviceTestClient('two')!.id, isNot(probe.id));
      },
    );
  });

  group('protocols change at once, without new clients', () {
    test('a new inbound reaches the server with its clients only', () async {
      final (c, _, remotes) = await applied();
      final two = remotes['two']!;
      await c.enterServiceMode('two');
      // The test client of the mode lands first.
      await c.reconcile();
      final submitted = two.submissions.length;
      await c.saveUser(client(carol));
      await c.prepareAndApply();
      expect(two.submissions, hasLength(submitted));

      final added = f.inbound('two', '5' * 32);
      await c.saveInbound(added);
      await c.prepareAndApply(serverIds: {'two'});

      expect(c.error, isNull);
      expect(two.submissions, hasLength(submitted + 1));
      final sent = two.submissions.values.last;
      expect((sent['resources'] as List).map((r) => r['id']), [
        '3' * 32,
        '4' * 32,
        '5' * 32,
      ]);
      expect(realUsers(c, two), [
        {'id': f.alice, 'enabled': true},
        {'id': f.bob, 'enabled': true},
      ]);
      expect(c.adoptionConfirmed('two', '5' * 32), isTrue);
      expect(c.serviceModeOf('two'), isNotNull);
      expect(proxyNames(c, f.alice, 'two'), isEmpty);

      // Nothing more to send: a second apply only reads the server.
      await c.prepareAndApply(serverIds: {'two'});
      await c.reconcile();
      expect(c.error, isNull);
      expect(two.submissions, hasLength(submitted + 1));
    });

    test('an AmneziaWG change applies with the clients it has', () async {
      final (c, _, remotes) = await applied(withAwg: true);
      final awgRemote = remotes[awgTarget('two')]!;
      await c.enterServiceMode('two');
      await c.reconcile();
      await c.saveUser(client(carol));
      await c.prepareAndApply();
      final submitted = awgRemote.submissions.length;

      await c.saveAwg(
        AwgInterface(serverId: 'two', spec: {...awg.spec(), 'mtu': 1300}),
      );
      await c.prepareAndApply(serverIds: {awgTarget('two')});

      expect(c.error, isNull);
      expect(awgRemote.submissions, hasLength(submitted + 1));
      final sent = awgRemote.submissions.values.last;
      expect((sent['resources'] as List).single['mtu'], 1300);
      expect(
        realUsers(c, awgRemote, awgTarget('two')).map((u) => (u as Map)['id']),
        [f.alice, f.bob],
      );
      expect(c.adoptionConfirmed(awgTarget('two'), 'd' * 32), isTrue);
    });

    test('a new server gets its protocol with the test client only', () async {
      final store = f.MemoryVpn();
      final remotes = {'one': f.Remote(store), 'two': f.Remote(store)};
      final c = f.controller(store, remotes);
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(client(f.alice));
      await c.saveInbound(f.inbound('one', '1' * 32));
      await c.prepareAndApply();
      await c.enterServiceMode('two');

      // Saved, not applied: the automatic round sends it.
      await c.saveInbound(f.inbound('two', '3' * 32));
      await c.reconcile();

      final two = remotes['two']!;
      expect(c.error, isNull);
      expect(two.submissions, hasLength(1));
      expect(
        (two.submissions.values.single['resources'] as List).single['id'],
        '3' * 32,
      );
      expect(sentUsers(two), [
        {'id': c.serviceTestClient('two')!.id, 'enabled': true},
      ]);
      expect(c.adoptionConfirmed('two', '3' * 32), isTrue);
    });
  });

  test(
    'a disable reaches a reachable target while the way back stalls',
    () async {
      final (c, _, remotes) = await applied(withAwg: true);
      final awgRemote = remotes[awgTarget('two')]!;
      await c.enterServiceMode('two');
      // The panel login was lost: VLESS is unreachable, AmneziaWG is not.
      remotes.remove('two');
      await c.exitServiceMode('two');
      expect(c.serviceModeOf('two')?.state, ServerServiceState.returning);
      expect(c.serviceModeExitIssue('two'), 'vpn_connection');
      final submitted = awgRemote.submissions.length;

      await c.saveUser(client(f.alice, enabled: false));
      await c.prepareAndApply();
      await c.reconcile();

      expect(awgRemote.submissions, hasLength(submitted + 1));
      final sent = awgRemote.submissions.values.last;
      expect(sent.containsKey('revokedUsers'), isFalse);
      expect(sent['users'], [
        {'id': f.alice, 'enabled': false},
        {'id': f.bob, 'enabled': true},
      ]);
      // The unreachable VLESS target still waits for it.
      expect(c.serviceAccessWaiting('two'), 1);
      expect(c.serviceAccessIssue('two'), 'vpn_connection');
      expect(c.serviceModeOf('two')?.state, ServerServiceState.returning);
    },
  );

  test('the way back retires a protocol removed meanwhile', () async {
    final (c, _, remotes) = await applied(withAwg: true);
    final awgRemote = remotes[awgTarget('two')]!;
    await c.enterServiceMode('two');
    final interface = c.workspace.awgInterfaces.single;
    await c.saveAwg(
      AwgInterface(
        serverId: 'two',
        spec: {...interface.spec, 'deleted': true, 'enabled': false},
      ),
    );
    expect(c.workspace.serverIds, isNot(contains(awgTarget('two'))));
    final submitted = awgRemote.submissions.length;

    await c.exitServiceMode('two');

    expect(c.error, isNull);
    expect(awgRemote.submissions, hasLength(submitted + 1));
    final retired =
        (awgRemote.submissions.values.last['resources'] as List).single;
    expect(retired['deleted'], isTrue);
    expect(c.serviceModeOf('two'), isNull);
  });

  test('the way back is not cancelled while a sent job may run', () async {
    final (c, _, remotes) = await applied();
    final two = remotes['two']!;
    await c.enterServiceMode('two');
    await c.saveUser(client(carol));
    await c.prepareAndApply();
    // The runner accepts the job, then the connection drops.
    two.loseReply = true;
    await c.exitServiceMode('two');
    expect(c.workspace.servers['two']!['pending'], isNotNull);
    remotes.remove('two');

    await c.cancelServiceModeExit('two');

    expect(c.error, 'vpn_busy');
    expect(c.serviceModeOf('two')?.state, ServerServiceState.returning);
  });

  test(
    'an unreachable server in service mode does not hold a removal',
    () async {
      final connecting = Completer<bool?>();
      late final Map<String, f.Remote> remotes;
      final (c, _, all) = await applied(
        connectForDeletion: (id) async =>
            id == 'two' ? connecting.future : remotes.containsKey(id),
      );
      remotes = all;
      final removed = <String>[];
      c.deletePublishedFile = (user, guard) async {
        await guard();
        removed.add(user.id);
      };
      await c.enterServiceMode('two');
      remotes.remove('two');

      await c
          .deleteUser(
            c.workspace.users.singleWhere((u) => u.id == f.alice),
            file: {
              'accountKey': 'account',
              'fileId': 'file',
              'registryId': 'registry',
              'folderId': 'folder',
            },
          )
          .timeout(const Duration(seconds: 10));

      expect(c.error, isNull);
      expect(removed, [f.alice]);
      expect(c.hasPendingRevocation('one'), isFalse);
      expect(c.hasPendingRevocation('two'), isTrue);

      // The background attempt is recorded by the next round.
      connecting.complete(false);
      await Future<void>.delayed(Duration.zero);
      await c.reconcile();
      final targets =
          c.workspace.users
                  .singleWhere((u) => u.id == f.alice)
                  .deletion!['targets']
              as Map;
      expect(targets['two']['connectionAttempts'], 1);
      expect(targets['two']['error'], 'vpn_connection');
    },
  );

  test('a background issue of a server goes away when it enters', () async {
    final (c, _, remotes) = await applied();
    remotes['two']!.failPlan = true;
    // Server two lacks a new resource: the automatic send fails there.
    await c.saveInbound(f.inbound('two', '5' * 32));
    await c.reconcile();
    expect(c.serverSyncIssue, 'vpn_connection');

    await c.enterServiceMode('two');

    expect(c.error, isNull);
    expect(c.serverSyncIssue, isNull);

    // One of unknown origin stays.
    c.serverSyncIssue = 'vpn_failed';
    await c.exitServiceMode('two');
    await c.cancelServiceModeExit('two');
    await c.enterServiceMode('one');
    expect(c.serverSyncIssue, 'vpn_failed');
  });

  group('template groups naming hidden proxies', () {
    String template(List<String> members) => jsonEncode({
      'proxies': <Object?>[],
      'proxy-groups': [
        {'name': 'Pick', 'type': 'select', 'proxies': members},
      ],
      'rules': ['MATCH,Pick'],
    });

    test('drop the reference, or keep the old profile when emptied', () async {
      var source = f.template;
      final (c, _, _) = await applied(source: () => source);
      final one = proxyNames(c, f.alice, 'one').toList();
      final two = proxyNames(c, f.alice, 'two').toList();
      source = template([...one, ...two, 'Ghost']);
      await c.refreshProfiles();
      expect(c.results[f.alice]!.hasBlockingErrors, isFalse);

      await c.enterServiceMode('two');

      final result = c.results[f.alice]!;
      expect(result.hasBlockingErrors, isFalse);
      expect(result.yaml, isNot(contains('Server two')));
      for (final name in one) {
        expect(result.yaml, contains(name));
      }
      // A genuinely unknown reference keeps its warning and stays.
      expect(result.yaml, contains('Ghost'));
      expect(
        result.diagnostics.map((d) => d.code),
        contains('unknown_proxy_reference'),
      );
      expect(c.workspace.profiles[f.alice]!['yaml'], result.yaml);

      // A group of hidden proxies only would be empty: blocking.
      await c.exitServiceMode('two');
      expect(c.serviceModeOf('two'), isNull);
      source = template(two);
      await c.refreshProfiles();
      final published = c.workspace.profiles[f.alice]!['hash'];
      await c.enterServiceMode('two');
      final blocked = c.results[f.alice]!;
      expect(blocked.hasBlockingErrors, isTrue);
      expect(
        blocked.diagnostics.where((d) => d.code == 'service_mode_group_empty'),
        [isA<ProfileDiagnostic>().having((d) => d.subject, 'subject', 'Pick')],
      );
      expect(c.workspace.profiles[f.alice]!['hash'], published);
    });
  });
}
