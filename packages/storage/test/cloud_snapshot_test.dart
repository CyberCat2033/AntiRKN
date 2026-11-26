import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fixtures/fake_snapshot_remote.dart';
import 'fixtures/journal_data.dart';
import 'fixtures/snapshot_fixture.dart';

Future<AutoSyncResult> _exchange(AutoSyncSession session) => session.exchange(
  apply: (_) async => true,
  cancellation: SyncCancellation(),
);

Map<String, dynamic> _vpnOf(Map<String, dynamic> snapshot) =>
    jsonDecode(
          (snapshot['documents'] as List).singleWhere(
                (row) => row['id'] == 'vpn-workspace-v1',
              )['source']
              as String,
        )
        as Map<String, dynamic>;

Future<(Map<String, dynamic>, int)> _readVpn(WorkspaceDatabase db) async {
  final stored = await db.readVpn();
  return (jsonDecode(stored.source!) as Map<String, dynamic>, stored.revision);
}

Future<void> _editVpn(
  WorkspaceDatabase db,
  void Function(Map<String, dynamic>) edit,
) async {
  final (vpn, revision) = await _readVpn(db);
  edit(vpn);
  await db.writeVpn(jsonEncode(vpn), expectedRevision: revision);
}

void main() {
  late Directory directory;
  final stores = <WorkspaceDatabase>[];
  final sessions = <AutoSyncSession>[];
  final tokens = FakeSnapshotTokens();
  late FakeSnapshotRemote remote;

  WorkspaceDatabase open(String name, int key) {
    final store = WorkspaceDatabase.open(
      '${directory.path}/$name.sqlite',
      key: SecretKeyData(List.filled(32, key)),
      offloadVpnWrites: true,
    );
    stores.add(store);
    return store;
  }

  Future<AutoSyncSession> session(WorkspaceDatabase store) async {
    final value = await store.openAutoSync(tokens, remote: remote);
    sessions.add(value);
    return value;
  }

  /// Pulls the cloud snapshot into [name] and reopens it, as a launch does.
  Future<WorkspaceDatabase> pull(
    String name,
    int key, {
    WorkspaceDatabase? db,
  }) async {
    final store = db ?? open(name, key);
    expect(await store.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    await store.close();
    stores.remove(store);
    return open(name, key);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cloud-snapshot-test-');
    remote = FakeSnapshotRemote();
  });
  tearDown(() async {
    for (final value in sessions) {
      await value.close();
    }
    sessions.clear();
    for (final value in stores) {
      await value.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  test('synthetic snapshot sizes by section, file backup and cloud', () async {
    final db = open('synthetic', 41);
    await fillSyntheticWorkspace(db, clients: 120, servers: 3);
    final file = await db.debugSnapshotSectionSizes();
    final cloud = await db.debugSnapshotSectionSizes(cloud: true);
    // Only byte counts are printed: no ids, names or values.
    for (final section in {...file.keys, ...cloud.keys}.toList()..sort()) {
      // ignore: avoid_print
      print(
        'snapshot_size section=$section file=${file[section] ?? 0} '
        'cloud=${cloud[section] ?? 0}',
      );
    }
    expect(file['publication.result'], greaterThan(0));
    expect(file['vpn.profiles.yaml'], greaterThan(0));
    expect(cloud['total'], lessThan(file['total']! ~/ 5));
  });

  test(
    'cloud snapshot v5 has no yaml, observations, runner answers or client credentials',
    () async {
      final a = open('a', 41);
      await fillSyntheticWorkspace(a);
      await _exchange(await session(a));
      final snapshot = await openFakeSnapshot(remote);
      expect(snapshot['version'], 5);
      expect(
        (snapshot['author'] as Map)['deviceId'],
        (await a.readWorkspaceIdentity()).deviceId,
      );
      final ids = [
        for (final row in snapshot['documents'] as List) row['id'] as String,
      ];
      expect(ids.where((id) => id.startsWith('publication/result/')), isEmpty);
      expect(ids.where((id) => id.startsWith('runner/')), isEmpty);
      expect(ids, contains('publication/settings'));
      expect(
        ids.where((id) => id.startsWith('publication/binding/')),
        hasLength(12),
      );
      for (final row in snapshot['servers'] as List) {
        final profile = jsonDecode(row['source'] as String) as Map;
        expect(profile.keys, isNot(contains('lastInfo')));
        expect(profile['hostKey'], isNotNull);
        expect(profile['secrets'], isNotEmpty);
      }
      final vpn = _vpnOf(snapshot);
      expect(vpn['users'], hasLength(120));
      for (final record in (vpn['servers'] as Map).values) {
        expect(
          (record as Map).keys.toSet().intersection({
            'observed',
            'verifiedAt',
            'appliedPayload',
            'authorizedPayload',
            'job',
          }),
          isEmpty,
        );
        expect(record['identity'], isA<String>());
        expect(record['resourceWorkspaceId'], isA<String>());
      }
      for (final profile in (vpn['profiles'] as Map).values) {
        expect((profile as Map).keys, ['publicationWorkspaceId']);
      }
      // The file backup format is unchanged and still complete.
      final file = await a.debugSnapshotSectionSizes();
      expect(file['publication.result'], greaterThan(0));
      expect(file['runner.cache'], greaterThan(0));
    },
  );

  test(
    'a v5 pull keeps this device cache for the same server and drops a replaced one',
    () async {
      final a = open('a', 41);
      final fixture = await fillSyntheticWorkspace(a);
      await _exchange(await session(a));
      // Another device starts from the cloud alone and replaces server 0.
      var c = await pull('c', 42);
      final replaced = fixture.serverIds[0], kept = fixture.serverIds[1];
      final server = await c.openServer(replaced);
      final profile = (await c.listServers())
          .singleWhere((s) => s.id == replaced)
          .profile;
      await server.saveProfile(
        SshProfile(
          id: profile.id,
          name: profile.name,
          host: profile.host,
          port: profile.port,
          username: profile.username,
          authMethod: profile.authMethod,
          secrets: profile.secrets,
          hostKey: const TrustedHostKey('ssh-ed25519', 'SHA256:reinstalled'),
        ),
      );
      await _editVpn(c, (vpn) {
        for (final entry in (vpn['servers'] as Map).entries) {
          if (vpnServerId(entry.key as String) == replaced) {
            entry.value['identity'] = '${profile.host}|SHA256:reinstalled';
          }
        }
      });
      await c.writeDraft('edited on another device');
      await _exchange(await session(c));
      expect((await openFakeSnapshot(remote))['version'], 5);

      final restored = await pull('a', 41, db: a);
      expect(await restored.readDraft(), 'edited on another device');
      final (vpn, _) = await _readVpn(restored);
      for (final entry in (vpn['servers'] as Map).entries) {
        final record = entry.value as Map;
        if (vpnServerId(entry.key as String) == replaced) {
          expect(record['observed'], isNull);
          expect(record['verifiedAt'], isNull);
        } else {
          expect(record['observed'], isNotEmpty);
          expect(record['verifiedAt'], isA<String>());
        }
      }
      for (final profile in (vpn['profiles'] as Map).values) {
        expect((profile as Map)['yaml'], isA<String>());
      }
      final servers = await restored.listServers();
      expect(
        servers.singleWhere((s) => s.id == replaced).profile.lastInfo,
        isNull,
      );
      expect(
        servers.singleWhere((s) => s.id == kept).profile.lastInfo,
        isNotNull,
      );
      final keptJournal =
          jsonDecode((await restored.readRunnerJournal(kept))!) as Map;
      expect(keptJournal['panelAccess'], isNotNull);
      expect(await restored.readRunnerJournal(replaced), isNull);
      expect(
        await restored.readPublicationDocument('result/${fixture.userIds[1]}'),
        isNotNull,
      );
      expect(jsonDecode((await restored.readSetting('syncCacheRefresh'))!), [
        replaced,
      ]);
      // The cache this device kept does not make it differ from the cloud.
      c = restored;
      remote.calls.clear();
      await _exchange(await session(c));
      expect(remote.calls, isEmpty);
    },
  );

  test(
    'cache-only writes after a pull neither upload nor block the next pull',
    () async {
      final a = open('a', 41);
      final fixture = await fillSyntheticWorkspace(a);
      await _exchange(await session(a));
      final b = await pull('b', 42);
      // A background re-read writes observations and compiled profiles only.
      await _editVpn(b, (vpn) {
        for (final record in (vpn['servers'] as Map).values) {
          record['observed'] = [
            {'id': 'refreshed'},
          ];
          record['verifiedAt'] = '2026-11-25T10:00:00.000Z';
        }
        (vpn['profiles'] as Map)[fixture.userIds[0]]['yaml'] = 'rebuilt';
      });
      remote.calls.clear();
      final writes = remote.writes;
      await _exchange(await session(b));
      expect(remote.writes, writes);
      expect(remote.calls, isEmpty);
      // An edit of intent is still uploaded.
      await b.writeDraft('intent changed');
      await _exchange(await session(b));
      expect(remote.writes, writes + 1);
      // A device with only cache writes still receives a newer cloud.
      await _editVpn(a, (vpn) {
        for (final record in (vpn['servers'] as Map).values) {
          record['verifiedAt'] = '2026-11-25T11:00:00.000Z';
        }
      });
      final restored = await pull('a', 41, db: a);
      expect(await restored.readDraft(), 'intent changed');
    },
  );

  test(
    'unfinished operations, tombstones and namespaces survive a v5 pull',
    () async {
      final a = open('a', 41);
      final fixture = await fillSyntheticWorkspace(a);
      final device = (await a.readWorkspaceIdentity()).deviceId;
      final target = fixture.serverIds[1], operationId = 'a1' * 16;
      await _editVpn(a, (vpn) {
        final record = (vpn['servers'] as Map)[target] as Map;
        record['pending'] = {
          'id': operationId,
          'kind': 'vless_apply',
          'payload': '{}',
        };
        record['operation'] = ServerOperation(
          operationId: operationId,
          executorDeviceId: device,
        ).toJson();
        record['authorizedPayload'] = '{"next":true}';
        record['job'] = {'id': operationId, 'status': 'running'};
        final users = vpn['users'] as List;
        users[0] = {
          ...users[0] as Map,
          'enabled': false,
          'deleted': true,
          'deletion': {
            'version': 1,
            'id': 'b2' * 16,
            'executor': device,
            'targets': {
              target: {'status': 'waiting'},
            },
          },
        };
      });
      await a.writeRunnerJournal(
        target,
        jsonEncode({
          'version': 1,
          'identity': 'server1.example|ignored',
          'pending': {'id': operationId, 'kind': 'vless_apply'},
          'operation': ServerOperation(
            operationId: operationId,
            executorDeviceId: device,
          ).toJson(),
          'selected': null,
          'cursor': 0,
          'panelAccess': {'id': 'x'},
        }),
      );
      await _exchange(await session(a));
      final b = await pull('b', 42);
      final (vpn, _) = await _readVpn(b);
      final record = (vpn['servers'] as Map)[target] as Map;
      expect(record['pending']['id'], operationId);
      expect(
        ServerOperation.fromJson(record['operation'] as Map).executorDeviceId,
        device,
      );
      expect(record['authorizedPayload'], '{"next":true}');
      expect(record['job'], isNotNull);
      expect(record['resourceWorkspaceId'], syntheticForeignNamespace);
      expect(
        (vpn['profiles'] as Map)[fixture.userIds[1]]['publicationWorkspaceId'],
        syntheticForeignNamespace,
      );
      final deleted = (vpn['users'] as List).first as Map;
      expect(deleted['deleted'], isTrue);
      expect(deleted['deletion']['executor'], device);
      final journal = jsonDecode((await b.readRunnerJournal(target))!) as Map;
      expect(journal['pending']['id'], operationId);
      expect(journal['operation']['executorDeviceId'], device);
      expect(journal.containsKey('panelAccess'), isFalse);
      expect(await b.readRestoredTargets(), contains(target));
      // Bindings already handed out stay with the workspace.
      expect(
        await b.readPublicationDocument('binding/${fixture.userIds[0]}'),
        isNotNull,
      );
    },
  );

  test(
    'service mode is intent: it survives a v5 pull and its change uploads',
    () async {
      final a = open('a', 41);
      final fixture = await fillSyntheticWorkspace(a);
      final server = fixture.serverIds[0];
      final mode = ServerServiceMode(
        state: ServerServiceState.active,
        since: DateTime.utc(2026, 11, 26, 10),
      );
      final (stored, revision) = await _readVpn(a);
      final workspace = VpnWorkspace.decode(jsonEncode(stored));
      await a.writeVpnWorkspace(
        workspace.copy(serviceMode: {server: mode}),
        expectedRevision: revision,
      );
      await _exchange(await session(a));
      final uploaded = _vpnOf(await openFakeSnapshot(remote));
      expect(uploaded['version'], 6);
      expect(uploaded['serviceMode'], {server: mode.toJson()});

      final b = await pull('b', 42);
      final pulled = VpnWorkspace.decode((await b.readVpn()).source!);
      expect(pulled.serviceModeOf(server), mode);
      expect(pulled.inServiceMode(awgTarget(server)), isTrue);
      expect(pulled.inServiceMode(fixture.serverIds[1]), isFalse);

      // Leaving service mode on one device is intent for the others too.
      final writes = remote.writes;
      final (current, next) = await _readVpn(b);
      await b.writeVpnWorkspace(
        VpnWorkspace.decode(jsonEncode(current)).copy(serviceMode: const {}),
        expectedRevision: next,
      );
      await _exchange(await session(b));
      expect(remote.writes, writes + 1);
      final cleared = _vpnOf(await openFakeSnapshot(remote));
      expect(cleared.containsKey('serviceMode'), isFalse);
      final restored = await pull('a', 41, db: a);
      expect(
        VpnWorkspace.decode((await restored.readVpn()).source!).serviceMode,
        isEmpty,
      );
    },
  );

  test('a v4 cloud snapshot is read and the next upload writes v5', () async {
    const userId = fixtureUserId;
    await sealFakeSnapshot(remote, {
      'version': 4,
      'createdAt': '2026-11-01T00:00:00.000Z',
      'workspaceId': fixtureWorkspaceId,
      'servers': <Object>[],
      'documents': [
        {'id': 'template-draft', 'revision': 1, 'source': 'draft from v4'},
        {
          'id': 'vpn-workspace-v1',
          'revision': 1,
          'source': fixtureCurrentVpnSource(),
        },
        {
          'id': 'publication/result/$userId',
          'revision': 1,
          'source': jsonEncode({
            'version': 1,
            'fileId': 'file-v4',
            'registryId': 'registry-v4',
            'head': 'a' * 32,
            'hash': 'b' * 64,
            'executor': 'c' * 32,
            'access': 'private',
          }),
        },
      ],
    });
    final b = await pull('b', 42);
    expect(await b.readDraft(), 'draft from v4');
    // Format 4 carried the author's cache; it is kept as received.
    expect(await b.readPublicationDocument('result/$userId'), isNotNull);
    await b.writeDraft('edited after v4');
    await _exchange(await session(b));
    final snapshot = await openFakeSnapshot(remote);
    expect(snapshot['version'], 5);
    expect([
      for (final row in snapshot['documents'] as List) row['id'],
    ], isNot(contains('publication/result/$userId')));
    for (final record in (_vpnOf(snapshot)['servers'] as Map).values) {
      expect((record as Map).keys, isNot(contains('observed')));
    }
  });

  test(
    'a newer cloud format is refused without touching data or the cloud',
    () async {
      final a = open('a', 41);
      await a.writeDraft('shared');
      await _exchange(await session(a));
      final b = await pull('b', 42);
      final cloud = await openFakeSnapshot(remote);
      await sealFakeSnapshot(remote, {...cloud, 'version': 6});
      final written = remote.snapshot;
      Matcher refused() => throwsA(
        isA<SyncTransportFailure>().having(
          (e) => e.issue,
          'issue',
          SyncTransportIssue.unsupportedVersion,
        ),
      );
      await expectLater(
        b.pullCurrentSnapshot(tokens, remote: remote),
        refused(),
      );
      expect(await b.readDraft(), 'shared');
      // A clean device keeps saying why, without asking Drive again.
      remote.calls.clear();
      final sync = await session(b);
      await expectLater(_exchange(sync), refused());
      expect(remote.calls, isEmpty);
      // Local edits are never written over the newer format.
      await b.writeDraft('edited locally');
      await expectLater(_exchange(sync), refused());
      expect(remote.snapshot, same(written));
      expect(await b.readDraft(), 'edited locally');
    },
  );

  test(
    'the same intent back in a readable format clears the refusal',
    () async {
      final a = open('a', 41);
      await a.writeDraft('shared');
      await _exchange(await session(a));
      final b = await pull('b', 42);
      final cloud = await openFakeSnapshot(remote);
      await sealFakeSnapshot(remote, {...cloud, 'version': 6});
      await expectLater(
        b.pullCurrentSnapshot(tokens, remote: remote),
        throwsA(isA<SyncTransportFailure>()),
      );
      // The cloud is readable again, with the intent this device holds: it
      // is only remembered, and sync works again.
      await sealFakeSnapshot(remote, cloud);
      expect(await b.pullCurrentSnapshot(tokens, remote: remote), isFalse);
      final sync = await session(b);
      expect((await _exchange(sync)).received, isFalse);
      await b.writeDraft('edited after');
      final writes = remote.writes;
      await _exchange(sync);
      expect(remote.writes, writes + 1);
    },
  );

  test('a reader of format 4 refuses v5 as a version, not as damage', () async {
    final a = open('a', 41);
    await a.writeDraft('v5 only');
    await _exchange(await session(a));
    // The file restore path validates format 4 exactly like the previous
    // release validated the cloud snapshot.
    final cloud = await openFakeSnapshot(remote);
    await expectLater(
      a.debugValidateSnapshot(jsonEncode(cloud), cloud: false),
      throwsA(
        isA<BackupFailure>().having(
          (e) => e.issue,
          'issue',
          BackupIssue.version,
        ),
      ),
    );
    await a.debugValidateSnapshot(jsonEncode(cloud), cloud: true);
  });
}
