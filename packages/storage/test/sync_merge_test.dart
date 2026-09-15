import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:antirkn_storage/src/backup_envelope.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/journal_data.dart';

const password = 'public-merge-backup-fixture';
void main() {
  late Directory directory;
  final stores = <WorkspaceDatabase>[];
  late WorkspaceDatabase a, b;
  late int baseline;
  String path(String name) => '${directory.path}/$name.sqlite';
  WorkspaceDatabase open(String name, [int key = 19]) {
    final db = WorkspaceDatabase.open(
      path(name),
      key: SecretKeyData(List.filled(32, key)),
    );
    stores.add(db);
    return db;
  }

  Future<WorkspaceDatabase> clone(
    WorkspaceDatabase source,
    String name, [
    int key = 41,
  ]) async {
    final backup = await source.createBackup(password),
        target = open(name, key);
    await target.restoreBackup(await target.prepareRestore(backup, password));
    await target.close();
    return open(name, key);
  }

  Future<List<Uint8List>> packets(
    WorkspaceDatabase source, [
    int? after,
  ]) async => (await source.preparePendingPackets(
    afterSequence: after ?? baseline,
  )).map((p) => p.bytes).toList();
  Future<void> saveServer(WorkspaceDatabase db, String id, String host) async =>
      (await db.openServer(id)).saveProfile(fixtureServer(host));
  Future<VpnWorkspace> vpn(WorkspaceDatabase db) async =>
      VpnWorkspace.decode((await db.readVpn()).source!);
  Future<void> saveVpn(WorkspaceDatabase db, VpnWorkspace value) async {
    final stored = await db.readVpn();
    await db.writeVpn(value.encode(), expectedRevision: stored.revision);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sync-merge-test-');
    a = open('a');
    await saveServer(a, 'one', 'base-one.example');
    await saveServer(a, 'two', 'base-two.example');
    await a.writeDraft('base-template');
    final identity = await a.readWorkspaceIdentity();
    await a.writeVpn(
      VpnWorkspace(
        id: identity.workspaceId,
        users: [
          VpnUser(id: '1' * 32, login: 'one', name: 'One'),
          VpnUser(id: '2' * 32, login: 'two', name: 'Two'),
        ],
      ).encode(),
      expectedRevision: 0,
    );
    baseline = (await a.readChanges()).last.header.sequence;
    b = await clone(a, 'b');
  });
  tearDown(() async {
    for (final db in stores) {
      await db.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  test(
    'independent entities converge and remote receipt never enters outbox',
    () async {
      await saveServer(a, 'one', 'edited-one.example');
      await saveServer(b, 'two', 'edited-two.example');
      final pa = await packets(a), pb = await packets(b);
      final qa = (await a.readPendingChanges()).length,
          qb = (await b.readPendingChanges()).length;
      expect((await a.receiveSyncPackets(pb)).conflicts, isEmpty);
      expect((await b.receiveSyncPackets(pa)).conflicts, isEmpty);
      expect((await a.listServers()).map((s) => s.profile.host).toSet(), {
        'edited-one.example',
        'edited-two.example',
      });
      expect((await b.listServers()).map((s) => s.profile.host).toSet(), {
        'edited-one.example',
        'edited-two.example',
      });
      expect((await a.readPendingChanges()).length, qa);
      expect((await b.readPendingChanges()).length, qb);
      await b.receiveSyncPackets(pa);
      expect((await b.readPendingChanges()).length, qb);
      expect(
        (await b.listServers()).first.profile.secrets,
        fixtureServer().secrets,
      );
    },
  );
  test(
    'missing predecessor survives restart and drains in causal order',
    () async {
      await a.writeDraft('first');
      await a.writeDraft('second');
      final p = await packets(a);
      final status = await b.receiveSyncPackets([p.last]);
      expect(status.missingChangeIds, hasLength(1));
      expect(status.waitingGroups, 1);
      expect(await b.readDraft(), 'base-template');
      await b.close();
      b = open('b', 41);
      expect((await b.readSyncMergeStatus()).waitingGroups, 1);
      expect((await b.receiveSyncPackets([p.first])).waitingGroups, 0);
      expect(await b.readDraft(), 'second');
    },
  );
  test(
    'a multi-entity transaction applies only when every member arrives',
    () async {
      final before = await vpn(a);
      await saveVpn(
        a,
        before.copy(
          users: [
            VpnUser(id: '1' * 32, login: 'one', name: 'Changed'),
            before.users.last,
          ],
        ),
      );
      // Changing a user and adding another also updates collection membership.
      await saveVpn(
        a,
        (await vpn(a)).copy(
          users: [
            ...(await vpn(a)).users,
            VpnUser(id: '3' * 32, login: 'three', name: 'Three'),
          ],
        ),
      );
      final p = await packets(a);
      expect(p.length, 3);
      final status = await b.receiveSyncPackets([p.last]);
      expect(status.waitingGroups, 1);
      expect((await vpn(b)).users, hasLength(2));
      await b.receiveSyncPackets(p.reversed.toList());
      expect((await vpn(b)).users, hasLength(3));
      expect((await vpn(b)).users.first.name, 'Changed');
    },
  );
  test(
    'concurrent templates preserve both versions; resolution joins branches and propagates',
    () async {
      await a.writeDraft('private-local-template');
      await b.writeDraft('private-remote-template');
      final pa = await packets(a), pb = await packets(b);
      final sa = await a.receiveSyncPackets(pb);
      await b.receiveSyncPackets(pa);
      final conflict = sa.conflicts.single;
      expect(conflict.ancestor!.source, 'base-template');
      expect(conflict.variants.map((v) => v.source).toSet(), {
        'private-local-template',
        'private-remote-template',
      });
      await expectLater(
        a.writeDraft('silent overwrite'),
        throwsA(isA<VaultFailure>()),
      );
      await expectLater(a.checkSyncEffects(), throwsA(isA<SyncMergeFailure>()));
      final choose = conflict.variants
          .firstWhere((v) => v.source == 'private-remote-template')
          .header
          .changeId;
      await a.resolveSyncConflict(conflict, choose);
      expect(await a.readDraft(), 'private-remote-template');
      expect((await a.readSyncMergeStatus()).conflicts, isEmpty);
      await b.receiveSyncPackets(await packets(a));
      expect((await b.readSyncMergeStatus()).conflicts, isEmpty);
      expect(await b.readDraft(), await a.readDraft());
      await a.receiveSyncPackets(pb);
      expect((await a.readSyncMergeStatus()).conflicts, isEmpty);
      await expectLater(
        a.resolveSyncConflict(conflict, choose),
        throwsA(isA<SyncMergeFailure>()),
      );
      await a.checkSyncEffects();
    },
  );
  test(
    'simultaneous equivalent resolutions converge and later edits cover both tips',
    () async {
      await a.writeDraft('left');
      await b.writeDraft('right');
      await a.receiveSyncPackets(await packets(b));
      await b.receiveSyncPackets(await packets(a));
      for (final db in [a, b]) {
        final c = (await db.readSyncMergeStatus()).conflicts.single;
        await db.resolveSyncConflict(
          c,
          c.variants.firstWhere((v) => v.source == 'left').header.changeId,
        );
      }
      await a.receiveSyncPackets(await packets(b));
      await b.receiveSyncPackets(await packets(a));
      expect((await a.readSyncMergeStatus()).conflicts, isEmpty);
      await a.writeDraft('after resolutions');
      await b.receiveSyncPackets(await packets(a));
      expect(await b.readDraft(), 'after resolutions');
      expect((await b.readSyncMergeStatus()).conflicts, isEmpty);
    },
  );
  test(
    'delete versus offline edit retains conflict and never restores deleted server',
    () async {
      final vault = await a.openServer('one');
      await vault.saveProfile(null);
      await saveServer(b, 'one', 'offline-edit.example');
      final pa = await packets(a), pb = await packets(b);
      for (final (db, p) in [(a, pb), (b, pa)]) {
        final status = await db.receiveSyncPackets(p);
        expect(status.conflicts, hasLength(1));
        expect(
          (await db.listServers()).map((s) => s.id),
          isNot(contains('one')),
        );
      }
      final c = (await a.readSyncMergeStatus()).conflicts.single;
      await a.resolveSyncConflict(
        c,
        c.variants.firstWhere((v) => v.header.deleted).header.changeId,
      );
      await b.receiveSyncPackets(await packets(a));
      expect((await b.listServers()).map((s) => s.id), isNot(contains('one')));
      await expectLater(
        saveServer(b, 'one', 'resurrection.example'),
        throwsA(isA<VaultFailure>()),
      );
    },
  );
  test(
    'independent new users merge collection references without losing either user',
    () async {
      await saveVpn(
        a,
        (await vpn(a)).copy(
          users: [
            ...(await vpn(a)).users,
            VpnUser(id: '3' * 32, login: 'three', name: 'Three'),
          ],
        ),
      );
      await saveVpn(
        b,
        (await vpn(b)).copy(
          users: [
            ...(await vpn(b)).users,
            VpnUser(id: '4' * 32, login: 'four', name: 'Four'),
          ],
        ),
      );
      final pa = await packets(a), pb = await packets(b);
      expect((await a.receiveSyncPackets(pb)).conflicts, isEmpty);
      expect((await b.receiveSyncPackets(pa)).conflicts, isEmpty);
      expect((await vpn(a)).users.map((u) => u.id).toSet(), {
        '1' * 32,
        '2' * 32,
        '3' * 32,
        '4' * 32,
      });
      expect((await vpn(a)).encode(), (await vpn(b)).encode());
      final c = await clone(a, 'c', 53);
      expect((await vpn(c)).encode(), (await vpn(a)).encode());
    },
  );
  test(
    'incompatible independent edits cannot violate unique login constraint',
    () async {
      await saveVpn(
        a,
        (await vpn(a)).copy(
          users: [
            VpnUser(id: '1' * 32, login: 'same', name: 'One'),
            (await vpn(a)).users.last,
          ],
        ),
      );
      await saveVpn(
        b,
        (await vpn(b)).copy(
          users: [
            (await vpn(b)).users.first,
            VpnUser(id: '2' * 32, login: 'same', name: 'Two'),
          ],
        ),
      );
      final before = (await b.readVpn()).source;
      final status = await b.receiveSyncPackets(await packets(a));
      expect(status.blockedGroups, 1);
      expect((await b.readVpn()).source, before);
      await saveVpn(
        b,
        (await vpn(b)).copy(
          users: [
            (await vpn(b)).users.first,
            VpnUser(id: '2' * 32, login: 'different', name: 'Two'),
          ],
        ),
      );
      expect((await b.retrySyncMerge()).blockedGroups, 0);
      expect((await vpn(b)).users.map((u) => u.login).toSet(), {
        'same',
        'different',
      });
    },
  );
  test(
    'backup retains conflicts, waiting groups and accepted history with a new local key',
    () async {
      await a.writeDraft('left');
      await b.writeDraft('right');
      await b.receiveSyncPackets(await packets(a));
      await saveServer(a, 'one', 'first.example');
      await saveServer(a, 'one', 'last.example');
      await b.receiveSyncPackets([(await packets(a)).last]);
      final c = await clone(b, 'c', 53);
      final state = await c.readSyncMergeStatus();
      expect(state.conflicts, hasLength(1));
      expect(state.waitingGroups, 1);
      await c.receiveSyncPackets(await packets(a));
      expect((await c.readSyncMergeStatus()).waitingGroups, 0);
      expect(
        (await c.listServers()).firstWhere((s) => s.id == 'one').profile.host,
        'last.example',
      );
    },
  );
  test(
    'failed application transaction preserves data; durable inbox retries after restart',
    () async {
      await a.writeDraft('received');
      final p = await packets(a);
      final raw = sqlite3.open(path('b'));
      raw.execute(
        "CREATE TRIGGER fail_merge BEFORE UPDATE ON documents BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      await expectLater(b.receiveSyncPackets(p), throwsA(anything));
      expect(await b.readDraft(), 'base-template');
      expect((await b.readSyncMergeStatus()).waitingGroups, 1);
      raw.execute('DROP TRIGGER fail_merge');
      raw.dispose();
      await b.close();
      b = open('b', 41);
      await b.retrySyncMerge();
      expect(await b.readDraft(), 'received');
    },
  );
  test('damaged packet fails before inbox or working records change', () async {
    await a.writeDraft('received');
    final p = await packets(a);
    p[0] = Uint8List.fromList(p.single);
    p.single[p.single.length - 1] ^= 1;
    await expectLater(
      b.receiveSyncPackets(p),
      throwsA(isA<SyncPacketFailure>()),
    );
    expect((await b.readSyncMergeStatus()).waitingGroups, 0);
    expect(await b.readDraft(), 'base-template');
  });
  test(
    'received state quarantines VPN operations and no secrets enter SQLite/WAL',
    () async {
      await saveVpn(
        a,
        (await vpn(a)).copy(
          servers: {
            'one': {
              'authorizedPayload': 'private-remote-operation',
              'pending': {'id': 'fixture'},
            },
          },
        ),
      );
      await b.receiveSyncPackets(await packets(a));
      expect(await b.readRestoredTargets(), contains('one'));
      await b.writeDraft('local change unrelated to operation');
      for (final suffix in ['', '-wal']) {
        final f = File('${path('b')}$suffix');
        if (!await f.exists()) continue;
        final text = latin1.decode(await f.readAsBytes());
        expect(text, isNot(contains(fixtureSecret)));
        expect(text, isNot(contains('private-remote-operation')));
      }
    },
  );
  test(
    'parallel receivers recheck the journal and retry without losing events',
    () async {
      await a.writeDraft('parallel');
      await saveServer(a, 'one', 'parallel.example');
      final p = await packets(a), second = open('b', 41);
      await second.readWorkspaceIdentity();
      await Future.wait([
        b
            .receiveSyncPackets([p.first])
            .then<Object>((s) => s, onError: (Object e) => e),
        second
            .receiveSyncPackets([p.last])
            .then<Object>((s) => s, onError: (Object e) => e),
      ]);
      await b.receiveSyncPackets(p);
      expect(await b.readDraft(), 'parallel');
      expect(
        (await b.listServers()).firstWhere((s) => s.id == 'one').profile.host,
        'parallel.example',
      );
      expect((await b.readSyncMergeStatus()).waitingGroups, 0);
    },
  );
  test(
    'authenticated ID substitution rejects; different ciphertext of the same event is a duplicate',
    () async {
      await a.writeDraft('received');
      final p = await packets(a);
      final event = await a.verifySyncPacket(p.single);
      final snapshot =
          jsonDecode(
                await BackupEnvelope.open(
                  await a.createBackup(password),
                  password,
                ),
              )
              as Map;
      final key = SecretKeyData(
        base64Decode(snapshot['syncKey']['key'] as String),
      );
      final codec = SyncPacketCodec(
        workspaceId: event.header.workspaceId,
        keyVersion: 1,
        key: key,
      );
      try {
        await b.receiveSyncPackets(p);
        expect(
          (await b.receiveSyncPackets([await codec.seal(event)])).conflicts,
          isEmpty,
        );
        await expectLater(
          b.receiveSyncPackets([
            await codec.seal(
              LocalChange(header: event.header, source: 'forged replacement'),
            ),
          ]),
          throwsA(isA<SyncMergeFailure>()),
        );
        expect(await b.readDraft(), 'received');
        final invalid = LocalChange(
          header: ChangeHeader.fromJson({
            ...event.header.toJson(),
            'changeId': 'e' * 32,
            'transactionId': 'e' * 32,
            'sequence': event.header.sequence + 100,
            'entityKind': 'server',
            'entityId': 'one',
          }),
          source: '{"id":"different"}',
        );
        await expectLater(
          b.receiveSyncPackets([await codec.seal(invalid)]),
          throwsA(isA<SyncMergeFailure>()),
        );
        expect((await b.readSyncMergeStatus()).blockedGroups, 0);
        final serverParent = (await a.readChanges())
            .firstWhere((e) => e.header.entityKind == ChangeEntityKind.server)
            .header;
        final brokenHistory = LocalChange(
          header: ChangeHeader.fromJson({
            ...event.header.toJson(),
            'changeId': 'e' * 32,
            'transactionId': 'e' * 32,
            'sequence': event.header.sequence + 100,
            'baseChangeId': serverParent.changeId,
            'baseRevision': serverParent.revision,
            'revision': serverParent.revision + 1,
          }),
          source: 'wrong-parent-kind',
        );
        final rejected = await b.receiveSyncPackets([
          await codec.seal(brokenHistory),
        ]);
        expect(rejected.rejectedGroups, 1);
        expect(rejected.blockedGroups, 0);
        expect(await b.readDraft(), 'received');
        await b.checkSyncEffects();
        final copy = await clone(b, 'rejected-backup', 53);
        expect((await copy.readSyncMergeStatus()).rejectedGroups, 1);
      } finally {
        key.destroy();
      }
    },
  );
  test(
    'crash after application commit retains inbox, working data and conflict decisions',
    () async {
      await a.writeDraft('survives crash');
      await File('${path('b')}.packets').writeAsString(
        jsonEncode((await packets(a)).map(base64Encode).toList()),
      );
      await b.close();
      final process = await Process.run(
        'flutter',
        [
          'test',
          '--no-pub',
          'test/fixtures/merge_crash_worker.dart',
          '--reporter',
          'expanded',
        ],
        environment: {'ANTIRKN_MERGE_CRASH_PATH': path('b')},
      );
      expect(
        process.exitCode,
        isNot(0),
        reason: 'The worker deliberately exits without finishing its test.',
      );
      expect(process.stdout, contains('merge_fixture_committed_without_close'));
      b = open('b', 41);
      expect(await b.readDraft(), 'survives crash');
      expect((await b.readSyncMergeStatus()).waitingGroups, 0);
      await b.receiveSyncPackets(await packets(a));
      expect(await b.readDraft(), 'survives crash');
    },
  );
  test(
    'schema v4 migration rollback preserves data and old writer is rejected after v5',
    () async {
      await b.close();
      final raw = sqlite3.open(path('b'));
      for (final table in [
        'sync_incoming',
        'sync_branches',
        'sync_conflicts',
        'sync_merge_meta',
      ]) {
        raw.execute('DROP TABLE $table');
      }
      for (final table in ['servers', 'documents']) {
        for (final action in ['insert', 'update', 'delete']) {
          raw.execute('DROP TRIGGER journal_guard_${table}_$action');
          raw.execute(
            "CREATE TRIGGER journal_guard_${table}_$action BEFORE $action ON $table WHEN (SELECT write_guard != 1 OR writer_device IS NOT device_id OR writer_version != 4 FROM sync_identity WHERE singleton=1) BEGIN SELECT RAISE(ABORT,'journal_writer_required'); END",
          );
        }
      }
      raw.userVersion = 4;
      final before = jsonEncode(raw.select('SELECT * FROM documents'));
      raw.execute('CREATE TABLE sync_branches (fixture INTEGER)');
      b = open('b', 41);
      await expectLater(b.readDraft(), throwsA(anything));
      expect(raw.userVersion, 4);
      expect(jsonEncode(raw.select('SELECT * FROM documents')), before);
      raw.execute('DROP TABLE sync_branches');
      expect(await b.readDraft(), 'base-template');
      expect(raw.userVersion, 5);
      raw.execute('BEGIN');
      try {
        raw.execute(
          'UPDATE sync_identity SET write_guard=1,writer_device=device_id,writer_version=4',
        );
        expect(
          () => raw.execute('UPDATE documents SET revision=revision+1'),
          throwsA(isA<SqliteException>()),
        );
      } finally {
        raw.execute('ROLLBACK');
        raw.dispose();
      }
    },
  );
}
