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
List<Object?> history(List<LocalChange> changes) => [
  for (final change in changes) [change.header.toJson(), change.source],
];

void main() {
  late Directory sourceDirectory, directory;
  late Uint8List backup;
  late WorkspaceIdentity sourceIdentity;
  late List<LocalChange> changes, pending;
  late String source;
  final stores = <WorkspaceDatabase>[];
  WorkspaceDatabase open([String name = 'destination']) {
    final store = WorkspaceDatabase.open(
      '${directory.path}/$name.sqlite',
      key: SecretKeyData(List.filled(32, 51)),
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
      changes = await db.readChanges();
      await db.acknowledgeChanges([changes.first.header.changeId]);
      pending = await db.readPendingChanges();
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
    'portable restore retains all credentials, revisions, tombstones and outbox with a new device identity',
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
      expect(plan.summary.changes, changes.length);
      expect(plan.summary.pending, pending.length);
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
      expect((await restored.readVpn()).source, fixtureVpn().encode());
      expect((await restored.readVpn()).revision, 9);
      expect(await restored.readDraft(), 'private-template-fixture');
      expect(
        await restored.readRunnerJournal(fixtureServerId),
        contains('private-runner-fixture'),
      );
      expect(history(await restored.readChanges()), history(changes));
      expect(history(await restored.readPendingChanges()), history(pending));
      expect(await restored.readLanguage(), AppLanguage.en);
      expect(await restored.readSetting('theme'), 'light');
      expect(await restored.readRestoredTargets(), {fixtureServerId});
      await restored.approveRestoredTargets([fixtureServerId]);
      expect(await restored.readRestoredTargets(), isEmpty);
      await expectLater(
        (await restored.openServer(
          'deleted-fixture',
        )).saveProfile(fixtureServer()),
        throwsA(isA<VaultFailure>()),
      );
      await restored.writeDraft('edited after restore');
      final last = (await restored.readChanges()).last;
      expect(last.header.deviceId, identity.deviceId);
      expect(last.header.sequence, changes.length + 1);
      final old = changes.singleWhere(
        (e) => e.header.entityKind == ChangeEntityKind.template,
      );
      expect(last.header.baseChangeId, old.header.changeId);
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
      final before = history(await db.readChanges());
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
      expect(history(await db.readChanges()), before);
    },
  );

  test(
    'valid encryption cannot hide an inconsistent snapshot, broken causal chain or unknown format',
    () async {
      final db = open();
      await db.writeDraft('keep');
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (data) => data['version'] = 99,
        (data) => (data['changes'] as List).removeLast(),
        (data) =>
            ((data['changes'] as List)[1]['header'] as Map)['baseChangeId'] =
                'a' * 32,
        (data) =>
            ((data['documents'] as List).first as Map)['source'] = 'modified',
        (data) => (data['outbox'] as List).add('f' * 32),
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
    'concurrent edit or acknowledgement invalidates preview; device preferences are retained',
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
      final acknowledged = await db.prepareRestore(backup, password);
      await second.acknowledgeChanges([
        (await second.readPendingChanges()).first.header.changeId,
      ]);
      await expectLater(
        db.restoreBackup(acknowledged),
        throwsA(failure(BackupIssue.changed)),
      );
      final retained = await db.prepareRestore(backup, password);
      await second.writeLanguage(AppLanguage.ru);
      await db.restoreBackup(retained);
      await db.close();
      expect(await open().readLanguage(), AppLanguage.ru);
    },
  );

  test(
    'write failure rolls back data, schema, journal, outbox and identity together',
    () async {
      final db = open();
      await db.writeDraft('keep');
      final identity = await db.readWorkspaceIdentity();
      final before = history(await db.readChanges());
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
      expect(history(await db.readPendingChanges()), before);
      expect(raw.userVersion, 4);
      expect(raw.select('PRAGMA foreign_key_check'), isEmpty);
      raw.execute('DROP TRIGGER fail_restore');
      await db.restoreBackup(await db.prepareRestore(backup, password));
      await db.close();
      expect(await open().readDraft(), 'private-template-fixture');
    },
  );

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
      expect(history(await restored.readChanges()), history(changes));
      expect(history(await restored.readPendingChanges()), history(pending));
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
