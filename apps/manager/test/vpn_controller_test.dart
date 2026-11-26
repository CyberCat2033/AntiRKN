import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/vpn/connection_checks.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const panel = '11111111111111111111111111111111';
const alice = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    bob = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const template =
    '{"proxies":[],"proxy-groups":[{"name":"ALL","type":"select","include-all-proxies":true}],"rules":["MATCH,ALL"]}';

class MemoryVpn implements VpnRepository {
  String? raw;
  int revision = 0;
  bool fail = false;
  @override
  Future<VpnStoredDocument> readVpn() async => VpnStoredDocument(raw, revision);
  @override
  Future<int> writeVpn(String source, {required int expectedRevision}) async {
    if (fail) throw const VaultFailure(VaultIssue.writeFailed);
    if (expectedRevision != revision) throw const VaultFailure(VaultIssue.busy);
    raw = source;
    return ++revision;
  }
}

class RestoredTargets implements WorkspaceRecoveryStore {
  final targets = <String>{'one', 'two'};
  @override
  Future<Set<String>> readRestoredTargets() async => Set.of(targets);
  @override
  Future<void> approveRestoredTargets(Iterable<String> approved) async =>
      targets.removeAll(approved);
}

class Remote implements RunnerTransport {
  Remote(this.store);
  final MemoryVpn store;
  final submissions = <String, Map<String, dynamic>>{};
  final actions = <String>[];
  bool loseReply = false,
      running = false,
      resumeStaysPartial = false,
      failBeforeSubmit = false,
      failPlan = false,
      failState = false;
  List<Map<String, dynamic>> state = [];
  List<Map<String, dynamic>>? customState;
  final jobs = <String, Map<String, dynamic>>{};
  @override
  String get bundledRelease => 'f' * 64;
  @override
  Future<RunnerInstallation> inspect(CancellationToken t) async =>
      throw UnimplementedError();
  @override
  Future<RunnerInstallation> install(
    RunnerInstallation p,
    CancellationToken t, {
    String? sudoPassword,
  }) async => throw UnimplementedError();
  Map<String, dynamic> response({
    List<Map<String, dynamic>> jobs = const [],
    Map<String, dynamic>? plan,
    List<Map<String, dynamic>>? state,
  }) => {
    'version': 1,
    'code': 'ok',
    'alive': true,
    'jobs': jobs,
    'vlessPlan': ?plan,
    'vlessState': ?(customState ?? state),
  };
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    final r = request.json, a = r['action'];
    actions.add(a as String);
    if (a == 'vless_plan') {
      if (failPlan) throw const SshFailure(SshIssue.disconnected);
      return RunnerResponse.fromJson(response(plan: {'fingerprint': 'e' * 64}));
    }
    if (a == 'vless_state') {
      if (failState) throw const SshFailure(SshIssue.disconnected);
      return RunnerResponse.fromJson(response(state: customState ?? state));
    }
    final id = r['id'] as String;
    if (a == 'submit') {
      if (failBeforeSubmit) {
        failBeforeSubmit = false;
        throw const SshFailure(SshIssue.disconnected);
      }
      expect(
        store.raw,
        contains(id),
        reason: 'Intent must be committed before mutation',
      );
      final p = Map<String, dynamic>.from(
        jsonDecode(r['payload'] as String) as Map,
      );
      submissions[id] = p;
      state =
          customState ??
          [
            for (final s in p['resources'] as List)
              {
                'id': s['id'],
                'workspaceId': p['workspaceId'],
                'spec': s,
                'confirmed': true,
                'revision': vlessRevision(Map<String, Object?>.from(p)),
                'publicKey': 'A' * 43,
                'shortId': '0123456789abcdef',
                'clients': [
                  for (final u in p['users'] as List)
                    {
                      'id': u['id'],
                      'enabled': u['enabled'],
                      'uuid':
                          '${(u['id'] as String).substring(0, 8)}-0000-4000-8000-${(s['id'] as String).substring(0, 12)}',
                    },
                ],
              },
          ];
      jobs.putIfAbsent(
        id,
        () => {
          'id': id,
          'kind': 'vless_apply',
          'count': r['count'],
          'interval': 1,
          'status': running ? 'running' : 'succeeded',
          'checkpoint': running ? 1 : r['count'],
          'sequence': 1,
          'cancelRequested': false,
          'events': <Object?>[],
        },
      );
      if (loseReply) {
        loseReply = false;
        throw const SshFailure(SshIssue.disconnected);
      }
      return RunnerResponse.fromJson(response(jobs: [jobs[id]!]));
    }
    if (!jobs.containsKey(id)) {
      return RunnerResponse.fromJson({...response(), 'code': 'missing'});
    }
    if (a == 'cancel') {
      jobs[id] = {...jobs[id]!, 'status': 'cancelled', 'cancelRequested': true};
    }
    if (a == 'resume' && !resumeStaysPartial) {
      jobs[id] = {
        ...jobs[id]!,
        'status': 'succeeded',
        'checkpoint': jobs[id]!['count'],
      };
    }
    return RunnerResponse.fromJson(response(jobs: [jobs[id]!]));
  }

  @override
  Future<void> emergencyReset(
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {}
}

class DelayedStatusRemote extends Remote {
  DelayedStatusRemote(super.store);
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    if (request.json['action'] == 'status') {
      if (!started.isCompleted) started.complete();
      await release.future;
    }
    return super.request(request, token, sudoPassword: sudoPassword);
  }
}

VlessInbound inbound(String server, String id) => VlessInbound(
  serverId: server,
  spec: {
    ...VlessInbound.defaults(),
    'id': id,
    'endpoint': '203.0.113.1',
    'sni': 'example.com',
    'target': 'example.com:443',
  },
);
VpnController controller(
  MemoryVpn store,
  Map<String, Remote> remotes, {
  String Function()? source,
  WorkspaceRecoveryStore? recovery,
  Future<bool?> Function(String serverId)? connectForDeletion,
  String? Function(String target)? remoteIssue,
}) => VpnController(
  repository: store,
  recovery: recovery,
  connectForDeletion: connectForDeletion,
  remoteIssue: remoteIssue,
  template: source ?? () => template,
  serverName: (id) => switch (id) {
    'one' => 'Server one',
    'two' => 'Server two',
    _ => id,
  },
  remote: (id) => remotes[id] == null
      ? null
      : VpnRemote(
          transport: remotes[id]!,
          panelId: panel,
          identity: 'identity-$id',
        ),
  timer: (d, f) => Timer(Duration.zero, () {}),
);
Future<void> setup(VpnController c) async {
  await c.load();
  await c.saveUser(VpnUser(id: alice, login: 'alice', name: 'Alice'));
  await c.saveUser(VpnUser(id: bob, login: 'bob', name: 'Bob'));
  for (final entry in [
    ('one', '1'),
    ('one', '2'),
    ('two', '3'),
    ('two', '4'),
  ]) {
    await c.saveInbound(inbound(entry.$1, entry.$2 * 32));
  }
}

