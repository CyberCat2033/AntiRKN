import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/journal_data.dart';

final class _Tokens implements SyncAccessTokenProvider {
  @override
  String get accountKey => 'snapshot-test-account';
  @override
  Future<String> accessToken() async => 'fixture';
}

final class _Remote implements SyncRemoteStore, SyncSnapshotStore {
  @override
  String get accountKey => 'snapshot-test-account';
  Uint8List? snapshot, key;
  int version = 0, writes = 0;
  bool unavailable = false, loseResponse = false;

  @override
  Future<SyncRemoteFile?> findSnapshot() async => snapshot == null
      ? null
      : SyncRemoteFile(
          id: 'snapshot-id',
          name: syncSnapshotName,
          size: snapshot!.length,
          version: '$version',
          packet: false,
        );

  @override
  Future<Uint8List> readSnapshot(String fileId) async =>
      Uint8List.fromList(snapshot!);

  @override
  Future<void> writeSnapshot(String? fileId, Uint8List bytes) async {
    if (unavailable) {
      throw const SyncTransportFailure(SyncTransportIssue.network);
    }
    snapshot = Uint8List.fromList(bytes);
    version++;
    writes++;
    if (loseResponse) {
      loseResponse = false;
      throw const SyncTransportFailure(SyncTransportIssue.network);
    }
  }

  @override
  Future<Uint8List?> readSnapshotKey() async =>
      key == null ? null : Uint8List.fromList(key!);

