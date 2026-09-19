import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as f;
import 'awg_test.dart' as awg;
import 'tt_test.dart' as tt;

class DeviceStore extends f.MemoryVpn implements ChangeJournalStore {
  DeviceStore(this.device);
  final String device;
  @override
  Future<WorkspaceIdentity> readWorkspaceIdentity() async =>
      WorkspaceIdentity(workspaceId: '0' * 32, deviceId: device);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  VpnUser user(VpnController c) =>
      c.workspace.users.singleWhere((u) => u.id == f.alice);

  test(
    'batch deletion validates the complete selection and commits before offline revocation',
    () async {
      final store = f.MemoryVpn();
      final c = f.controller(store, {});
      addTearDown(c.dispose);
      await f.setup(c);
      final reviewed = c.workspace.users.toList();
      await c.saveUser(VpnUser(id: f.bob, login: 'bob', name: 'Changed'));
      await c.deleteUsers(reviewed);
      expect(c.error, 'vpn_conflict');
      expect(c.workspace.users.every((u) => !u.deleted), true);
      final current = c.workspace.users.toList();
      store.fail = true;
      await c.deleteUsers(current);
      expect(c.error, 'vpn_storage');
      expect(c.workspace.users.every((u) => !u.deleted), true);
      store.fail = false;
      await c.deleteUsers(current);
      expect(c.workspace.users.every((u) => u.deleted), true);
      expect(c.pendingRevocations, hasLength(2));
      final restored = f.controller(store, {});
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.pendingRevocations, hasLength(2));
    },
  );

  test(
    'offline deletion persists; restart revokes both servers; same login can be added again',
    () async {
      final store = f.MemoryVpn(), remotes = <String, f.Remote>{};
      remotes.addAll({'one': f.Remote(store), 'two': f.Remote(store)});
      var c = f.controller(store, remotes);
      await f.setup(c);
      await c.prepare();
      await c.apply();
      final one = remotes.remove('one')!;
      await c.deleteUser(user(c));
      expect(user(c).deleted, true);
      expect(user(c).enabled, false);
      expect(user(c).deletionComplete, false);
      expect(c.hasRunning, false);
      expect(c.hasPendingRevocation('one'), true);
      expect(c.results.containsKey(f.alice), false);
      expect(c.workspace.profiles.containsKey(f.alice), false);
      expect((jsonDecode(store.raw!) as Map)['version'], 4);
      c.dispose();
      c = f.controller(store, remotes);
      addTearDown(c.dispose);
      await c.load();
      remotes['one'] = one;
      await c.reconcile();
      expect(c.error, isNull);
      expect(user(c).deletionComplete, true);
      for (final remote in remotes.values) {
        expect(remote.submissions.length, 2);
        for (final resource in remote.state) {
          final clients = resource['clients'] as List;
          expect(
            clients.singleWhere((u) => u['id'] == f.alice)['enabled'],
            false,
          );
          expect(clients.singleWhere((u) => u['id'] == f.bob)['enabled'], true);
        }
      }
      await c.saveUser(VpnUser(id: 'c' * 32, login: 'alice', name: 'Alice'));
      expect(c.error, isNull);
      expect(
        c.workspace.users
            .where((u) => !u.deleted && u.login == 'alice')
            .single
            .id,
        'c' * 32,
      );
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      expect(c.error, 'vpn_user_deleted');
    },
  );

  test(
    'force-hidden deletion does not invisibly block a later client addition',
    () async {
      final store = f.MemoryVpn();
      final server = f.Remote(store);
      final remotes = <String, f.Remote>{'one': server};
      var reconnect = false;
      VpnController controller() => VpnController(
        repository: store,
        template: () => f.template,
        remote: (id) => remotes[id] == null
            ? null
            : VpnRemote(
                transport: remotes[id]!,
                panelId: f.panel,
                identity: 'identity-$id',
              ),
        connectForDeletion: (_) async => false,
        connectForAction: (_) async {
          if (!reconnect) return false;
          remotes['one'] = server;
          return true;
        },
        timer: (duration, callback) => Timer(Duration.zero, () {}),
      );

      var c = controller();
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      await c.saveInbound(f.inbound('one', '1' * 32));
      await c.prepareAndApply();
      expect(c.results[f.alice]!.hasBlockingErrors, false);

      remotes.clear();
      await c.deleteUser(user(c));
      c.dispose();
      final saved = jsonDecode(store.raw!) as Map<String, dynamic>;
      final deleted = (saved['users'] as List).single as Map<String, dynamic>;
      final target = (deleted['deletion']['targets']['one'] as Map);
      target['connectionAttempts'] = 3;
      target['connectAfter'] = 0;
      store.raw = jsonEncode(saved);

      c = controller();
      addTearDown(c.dispose);
      await c.load();
      expect(c.canForceDelete(user(c)), true);
      await c.forceDeleteClient(f.alice);
      expect(user(c).deletion!['hidden'], true);
      expect(c.pendingRevocations, hasLength(1));
      expect(c.hasUnappliedActiveAccess, false);
      await c.recoverHiddenPendingAccessChanges();
      expect(c.pendingRevocations, hasLength(1));

      await c.saveUser(VpnUser(id: f.bob, login: 'bob', name: 'Bob'));
      expect(c.hasUnappliedActiveAccess, true);
      server.running = true;
      reconnect = true;
      await c.recoverHiddenPendingAccessChanges();

      expect(c.error, isNull);
      expect(user(c).deletionComplete, false);
      expect(c.pendingRevocations, hasLength(1));
      expect(c.results[f.bob]!.hasBlockingErrors, true);
      expect(c.workspace.servers['one']?['authorizedPayload'], isNotNull);

      server.running = false;
      for (final job in server.jobs.values) {
        job['status'] = 'succeeded';
        job['checkpoint'] = job['count'];
      }
      await c.reconcile();

      expect(c.error, isNull);
      expect(user(c).deletionComplete, true);
      expect(c.pendingRevocations, isEmpty);
      expect(c.results[f.bob]!.hasBlockingErrors, false);
      expect(c.workspace.profiles[f.bob]?['yaml'], contains('VLESS-Bob'));
      expect(
        server.state
            .expand((resource) => resource['clients'] as List)
            .where((client) => client['id'] == f.bob)
            .single['enabled'],
        true,
      );
    },
  );

  test('storage failure cannot revoke, hide client or delete file', () async {
    final store = f.MemoryVpn(), remotes = <String, f.Remote>{};
    remotes.addAll({'one': f.Remote(store), 'two': f.Remote(store)});
    final c = f.controller(store, remotes);
    addTearDown(c.dispose);
    await f.setup(c);
    await c.prepare();
    await c.apply();
    for (final remote in remotes.values) {
      remote.actions.clear();
    }
    store.fail = true;
    await c.deleteUser(user(c));
    expect(c.error, 'vpn_storage');
    expect(user(c).deleted, false);
    expect(remotes.values.expand((r) => r.actions), isEmpty);
  });
  test(
    'second device waits; offline or running jobs prevent takeover; completed job is reused',
    () async {
      final first = DeviceStore('a' * 32), second = DeviceStore('b' * 32);
      final remotes = <String, f.Remote>{
        'one': f.Remote(first),
        'two': f.Remote(first),
      };
      final a = f.controller(first, remotes);
      addTearDown(a.dispose);
      await f.setup(a);
      await a.prepare();
      await a.apply();
      remotes['one']!.loseReply = true;
      await a.deleteUser(user(a));
      expect(user(a).deletionComplete, false);
      second.raw = first.raw;
      second.revision = first.revision;
      final access = <String, f.Remote>{};
      final b = f.controller(second, access);
      addTearDown(b.dispose);
      await b.load();
      final before = remotes.values.fold<int>(
        0,
        (n, r) => n + r.actions.length,
      );
      await b.reconcile();
      expect(
        remotes.values.fold<int>(0, (n, r) => n + r.actions.length),
        before,
      );
      await b.retryDeletion(f.alice);
      expect(b.error, 'vpn_connection');
      expect(b.ownsDeletion(user(b)), false);
      access.addAll(remotes);
      final id = user(a).deletion!['targets']['one']['request']['id'] as String;
      final job = remotes['one']!.jobs[id]!;
      remotes['one']!.jobs[id] = {...job, 'status': 'running', 'checkpoint': 1};
      await b.retryDeletion(f.alice);
      expect(b.error, 'vpn_busy');
      expect(b.ownsDeletion(user(b)), false);
      remotes['one']!.jobs[id] = job;
      final submits = remotes['one']!.actions
          .where((v) => v == 'submit')
          .length;
      await b.retryDeletion(f.alice);
      expect(b.error, isNull);
      expect(b.ownsDeletion(user(b)), true);
      expect(user(b).deletionComplete, true);
      expect(
        remotes['one']!.actions.where((v) => v == 'submit').length,
        submits,
      );
    },
  );

  test(
    'lost submit reply recovers the existing ID without another submit',
    () async {
      final store = f.MemoryVpn(), remotes = <String, f.Remote>{};
      remotes.addAll({'one': f.Remote(store), 'two': f.Remote(store)});
      final c = f.controller(store, remotes);
      addTearDown(c.dispose);
      await f.setup(c);
      await c.prepare();
      await c.apply();
      remotes['one']!.loseReply = true;
      await c.deleteUser(user(c));
      final count = remotes['one']!.actions.where((a) => a == 'submit').length;
      expect(user(c).deletionComplete, false);
      await c.retryDeletion(f.alice);
      expect(c.error, isNull);
      expect(user(c).deletionComplete, true);
      expect(remotes['one']!.actions.where((a) => a == 'submit').length, count);
    },
  );

  test(
    'deletion preserves actual server resources and unrelated unapproved drafts',
    () async {
      final store = f.MemoryVpn(), remotes = <String, f.Remote>{};
      remotes.addAll({'one': f.Remote(store), 'two': f.Remote(store)});
      final c = f.controller(store, remotes);
      addTearDown(c.dispose);
      await f.setup(c);
      await c.prepare();
      await c.apply();
      final old = c.workspace.inbounds.first;
      await c.saveInbound(
        VlessInbound(
          serverId: old.serverId,
          spec: {...old.spec, 'name': 'Unapproved draft'},
        ),
      );
      await c.deleteUser(user(c));
      expect(user(c).deletionComplete, true);
      expect(remotes['one']!.state.first['spec']['name'], old.name);
      expect(
        c.workspace.inbounds.singleWhere((r) => r.id == old.id).name,
        'Unapproved draft',
      );
    },
  );

  test(
    'inconsistent access sets stop a target rather than granting unrelated users',
    () async {
      final store = f.MemoryVpn(), remotes = <String, f.Remote>{};
      remotes.addAll({'one': f.Remote(store), 'two': f.Remote(store)});
      final c = f.controller(store, remotes);
      addTearDown(c.dispose);
      await f.setup(c);
      await c.prepare();
      await c.apply();
      (remotes['one']!.state.first['clients'] as List).singleWhere(
        (u) => u['id'] == f.bob,
      )['enabled'] = false;
      await c.deleteUser(user(c));
      expect(user(c).deletionComplete, false);
      expect(user(c).deletion!['targets']['one']['error'], 'vpn_conflict');
      expect(remotes['one']!.submissions.length, 1);
      expect(user(c).deletion!['targets']['two']['status'], 'revoked');
    },
  );

  for (final protocol in ['awg', 'tt']) {
    test(
      '$protocol revokes only selected credentials and preserves node settings',
      () async {
        final store = f.MemoryVpn();
        final actual = protocol == 'awg'
            ? (awg.AwgRemote(store)..busyOnce = false)
            : (tt.TtRemote(store)..busyOnce = false);
        final target = protocol == 'awg' ? awgTarget('one') : ttTarget('one');
        final c = f.controller(store, {target: actual});
        addTearDown(c.dispose);
        await c.load();
        await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
        await c.saveUser(VpnUser(id: f.bob, login: 'bob', name: 'Bob'));
        if (protocol == 'awg') {
          await c.saveAwg(AwgInterface(serverId: 'one', spec: awg.spec()));
        } else {
          await c.saveTt(TrustTunnelEndpoint(serverId: 'one', spec: tt.spec()));
        }
        await c.prepare();
        await c.apply();
        final before = jsonEncode(actual.state.single['spec']);
        await c.deleteUser(user(c));
        expect(c.error, isNull);
        expect(user(c).deletionComplete, true);
        expect(jsonEncode(actual.state.single['spec']), before);
        final clients = actual.state.single['clients'] as List;
        expect(
          clients.singleWhere((u) => u['id'] == f.alice)['enabled'],
          false,
        );
        expect(clients.singleWhere((u) => u['id'] == f.bob)['enabled'], true);
      },
    );
  }

  test(
    'optional file cleanup retries separately after access revocation',
    () async {
      final c = f.controller(f.MemoryVpn(), {});
      addTearDown(c.dispose);
      await c.load();
      await c.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      var calls = 0;
      c.deletePublishedFile = (user, guard) async {
        await guard();
        expect(user.deleted, true);
        expect(user.revocationComplete, true);
        calls++;
        if (calls == 1) {
          throw const PublicationFailure(PublicationIssue.unauthorized);
        }
      };
      await c.deleteUser(
        user(c),
        file: {
          'accountKey': 'account',
          'fileId': 'exact-file',
          'registryId': 'registry',
          'folderId': 'folder',
        },
      );
      expect(user(c).revocationComplete, true);
      expect(user(c).deletionComplete, false);
      expect(user(c).deletion!['file']['error'], 'unauthorized');
      expect(c.hasRunning, false);
      await c.saveUser(VpnUser(id: 'c' * 32, login: 'alice', name: 'Alice'));
      await c.prepare();
      expect(c.error, isNull);
      await c.retryDeletion(f.alice);
      expect(user(c).deletionComplete, true);
      expect(calls, 2);
    },
  );
  test(
    'proxy names append inbound only for multiple VLESS and keep stable duplicate suffixes',
    () async {
      final store = f.MemoryVpn();
      final c = f.controller(store, {
        'one': f.Remote(store),
        'two': f.Remote(store),
        awgTarget('one'): awg.AwgRemote(store)..busyOnce = false,
        ttTarget('one'): tt.TtRemote(store)..busyOnce = false,
      });
      addTearDown(c.dispose);
      await f.setup(c);
      for (final r in c.workspace.inbounds.toList()) {
        await c.saveInbound(
          VlessInbound(
            serverId: r.serverId,
            spec: {...r.spec, 'name': 'Node_${r.id[0]}'},
          ),
        );
      }
      await c.saveAwg(
        AwgInterface(
          serverId: 'one',
          spec: {...awg.spec(), 'id': 'd' * 32, 'name': 'Amnezia'},
        ),
      );
      await c.saveTt(
        TrustTunnelEndpoint(
          serverId: 'one',
          spec: {...tt.spec(), 'id': 'e' * 32, 'name': 'Trust'},
        ),
      );
      await c.prepare();
      await c.apply();
      expect(c.error, isNull);
      expect(
        awgUserAccesses(
          c.workspace,
          f.alice,
          serverNames: c.profileServerNames,
        ).single.name,
        'AmneziaWG-Alice_Server one',
      );
      expect(
        ttUserAccesses(
          c.workspace,
          f.alice,
          serverNames: c.profileServerNames,
        ).single.name,
        'TrustTunnel-Alice_Server one',
      );
      final vless = vlessUserAccesses(
        c.workspace,
        f.alice,
        serverNames: c.profileServerNames,
      );
      final expected = <String>{
        'VLESS-Alice_Server one-Node_1',
        'VLESS-Alice_Server one-Node_2',
        'VLESS-Alice_Server two-Node_3',
        'VLESS-Alice_Server two-Node_4',
      };
      expect(vless.map((p) => p.name).toSet(), expected);
      final before = awgUserAccesses(
        c.workspace,
        f.alice,
        serverNames: c.profileServerNames,
      ).single.fields;
      final renamed = c.workspace.copy(
        users: [
          VpnUser(id: f.alice, login: 'alice', name: 'USER'),
          c.workspace.users.last,
        ],
      );
      final after = awgUserAccesses(
        renamed,
        f.alice,
        serverNames: c.profileServerNames,
      ).single.fields;
      expect(after, {...before, 'name': 'AmneziaWG-USER_Server one'});
      final nodes = c.workspace.inbounds
          .map(
            (r) => VlessInbound(
              serverId: r.serverId,
              spec: {...r.spec, 'name': 'Same'},
            ),
          )
          .toList();
      final duplicate = c.workspace.copy(
        inbounds: nodes,
        servers: {
          for (final entry in c.workspace.servers.entries)
            entry.key: {
              ...entry.value,
              'observed': [
                for (final o in entry.value['observed'] as List? ?? [])
                  {
                    ...o as Map,
                    'spec':
                        nodes.where((r) => r.id == o['id']).firstOrNull?.spec ??
                        o['spec'],
                  },
              ],
            },
        },
      );
      final names = vlessUserAccesses(
        duplicate,
        f.alice,
        serverNames: c.profileServerNames,
      ).map((p) => p.name).toSet();
      expect(names.length, nodes.length);
      expect(names, {
        'VLESS-Alice_Server one-Same',
        'VLESS-Alice_Server one-Same_2',
        'VLESS-Alice_Server two-Same',
        'VLESS-Alice_Server two-Same_2',
      });
      expect(
        vlessUserAccesses(
          duplicate.copy(inbounds: nodes.reversed.toList()),
          f.alice,
          serverNames: c.profileServerNames,
        ).map((p) => p.name).toSet(),
        names,
      );
    },
  );
}