Future<String> seedPausedPartial(
  VpnController c,
  MemoryVpn store,
  Remote remote,
) async {
  final payload = c.workspace.desired('one', panel);
  final jobId = '1' * 32;
  final request = RunnerRequest.vlessApply(jobId, payload, 'f' * 64);
  remote.jobs[jobId] = {
    'id': jobId,
    'kind': 'vless_apply',
    'count': request.json['count'],
    'interval': 1,
    'status': 'partially_applied',
    'checkpoint': (request.json['count'] as int) - 1,
    'sequence': 1,
    'cancelRequested': false,
    'events': <Object?>[],
  };
  remote.customState = [
    for (final inbound in c.workspace.inbounds.where(
      (inbound) => inbound.serverId == 'one',
    ))
      {
        'id': inbound.id,
        'workspaceId': c.workspace.resourceWorkspaceId('one'),
        'spec': inbound.spec,
        'confirmed': true,
        'revision': vlessRevision(payload),
        'publicKey': 'A' * 43,
        'shortId': '0123456789abcdef',
        'clients': <dynamic>[],
      },
  ];
  await store.writeVpn(
    jsonEncode({
      ...jsonDecode(store.raw!) as Map,
      'servers': {
        'one': {
          'identity': 'identity-one',
          'panelId': panel,
          'paused': true,
          'error': 'vpn_partially_applied',
          'authorizedPayload': jsonEncode(payload),
          'pending': request.json,
          'job': remote.jobs[jobId],
        },
      },
    }),
    expectedRevision: store.revision,
  );
  await c.load();
  return jobId;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'adding one client leaves existing compiled profiles untouched',
    () async {
      final store = MemoryVpn(), remote = Remote(store);
      final c = controller(store, {'one': remote});
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(VpnUser(id: alice, login: 'alice', name: 'Alice'));
      await c.saveInbound(inbound('one', '1' * 32));
      await c.prepareAndApply();
      final existing = c.results[alice];
      expect(existing?.hasBlockingErrors, isFalse);

      await c.saveUser(VpnUser(id: bob, login: 'bob', name: 'Bob'));
      await c.prepareAndApply();

      expect(identical(c.results[alice], existing), isTrue);
      expect(c.results[bob]?.hasBlockingErrors, isFalse);
      expect(c.results[bob]?.yaml, contains('bbbbbbbb-0000'));

      final previous = c.results[alice];
      final inboundBefore = c.workspace.inbounds.single;
      await c.saveInbound(
        VlessInbound(
          serverId: inboundBefore.serverId,
          spec: {...inboundBefore.spec, 'endpoint': '198.51.100.20'},
        ),
      );
      await c.prepareAndApply();
      expect(identical(c.results[alice], previous), isFalse);
      expect(c.results[alice]?.yaml, contains('198.51.100.20'));
    },
  );
  test(
    'independent servers reconcile together without losing records',
    () async {
      final store = MemoryVpn();
      final one = DelayedStatusRemote(store), two = DelayedStatusRemote(store);
      final c = controller(store, {'one': one, 'two': two});
      addTearDown(c.dispose);
      await setup(c);
      await c.prepare();
      final applying = c.apply();
      try {
        await one.started.future.timeout(const Duration(seconds: 3));
        await two.started.future.timeout(const Duration(seconds: 3));
        expect(c.workspace.servers['one']?['pending'], isNotNull);
        expect(c.workspace.servers['two']?['pending'], isNotNull);
      } finally {
        one.release.complete();
        two.release.complete();
        await applying;
      }
      expect(c.error, isNull);
      expect(c.workspace.servers['one']?['pending'], isNull);
      expect(c.workspace.servers['two']?['pending'], isNull);
      expect(
        VpnWorkspace.decode(store.raw!).servers.keys,
        containsAll(['one', 'two']),
      );
    },
  );
  test(
    'restored offline intentions wait for a fresh explicit plan and cannot replay on reconnect',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({'one': Remote(store), 'two': Remote(store)});
      final c = controller(store, remotes);
      await setup(c);
      // Obtain panel bindings first, then authorize an offline change.
      await c.prepare();
      await c.apply();
      await c.saveUser(
        VpnUser(id: alice, login: 'alice', name: 'Changed', enabled: false),
      );
      final connections = Map.of(remotes);
      remotes.clear();
      await c.prepare();
      await c.apply();
      expect(c.error, isNull);
      c.dispose();
      remotes.addAll(connections);
      for (final remote in remotes.values) {
        remote.actions.clear();
      }
      final recovery = RestoredTargets();
      final restored = controller(store, remotes, recovery: recovery);
      addTearDown(restored.dispose);
      await restored.load();
      await restored.reconcile();
      expect(restored.needsRestoreReview('one'), isTrue);
      expect(
        remotes.values.expand((r) => r.actions),
        isNot(contains('submit')),
      );
      await restored.reviewRestored('one');
      expect(
        remotes.values.expand((r) => r.actions),
        isNot(contains('submit')),
      );
      await restored.prepare();
      expect(restored.error, isNull);
      await restored.apply();
      expect(restored.error, isNull);
      expect(recovery.targets, isEmpty);
      expect(remotes.values.expand((r) => r.actions), contains('submit'));
    },
  );

  test(
    'restored pending request is queried by ID and never submitted during review',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({
        'one': Remote(store)..loseReply = true,
        'two': Remote(store),
      });
      final c = controller(store, remotes);
      await setup(c);
      await c.prepare();
      await c.apply();
      expect(c.workspace.servers['one']!['pending'], isNotNull);
      c.dispose();
      final recovery = RestoredTargets();
      final restored = controller(store, remotes, recovery: recovery);
      addTearDown(restored.dispose);
      await restored.load();
      for (final remote in remotes.values) {
        remote.actions.clear();
      }
      await restored.reconcile();
      await restored.reviewRestored('one');
      expect(restored.error, isNull);
      expect(remotes['one']!.actions, contains('status'));
      expect(remotes['one']!.actions, isNot(contains('submit')));
      expect(restored.workspace.servers['one']!['pending'], isNull);
    },
  );
  test(
    'two clients x two servers x two inbounds, only personal credentials in each YAML',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({'one': Remote(store), 'two': Remote(store)});
      final c = controller(store, remotes);
      addTearDown(c.dispose);
      await setup(c);
      expect(remotes.values.every((r) => r.submissions.isEmpty), isTrue);
      await c.prepare();
      expect(c.plans.length, 2);
      expect(remotes.values.every((r) => r.submissions.isEmpty), isTrue);
      await c.apply();
      expect(c.error, isNull);
      expect(c.results[alice]!.hasBlockingErrors, isFalse);
      expect(vlessUserAccesses(c.workspace, alice).length, 4);
      expect(c.results[alice]!.yaml, contains('aaaaaaaa-0000'));
      expect(c.results[alice]!.yaml, isNot(contains('bbbbbbbb-0000')));
      expect(c.results[bob]!.yaml, contains('bbbbbbbb-0000'));
      expect(c.results[bob]!.yaml, isNot(contains('aaaaaaaa-0000')));
      final before = c.results[alice]!.yaml;
      await c.saveUser(VpnUser(id: alice, login: 'alice', name: 'Renamed'));
      expect(
        c.results[alice]!.yaml,
        before!.replaceAll('Alice_Server', 'Renamed_Server'),
      );
      final restored = controller(store, remotes);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.workspace.users.length, 2);
      expect(restored.results[alice]!.yaml, c.results[alice]!.yaml);
    },
  );
  test(
    'forced profile regeneration refreshes readback without submitting a plan',
    () async {
      final store = MemoryVpn(), remote = Remote(store);
      final c = controller(store, {'one': remote});
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(VpnUser(id: alice, login: 'alice', name: 'Alice'));
      final original = inbound('one', '1' * 32);
      await c.saveInbound(original);
      await c.prepareAndApply();
      expect(c.results[alice]!.hasBlockingErrors, isFalse);

      final changed = VlessInbound(
        serverId: original.serverId,
        spec: {...original.spec, 'endpoint': '198.51.100.20'},
      );
      await c.saveInbound(changed);
      expect(c.results[alice]!.diagnostics.single.code, 'vpn_pending_settings');
      expect(
        c.results[alice]!.diagnostics.single.subject,
        'VLESS · Server one · VLESS',
      );
      remote.state = [
        for (final observation in remote.state)
          {...observation, 'spec': changed.spec},
      ];
      final submitted = remote.submissions.length;
      remote.actions.clear();

      await c.regenerateProfile(alice);

      expect(c.error, isNull);
      expect(c.results[alice]!.hasBlockingErrors, isFalse);
      expect(c.results[alice]!.yaml, contains('198.51.100.20'));
      expect(remote.actions, ['vless_state']);
      expect(remote.submissions, hasLength(submitted));
    },
  );
  test(
    'uncertain reply replays the persisted operation ID after controller restart',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({
        'one': Remote(store)..loseReply = true,
        'two': Remote(store),
      });
      final c = controller(store, remotes);
      await setup(c);
      await c.prepare();
      await c.apply();
      expect(c.workspace.servers['one']!['pending'], isNotNull);
      final id = remotes['one']!.submissions.keys.single;
      c.dispose();
      final next = controller(store, remotes);
      addTearDown(next.dispose);
      await next.load();
      await next.reconcile();
      expect(remotes['one']!.submissions.keys, [id]);
      expect(next.workspace.servers['one']!['pending'], isNull);
      expect(next.results[alice]!.hasBlockingErrors, isFalse);
    },
  );
  test(
    'offline revocation waits, approved plan applies automatically on reconnection',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({'one': Remote(store), 'two': Remote(store)});
      final c = controller(store, remotes);
      addTearDown(c.dispose);
      await setup(c);
      await c.prepare();
      await c.apply();
      final offline = remotes.remove('two')!;
      await c.saveUser(
        VpnUser(id: alice, login: 'alice', name: 'Alice', enabled: false),
      );
      await c.prepare();
      expect(c.plans.where((p) => p.preview == null).length, 1);
      await c.apply();
      expect((offline.state.first['clients'] as List).first['enabled'], isTrue);
      remotes['two'] = offline;
      await c.reconcile();
      expect(
        offline.state.every(
          (r) => (r['clients'] as List).first['enabled'] == false,
        ),
        isTrue,
      );
      expect(c.workspace.servers['two']!['pending'], isNull);
    },
  );
  test('failed local intent write causes zero server submissions', () async {
    final store = MemoryVpn(), remotes = <String, Remote>{};
    remotes.addAll({'one': Remote(store), 'two': Remote(store)});
    final c = controller(store, remotes);
    addTearDown(c.dispose);
    await setup(c);
    await c.prepare();
    store.fail = true;
    await c.apply();
    expect(c.error, 'vpn_storage');
    expect(remotes.values.every((r) => r.submissions.isEmpty), isTrue);
  });
  test(
    'duplicate client login rejected, invalid template preserves last valid revision',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({'one': Remote(store), 'two': Remote(store)});
      var source = template;
      final c = controller(store, remotes, source: () => source);
      addTearDown(c.dispose);
      await setup(c);
      await c.prepare();
      await c.apply();
      final good = c.workspace.profiles[alice]!['yaml'];
      await c.saveUser(
        VpnUser(id: 'e' * 32, login: 'ALICE', name: 'Collision'),
      );
      expect(c.error, 'vpn_duplicate');
      expect(c.workspace.users.length, 2);
      source = '[invalid';
      await c.reconcile();
      expect(c.results[alice]!.hasBlockingErrors, isTrue);
      expect(c.workspace.profiles[alice]!['yaml'], good);
    },
  );
  test('offline cancellation is sent before any resubmission', () async {
    final store = MemoryVpn(), remotes = <String, Remote>{};
    remotes.addAll({
      'one': Remote(store)..running = true,
      'two': Remote(store),
    });
    final c = controller(store, remotes);
    addTearDown(c.dispose);
    await setup(c);
    await c.prepare();
    await c.apply();
    final offline = remotes.remove('one')!;
    await c.cancel('one');
    offline.actions.clear();
    remotes['one'] = offline;
    await c.reconcile();
    expect(offline.actions.first, 'cancel');
    expect(offline.actions, isNot(contains('submit')));
    expect((c.workspace.servers['one']!['job'] as Map)['status'], 'cancelled');
  });
  test(
    'cancel queued offline intent prevents submission after reconnect',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({'one': Remote(store), 'two': Remote(store)});
      final c = controller(store, remotes);
      addTearDown(c.dispose);
      await setup(c);
      await c.prepare();
      await c.apply();
      final offline = remotes.remove('two')!;
      final before = offline.submissions.length;
      await c.saveUser(
        VpnUser(id: alice, login: 'alice', name: 'Alice', enabled: false),
      );
      await c.prepare();
      await c.apply();
      await c.cancel('two');
      remotes['two'] = offline;
      await c.reconcile();
      expect(offline.submissions.length, before);
    },
  );
  test(
    'unconfirmed cancellation cannot be replaced with another job',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({
        'one': Remote(store)..running = true,
        'two': Remote(store),
      });
      final c = controller(store, remotes);
      addTearDown(c.dispose);
      await setup(c);
      await c.prepare();
      await c.apply();
      remotes.remove('one');
      await c.cancel('one');
      final pending = c.workspace.servers['one']!['pending'];
      await c.prepare();
      expect(c.error, 'vpn_busy');
      expect(c.plans, isEmpty);
      expect(c.workspace.servers['one']!['pending'], pending);
    },
  );
  test(
    'cancel after submission never reached server clears durable intent',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({
        'one': Remote(store)..failBeforeSubmit = true,
        'two': Remote(store),
      });
      final c = controller(store, remotes);
      addTearDown(c.dispose);
      await setup(c);
      await c.prepare();
      await c.apply();
      expect(c.workspace.servers['one']!['pending'], isNotNull);
      await c.cancel('one');
      expect(c.workspace.servers['one']!['pending'], isNull);
      await c.reconcile();
      expect(remotes['one']!.submissions, isEmpty);
    },
  );
  test(
    'forget inaccessible server retires local resources without claiming revocation',
    () async {
      final store = MemoryVpn();
      final remotes = <String, Remote>{
        'one': Remote(store)..running = true,
        'two': Remote(store),
      };
      final c = controller(store, remotes);
      addTearDown(c.dispose);
      await setup(c);
      await c.prepare();
      await c.apply();
      expect(c.workspace.servers['one']!['pending'], isNotNull);
      final inaccessible = remotes.remove('one')!;
      inaccessible.actions.clear();
      await c.deleteUser(
        c.workspace.users.singleWhere((user) => user.id == alice),
      );
      expect(c.hasPendingRevocation('one'), isTrue);
      expect(c.hasRunning, isTrue);
      expect(c.hasLocalServerState('one'), isTrue);
      expect(c.orphanedPhysicalServerIds({'two'}), {'one'});

      expect(await c.forgetServersLocally({'one'}), isTrue);

      expect(inaccessible.actions, isEmpty);
      expect(
        c.workspace.inbounds
            .where((resource) => resource.serverId == 'one')
            .every((resource) => resource.deleted && !resource.enabled),
        isTrue,
      );
      expect(
        c.workspace.inbounds
            .where((resource) => resource.serverId == 'two')
            .every((resource) => !resource.deleted && resource.enabled),
        isTrue,
      );
      final forgotten = c.workspace.servers['one']!;
      expect(forgotten['pending'], isNull);
      expect(forgotten['job'], isNull);
      expect(forgotten['operation'], isNull);
      expect(forgotten['observed'], isEmpty);
      expect(forgotten['forgottenLocallyAt'], isA<String>());
      final deleted = c.workspace.users.singleWhere((user) => user.id == alice);
      expect(deleted.deletion!['targets']['one']['status'], 'abandoned');
      expect(deleted.revocationComplete, isFalse);
      expect(deleted.revocationSettled, isTrue);
      expect(deleted.deletionComplete, isTrue);
      expect(c.hasPendingRevocation('one'), isFalse);
      expect(c.hasRunning, isFalse);
      expect(c.hasLocalServerState('one'), isFalse);
      expect(c.orphanedPhysicalServerIds({'two'}), isEmpty);
      expect(c.results[bob]!.hasBlockingErrors, isFalse);
      expect(c.workspace.serverIds, {'two'});

      await c.saveUser(
        VpnUser(
          id: 'cccccccccccccccccccccccccccccccc',
          login: 'charlie',
          name: 'Charlie',
          enabled: true,
        ),
      );
      await c.prepareAndApply();
      expect(c.workspace.serverIds, {'two'});
      expect(c.hasLocalServerState('one'), isFalse);
      expect(c.workspace.servers['one']?['authorizedPayload'], isNull);
      expect(c.workspace.servers['one']?['paused'], isTrue);
    },
  );

  test(
    'orphaned server with offline authorizedPayload is detected and forgotten without resurrecting',
    () async {
      final store = MemoryVpn();
      final remotes = <String, Remote>{'two': Remote(store)};
      final c = controller(store, remotes);
      addTearDown(c.dispose);
      await setup(c);
      await store.writeVpn(
        jsonEncode({
          ...jsonDecode(store.raw!) as Map,
          'servers': {
            'ghost': {
              'authorizedPayload': jsonEncode({
                'version': 1,
                'resources': <dynamic>[],
                'users': <dynamic>[],
              }),
              'paused': false,
            },
          },
        }),
        expectedRevision: store.revision,
      );
      await c.load();
      expect(c.orphanedPhysicalServerIds({'one', 'two'}), {'ghost'});
      expect(await c.forgetServersLocally({'ghost'}), isTrue);
      expect(c.orphanedPhysicalServerIds({'one', 'two'}), isEmpty);
      expect(c.workspace.servers['ghost']?['authorizedPayload'], isNull);
      expect(c.workspace.servers['ghost']?['paused'], isTrue);
      expect(c.workspace.serverIds, {'one', 'two'});
      await c.prepareAndApply();
      expect(c.workspace.servers['ghost']?['authorizedPayload'], isNull);
      expect(c.workspace.servers['ghost']?['paused'], isTrue);
      expect(c.workspace.serverIds, {'one', 'two'});
    },
  );

  test(
    'reconcile succeeds and confirms active resource when deleted inbounds have older revision or are omitted',
    () async {
      final store = MemoryVpn();
      final remote = Remote(store);
      final c = controller(store, {'one': remote});
      addTearDown(c.dispose);
      await setup(c);

      final inbounds = c.workspace.inbounds
          .where((r) => r.serverId == 'one')
          .toList();
      expect(inbounds.length, 2);
      final active = inbounds[0];
      final deleted = inbounds[1];

      // Mark one inbound deleted
      await c.deleteInbounds([deleted]);
      expect(
        c.workspace.inbounds.where((r) => r.serverId == 'one' && r.deleted),
        hasLength(1),
      );

      // Custom mock state where deleted inbound has an older revision and active inbound has expected revision
      remote.customState = [
        {
          'id': active.id,
          'workspaceId': c.workspace.resourceWorkspaceId('one'),
          'spec': active.spec,
          'confirmed': true,
          'revision': vlessRevision(c.workspace.desired('one', panel)),
          'publicKey': 'A' * 43,
          'shortId': '0123456789abcdef',
          'clients': <dynamic>[],
        },
        {
          'id': deleted.id,
          'workspaceId': c.workspace.resourceWorkspaceId('one'),
          'spec': {...deleted.spec, 'deleted': true, 'enabled': false},
          'confirmed': true,
          'deleted': true,
          'exists': false,
          'revision': 'older-stale-revision-00000000000',
          'clients': <dynamic>[],
        },
      ];

      await c.prepareAndApply(serverIds: {'one'});
      expect(c.error, isNull);
      expect(c.workspace.servers['one']?['pending'], isNull);
      expect(c.workspace.servers['one']?['paused'], isFalse);
      expect(c.adoptionConfirmed('one', active.id), isTrue);
    },
  );

  test(
    'resume unpauses and completes when remote job status is succeeded',
    () async {
      final store = MemoryVpn();
      final remote = Remote(store);
      final c = controller(store, {'one': remote});
      addTearDown(c.dispose);
      await setup(c);

      final inbounds = c.workspace.inbounds
          .where((r) => r.serverId == 'one')
          .toList();
      final payload = c.workspace.desired('one', panel);
      final jobId = '1' * 32;
      final req = RunnerRequest.vlessApply(jobId, payload, 'f' * 64);
      remote.jobs[jobId] = {
        'id': jobId,
        'kind': 'vless_apply',
        'count': 2,
        'interval': 1,
        'status': 'succeeded',
        'checkpoint': 2,
        'sequence': 1,
        'cancelRequested': false,
        'events': <Object?>[],
      };
      remote.customState = [
        for (final ib in inbounds)
          {
            'id': ib.id,
            'workspaceId': c.workspace.resourceWorkspaceId('one'),
            'spec': ib.spec,
            'confirmed': true,
            'revision': vlessRevision(payload),
            'publicKey': 'A' * 43,
            'shortId': '0123456789abcdef',
            'clients': <dynamic>[],
          },
      ];

      // Simulate a server paused with pending request whose job already succeeded on remote
      await store.writeVpn(
        jsonEncode({
          ...jsonDecode(store.raw!) as Map,
          'servers': {
            'one': {
              'identity': 'identity-one',
              'panelId': panel,
              'paused': true,
              'error': 'vpn_conflict',
              'pending': req.json,
            },
          },
        }),
        expectedRevision: store.revision,
      );
      await c.load();

      expect(c.workspace.servers['one']?['paused'], isTrue);
      expect(c.workspace.servers['one']?['pending'], isNotNull);

      await c.resume('one');
      expect(c.error, isNull);
      expect(c.workspace.servers['one']?['paused'], isFalse);
      expect(c.workspace.servers['one']?['pending'], isNull);
      expect(c.adoptionConfirmed('one', inbounds.first.id), isTrue);
    },
  );
  test(
    'paused partial VLESS job resumes automatically with its saved ID',
    () async {
      final store = MemoryVpn(), remote = Remote(store);
      final c = controller(store, {'one': remote});
      addTearDown(c.dispose);
      await setup(c);
      final jobId = await seedPausedPartial(c, store, remote);

      await c.reconcile();

      expect(c.error, isNull);
      expect(remote.actions, contains('resume'));
      expect(remote.submissions, isEmpty);
      expect(c.workspace.servers['one']?['autoResumeAttemptedId'], jobId);
      expect(c.workspace.servers['one']?['pending'], isNull);
      expect(c.workspace.servers['one']?['paused'], isFalse);
    },
  );
  test('automatic VLESS resume is attempted only once per saved job', () async {
    final store = MemoryVpn(),
        remote = Remote(store)..resumeStaysPartial = true;
    final c = controller(store, {'one': remote});
    addTearDown(c.dispose);
    await setup(c);
    final jobId = await seedPausedPartial(c, store, remote);

    await c.reconcile();
    expect(remote.actions.where((action) => action == 'resume'), hasLength(1));
    expect(c.workspace.servers['one']?['autoResumeAttemptedId'], jobId);
    expect(c.workspace.servers['one']?['pending'], isNotNull);
    expect(c.workspace.servers['one']?['paused'], isTrue);

    await c.load();
    await c.reconcile();
    expect(remote.actions.where((action) => action == 'resume'), hasLength(1));
    expect(remote.submissions, isEmpty);
  });
  test('changed desired access is never resumed automatically', () async {
    final store = MemoryVpn(), remote = Remote(store);
    final c = controller(store, {'one': remote});
    addTearDown(c.dispose);
    await setup(c);
    await seedPausedPartial(c, store, remote);
    await c.saveUser(
      VpnUser(id: alice, login: 'alice', name: 'Alice', enabled: false),
    );

    await c.reconcile();

    expect(remote.actions, isNot(contains('resume')));
    expect(c.workspace.servers['one']?['pending'], isNotNull);
    expect(c.workspace.servers['one']?['paused'], isTrue);
  });
  test(
    'syncAllServersAndProfiles polls servers in parallel and rebuilds profiles',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({'one': Remote(store), 'two': Remote(store)});
      final c = controller(store, remotes);
      await setup(c);
      await c.prepare();
      await c.apply();

      remotes['one']!.actions.clear();
      remotes['two']!.actions.clear();

      final sync = await c.syncAllServersAndProfiles();

      expect(sync.verified, isTrue);
      expect(c.error, isNull);
      expect(remotes['one']!.actions, contains('vless_state'));
      expect(remotes['two']!.actions, contains('vless_state'));
      expect(c.results[alice]?.hasBlockingErrors, isFalse);
      expect(c.results[bob]?.hasBlockingErrors, isFalse);
    },
  );
  test(
    'saved server verification skips SSH until desired access changes',
    () async {
      final store = MemoryVpn();
      final remotes = <String, Remote>{
        'one': Remote(store),
        'two': Remote(store),
      };
      final c = controller(store, remotes);
      await setup(c);
      await c.prepare();
      await c.apply();
      expect(c.hasCurrentVerifiedProfiles, isTrue);

      for (final remote in remotes.values) {
        remote.actions.clear();
      }
      final cached = await c.syncAllServersAndProfiles(
        allowVerifiedSnapshot: true,
      );
      expect(cached.verified, isTrue);
      expect(cached.usedSavedVerification, isTrue);
      expect(remotes.values.every((remote) => remote.actions.isEmpty), isTrue);

      final fresh = await c.syncAllServersAndProfiles();
      expect(fresh.verified, isTrue);
      expect(fresh.usedSavedVerification, isFalse);
      expect(remotes['one']!.actions, contains('vless_state'));
      // Settled servers are read, never planned or applied again: an apply
      // would restart their core and drop live sessions.
      for (final remote in remotes.values) {
        expect(remote.actions, isNot(contains('vless_plan')));
        expect(remote.actions, isNot(contains('submit')));
      }

      await c.saveUser(
        VpnUser(id: alice, login: 'alice', name: 'Alice', enabled: false),
      );
      expect(c.hasCurrentVerifiedProfiles, isFalse);
      for (final remote in remotes.values) {
        remote.actions.clear();
      }
      final changed = await c.syncAllServersAndProfiles(
        allowVerifiedSnapshot: true,
      );
      expect(changed.usedSavedVerification, isFalse);
      expect(remotes['one']!.actions, contains('vless_plan'));
    },
  );
  test(
    'ordinary publish rebuilds a changed base template without checking unchanged servers',
    () async {
      final store = MemoryVpn();
      final remotes = <String, Remote>{
        'one': Remote(store),
        'two': Remote(store),
      };
      var source = template;
      final c = controller(store, remotes, source: () => source);
      addTearDown(c.dispose);
      await setup(c);
      await c.prepare();
      await c.apply();
      expect(c.hasCurrentVerifiedProfiles, isTrue);
      final oldHash = c.workspace.profiles[alice]?['hash'];

      source = template.replaceFirst(
        '"MATCH,ALL"',
        '"DOMAIN-SUFFIX,example.com,ALL","MATCH,ALL"',
      );
      for (final remote in remotes.values) {
        remote.actions.clear();
        remote.failState = true;
      }
      expect(c.hasCurrentVerifiedProfiles, isFalse);

      final sync = await c.syncAllServersAndProfiles(
        allowVerifiedSnapshot: true,
      );

      expect(sync.verified, isTrue);
      expect(sync.usedSavedVerification, isTrue);
      expect(c.workspace.profiles[alice]?['hash'], isNot(oldHash));
      expect(c.results[alice]?.hasBlockingErrors, isFalse);
      expect(remotes.values.every((remote) => remote.actions.isEmpty), isTrue);
    },
  );
  test(
    'syncAllServersAndProfiles isolates single server failure without aborting remaining servers',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({'one': Remote(store), 'two': Remote(store)});
      final c = controller(store, remotes);
      await setup(c);
      await c.prepare();
      await c.apply();

      remotes['one']!.actions.clear();
      remotes['two']!.actions.clear();
      remotes['two']!.failState = true;

      final sync = await c.syncAllServersAndProfiles();

      expect(sync.verified, isFalse);
      expect(sync.issue, 'vpn_connection');
      expect(c.error, 'vpn_connection');
      expect(remotes['one']!.actions, contains('vless_state'));
      expect(c.results[alice], isNotNull);
    },
  );
  test(
    'server check keeps prepare failure after successful state read',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({'one': Remote(store), 'two': Remote(store)});
      final c = controller(store, remotes);
      await setup(c);
      await c.prepare();
      await c.apply();
      // A changed client needs a plan; settled servers are only read.
      await c.saveUser(
        VpnUser(id: alice, login: 'alice', name: 'Alice', enabled: false),
      );
      remotes['one']!.failPlan = true;

      final failed = await c.syncAllServersAndProfiles();
      expect(failed.verified, isFalse);
      expect(failed.issue, 'vpn_connection');
      expect(c.serverSyncIssue, 'vpn_connection');
      expect(remotes['one']!.actions, contains('vless_state'));

      remotes['one']!.failPlan = false;
      final recovered = await c.syncAllServersAndProfiles();
      expect(recovered.verified, isTrue);
      expect(c.serverSyncIssue, isNull);
    },
  );
  test(
    'test_flutter_pending_auto_cleanup: runner reset clears vpn pending state and restores readback',
    () async {
      final store = MemoryVpn(), remotes = <String, Remote>{};
      remotes.addAll({'one': Remote(store), 'two': Remote(store)});
      final c = controller(store, remotes);
      addTearDown(c.dispose);
      await setup(c);

      const inboundOne = '11111111111111111111111111111111';
      final inbSpec = c.workspace.inbounds
          .firstWhere((i) => i.id == inboundOne)
          .spec;

      c.workspace = c.workspace.copy(
        servers: {
          ...c.workspace.servers,
          'one': {
            'identity': 'identity-one',
            'panelId': panel,
            'pending': {
              'jobId': 'job-1234',
              'startedAt': DateTime.now().toUtc().toIso8601String(),
            },
            'observed': [
              {
                'id': inboundOne,
                'confirmed': true,
                'workspaceId': c.workspace.resourceWorkspaceId('one'),
                'spec': inbSpec,
              },
            ],
          },
        },
      );

      expect(c.adoptionConfirmed('one', inboundOne), isFalse);
      final key = (target: 'one', resource: inboundOne);
      expect(
        c.connections.evaluateReadiness(key).state,
        InboundReadinessState.pendingOperation,
      );

      final runnerEvents = ChangeNotifier();
      var isIdle = false;
      c.bindRunner('one', runnerEvents, () => isIdle);

      isIdle = true;
      runnerEvents.notifyListeners();

      expect(c.workspace.servers['one']?['pending'], isNull);
      expect(c.adoptionConfirmed('one', inboundOne), isTrue);
      expect(
        c.connections.evaluateReadiness(key).state,
        InboundReadinessState.ready,
      );
    },
  );
  group('a job snapshot without its request', () {
    Future<(VpnController, MemoryVpn, Remote, String)> stale() async {
      final store = MemoryVpn();
      final remote = Remote(store);
      final remotes = {'one': remote, 'two': Remote(store)};
      final c = controller(store, remotes);
      await setup(c);
      await c.prepare();
      await c.apply();
      final doc = jsonDecode(store.raw!) as Map<String, dynamic>;
      final record = (doc['servers'] as Map)['one'] as Map;
      expect(record['pending'], isNull);
      final job = Map<String, dynamic>.from(record['job'] as Map);
      record['job'] = {...job, 'status': 'planned', 'checkpoint': 0};
      store.raw = jsonEncode(doc);
      c.dispose();
      final reloaded = controller(store, remotes);
      await reloaded.load();
      expect(reloaded.currentJob('one')!.status, 'planned');
      return (reloaded, store, remote, job['id'] as String);
    }

    test('takes the real outcome from the runner', () async {
      final (c, _, _, _) = await stale();
      addTearDown(c.dispose);
      await c.reconcile();
      expect(c.currentJob('one')!.status, 'succeeded');
    });

    test('is dropped once the runner no longer knows the job', () async {
      final (c, _, remote, id) = await stale();
      addTearDown(c.dispose);
      remote.jobs.remove(id);
      await c.reconcile();
      expect(c.currentJob('one'), isNull);
    });
  });

  group('service mode', () {
    const carol = 'cccccccccccccccccccccccccccccccc';
    Iterable<String> proxyNames(VpnController c, String user, String server) =>
        RegExp(
          'VLESS-[A-Za-z]+_Server $server[^\\s"\',}]*',
        ).allMatches(c.results[user]!.yaml!).map((m) => m.group(0)!);

    Future<(VpnController, MemoryVpn, Map<String, Remote>)> applied() async {
      final store = MemoryVpn();
      final remotes = {'one': Remote(store), 'two': Remote(store)};
      final c = controller(store, remotes);
      addTearDown(c.dispose);
      await setup(c);
      await c.prepareAndApply();
      expect(c.error, isNull);
      expect(c.hasCurrentVerifiedProfiles, isTrue);
      return (c, store, remotes);
    }

    test(
      'entering leaves profiles at once and keeps other proxy names',
      () async {
        final (c, store, remotes) = await applied();
        final names = proxyNames(c, alice, 'one').toList();
        expect(names, hasLength(2));
        expect(proxyNames(c, alice, 'two'), hasLength(2));
        final actions = remotes['two']!.actions.length;

        await c.enterServiceMode('two');

        expect(c.error, isNull);
        expect(remotes['two']!.actions, hasLength(actions));
        expect(c.serviceModeOf('awg/two')?.state, ServerServiceState.active);
        expect(c.results[alice]!.hasBlockingErrors, isFalse);
        expect(proxyNames(c, alice, 'two'), isEmpty);
        expect(proxyNames(c, alice, 'one'), names);
        expect(
          c.workspace.profiles[alice]!['yaml'],
          isNot(contains('Server two')),
        );
        expect(c.clientCountOn('two'), 0);
        expect(c.clientCountOn('one'), 2);
        expect(c.hasCurrentVerifiedProfiles, isTrue);
        // The change is saved and synced with the workspace.
        final saved = VpnWorkspace.decode(store.raw!);
        expect(saved.serviceModeOf('two')?.state, ServerServiceState.active);
        final reloaded = controller(store, remotes);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(reloaded.serviceModeOf('two'), saved.serviceModeOf('two'));
        expect(proxyNames(reloaded, alice, 'two'), isEmpty);
      },
    );

    test(
      'a new client is provisioned only outside it and its profile compiles',
      () async {
        final (c, _, remotes) = await applied();
        await c.enterServiceMode('two');
        // The test client of the mode lands first.
        await c.reconcile();
        final submitted = remotes['two']!.submissions.length;
        final actions = remotes['two']!.actions.length;

        await c.saveUser(VpnUser(id: carol, login: 'carol', name: 'Carol'));
        await c.prepareAndApply();

        expect(c.error, isNull);
        expect(remotes['two']!.actions, hasLength(actions));
        expect(remotes['two']!.submissions, hasLength(submitted));
        expect(
          remotes['one']!.submissions.values.last['users'],
          contains(containsPair('id', carol)),
        );
        // Server two never saw carol, yet nothing waits for it.
        final result = c.results[carol]!;
        expect(result.hasBlockingErrors, isFalse);
        expect(result.yaml, contains('cccccccc-0000'));
        expect(proxyNames(c, carol, 'two'), isEmpty);
        expect(c.hasUnappliedActiveAccess, isFalse);
        expect(c.missingOnServer('two'), 0);
        expect(c.hasCurrentVerifiedProfiles, isTrue);
        expect(c.serverSyncIssue, isNull);

        // A person's explicit apply reads it and finds nothing to send:
        // carol is never added there.
        await c.prepareAndApply(serverIds: {'two'});
        expect(c.error, isNull);
        expect(remotes['two']!.submissions, hasLength(submitted));
      },
    );

    test('an approved payload left for it is not sent on reconnect', () async {
      final (c, _, remotes) = await applied();
      final two = remotes.remove('two')!;
      await c.saveUser(VpnUser(id: carol, login: 'carol', name: 'Carol'));
      await c.prepareAndApply();
      final record = c.workspace.servers['two']!;
      expect(record['authorizedPayload'], isNot(record['appliedPayload']));
      expect(c.hasCurrentVerifiedProfiles, isFalse);

      await c.enterServiceMode('two');
      expect(c.hasCurrentVerifiedProfiles, isTrue);
      remotes['two'] = two;
      final submitted = two.submissions.length;
      await c.reconcile();
      await c.syncAllServersAndProfiles();

      // Only the test client of the mode is sent, never carol.
      final sent = two.submissions.values.skip(submitted).toList();
      expect(sent, isNotEmpty);
      for (final payload in sent) {
        expect(
          (payload['users'] as List).map((u) => (u as Map)['id']),
          allOf(
            isNot(contains(carol)),
            contains(c.serviceTestClient('two')!.id),
          ),
        );
      }
      expect(c.serverSyncIssue, isNull);
      expect(c.results[carol]!.hasBlockingErrors, isFalse);
      expect(c.attention.every((item) => !item.needsUser), isTrue);
      expect(
        c.attention.expand((item) => item.targets).map((t) => t.code),
        everyElement('vpn_service_mode'),
      );
    });

    VpnUser client(String id, {bool enabled = true}) => VpnUser(
      id: id,
      login: {alice: 'alice', bob: 'bob', carol: 'carol'}[id]!,
      name: {alice: 'Alice', bob: 'Bob', carol: 'Carol'}[id]!,
      enabled: enabled,
    );
    Matcher hasClient(String id, bool enabled) =>
        contains(equals({'id': id, 'enabled': enabled}));
    List<Object?> sentUsers(Remote remote) =>
        remote.submissions.values.last['users'] as List;
    // The last users sent but the test client of the mode.
    List<Object?> realUsers(VpnController c, Remote remote) => [
      for (final u in sentUsers(remote))
        if ((u as Map)['id'] != c.serviceTestClient('two')?.id) u,
    ];
    void finishJobs(Remote remote) {
      remote.running = false;
      for (final job in remote.jobs.values) {
        job['status'] = 'succeeded';
        job['checkpoint'] = job['count'];
      }
    }

    test(
      'a disabled client reaches it from a readback that adds nobody',
      () async {
        final (c, _, remotes) = await applied();
        final two = remotes['two']!;
        await c.enterServiceMode('two');
        await c.reconcile();
        expect(
          sentUsers(two),
          [
            {'id': alice, 'enabled': true},
            {'id': bob, 'enabled': true},
            {'id': c.serviceTestClient('two')!.id, 'enabled': true},
          ]..sort((a, b) => a['id'].toString().compareTo(b['id'].toString())),
        );
        // Carol exists only outside service mode.
        await c.saveUser(client(carol));
        await c.prepareAndApply();
        final submitted = two.submissions.length;

        await c.saveUser(client(alice, enabled: false));
        await c.prepareAndApply();
        expect(c.serviceAccessWaiting('two'), 1);
        await c.reconcile();

        expect(c.error, isNull);
        expect(c.serverSyncIssue, isNull);
        expect(two.submissions, hasLength(submitted + 1));
        final sent = two.submissions.values.last;
        expect(sent.containsKey('revokedUsers'), isFalse);
        expect(realUsers(c, two), [
          {'id': alice, 'enabled': false},
          {'id': bob, 'enabled': true},
        ]);
        expect(
          two.state.expand((r) => r['clients'] as List).map((u) => u['id']),
          isNot(contains(carol)),
        );
        expect(c.serviceAccessWaiting('two'), 0);
        expect(c.serviceAccessIssue('two'), isNull);
        expect(c.serviceModeOf('two')?.state, ServerServiceState.active);
        expect(c.hasCurrentVerifiedProfiles, isTrue);
        expect(c.attention.every((item) => !item.needsUser), isTrue);

        // Enabled again: the same way, still without carol.
        await c.saveUser(client(alice));
        await c.prepareAndApply();
        await c.reconcile();
        expect(two.submissions, hasLength(submitted + 2));
        expect(realUsers(c, two), [
          {'id': alice, 'enabled': true},
          {'id': bob, 'enabled': true},
        ]);
        expect(c.serviceAccessWaiting('two'), 0);
      },
    );

    test('re-enabling a client it lacks sends nothing there', () async {
      final (c, _, remotes) = await applied();
      final two = remotes['two']!;
      await c.enterServiceMode('two');
      await c.reconcile();
      await c.saveUser(client(carol, enabled: false));
      await c.prepareAndApply();
      final actions = two.actions.length;

      await c.saveUser(client(carol));
      await c.prepareAndApply();
      await c.reconcile();

      expect(c.error, isNull);
      expect(two.actions, hasLength(actions));
      expect(c.serviceAccessWaiting('two'), 0);
      expect(sentUsers(remotes['one']!), hasClient(carol, true));
    });

    test(
      'a disable for it offline blocks nothing and is retried on reconnect',
      () async {
        final (c, store, remotes) = await applied();
        await c.enterServiceMode('two');
        final two = remotes.remove('two')!;
        final submitted = two.submissions.length;

        await c.saveUser(client(alice, enabled: false));
        await c.prepareAndApply();
        await c.reconcile();

        expect(c.error, isNull);
        expect(c.serverSyncIssue, isNull);
        expect(sentUsers(remotes['one']!), hasClient(alice, false));
        expect(c.serviceAccessWaiting('two'), 1);
        expect(c.serviceAccessIssue('two'), 'vpn_connection');
        expect(c.hasCurrentVerifiedProfiles, isTrue);
        expect((await c.syncAllServersAndProfiles()).issue, isNull);
        expect(c.attention.every((item) => !item.needsUser), isTrue);

        // A restart keeps the intent: it is the client's own saved state.
        final restarted = controller(store, remotes);
        addTearDown(restarted.dispose);
        await restarted.load();
        expect(restarted.serviceAccessWaiting('two'), 1);
        remotes['two'] = two;
        await restarted.reconcile();

        expect(restarted.serverSyncIssue, isNull);
        expect(two.submissions, hasLength(submitted + 1));
        expect(realUsers(restarted, two), [
          {'id': alice, 'enabled': false},
          {'id': bob, 'enabled': true},
        ]);
        expect(
          sentUsers(two),
          hasClient(restarted.serviceTestClient('two')!.id, true),
        );
        expect(restarted.serviceAccessWaiting('two'), 0);
        expect(restarted.serviceAccessIssue('two'), isNull);
      },
    );

    test(
      'a deletion revokes it later without holding the file or other servers',
      () async {
        final (c, _, remotes) = await applied();
        await c.enterServiceMode('two');
        final two = remotes.remove('two')!;
        final removedFiles = <String>[];
        c.deletePublishedFile = (user, guard) async {
          await guard();
          removedFiles.add(user.id);
        };
        VpnUser deleted() =>
            c.workspace.users.singleWhere((u) => u.id == alice);

        await c.deleteUser(
          deleted(),
          file: {
            'accountKey': 'account',
            'fileId': 'file',
            'registryId': 'registry',
            'folderId': 'folder',
          },
        );

        expect(c.error, isNull);
        // Server two still owes the revocation; the Drive file is gone.
        expect(removedFiles, [alice]);
        expect(deleted().deletion!['file']['status'], 'deleted');
        expect(deleted().deletionComplete, isFalse);
        expect(c.hasPendingRevocation('two'), isTrue);
        expect(c.hasPendingRevocation('one'), isFalse);
        expect(c.hasRunning, isFalse);

        // Other servers' plans go on and publication is not held.
        await c.saveUser(client(carol));
        await c.prepareAndApply();
        expect(c.error, isNull);
        expect(sentUsers(remotes['one']!), hasClient(carol, true));
        expect(c.hasCurrentVerifiedProfiles, isTrue);
        expect(c.attention.every((item) => !item.needsUser), isTrue);

        remotes['two'] = two;
        await c.reconcile();

        expect(c.error, isNull);
        expect(deleted().deletionComplete, isTrue);
        expect(
          two.submissions.values.map((p) => p['revokedUsers']),
          contains(equals([alice])),
        );
        expect(
          two.state
              .expand((r) => r['clients'] as List)
              .where((u) => u['id'] == alice)
              .map((u) => u['enabled']),
          everyElement(false),
        );
        // Carol is still not provisioned there.
        expect(
          sentUsers(two).map((u) => (u as Map)['id']),
          isNot(contains(carol)),
        );
        expect(removedFiles, [alice]);
      },
    );

    test(
      'the way back adds missing clients and ends only after readback',
      () async {
        final (c, _, remotes) = await applied();
        final two = remotes['two']!;
        await c.enterServiceMode('two');
        await c.saveUser(client(carol));
        await c.prepareAndApply();
        expect(c.serviceModeExitNewClients('two'), 1);
        two.running = true;

        await c.exitServiceMode('two');

        expect(c.error, isNull);
        expect(c.serviceModeOf('two')?.state, ServerServiceState.returning);
        expect(c.serviceModeExiting('two'), isTrue);
        expect(c.serviceModeExitIssue('two'), isNull);
        expect(sentUsers(two), hasClient(carol, true));
        // Until its readback confirms it, it stays out of profiles and
        // holds nothing.
        expect(proxyNames(c, carol, 'two'), isEmpty);
        expect(c.hasCurrentVerifiedProfiles, isTrue);
        expect(c.serverSyncIssue, isNull);

        finishJobs(two);
        await c.reconcile();

        expect(c.serverSyncIssue, isNull);
        expect(c.serviceModeOf('two'), isNull);
        expect(c.serviceModeExiting('two'), isFalse);
        expect(proxyNames(c, carol, 'two'), hasLength(2));
        expect(proxyNames(c, alice, 'two'), hasLength(2));
        expect(c.clientCountOn('two'), 3);
        expect(c.hasCurrentVerifiedProfiles, isTrue);
      },
    );

    test(
      'a failed way back stays returning and resumes after a restart',
      () async {
        final (c, store, remotes) = await applied();
        final two = remotes.remove('two')!;
        await c.enterServiceMode('two');

        // Offline: the readback it has from before is not enough.
        await c.exitServiceMode('two');
        expect(c.serviceModeOf('two')?.state, ServerServiceState.returning);
        expect(c.serviceModeExitIssue('two'), 'vpn_connection');
        expect(proxyNames(c, alice, 'two'), isEmpty);

        // Reachable, but its plan fails: still returning, nothing global.
        remotes['two'] = two;
        await c.saveUser(client(carol));
        await c.prepareAndApply();
        two.failPlan = true;
        await c.exitServiceMode('two');
        expect(c.error, isNull);
        expect(c.serviceModeOf('two')?.state, ServerServiceState.returning);
        expect(c.serviceModeExitIssue('two'), 'vpn_connection');
        expect(c.serverSyncIssue, isNull);
        expect(c.hasCurrentVerifiedProfiles, isTrue);
        expect(proxyNames(c, carol, 'two'), isEmpty);

        two.failPlan = false;
        final restarted = controller(store, remotes);
        addTearDown(restarted.dispose);
        await restarted.load();
        expect(restarted.serviceModeExiting('two'), isTrue);
        await restarted.reconcile();

        expect(restarted.serverSyncIssue, isNull);
        expect(restarted.serviceModeOf('two'), isNull);
        expect(sentUsers(two), hasClient(carol, true));
        expect(proxyNames(restarted, carol, 'two'), hasLength(2));
      },
    );

    test('the way back can be cancelled', () async {
      final (c, _, remotes) = await applied();
      remotes.remove('two');
      await c.enterServiceMode('two');
      await c.exitServiceMode('two');
      expect(c.serviceModeOf('two')?.state, ServerServiceState.returning);

      await c.cancelServiceModeExit('two');

      expect(c.error, isNull);
      expect(c.serviceModeOf('two')?.state, ServerServiceState.active);
      expect(c.serviceModeExiting('two'), isFalse);
      expect(c.serviceModeExitIssue('two'), isNull);
    });

    test('entering waits for a job running on a reachable server', () async {
      final (c, _, remotes) = await applied();
      remotes['two']!.running = true;
      await c.saveUser(client(carol));
      await c.prepareAndApply();

      await c.enterServiceMode('two');
      expect(c.error, 'vpn_busy');
      expect(c.serviceModeOf('two'), isNull);

      // Unreachable, the job cannot be observed: entering is allowed.
      remotes.remove('two');
      await c.enterServiceMode('two');
      expect(c.error, isNull);
      expect(c.serviceModeOf('two')?.state, ServerServiceState.active);
    });
  });
}