  @override
  Future<void> createSnapshotKey(Uint8List bytes) async {
    if (key != null) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
    key = Uint8List.fromList(bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<AutoSyncResult> _upload(AutoSyncSession session, {bool retry = false}) =>
    session.exchange(
      apply: (_) async => true,
      cancellation: SyncCancellation(),
      forceRecovery: retry,
    );

void main() {
  late Directory directory;
  final stores = <WorkspaceDatabase>[];
  final sessions = <AutoSyncSession>[];
  final tokens = _Tokens();
  late _Remote remote;

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

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('single-snapshot-test-');
    remote = _Remote();
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

  test(
    'one encrypted cloud snapshot replaces the previous current state',
    () async {
      final first = open('first', 11);
      await first.writeDraft('private current draft');
      final sync = await session(first);
      expect(remote.writes, 0);
      await _upload(sync);
      expect(remote.writes, 1);
      expect(
        String.fromCharCodes(remote.snapshot!),
        isNot(contains('private current draft')),
      );
      await first.writeDraft('second current draft');
      await _upload(sync);
      expect(remote.writes, 2);
      expect(await first.readDraft(), 'second current draft');
      expect(
        await File('${directory.path}/first.sqlite.current-snapshot').exists(),
        isTrue,
      );
    },
  );

  test('isolated database uploads and restores a current snapshot', () async {
    final first = await WorkspaceDatabase.openIsolated(
      '${directory.path}/isolated-first.sqlite',
      key: SecretKeyData(List.filled(32, 31)),
    );
    stores.add(first);
    await first.writeDraft('isolated private draft');
    await first.upsertVpnUser(
      VpnUser(
        id: fixtureUserId,
        login: 'fixture',
        name: 'Fixture',
        baseTemplate: 'rules: [MATCH,DIRECT]\n# individual-private-fixture',
        baseTemplateName: 'individual.yaml',
      ),
      expectedRevision: 0,
    );
    await _upload(await session(first));
    expect(
      String.fromCharCodes(remote.snapshot!),
      isNot(contains('individual-private-fixture')),
    );
    final second = await WorkspaceDatabase.openIsolated(
      '${directory.path}/isolated-second.sqlite',
      key: SecretKeyData(List.filled(32, 32)),
    );
    stores.add(second);
    expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    await second.close();
    final reopened = await WorkspaceDatabase.openIsolated(
      '${directory.path}/isolated-second.sqlite',
      key: SecretKeyData(List.filled(32, 32)),
    );
    stores.add(reopened);
    expect(await reopened.readDraft(), 'isolated private draft');
    final user = VpnWorkspace.decode(
      (await reopened.readVpn()).source!,
    ).users.single;
    expect(user.baseTemplate, contains('individual-private-fixture'));
    expect(user.baseTemplateName, 'individual.yaml');
  });

  test(
    'saved snapshot bounds the local journal and later edits still work',
    () async {
      final first = open('first', 11);
      for (var index = 0; index < 80; index++) {
        await first.writeDraft('draft $index');
      }
      final path = '${directory.path}/first.sqlite';
      int count() {
        final db = sqlite3.open(path);
        try {
          return db.select('SELECT count(*) AS n FROM sync_changes').single['n']
              as int;
        } finally {
          db.dispose();
        }
      }

      expect(count(), greaterThan(50));
      await _upload(await session(first));
      expect(count(), lessThan(5));
      expect((await first.readSyncMergeStatus()).conflicts, isEmpty);
      await first.writeDraft('draft after compaction');
      expect(await first.readDraft(), 'draft after compaction');
      expect((await first.readSyncMergeStatus()).conflicts, isEmpty);
      await _upload(await session(first));
      expect(count(), lessThan(5));
    },
  );

  test(
    'profile publication remains readable after repeated compaction',
    () async {
      final first = open('first', 11);
      final workspaceId = (await first.readWorkspaceIdentity()).workspaceId;
      const userId = '11111111111111111111111111111111';
      Future<void> saveProfile(String yaml) async {
        final before = await first.readVpn();
        final source = before.source == null
            ? VpnWorkspace(
                id: workspaceId,
                users: [VpnUser(id: userId, login: 'fixture', name: 'Fixture')],
              )
            : VpnWorkspace.decode(before.source!);
        final hash = (await Sha256().hash(
          utf8.encode(yaml),
        )).bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
        await first.writeVpn(
          source
              .copy(
                profiles: {
                  userId: {'yaml': yaml, 'hash': hash},
                },
              )
              .encode(),
          expectedRevision: before.revision,
        );
      }

      await saveProfile('first current profile');
      final firstHead = (await first.readPublicationDraft(userId))!.headId;
      await _upload(await session(first));
      await saveProfile('second current profile');
      expect(
        (await first.readPublicationDraft(userId))!.ancestors,
        contains(firstHead),
      );
      await _upload(await session(first));
      await saveProfile('third current profile');
      expect(
        (await first.readPublicationDraft(userId))!.bytes,
        utf8.encode('third current profile'),
      );
      expect((await first.readSyncMergeStatus()).conflicts, isEmpty);
    },
  );

  test(
    'failed upload leaves encrypted local snapshot for startup retry',
    () async {
      final first = open('first', 11);
      await first.writeDraft('keep when offline');
      final sync = await session(first);
      remote.unavailable = true;
      await expectLater(_upload(sync), throwsA(isA<SyncTransportFailure>()));
      final local = File('${directory.path}/first.sqlite.current-snapshot');
      expect(await local.exists(), isTrue);
      expect(
        String.fromCharCodes(await local.readAsBytes()),
        isNot(contains('keep when offline')),
      );
      remote.unavailable = false;
      await _upload(sync, retry: true);
      expect(remote.writes, 1);
      await _upload(sync, retry: true);
      expect(remote.writes, 1);
    },
  );

  test(
    'lost Drive response is acknowledged on retry without another write',
    () async {
      final first = open('first', 11);
      await first.writeDraft('accepted despite lost response');
      final sync = await session(first);
      remote.loseResponse = true;
      await expectLater(_upload(sync), throwsA(isA<SyncTransportFailure>()));
      expect(remote.writes, 1);
      await _upload(sync, retry: true);
      expect(remote.writes, 1);
      expect(await first.readDraft(), 'accepted despite lost response');
    },
  );

  test(
    'empty second device imports servers, clients and secrets; clean first device follows later snapshot',
    () async {
      await createV1('${directory.path}/first.sqlite');
      final first = WorkspaceDatabase.open(
        '${directory.path}/first.sqlite',
        key: fixtureKey(),
      );
      stores.add(first);
      expect(
        (await first.listServers()).single.profile.secrets,
        fixtureServer().secrets,
      );
      expect((await first.readVpn()).source, fixtureVpn().encode());
      await _upload(await session(first));
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      final restored = open('second', 22);
      expect(
        (await restored.listServers()).single.profile.secrets,
        fixtureServer().secrets,
      );
      expect((await restored.readVpn()).source, fixtureCurrentVpnSource());
      await restored.writeDraft('new state from second');
      await _upload(await session(restored));
      expect(await first.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await first.close();
      final refreshed = WorkspaceDatabase.open(
        '${directory.path}/first.sqlite',
        key: fixtureKey(),
      );
      stores.add(refreshed);
      expect(await refreshed.readDraft(), 'new state from second');
      expect(
        (await refreshed.listServers()).single.profile.secrets,
        fixtureServer().secrets,
      );
      expect((await refreshed.readVpn()).source, fixtureCurrentVpnSource());
    },
  );

  test(
    'different nonempty local workspace cannot overwrite cloud state',
    () async {
      final first = open('first', 11);
      await first.writeDraft('cloud data');
      await _upload(await session(first));
      final second = open('second', 22);
      await second.writeDraft('independent local data');
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isFalse);
      await expectLater(
        _upload(await session(second)),
        throwsA(
          isA<SyncTransportFailure>().having(
            (e) => e.issue,
            'issue',
            SyncTransportIssue.conflict,
          ),
        ),
      );
      expect(await second.readDraft(), 'independent local data');
      expect(remote.writes, 1);
    },
  );

  test(
    'clean device after another device upload receives the new version',
    () async {
      final first = open('first', 11);
      await first.writeDraft('version one');
      await _upload(await session(first));
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      final restored = open('second', 22);
      await restored.writeDraft('version two');
      await _upload(await session(restored));
      final writes = remote.writes;
      // First device has no edits; leaving the app must not report a conflict
      // and must not overwrite or race the newer cloud state.
      final result = await _upload(await session(first));
      expect(result.remoteNewer, isTrue);
      expect(remote.writes, writes);
      await _upload(await session(first), retry: true);
      expect(remote.writes, writes);
      expect(await first.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await first.close();
      final refreshed = open('first', 11);
      expect(await refreshed.readDraft(), 'version two');
    },
  );

  test(
    'unconfirmed snapshot of a clean device does not block a later pull',
    () async {
      final first = open('first', 11);
      await first.writeDraft('version one');
      await _upload(await session(first));
      // Leaving again without edits; the upload never reaches Drive.
      remote.unavailable = true;
      await expectLater(
        _upload(await session(first)),
        throwsA(isA<SyncTransportFailure>()),
      );
      remote.unavailable = false;
      final local = File('${directory.path}/first.sqlite.current-snapshot');
      expect(await local.exists(), isTrue);
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      final restored = open('second', 22);
      await restored.writeDraft('version two');
      await _upload(await session(restored));
      final writes = remote.writes;
      // Startup recovery finds nothing to send and does not conflict.
      await _upload(await session(first), retry: true);
      expect(remote.writes, writes);
      expect(await first.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await first.close();
      final refreshed = open('first', 11);
      expect(await refreshed.readDraft(), 'version two');
      expect(await local.exists(), isFalse);
      // The refreshed device is clean and bound to the received version.
      await refreshed.writeDraft('version three');
      await _upload(await session(refreshed));
      expect(remote.writes, writes + 1);
    },
  );

  test(
    'empty unbound device never uploads over an existing cloud snapshot',
    () async {
      final first = open('first', 11);
      await first.writeDraft('cloud data');
      await _upload(await session(first));
      final second = open('second', 22);
      final result = await _upload(await session(second));
      expect(result.remoteNewer, isTrue);
      expect(remote.writes, 1);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      expect(await open('second', 22).readDraft(), 'cloud data');
    },
  );

  test(
    'device id and sync key stay stable across cloud pulls of one workspace',
    () async {
      final first = open('first', 11);
      await first.writeDraft('version one');
      await _upload(await session(first));
      final second = open('second', 22);
      final ownDevice = (await second.readWorkspaceIdentity()).deviceId;
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      var restored = open('second', 22);
      final identity = await restored.readWorkspaceIdentity();
      expect(identity.deviceId, ownDevice);
      Uint8List syncKey() {
        final db = sqlite3.open('${directory.path}/second.sqlite');
        try {
          return db.select('SELECT payload FROM sync_keys').single['payload']
              as Uint8List;
        } finally {
          db.dispose();
        }
      }

      final operation = ServerOperation(
        operationId: 'e' * 32,
        executorDeviceId: identity.deviceId,
      );
      final vpn = await restored.readVpn();
      await restored.writeVpn(
        VpnWorkspace(
          id: identity.workspaceId,
          servers: {
            fixtureServerId: {'operation': operation.toJson()},
          },
        ).encode(),
        expectedRevision: vpn.revision,
      );
      await _upload(await session(restored));
      final key = syncKey();
      await first.close();
      final firstAgain = open('first', 11);
      expect(
        await firstAgain.pullCurrentSnapshot(tokens, remote: remote),
        isTrue,
      );
      await firstAgain.close();
      final edited = open('first', 11);
      await edited.writeDraft('version two');
      await _upload(await session(edited));
      expect(
        await restored.pullCurrentSnapshot(tokens, remote: remote),
        isTrue,
      );
      await restored.close();
      restored = open('second', 22);
      final after = await restored.readWorkspaceIdentity();
      expect(after.deviceId, ownDevice);
      expect(after.workspaceId, identity.workspaceId);
      expect(syncKey(), key);
      expect(await restored.readDraft(), 'version two');
      final record = VpnWorkspace.decode(
        (await restored.readVpn()).source!,
      ).servers[fixtureServerId]!;
      expect(
        ServerOperation.fromJson(record['operation'] as Map).executorDeviceId,
        after.deviceId,
      );
    },
  );

  test(
    'legacy merge conflicts do not block upload and are cleared after it',
    () async {
      final path = '${directory.path}/legacy.sqlite';
      var store = open('legacy', 33);
      await store.writeDraft('materialized state');
      await store.close();
      final db = sqlite3.open(path);
      try {
        for (final row in db.select(
          'SELECT entity_kind,entity_id FROM sync_heads',
        )) {
          db.execute('INSERT INTO sync_conflicts VALUES (?,?)', [
            row['entity_kind'],
            row['entity_id'],
          ]);
          db.execute('INSERT INTO sync_branches VALUES (?,?,?)', [
            row['entity_kind'],
            row['entity_id'],
            'f' * 32,
          ]);
        }
        db.execute("INSERT INTO sync_incoming VALUES (?,'{}',x'00',0)", [
          'a' * 32,
        ]);
      } finally {
        db.dispose();
      }
      store = open('legacy', 33);
      await _upload(await session(store));
      expect(remote.writes, 1);
      int count(String sql) {
        final db = sqlite3.open(path);
        try {
          return db.select(sql).single['n'] as int;
        } finally {
          db.dispose();
        }
      }

      expect(count('SELECT count(*) AS n FROM sync_conflicts'), 0);
      expect(count('SELECT count(*) AS n FROM sync_incoming'), 0);
      expect(
        count(
          'SELECT count(*) AS n FROM (SELECT 1 FROM sync_branches GROUP BY entity_kind,entity_id HAVING count(*)>1)',
        ),
        0,
      );
      await store.writeDraft('edited after cleanup');
      expect(await store.readDraft(), 'edited after cleanup');
      await _upload(await session(store));
      expect(remote.writes, 2);
    },
  );
}
