import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_storage/src/backup_envelope.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/journal_data.dart';

const password = 'portable-backup-test-password';
Matcher failure(BackupIssue value) =>
    isA<BackupFailure>().having((e) => e.issue, 'issue', value);

/// The whole local journal at [path]: identity, heads and history.
String journal(String path) {
  final db = sqlite3.open(path);
  try {
    return [
      db.select('SELECT * FROM sync_identity'),
      db.select('SELECT * FROM sync_heads ORDER BY 1,2'),
      db.select('SELECT * FROM sync_history ORDER BY 1'),
    ].toString();
  } finally {
    db.dispose();
  }
}

void main() {
  late Directory sourceDirectory, directory;
  late Uint8List backup;
  late WorkspaceIdentity sourceIdentity;
  late int sourceHeads;
  late String source;
  final stores = <WorkspaceDatabase>[];
  WorkspaceDatabase open([String name = 'destination']) {
    final store = WorkspaceDatabase.open(
      '${directory.path}/$name.sqlite',
      key: SecretKeyData(List.filled(32, 51)),
      offloadVpnWrites: true,
    );
    stores.add(store);
    return store;
  }

  setUpAll(() async {
    sourceDirectory = await Directory.systemTemp.createTemp(
      'backup-source-fixture-',
    );
    final path = '${sourceDirectory.path}/source.sqlite';
    await createV1(path);
    final db = WorkspaceDatabase.open(path, key: fixtureKey());
    try {
      sourceIdentity = await db.readWorkspaceIdentity();
      final removed = await db.openServer('deleted-fixture');
      await removed.saveProfile(fixtureServer());
      await removed.saveProfile(null);
      sourceHeads = journalHeads(path).length;
      backup = await db.createBackup(password);
      source = await BackupEnvelope.open(backup, password);
    } finally {
      await db.close();
    }
  });
  tearDownAll(() async => sourceDirectory.delete(recursive: true));
  setUp(
    () async => directory = await Directory.systemTemp.createTemp(
      'backup-destination-fixture-',
    ),
  );
  tearDown(() async {
    for (final store in stores) {
      await store.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  test(
    'portable restore retains current credentials and revisions with a new device identity',
    () async {
      final db = open();
      final original = await db.readWorkspaceIdentity();
      await (await db.openServer(
        'replaced',
      )).saveProfile(fixtureServer('old.example'));
      await db.writeLanguage(AppLanguage.en);
      await db.writeSetting('theme', 'light');
      final plan = await db.prepareRestore(backup, password);
      expect(plan.summary.servers, 1);
      expect(plan.summary.users, 1);
      expect(plan.toString(), isNot(contains(fixtureSecret)));
      await db.restoreBackup(plan);
      await expectLater(
        db.writeDraft('stale controller'),
        throwsA(isA<VaultFailure>()),
      );
      await db.close();
      final restored = open();
      final identity = await restored.readWorkspaceIdentity();
      expect(identity.workspaceId, sourceIdentity.workspaceId);
      expect(identity.deviceId, isNot(sourceIdentity.deviceId));
      expect(identity.deviceId, isNot(original.deviceId));
      final server = (await restored.listServers()).single;
      expect(server.id, fixtureServerId);
      expect(server.revision, 7);
      expect(server.profile.secrets, fixtureServer().secrets);
      expect(server.profile.hostKey!.fingerprint, 'SHA256:fixture-trust');
      expect((await restored.readVpn()).source, fixtureCurrentVpnSource());
      expect((await restored.readVpn()).revision, 9);
      expect(await restored.readDraft(), 'private-template-fixture');
      expect(
        await restored.readRunnerJournal(fixtureServerId),
        contains('private-runner-fixture'),
      );
      expect(
        journalHeads('${directory.path}/destination.sqlite').length,
        lessThan(sourceHeads),
      );
      expect(source, isNot(contains('"changes"')));
      expect(source, isNot(contains('"outbox"')));
      expect(source, isNot(contains('"incoming"')));
      expect(source, isNot(contains('"syncPackets"')));
      expect(source, isNot(contains('private-old-yaml-fixture')));
      expect(await restored.readLanguage(), AppLanguage.en);
      expect(await restored.readSetting('theme'), 'light');
      expect(await restored.readRestoredTargets(), {fixtureServerId});
      await restored.approveRestoredTargets([fixtureServerId]);
      expect(await restored.readRestoredTargets(), isEmpty);
      await (await restored.openServer(
        'deleted-fixture',
      )).saveProfile(fixtureServer());
      final beforeEdit = journalHeads('${directory.path}/destination.sqlite');
      await restored.writeDraft('edited after restore');
      expect(
        movedHeads(
          beforeEdit,
          journalHeads('${directory.path}/destination.sqlite'),
        ),
        {'template:default'},
      );
      // A restored copy can itself be backed up and read without either old key.
      final next = await restored.createBackup(password);
      final second = open('second');
      await second.restoreBackup(await second.prepareRestore(next, password));
      await second.close();
      expect(await open('second').readDraft(), 'edited after restore');
    },
  );

  test(
    'wrong password, truncated file, header and ciphertext tampering leave existing data intact',
    () async {
      final db = open();
      await db.writeDraft('keep this');
      final before = journal('${directory.path}/destination.sqlite');
      await expectLater(
        db.prepareRestore(backup, 'incorrect-password'),
        throwsA(failure(BackupIssue.invalid)),
      );
      for (final offset in [0, 9, 25, backup.length - 1]) {
        final damaged = Uint8List.fromList(backup)..[offset] ^= 1;
        await expectLater(
          db.prepareRestore(damaged, password),
          throwsA(failure(BackupIssue.invalid)),
        );
      }
      await expectLater(
        db.prepareRestore(
          Uint8List.fromList(backup.take(40).toList()),
          password,
        ),
        throwsA(failure(BackupIssue.invalid)),
      );
      final future = Uint8List.fromList(backup)..[8] = 2;
      await expectLater(
        db.prepareRestore(future, password),
        throwsA(failure(BackupIssue.version)),
      );
      expect(await db.readDraft(), 'keep this');
      expect(journal('${directory.path}/destination.sqlite'), before);
    },
  );

  test(
    'valid encryption cannot hide invalid current records or unknown format',
    () async {
      final db = open();
      await db.writeDraft('keep');
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (data) => data['version'] = 99,
        (data) =>
            (data['servers'] as List).add((data['servers'] as List).first),
        (data) => (data['documents'] as List).first['revision'] = 0,
        (data) =>
            ((data['documents'] as List).first as Map)['source'] = 'modified',
        (data) => data['outbox'] = <String>['f' * 32],
      ]) {
        final data = jsonDecode(source) as Map<String, dynamic>;
        mutate(data);
        final encoded = await BackupEnvelope.seal(jsonEncode(data), password);
        await expectLater(
          db.prepareRestore(encoded, password),
          throwsA(isA<BackupFailure>()),
        );
      }
      expect(await db.readDraft(), 'keep');
    },
  );

  test(
    'concurrent edit invalidates preview; device preferences are retained',
    () async {
      final db = open(), second = open();
      await db.writeDraft('before');
      final plan = await db.prepareRestore(backup, password);
      await second.writeDraft('concurrent');
      await expectLater(
        db.restoreBackup(plan),
        throwsA(failure(BackupIssue.changed)),
      );
      expect(await db.readDraft(), 'concurrent');
      final retained = await db.prepareRestore(backup, password);
      await second.writeLanguage(AppLanguage.ru);
      await db.restoreBackup(retained);
      await db.close();
      expect(await open().readLanguage(), AppLanguage.ru);
    },
  );

  test('write failure rolls back data, journal and identity together', () async {
    final db = open();
    await db.writeDraft('keep');
    final identity = await db.readWorkspaceIdentity();
    final before = journal('${directory.path}/destination.sqlite');
    final raw = sqlite3.open('${directory.path}/destination.sqlite');
    addTearDown(raw.dispose);
    raw.execute(
      "CREATE TRIGGER fail_restore BEFORE INSERT ON servers BEGIN SELECT RAISE(ABORT, 'fixture'); END",
    );
    await expectLater(
      db.restoreBackup(await db.prepareRestore(backup, password)),
      throwsA(failure(BackupIssue.storage)),
    );
    expect(await db.readDraft(), 'keep');
    expect((await db.readWorkspaceIdentity()).deviceId, identity.deviceId);
    expect(journal('${directory.path}/destination.sqlite'), before);
    expect(raw.userVersion, 7);
    expect(raw.select('PRAGMA foreign_key_check'), isEmpty);
    raw.execute('DROP TRIGGER fail_restore');
    await db.restoreBackup(await db.prepareRestore(backup, password));
    await db.close();
    expect(await open().readDraft(), 'private-template-fixture');
  });

  test(
    'other open editors and a shipped v2 writer cannot write after restore',
    () async {
      final db = open(), stale = open();
      await stale.readWorkspaceIdentity();
      final editor = await stale.openServer(fixtureServerId);
      await db.restoreBackup(await db.prepareRestore(backup, password));
      await expectLater(
        editor.saveProfile(fixtureServer('stale.example')),
        throwsA(isA<VaultFailure>()),
      );
      await expectLater(
        stale.writeDraft('stale'),
        throwsA(isA<VaultFailure>()),
      );
      await expectLater(
        stale.writeLanguage(AppLanguage.ru),
        throwsA(isA<VaultFailure>()),
      );
      final raw = sqlite3.open('${directory.path}/destination.sqlite');
      try {
        raw.execute('BEGIN IMMEDIATE');
        raw.execute('UPDATE sync_identity SET write_guard=1 WHERE singleton=1');
        expect(
          () => raw.execute('DELETE FROM documents'),
          throwsA(isA<SqliteException>()),
        );
        raw.execute('ROLLBACK');
      } finally {
        raw.dispose();
      }
    },
  );

  test(
    'cancelled, foreign and reused plans cannot replace a workspace',
    () async {
      final db = open(), other = open('other');
      final plan = await db.prepareRestore(backup, password);
      await expectLater(
        other.restoreBackup(plan),
        throwsA(failure(BackupIssue.changed)),
      );
      plan.dispose();
      await expectLater(
        db.restoreBackup(plan),
        throwsA(failure(BackupIssue.changed)),
      );
      final applied = await db.prepareRestore(backup, password);
      await db.restoreBackup(applied);
      await expectLater(
        db.restoreBackup(applied),
        throwsA(failure(BackupIssue.changed)),
      );
    },
  );

  test(
    'archive and restored DB/WAL contain no plaintext fixture secrets; encryption is randomized',
    () async {
      final db = open();
      await db.restoreBackup(await db.prepareRestore(backup, password));
      await db.close();
      final restored = open();
      final another = await restored.createBackup(password);
      expect(another, isNot(backup));
      for (final bytes in [
        backup,
        another,
        for (final file in directory.listSync().whereType<File>())
          file.readAsBytesSync(),
      ]) {
        final raw = latin1.decode(bytes);
        for (final secret in [
          fixtureSecret,
          'private-ssh-fixture',
          'private-template-fixture',
          'private-yaml-fixture',
          'private-awg-key-fixture',
          'private-tt-password-fixture',
        ]) {
          expect(raw, isNot(contains(secret)));
        }
      }
    },
  );

  test(
    'empty workspace is portable and input limits fail before expensive decryption',
    () async {
      final db = open();
      final bytes = await db.createBackup(password);
      final other = open('empty');
      final plan = await other.prepareRestore(bytes, password);
      expect(plan.summary.servers, 0);
      expect(plan.summary.users, 0);
      await other.restoreBackup(plan);
      await expectLater(
        () => BackupEnvelope.open(
          Uint8List(maxWorkspaceBackupBytes + 1),
          password,
        ),
        throwsA(failure(BackupIssue.tooLarge)),
      );
      await expectLater(
        db.createBackup('short'),
        throwsA(failure(BackupIssue.password)),
      );
    },
  );

  test(
    'repeated edits do not grow the portable archive with history',
    () async {
      final db = open();
      for (var i = 0; i < 200; i++) {
        await db.writeDraft('current-$i');
      }
      final bytes = await db.createBackup(password);
      final source = await BackupEnvelope.open(bytes, password);
      expect(bytes.length, lessThan(4096));
      expect(source, contains('current-199'));
      expect(source, isNot(contains('current-198')));
      expect(source, isNot(contains('"changes"')));
    },
  );

  test('runner job keeps current status without old progress events', () async {
    final db = open();
    const serverId = 'runner-fixture';
    final journal = jsonEncode({
      'version': 1,
      'identity': 'fixture',
      'pending': null,
      'selected': {
        'id': '1' * 32,
        'kind': 'diagnostic',
        'status': 'succeeded',
        'checkpoint': 1,
        'count': 1,
        'interval': 1,
        'sequence': 1,
        'cancelRequested': false,
        'events': [
          {
            'sequence': 1,
            'timestamp': 1,
            'code': 'succeeded',
            'progress': 1,
            'total': 1,
          },
        ],
      },
      'cursor': 1,
    });
    await db.writeRunnerJournal(serverId, journal);
    final source = await BackupEnvelope.open(
      await db.createBackup(password),
      password,
    );
    final row = ((jsonDecode(source) as Map)['documents'] as List)
        .cast<Map>()
        .singleWhere((record) => record['id'] == 'runner/$serverId');
    final selected =
        (jsonDecode(row['source'] as String) as Map)['selected'] as Map;
    expect(selected['status'], 'succeeded');
    expect(selected['events'], isEmpty);
  });

  test(
    'restore survives a separate process exiting before SQLite close',
    () async {
      final db = open();
      await db.writeDraft('before abrupt restore');
      await db.close();
      final file = File('${directory.path}/fixture.antirkn');
      await file.writeAsBytes(backup);
      final worker = await Process.run(
        'flutter',
        ['test', '--no-pub', 'test/fixtures/backup_crash_worker.dart'],
        environment: {
          'ANTIRKN_BACKUP_CRASH_DB': '${directory.path}/destination.sqlite',
          'ANTIRKN_BACKUP_CRASH_FILE': file.path,
        },
      );
      expect(worker.exitCode, isNot(0));
      expect(worker.stdout, contains('backup_fixture_committed_without_close'));
      final restored = open();
      expect(await restored.readDraft(), 'private-template-fixture');
      expect(
        journalHeads('${directory.path}/destination.sqlite').length,
        lessThan(sourceHeads),
      );
      expect(
        (await restored.listServers()).single.profile.secrets,
        fixtureServer().secrets,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'desktop file replacement stages ciphertext and cleans up on rename failure',
    () async {
      final path = '${directory.path}/copy.antirkn';
      await writeBackupFile(path, Uint8List.fromList([1, 2, 3]));
      await writeBackupFile(path, backup);
      expect(await File(path).readAsBytes(), backup);
      final blocked = Directory('${directory.path}/directory.antirkn');
      await blocked.create();
      await expectLater(
        writeBackupFile(blocked.path, backup),
        throwsA(isA<FileSystemException>()),
      );
      expect(directory.listSync().whereType<File>().map((f) => f.path), [path]);
    },
  );
}
