import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/journal_data.dart';

void main() {
  late Directory directory;
  late String path;
  final stores = <WorkspaceDatabase>[];
  WorkspaceDatabase open() {
    final db = WorkspaceDatabase.open(path, key: fixtureKey());
    stores.add(db);
    return db;
  }

  void sql(String statement) {
    final db = sqlite3.open(path);
    try {
      db.execute(statement);
    } finally {
      db.dispose();
    }
  }

  List<String> ids(List<LocalChange> changes) =>
      changes.map((e) => e.header.changeId).toList();
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('antirkn-journal-test-');
    path = '${directory.path}/workspace.sqlite';
  });
  tearDown(() async {
    for (final db in stores) {
      await db.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  for (final version in [1, 2, 3]) {
    test(
      'migrates VPN v$version without rewriting old ciphertext or identities',
      () async {
        await createV1(path, vpnVersion: version);
        final raw = sqlite3.open(path);
        final oldServer = raw.select('SELECT * FROM servers').single;
        final oldDocuments = raw.select('SELECT * FROM documents ORDER BY id');
        raw.dispose();
        final db = open();
        final identity = await db.readWorkspaceIdentity();
        expect(identity.workspaceId, fixtureWorkspaceId);
        final saved = (await db.listServers()).single;
        expect(saved.id, fixtureServerId);
        expect(saved.revision, 7);
        expect(saved.profile.secrets, fixtureServer().secrets);
        expect(saved.profile.hostKey!.fingerprint, 'SHA256:fixture-trust');
        expect((await db.readVpn()).revision, 9);
        final vpn = VpnWorkspace.decode((await db.readVpn()).source!);
        expect(vpn.id, fixtureWorkspaceId);
        expect(vpn.servers, fixtureVpn().servers);
        expect(vpn.profiles, fixtureVpn().profiles);
        expect(await db.readSetting('language'), 'ru');
        expect(await db.readSetting('theme'), 'dark');
        final changes = await db.readChanges();
        expect(
          changes.map((e) => e.header.entityKind),
          containsAll([
            ChangeEntityKind.workspace,
            ChangeEntityKind.server,
            ChangeEntityKind.template,
            ChangeEntityKind.vpnUser,
            ChangeEntityKind.vlessInbound,
            ChangeEntityKind.vpnServerState,
            ChangeEntityKind.profile,
            ChangeEntityKind.runnerState,
            if (version >= 2) ChangeEntityKind.awgInterface,
            if (version >= 3) ChangeEntityKind.ttEndpoint,
          ]),
        );
        expect(
          changes.every(
            (e) => e.header.revision == 1 && e.header.baseChangeId == null,
          ),
          isTrue,
        );
        expect(changes.map((e) => e.header.transactionId).toSet().length, 1);
        expect(
          changes.map((e) => e.header.transactionIndex),
          List.generate(changes.length, (i) => i),
        );
        expect(
          changes.every((e) => e.header.transactionSize == changes.length),
          isTrue,
        );
        await db.close();
        final after = sqlite3.open(path);
        expect(after.userVersion, 4);
        expect(after.select('SELECT * FROM servers').single, oldServer);
        expect(
          after.select('SELECT * FROM documents ORDER BY id'),
          oldDocuments,
        );
        after.dispose();
        final reopened = open();
        expect(
          (await reopened.readWorkspaceIdentity()).deviceId,
          identity.deviceId,
        );
        expect(ids(await reopened.readPendingChanges()), ids(changes));
        await reopened.writeVpn(
          vpn
              .copy(
                users: [
                  VpnUser(id: fixtureUserId, login: 'renamed', name: 'Renamed'),
                ],
              )
              .encode(),
          expectedRevision: 9,
        );
        final delta = await reopened.readChanges(
          afterSequence: changes.last.header.sequence,
        );
        expect(
          delta
              .where((e) => e.header.entityKind == ChangeEntityKind.vpnUser)
              .single
              .header
              .revision,
          2,
        );
        expect(
          delta.any(
            (e) => e.header.entityKind == ChangeEntityKind.vpnServerState,
          ),
          isFalse,
        );
        final latest = VpnWorkspace.decode((await reopened.readVpn()).source!);
        expect(latest.servers, vpn.servers);
      },
    );
  }

  test(
    'two initializers converge; independent installations have distinct identities',
    () async {
      final first = open(), second = open();
      final identity = await Future.wait([
        first.readWorkspaceIdentity(),
        second.readWorkspaceIdentity(),
      ]);
      expect(identity[0].workspaceId, identity[1].workspaceId);
      expect(identity[0].deviceId, identity[1].deviceId);
      expect((await first.readChanges()).length, 1);
      final other = WorkspaceDatabase.open(
        '${directory.path}/other.sqlite',
        key: fixtureKey(),
      );
      stores.add(other);
      expect(
        (await other.readWorkspaceIdentity()).deviceId,
        isNot(identity[0].deviceId),
      );
      expect(
        (await other.readWorkspaceIdentity()).workspaceId,
        isNot(identity[0].workspaceId),
      );
      final empty = await first.readVpn();
      expect(empty.source, isNull);
      expect(empty.workspaceId, identity[0].workspaceId);
      await first.writeVpn(
        VpnWorkspace(id: empty.workspaceId!).encode(),
        expectedRevision: 0,
      );
      await expectLater(
        first.writeVpn(VpnWorkspace.empty().encode(), expectedRevision: 1),
        throwsA(isA<VaultFailure>()),
      );
    },
  );

  test(
    'shipped v2 schema upgrades with the same identity, ciphertext and events; wrong key cannot migrate it',
    () async {
      await createV1(path);
      final original = open();
      final identity = await original.readWorkspaceIdentity();
      final events = ids(await original.readPendingChanges());
      await original.close();
      final raw = sqlite3.open(path);
      final ciphertext = raw.select('SELECT * FROM servers').single;
      try {
        // Reconstruct the shipped v2 schema; record encryption and headers are
        // unchanged across v2/v3 and come from the independent v1 fixture.
        for (final table in ['servers', 'documents']) {
          for (final action in ['insert', 'update', 'delete']) {
            raw.execute('DROP TRIGGER journal_guard_${table}_$action');
            raw.execute(
              "CREATE TRIGGER journal_guard_${table}_$action BEFORE $action ON $table WHEN (SELECT write_guard FROM sync_identity WHERE singleton=1) != 1 BEGIN SELECT RAISE(ABORT, 'journal_writer_required'); END",
            );
          }
        }
        raw.execute('ALTER TABLE sync_identity DROP COLUMN writer_device');
        raw.execute('ALTER TABLE sync_identity DROP COLUMN writer_version');
        raw.execute('DROP TABLE sync_packets');
        raw.execute('DROP TABLE sync_keys');
        raw.userVersion = 2;
        final wrong = WorkspaceDatabase.open(
          path,
          key: SecretKeyData(List.filled(32, 8)),
        );
        stores.add(wrong);
        await expectLater(
          wrong.readWorkspaceIdentity(),
          throwsA(isA<VaultFailure>()),
        );
        expect(raw.userVersion, 2);
        final migrated = open();
        expect(
          (await migrated.readWorkspaceIdentity()).deviceId,
          identity.deviceId,
        );
        expect(raw.userVersion, 4);
        expect(raw.select('SELECT * FROM servers').single, ciphertext);
        expect(ids(await migrated.readPendingChanges()), events);
        expect(
          (await migrated.listServers()).single.profile.secrets,
          fixtureServer().secrets,
        );
      } finally {
        raw.dispose();
      }
    },
  );

  test(
    'event chains, immutable history, exact acknowledgements and pending cursor survive restart',
    () async {
      final db = open();
      await db.writeDraft('first');
      final first = (await db.readChanges()).last;
      await db.writeDraft('second');
      await db.writeDraft('second');
      await db.writeRunnerJournal(fixtureServerId, 'runner-fixture');
      final changes = await db.readChanges();
      final second = changes[2];
      expect(second.header.baseChangeId, first.header.changeId);
      expect(second.header.baseRevision, first.header.revision);
      expect(changes.map((e) => e.header.sequence), [1, 2, 3, 4]);
      final page = await db.readPendingChanges(limit: 2);
      expect(ids(page), ids(changes.take(2).toList()));
      expect(
        ids(await db.readPendingChanges(afterSequence: 2)),
        ids(changes.skip(2).toList()),
      );
      await db.acknowledgeChanges([first.header.changeId]);
      await db.acknowledgeChanges([first.header.changeId]);
      await expectLater(
        db.acknowledgeChanges([second.header.changeId, 'unknown-id']),
        throwsA(isA<VaultFailure>()),
      );
      expect(
        ids(await db.readPendingChanges()),
        contains(second.header.changeId),
      );
      expect(() => sql('DELETE FROM sync_changes'), throwsA(anything));
      await db.close();
      final reopened = open();
      expect(ids(await reopened.readChanges()), ids(changes));
      expect(
        ids(await reopened.readPendingChanges()),
        ids(
          changes
              .where((e) => e.header.changeId != first.header.changeId)
              .toList(),
        ),
      );
      expect(await reopened.readDraft(), 'second');
      await reopened.writeLanguage(AppLanguage.ru);
      await reopened.writeSetting('theme', 'dark');
      expect(ids(await reopened.readChanges()), ids(changes));
    },
  );

  test(
    'deletion retains tombstone and blocks stale writers and reuse of server ID',
    () async {
      final db = open();
      final one = await db.openServer(fixtureServerId);
      await one.saveProfile(fixtureServer());
      final old = await open().openServer(fixtureServerId);
      await one.saveProfile(null);
      await one.saveProfile(null);
      final changes = await db.readChanges();
      expect(changes.last.header.deleted, isTrue);
      expect(changes.last.source, isNull);
      expect(changes.last.header.baseChangeId, changes[1].header.changeId);
      await expectLater(
        old.saveProfile(fixtureServer('old.example')),
        throwsA(isA<VaultFailure>()),
      );
      await expectLater(
        (await db.openServer(fixtureServerId)).saveProfile(fixtureServer()),
        throwsA(isA<VaultFailure>()),
      );
      await db.close();
      expect((await open().readChanges()).last.header.deleted, isTrue);
      expect(await open().listServers(), isEmpty);
    },
  );

  test(
    'VPN removal and soft resource deletion keep causal revisions and credentials',
    () async {
      final db = open();
      final initial = await db.readVpn();
      final vpn = fixtureVpn(initial.workspaceId!);
      await db.writeVpn(vpn.encode(), expectedRevision: 0);
      final old = await db.readChanges();
      final deleted = VlessInbound(
        serverId: fixtureServerId,
        spec: {...vpn.inbounds.single.spec, 'enabled': false, 'deleted': true},
      );
      await db.writeVpn(
        vpn.copy(users: [], inbounds: [deleted]).encode(),
        expectedRevision: 1,
      );
      final delta = await db.readChanges(
        afterSequence: old.last.header.sequence,
      );
      final user = delta.singleWhere(
        (e) => e.header.entityKind == ChangeEntityKind.vpnUser,
      );
      final resource = delta.singleWhere(
        (e) => e.header.entityKind == ChangeEntityKind.vlessInbound,
      );
      expect(user.header.deleted, isTrue);
      expect(user.source, isNull);
      expect(resource.header.deleted, isTrue);
      expect(jsonDecode(resource.source!)['spec']['deleted'], isTrue);
      expect(
        VpnWorkspace.decode((await db.readVpn()).source!).servers,
        vpn.servers,
      );
      await expectLater(
        db.writeVpn(vpn.encode(), expectedRevision: 1),
        throwsA(isA<VaultFailure>()),
      );
    },
  );

  test(
    'outbox failure rolls back data, all events, heads and sequence together',
    () async {
      final db = open();
      final initial = await db.readVpn();
      final before = await db.readChanges();
      sql(
        "CREATE TRIGGER reject_outbox BEFORE INSERT ON sync_outbox WHEN (SELECT count(*) FROM sync_changes)>2 BEGIN SELECT RAISE(ABORT, 'fixture_failure'); END",
      );
      await expectLater(
        db.writeVpn(
          fixtureVpn(initial.workspaceId!).encode(),
          expectedRevision: 0,
        ),
        throwsA(anything),
      );
      expect((await db.readVpn()).source, isNull);
      expect(ids(await db.readChanges()), ids(before));
      await db.close();
      sql('DROP TRIGGER reject_outbox');
      final reopened = open();
      expect(ids(await reopened.readPendingChanges()), ids(before));
      await reopened.writeVpn(
        fixtureVpn(initial.workspaceId!).encode(),
        expectedRevision: 0,
      );
      final changes = await reopened.readChanges();
      expect(
        changes.map((e) => e.header.sequence),
        List.generate(changes.length, (i) => i + 1),
      );
      expect((await reopened.readVpn()).revision, 1);
    },
  );

  test(
    'each server, template and runner write/delete rolls back when enqueue fails',
    () async {
      final db = open();
      final server = await db.openServer(fixtureServerId);
      await server.saveProfile(fixtureServer());
      await db.writeDraft('saved');
      await db.writeRunnerJournal(fixtureServerId, 'saved');
      final old = ids(await db.readChanges());
      sql(
        "CREATE TRIGGER reject_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT, 'fixture'); END",
      );
      for (final action in [
        () => server.saveProfile(fixtureServer('changed.example')),
        () => server.saveProfile(null),
        () => db.writeDraft('changed'),
        () => db.writeRunnerJournal(fixtureServerId, 'changed'),
      ]) {
        await expectLater(action(), throwsA(anything));
      }
      expect((await db.listServers()).single.profile.host, 'fixture.example');
      expect(await db.readDraft(), 'saved');
      expect(await db.readRunnerJournal(fixtureServerId), 'saved');
      expect(ids(await db.readChanges()), old);
    },
  );

  test(
    'interrupted migration leaves v1 intact and retry seeds exactly once',
    () async {
      await createV1(path);
      sql('CREATE TABLE sync_outbox (fixture INTEGER)');
      final db = open();
      await expectLater(db.readWorkspaceIdentity(), throwsA(anything));
      final raw = sqlite3.open(path);
      expect(raw.userVersion, 1);
      expect(
        raw.select("SELECT name FROM sqlite_master WHERE name='sync_identity'"),
        isEmpty,
      );
      expect(raw.select('SELECT revision FROM servers').single['revision'], 7);
      raw.dispose();
      sql('DROP TABLE sync_outbox');
      expect(
        (await db.readWorkspaceIdentity()).workspaceId,
        fixtureWorkspaceId,
      );
      final before = ids(await db.readChanges());
      expect(ids(await open().readChanges()), before);
    },
  );

  test(
    'corrupt old data fails before schema migration and wrong device key cannot write',
    () async {
      await createV1(path);
      final wrong = WorkspaceDatabase.open(
        path,
        key: SecretKeyData(List.filled(32, 8)),
      );
      stores.add(wrong);
      await expectLater(
        wrong.writeDraft('wrong'),
        throwsA(isA<VaultFailure>()),
      );
      var raw = sqlite3.open(path);
      expect(raw.userVersion, 1);
      raw.dispose();
      final db = open();
      await db.readWorkspaceIdentity();
      final other = WorkspaceDatabase.open(
        path,
        key: SecretKeyData(List.filled(32, 8)),
      );
      stores.add(other);
      await expectLater(
        other.writeDraft('wrong'),
        throwsA(isA<VaultFailure>()),
      );
      expect(await db.readDraft(), 'private-template-fixture');
      raw = sqlite3.open(path);
      expect(raw.userVersion, 4);
      raw.dispose();
    },
  );

  test(
    'concurrent writers cannot lose events; retry retains gap-free sequence',
    () async {
      final first = open(), second = open();
      await Future.wait([
        first.readWorkspaceIdentity(),
        second.readWorkspaceIdentity(),
      ]);
      final handles = [
        await first.openServer('one'),
        await second.openServer('two'),
      ];
      final outcomes = await Future.wait(
        handles.map((h) async {
          try {
            await h.saveProfile(fixtureServer());
            return true;
          } on VaultFailure catch (e) {
            expect(e.issue, VaultIssue.busy);
            return false;
          }
        }),
      );
      for (var i = 0; i < handles.length; i++) {
        if (!outcomes[i]) await handles[i].saveProfile(fixtureServer());
      }
      expect((await first.listServers()).length, 2);
      final changes = await first.readChanges();
      expect(changes.map((e) => e.header.sequence), [1, 2, 3]);
      expect(ids(changes).toSet().length, 3);
    },
  );

  test(
    'journal authenticates header/payload and never stores secret plaintext in DB or WAL',
    () async {
      await createV1(path);
      final db = open();
      final changes = await db.readChanges();
      for (final file in directory.listSync().whereType<File>()) {
        final raw = latin1.decode(await file.readAsBytes());
        for (final secret in [
          fixtureSecret,
          'private-ssh-fixture',
          'private-template-fixture',
          'private-yaml-fixture',
          'private-awg-key-fixture',
          'private-tt-password-fixture',
          'private-runner-fixture',
        ]) {
          expect(raw, isNot(contains(secret)), reason: file.path);
        }
      }
      expect(changes.toString(), isNot(contains(fixtureSecret)));
      sql('DROP TRIGGER sync_changes_immutable_update');
      sql(
        'UPDATE sync_changes SET payload=(SELECT payload FROM sync_changes WHERE sequence=1) WHERE sequence=2',
      );
      await expectLater(db.readChanges(), throwsA(isA<VaultFailure>()));
      expect(
        (await db.listServers()).single.profile.secrets[ServerSecret
            .sshPassword],
        fixtureSecret,
      );
    },
  );

  test(
    'process exit without close recovers committed WAL and the same pending event IDs',
    () async {
      final worker = await Process.run(
        'flutter',
        ['test', '--no-pub', 'test/fixtures/journal_crash_worker.dart'],
        environment: {'ANTIRKN_JOURNAL_CRASH_DB': path},
      );
      expect(worker.exitCode, isNot(0));
      expect(
        worker.stdout,
        contains('journal_fixture_committed_without_close'),
      );
      final db = open();
      expect(await db.readDraft(), 'private-crash-fixture');
      final changes = await db.readPendingChanges();
      expect(changes.map((e) => e.header.sequence), [1, 2]);
      await db.writeDraft('private-crash-fixture');
      expect(ids(await db.readPendingChanges()), ids(changes));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'an already-open v1 connection cannot bypass journaling after migration',
    () async {
      await createV1(path);
      final old = sqlite3.open(path);
      addTearDown(old.dispose);
      final db = open();
      final changes = await db.readChanges();
      expect(() => old.execute('DELETE FROM servers'), throwsA(anything));
      expect(() => old.execute('DELETE FROM documents'), throwsA(anything));
      expect((await db.listServers()).single.id, fixtureServerId);
      expect(ids(await db.readChanges()), ids(changes));
      await db.writeDraft('updated by current application');
      expect((await db.readChanges()).length, changes.length + 1);
    },
  );
}
