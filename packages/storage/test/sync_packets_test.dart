import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_storage/src/backup_envelope.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/journal_data.dart';

const password = 'public-sync-backup-fixture-password';

void main() {
  late Directory directory;
  final stores = <WorkspaceDatabase>[];
  String path(String name) => '${directory.path}/$name.sqlite';
  WorkspaceDatabase open(String name, [int keyByte = 19]) {
    final store = WorkspaceDatabase.open(
      path(name),
      key: SecretKeyData(List.filled(32, keyByte)),
    );
    stores.add(store);
    return store;
  }

  T sql<T>(String name, T Function(Database) action) {
    final raw = sqlite3.open(path(name));
    try {
      return action(raw);
    } finally {
      raw.dispose();
    }
  }

  String state(String name) => sql(
    name,
    (db) => jsonEncode({
      for (final table in [
        'servers',
        'documents',
        'settings',
        'sync_identity',
        'sync_keys',
        'sync_packets',
        'sync_changes',
        'sync_outbox',
        'sync_heads',
      ])
        table: db.select('SELECT * FROM $table ORDER BY 1'),
    }),
  );
  List<String> encoded(List<EncryptedChangePacket> packets) =>
      packets.map((e) => base64Encode(e.bytes)).toList();
  Future<WorkspaceDatabase> clone(
    WorkspaceDatabase source,
    String name,
    int keyByte,
  ) async {
    final target = open(name, keyByte);
    final backup = await source.createBackup(password);
    await target.restoreBackup(await target.prepareRestore(backup, password));
    await target.close();
    return open(name, keyByte);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sync-packets-test-');
  });
  tearDown(() async {
    for (final store in stores) {
      await store.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  test(
    'two stores with distinct local keys share packets through backup, retain IDs and never apply received data',
    () async {
      await createV1(path('first'));
      final first = open('first');
      final removed = await first.openServer('deleted-fixture');
      await removed.saveProfile(fixtureServer());
      await removed.saveProfile(null);
      final packets = await first.preparePendingPackets();
      final events = await first.readPendingChanges();
      final second = await clone(first, 'second', 41);
      final identity = await first.readWorkspaceIdentity();
      final secondIdentity = await second.readWorkspaceIdentity();
      expect(identity.workspaceId, secondIdentity.workspaceId);
      expect(identity.deviceId, isNot(secondIdentity.deviceId));
      expect(encoded(await second.preparePendingPackets()), encoded(packets));
      expect(
        (await second.listServers()).single.profile.secrets,
        fixtureServer().secrets,
      );
      final before = state('second');
      for (var i = 0; i < packets.length; i++) {
        final actual = await second.verifySyncPacket(packets[i].bytes);
        expect(actual.header.toJson(), events[i].header.toJson());
        expect(actual.source, events[i].source);
      }
      await second.verifySyncPacket(packets.last.bytes);
      expect(state('second'), before);
      await second.writeDraft('a change from the other installation');
      final newer = (await second.preparePendingPackets(
        afterSequence: events.last.header.sequence,
      )).single;
      final firstBefore = state('first');
      expect(
        (await first.verifySyncPacket(newer.bytes)).header.deviceId,
        secondIdentity.deviceId,
      );
      expect(state('first'), firstBefore);
      expect(await first.readDraft(), 'private-template-fixture');
    },
  );

  test(
    'preparation, paging, acknowledgements and restart keep exact ciphertext and pending IDs',
    () async {
      final first = open('first');
      await first.writeDraft('one');
      await first.writeDraft('two');
      final pending = await first.readPendingChanges();
      final packets = await first.preparePendingPackets(limit: 2);
      expect(packets.length, 2);
      expect((await first.readPendingChanges()).length, pending.length);
      expect(
        encoded(await first.preparePendingPackets(limit: 2)),
        encoded(packets),
      );
      final last = await first.preparePendingPackets(
        afterSequence: packets.last.sequence,
      );
      expect(last.single.changeId, pending.last.header.changeId);
      await first.acknowledgeChanges([packets.first.changeId]);
      final expected = [packets.last, last.single];
      await first.close();
      final reopened = open('first');
      expect(
        encoded(await reopened.preparePendingPackets()),
        encoded(expected),
      );
      await expectLater(
        reopened.preparePendingPackets(limit: 101),
        throwsArgumentError,
      );
      expect(() => packets.first.bytes[0] = 0, throwsUnsupportedError);
    },
  );

  test(
    'header, nonce, body, tag, wrong key and foreign workspace leave all destination tables intact',
    () async {
      final first = open('first');
      await first.writeDraft('secret-fixture-source');
      final packets = await first.preparePendingPackets();
      final second = await clone(first, 'second', 41);
      final good = packets.last.bytes, before = state('second');
      for (final offset in [
        0,
        syncVersionOffset,
        syncSuiteOffset,
        syncKeyVersionOffset + 3,
        syncWorkspaceIdOffset,
        syncChangeIdOffset,
        syncHeaderBytes,
        syncHeaderBytes + syncNonceBytes,
        good.length - 1,
      ]) {
        final damaged = Uint8List.fromList(good)..[offset] ^= 1;
        await expectLater(
          second.verifySyncPacket(damaged),
          throwsA(isA<SyncPacketFailure>()),
        );
        expect(state('second'), before);
      }
      final foreign = open('foreign');
      final foreignPacket =
          (await foreign.preparePendingPackets()).single.bytes;
      await expectLater(
        second.verifySyncPacket(foreignPacket),
        throwsA(isA<SyncPacketFailure>()),
      );
      // Same workspace, different legitimate key: format validation alone is insufficient.
      final data =
          jsonDecode(
                await BackupEnvelope.open(
                  await first.createBackup(password),
                  password,
                ),
              )
              as Map<String, dynamic>;
      (data['syncKey'] as Map)['key'] = base64Encode(List.filled(32, 77));
      data['syncPackets'] = <Object?>[];
      final third = open('third', 51);
      final wrongKeyBackup = await BackupEnvelope.seal(
        jsonEncode(data),
        password,
      );
      await third.restoreBackup(
        await third.prepareRestore(wrongKeyBackup, password),
      );
      await third.close();
      final wrong = open('third', 51), wrongBefore = state('third');
      await expectLater(
        wrong.verifySyncPacket(good),
        throwsA(isA<SyncPacketFailure>()),
      );
      expect(state('third'), wrongBefore);
      expect(
        (await second.verifySyncPacket(good)).source,
        'secret-fixture-source',
      );
      expect(state('second'), before);
    },
  );

  test(
    'failed cache transaction rolls back every packet and preserves queue and entities',
    () async {
      final db = open('first');
      await db.writeDraft('source');
      final before = state('first');
      sql(
        'first',
        (raw) => raw.execute(
          "CREATE TRIGGER fail_packet BEFORE INSERT ON sync_packets WHEN (SELECT COUNT(*) FROM sync_packets) = 1 BEGIN SELECT RAISE(ABORT,'fixture'); END",
        ),
      );
      await expectLater(db.preparePendingPackets(), throwsA(anything));
      expect(state('first'), before);
      sql('first', (raw) => raw.execute('DROP TRIGGER fail_packet'));
      expect((await db.preparePendingPackets()).length, 2);
    },
  );

  test(
    'concurrent initialization and preparation converge on one durable key and packet per event',
    () async {
      final first = open('first'), second = open('first');
      await Future.wait([
        first.readWorkspaceIdentity(),
        second.readWorkspaceIdentity(),
      ]);
      await first.writeDraft('shared');
      final prepared = await Future.wait([
        first.preparePendingPackets(),
        second.preparePendingPackets(),
      ]);
      expect(encoded(prepared[0]), encoded(prepared[1]));
      expect(
        sql(
          'first',
          (raw) =>
              raw.select('SELECT COUNT(*) AS n FROM sync_keys').single['n'],
        ),
        1,
      );
      expect(
        sql(
          'first',
          (raw) =>
              raw.select('SELECT COUNT(*) AS n FROM sync_packets').single['n'],
        ),
        2,
      );
    },
  );

  test(
    'missing or corrupted key never silently regenerates and no secrets appear in SQLite or WAL',
    () async {
      await createV1(path('first'));
      final first = open('first');
      await first.preparePendingPackets();
      final snapshot =
          jsonDecode(
                await BackupEnvelope.open(
                  await first.createBackup(password),
                  password,
                ),
              )
              as Map;
      final encodedKey = (snapshot['syncKey'] as Map)['key'] as String;
      final rawKey = base64Decode(encodedKey);
      for (final entry in directory.listSync().whereType<File>()) {
        final bytes = await entry.readAsBytes();
        final visible = latin1.decode(bytes);
        for (final text in [
          fixtureSecret,
          'private-ssh-fixture',
          encodedKey,
          latin1.decode(rawKey),
        ]) {
          expect(visible, isNot(contains(text)));
        }
      }
      sql(
        'first',
        (raw) => raw.execute('UPDATE sync_keys SET payload=zeroblob(80)'),
      );
      final corrupt = state('first');
      await expectLater(
        first.preparePendingPackets(),
        throwsA(isA<SyncPacketFailure>()),
      );
      expect(state('first'), corrupt);
      await first.close();
      final reopened = open('first');
      await expectLater(
        reopened.readWorkspaceIdentity(),
        throwsA(isA<SyncPacketFailure>()),
      );
      sql('first', (raw) => raw.execute('DELETE FROM sync_keys'));
      final missing = state('first');
      await expectLater(
        reopened.readWorkspaceIdentity(),
        throwsA(isA<SyncPacketFailure>()),
      );
      expect(state('first'), missing);
    },
  );

  test(
    'corrupt cached ciphertext is rejected instead of regenerated or acknowledged; backup also refuses it',
    () async {
      final first = open('first');
      final packet = (await first.preparePendingPackets()).single;
      final broken = Uint8List.fromList(packet.bytes)..[syncHeaderBytes] ^= 1;
      sql(
        'first',
        (raw) => raw.execute('UPDATE sync_packets SET payload=?', [broken]),
      );
      final before = state('first');
      await expectLater(
        first.preparePendingPackets(),
        throwsA(isA<SyncPacketFailure>()),
      );
      await expectLater(
        first.createBackup(password),
        throwsA(isA<BackupFailure>()),
      );
      expect(state('first'), before);
    },
  );

  test(
    'backup v1 restores with a new sync key; v2 corruption is rejected before replacement',
    () async {
      final first = open('first');
      await first.writeDraft('legacy-content');
      await first.preparePendingPackets();
      final data =
          jsonDecode(
                await BackupEnvelope.open(
                  await first.createBackup(password),
                  password,
                ),
              )
              as Map<String, dynamic>;
      final legacy = Map<String, dynamic>.from(data)
        ..['version'] = 1
        ..remove('syncKey')
        ..remove('syncPackets')
        ..remove('incoming')
        ..remove('heads');
      final second = open('second', 42);
      final bytes = await BackupEnvelope.seal(jsonEncode(legacy), password);
      await second.restoreBackup(await second.prepareRestore(bytes, password));
      await second.close();
      final restored = open('second', 42);
      expect(await restored.readDraft(), 'legacy-content');
      expect((await restored.preparePendingPackets()).length, 2);
      final before = state('second');
      (data['syncKey'] as Map)['key'] = base64Encode(List.filled(32, 66));
      final corrupt = await BackupEnvelope.seal(jsonEncode(data), password);
      await expectLater(
        restored.prepareRestore(corrupt, password),
        throwsA(isA<BackupFailure>()),
      );
      expect(state('second'), before);
    },
  );

  test(
    'restore insertion failure rolls back the sync key, cached packets and working data',
    () async {
      final first = open('first');
      await first.writeDraft('original');
      final packets = await first.preparePendingPackets();
      final source = open('source', 55);
      await (await source.openServer('incoming')).saveProfile(fixtureServer());
      final backup = await source.createBackup(password);
      final plan = await first.prepareRestore(backup, password),
          before = state('first');
      sql(
        'first',
        (raw) => raw.execute(
          "CREATE TRIGGER fail_restore BEFORE INSERT ON servers BEGIN SELECT RAISE(ABORT,'fixture'); END",
        ),
      );
      await expectLater(
        first.restoreBackup(plan),
        throwsA(isA<BackupFailure>()),
      );
      expect(state('first'), before);
      expect(encoded(await first.preparePendingPackets()), encoded(packets));
    },
  );

  test(
    'a new cached packet invalidates an outstanding restore preview',
    () async {
      final first = open('first');
      final backup = await first.createBackup(password);
      final plan = await first.prepareRestore(backup, password);
      await first.preparePendingPackets();
      await expectLater(
        first.restoreBackup(plan),
        throwsA(
          isA<BackupFailure>().having(
            (e) => e.issue,
            'issue',
            BackupIssue.changed,
          ),
        ),
      );
    },
  );
  void downgradeToV3() => sql('first', (raw) {
    for (final table in ['servers', 'documents']) {
      for (final action in ['insert', 'update', 'delete']) {
        raw.execute('DROP TRIGGER journal_guard_${table}_$action');
        raw.execute(
          "CREATE TRIGGER journal_guard_${table}_$action BEFORE $action ON $table WHEN (SELECT write_guard != 1 OR writer_device IS NOT device_id FROM sync_identity WHERE singleton=1) BEGIN SELECT RAISE(ABORT,'journal_writer_required'); END",
        );
      }
    }
    raw.execute('ALTER TABLE sync_identity DROP COLUMN writer_version');
    raw.execute('DROP TABLE sync_packets');
    raw.execute('DROP TABLE sync_keys');
    for (final table in [
      'sync_incoming',
      'sync_branches',
      'sync_conflicts',
      'sync_merge_meta',
    ]) {
      raw.execute('DROP TABLE $table');
    }
    raw.userVersion = 3;
  });

  test(
    'v3 migration preserves records, blocks an old writer and rolls back failed schema creation',
    () async {
      await createV1(path('first'));
      final first = open('first');
      final identity = await first.readWorkspaceIdentity();
      final records = sql(
        'first',
        (raw) => jsonEncode(raw.select('SELECT * FROM servers')),
      );
      await first.close();
      downgradeToV3();
      sql(
        'first',
        (raw) => raw.execute('CREATE TABLE sync_packets (collision TEXT)'),
      );
      final failed = open('first');
      await expectLater(failed.readWorkspaceIdentity(), throwsA(anything));
      expect(sql('first', (raw) => raw.userVersion), 3);
      expect(
        sql(
          'first',
          (raw) => raw.select(
            "SELECT name FROM sqlite_master WHERE name='sync_keys'",
          ),
        ),
        isEmpty,
      );
      sql('first', (raw) => raw.execute('DROP TABLE sync_packets'));
      expect(
        (await failed.readWorkspaceIdentity()).deviceId,
        identity.deviceId,
      );
      expect(sql('first', (raw) => raw.userVersion), 5);
      expect(
        sql('first', (raw) => jsonEncode(raw.select('SELECT * FROM servers'))),
        records,
      );
      sql('first', (raw) {
        raw.execute('BEGIN IMMEDIATE');
        try {
          raw.execute(
            'UPDATE sync_identity SET write_guard=1,writer_device=device_id',
          );
          expect(
            () => raw.execute('DELETE FROM servers'),
            throwsA(isA<SqliteException>()),
          );
        } finally {
          raw.execute('ROLLBACK');
        }
      });
      await failed.writeDraft('new writer still works');
      expect((await failed.preparePendingPackets()).isNotEmpty, isTrue);
    },
  );

  test(
    'verification on an unmigrated database cannot create keys or change its schema',
    () async {
      final source = open('source');
      final bytes = (await source.preparePendingPackets()).single.bytes;
      final target = open('first');
      final before = sql(
        'first',
        (raw) => jsonEncode(raw.select('SELECT * FROM sqlite_master')),
      );
      await expectLater(
        target.verifySyncPacket(bytes),
        throwsA(isA<SyncPacketFailure>()),
      );
      expect(
        sql(
          'first',
          (raw) => jsonEncode(raw.select('SELECT * FROM sqlite_master')),
        ),
        before,
      );
      expect(sql('first', (raw) => raw.userVersion), 1);
    },
  );

  test(
    'process exit after preparation preserves the exact packets and queue in WAL',
    () async {
      final worker = await Process.run(
        'flutter',
        ['test', '--no-pub', 'test/fixtures/sync_crash_worker.dart'],
        environment: {'ANTIRKN_SYNC_CRASH_DB': path('first')},
      );
      expect(worker.exitCode, isNot(0));
      expect(worker.stdout, contains('sync_fixture_committed_without_close'));
      final saved = sql(
        'first',
        (raw) => [
          for (final row in raw.select(
            'SELECT p.payload FROM sync_packets p JOIN sync_changes c ON c.change_id=p.change_id ORDER BY c.sequence',
          ))
            base64Encode(row['payload'] as Uint8List),
        ],
      );
      expect(saved.length, 2);
      final reopened = open('first');
      expect(encoded(await reopened.preparePendingPackets()), saved);
      expect((await reopened.readPendingChanges()).length, 2);
      expect(await reopened.readDraft(), 'public-crash-fixture');
    },
  );
}
