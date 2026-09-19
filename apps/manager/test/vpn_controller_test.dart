import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
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
  bool loseReply = false, running = false, failBeforeSubmit = false;
  List<Map<String, dynamic>> state = [];
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
    'vlessState': ?state,
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
      return RunnerResponse.fromJson(response(plan: {'fingerprint': 'e' * 64}));
    }
    if (a == 'vless_state') {
      return RunnerResponse.fromJson(response(state: state));
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
      state = [
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
    if (a == 'resume') {
      jobs[id] = {
        ...jobs[id]!,
        'status': 'succeeded',
        'checkpoint': jobs[id]!['count'],
      };
    }
    return RunnerResponse.fromJson(response(jobs: [jobs[id]!]));
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
  CoreConfigValidator? coreValidator,
}) => VpnController(
  repository: store,
  coreValidator: coreValidator,
  recovery: recovery,
  template: source ?? () => template,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
        before!.replaceAll('Alice_VLESS', 'Renamed_VLESS'),
      );
      final restored = controller(store, remotes);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.workspace.users.length, 2);
      expect(restored.results[alice]!.yaml, c.results[alice]!.yaml);
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
      expect((jsonDecode(store.raw!) as Map)['version'], 5);
      expect(c.hasPendingRevocation('one'), isFalse);
      expect(c.hasRunning, isFalse);
      expect(c.results[bob]!.hasBlockingErrors, isFalse);
    },
  );
}
