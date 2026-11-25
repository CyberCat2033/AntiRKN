import 'dart:io';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_storage/src/backup_envelope.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/journal_data.dart';

void main() {
  test('isolated database serves repositories and survives reopen', () async {
    final temp = await Directory.systemTemp.createTemp('isolated-workspace-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/workspace.sqlite';
    Future<WorkspaceDatabase> open() => WorkspaceDatabase.openIsolated(
      path,
      key: SecretKeyData(List.filled(32, 71)),
    );
    final db = await open();
    await db.inspectLegacy();
    expect(db.needsLegacyPassword, isFalse);
    await db.writeSetting('language', 'ru');
    expect(await db.readSetting('language'), 'ru');
    final change = db.localChanges.first.timeout(const Duration(seconds: 5));
    await db.writeDraft('private-template');
    await change;
    expect(await db.readDraft(), 'private-template');
    final serverId = db.newServerId();
    final server = await db.openServer(serverId);
    expect(server.profile, isNull);
    await server.saveProfile(fixtureServer());
    expect(server.profile?.host, fixtureServer().host);
    expect((await db.listServers()).single.id, serverId);
    final secondId = db.newServerId();
    await (await db.openServer(
      secondId,
    )).saveProfile(fixtureServer('second.example'));
    final stale = await db.openServer(secondId);
    await (await db.openServer(
      secondId,
    )).saveProfile(fixtureServer('new.example'));
    await expectLater(
      stale.saveProfile(fixtureServer('stale.example')),
      throwsA(isA<VaultFailure>()),
    );
    final second = (await db.listServers()).singleWhere(
      (item) => item.id == secondId,
    );
    await db.deleteServers([second]);
    expect((await db.listServers()).map((item) => item.id), [serverId]);
    final identity = await db.readWorkspaceIdentity();
    await db.writeVpnWorkspace(
      VpnWorkspace(id: identity.workspaceId),
      expectedRevision: 0,
    );
    await db.upsertVpnUser(
      VpnUser(id: 'a' * 32, login: 'alice', name: 'Alice'),
      expectedRevision: 1,
    );
    const yaml = 'private profile fixture';
    final hash = (await Sha256().hash(
      utf8.encode(yaml),
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await db.upsertVpnProfile('a' * 32, {
      'yaml': yaml,
      'hash': hash,
      'publicationWorkspaceId': identity.workspaceId,
    }, expectedRevision: 2);
    final draft = await db.readPublicationDraft('a' * 32);
    expect(draft?.bytes, utf8.encode(yaml));
    await db.checkPublicationDraft(draft!);
    expect((await db.readVpn()).revision, 3);
    expect(journalHeads(path).length, greaterThan(2));
    final bytes = await db.createBackup('isolated-backup-password');
    final plan = await db.prepareRestore(bytes, 'isolated-backup-password');
    expect(plan.summary.users, 1);
    plan.dispose();
    await db.close();
    final reopened = await open();
    addTearDown(reopened.close);
    expect(await reopened.readDraft(), 'private-template');
    expect(
      (await reopened.listServers()).single.profile.host,
      fixtureServer().host,
    );
    expect(
      VpnWorkspace.decode(
        (await reopened.readVpn()).source!,
      ).users.single.login,
      'alice',
    );
  });

  test('isolated startup retains a wrong-key failure', () async {
    final temp = await Directory.systemTemp.createTemp('isolated-key-test-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/workspace.sqlite';
    final first = await WorkspaceDatabase.openIsolated(
      path,
      key: SecretKeyData(List.filled(32, 72)),
    );
    await first.readWorkspaceIdentity();
    await first.close();
    await expectLater(
      WorkspaceDatabase.openIsolated(
        path,
        key: SecretKeyData(List.filled(32, 73)),
      ),
      throwsA(
        isA<VaultFailure>().having(
          (error) => error.issue,
          'issue',
          VaultIssue.corrupt,
        ),
      ),
    );
  });

  test('isolated backup preview restores atomically', () async {
    final temp = await Directory.systemTemp.createTemp('isolated-restore-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/workspace.sqlite';
    final db = await WorkspaceDatabase.openIsolated(
      path,
      key: SecretKeyData(List.filled(32, 74)),
    );
    await db.writeDraft('before backup');
    final backup = await db.createBackup('isolated-restore-password');
    await db.writeDraft('after backup');
    final stale = await db.prepareRestore(backup, 'isolated-restore-password');
    await db.writeDraft('newer than preview');
    await expectLater(db.restoreBackup(stale), throwsA(isA<BackupFailure>()));
    expect(await db.readDraft(), 'newer than preview');
    final fresh = await db.prepareRestore(backup, 'isolated-restore-password');
    await db.restoreBackup(fresh);
    await db.close();
    final reopened = await WorkspaceDatabase.openIsolated(
      path,
      key: SecretKeyData(List.filled(32, 74)),
    );
    addTearDown(reopened.close);
    expect(await reopened.readDraft(), 'before backup');
  });

  test(
    'backup of a database with legacy merge conflicts exports its current state',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'isolated-backup-conflict-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final path = '${temp.path}/workspace.sqlite';
      createV6Legacy(path);
      final db = await WorkspaceDatabase.openIsolated(path, key: fixtureKey());
      addTearDown(db.close);
      final bytes = await db.createBackup('isolated-backup-password');
      final content =
          jsonDecode(
                await BackupEnvelope.open(bytes, 'isolated-backup-password'),
              )
              as Map<String, dynamic>;
      expect(
        (content['documents'] as List).cast<Map>().singleWhere(
          (row) => row['id'] == 'template-draft',
        )['source'],
        'private-template-fixture',
      );
      final plan = await db.prepareRestore(bytes, 'isolated-backup-password');
      expect(plan.summary.workspaceId, legacyWorkspaceId);
      plan.dispose();
    },
  );

  test('a SQLite write lock does not block the caller event loop', () async {
    final temp = await Directory.systemTemp.createTemp('isolated-lock-test-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}/workspace.sqlite';
    final db = await WorkspaceDatabase.openIsolated(
      path,
      key: SecretKeyData(List.filled(32, 75)),
    );
    addTearDown(db.close);
    final raw = sqlite3.open(path);
    addTearDown(raw.dispose);
    raw.execute('BEGIN IMMEDIATE');
    var finished = false;
    final write = db
        .writeSetting('blocked', 'value')
        .then((_) => finished = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(finished, isFalse);
    raw.execute('ROLLBACK');
    await write;
    expect(await db.readSetting('blocked'), 'value');
  });
}
