import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/journal_data.dart';

typedef _Head = ({int revision, String changeId, bool deleted});

void main() {
  late Directory directory;
  late String path;
  final stores = <WorkspaceDatabase>[];
  WorkspaceDatabase open() {
    final db = WorkspaceDatabase.open(path, key: fixtureKey());
    stores.add(db);
    return db;
  }

  T raw<T>(T Function(Database db) read) {
    final db = sqlite3.open(path);
    try {
      return read(db);
    } finally {
      db.dispose();
    }
  }

  void sql(String statement) => raw((db) => db.execute(statement));

  /// Current head of every entity: `kind:id` to its version.
  Map<String, _Head> heads() => raw(
    (db) => {
      for (final row in db.select('SELECT * FROM sync_heads'))
        '${row['entity_kind']}:${row['entity_id']}': (
          revision: row['revision'] as int,
          changeId: row['change_id'] as String,
          deleted: row['deleted'] == 1,
        ),
    },
  );
  int sequence() => raw(
    (db) =>
        db.select('SELECT sequence FROM sync_identity').single['sequence']
            as int,
  );
  List<String> parents(String changeId) => raw(
    (db) => List<String>.from(
      jsonDecode(
            db.select('SELECT parents FROM sync_history WHERE change_id=?', [
                  changeId,
                ]).single['parents']
                as String,
          )
          as List,
    ),
  );

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
        final oldServer = raw((db) => db.select('SELECT * FROM servers'));
        final oldDocuments = raw(
          (db) => db.select('SELECT * FROM documents ORDER BY id'),
        );
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
        final initial = heads();
        expect(
          initial.keys.map((key) => key.split(':').first).toSet(),
          containsAll([
            'workspace',
            'server',
            'template',
            'vpnUser',
            'vlessInbound',
            'vpnServerState',
            'profile',
            'runnerState',
            if (version >= 2) 'awgInterface',
            if (version >= 3) 'ttEndpoint',
          ]),
        );
        expect(initial.values.every((h) => h.revision == 1), isTrue);
        expect(sequence(), initial.length);
        await db.close();
        raw((after) {
          expect(after.userVersion, 7);
          expect(after.select('SELECT * FROM servers'), oldServer);
          expect(
            after.select('SELECT * FROM documents ORDER BY id'),
            oldDocuments,
          );
        });
        final reopened = open();
        expect(
          (await reopened.readWorkspaceIdentity()).deviceId,
          identity.deviceId,
        );
        expect(heads(), initial);
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
        final user = heads()['vpnUser:$fixtureUserId']!;
        expect(user.revision, 2);
        expect(parents(user.changeId), [
          initial['vpnUser:$fixtureUserId']!.changeId,
        ]);
        // The full write repairs namespaces of every server record.
        expect(
          heads()['vpnServerState:$fixtureServerId']!.revision,
          greaterThan(1),
        );
        final latest = VpnWorkspace.decode((await reopened.readVpn()).source!);
        for (final entry in vpn.servers.entries) {
          final stored = Map<String, dynamic>.from(latest.servers[entry.key]!);
          expect(stored.remove('resourceWorkspaceId'), vpn.id);
          expect(stored, entry.value);
        }
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
      expect(heads().keys, ['workspace:${identity[0].workspaceId}']);
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
    'heads advance per changed entity; settings and equal writes change nothing',
    () async {
      final db = open();
      await db.writeDraft('first');
      final first = heads()['template:default']!;
      final counter = sequence();
      await db.writeDraft('second');
      await db.writeDraft('second');
      await db.writeRunnerJournal(fixtureServerId, 'runner-fixture');
      final second = heads()['template:default']!;
      expect(second.revision, first.revision + 1);
      expect(parents(second.changeId), [first.changeId]);
      expect(heads()['runnerState:$fixtureServerId']!.revision, 1);
      expect(sequence(), counter + 2);
      await db.writeLanguage(AppLanguage.ru);
      await db.writeSetting('theme', 'dark');
      expect(sequence(), counter + 2);
      await db.close();
      final reopened = open();
      expect(await reopened.readDraft(), 'second');
      expect(heads()['template:default'], second);
    },
  );

  test(
    'deletion retains tombstone and blocks stale writers and reuse of server ID',
    () async {
      final db = open();
      final one = await db.openServer(fixtureServerId);
      await one.saveProfile(fixtureServer());
      final created = heads()['server:$fixtureServerId']!;
      final old = await open().openServer(fixtureServerId);
      await one.saveProfile(null);
      await one.saveProfile(null);
      final deleted = heads()['server:$fixtureServerId']!;
      expect(deleted.deleted, isTrue);
      expect(parents(deleted.changeId), [created.changeId]);
      await expectLater(
        old.saveProfile(fixtureServer('old.example')),
        throwsA(isA<VaultFailure>()),
      );
      await expectLater(
        (await db.openServer(fixtureServerId)).saveProfile(fixtureServer()),
        throwsA(isA<VaultFailure>()),
      );
      await db.close();
      expect(heads()['server:$fixtureServerId']!.deleted, isTrue);
      expect(await open().listServers(), isEmpty);
    },
  );

  test('batch server deletion leaves a tombstone for every server', () async {
    final db = open();
    final id = await db.readWorkspaceIdentity();
    await db.writeVpnWorkspace(
      VpnWorkspace(id: id.workspaceId),
      expectedRevision: 0,
    );
    final sid = db.newServerId();
    await (await db.openServer(sid)).saveProfile(fixtureServer('a.example'));
    await db.deleteServers(await db.listServers());
    expect(await db.listServers(), isEmpty);
    expect(heads()['server:$sid']!.deleted, isTrue);
  });

  test(
    'VPN removal and soft resource deletion keep revisions and credentials',
    () async {
      final db = open();
      final initial = await db.readVpn();
      final vpn = fixtureVpn(initial.workspaceId!);
      await db.writeVpn(vpn.encode(), expectedRevision: 0);
      final deleted = VlessInbound(
        serverId: fixtureServerId,
        spec: {...vpn.inbounds.single.spec, 'enabled': false, 'deleted': true},
      );
      await db.writeVpn(
        vpn.copy(users: [], inbounds: [deleted]).encode(),
        expectedRevision: 1,
      );
      final user = heads()['vpnUser:$fixtureUserId']!;
      final resource = heads()['vlessInbound:${'c' * 32}']!;
      expect(user.deleted, isTrue);
      expect(user.revision, 2);
      expect(resource.deleted, isTrue);
      final savedServers = VpnWorkspace.decode(
        (await db.readVpn()).source!,
      ).servers;
      for (final entry in vpn.servers.entries) {
        final stored = Map<String, dynamic>.from(savedServers[entry.key]!);
        expect(stored.remove('resourceWorkspaceId'), vpn.id);
        expect(stored, entry.value);
      }
      await expectLater(
        db.writeVpn(vpn.encode(), expectedRevision: 1),
        throwsA(isA<VaultFailure>()),
      );
      // A removed client never returns under the same id.
      await expectLater(
        db.writeVpn(
          vpn.copy(inbounds: [deleted]).encode(),
          expectedRevision: 2,
        ),
        throwsA(isA<VaultFailure>()),
      );
    },
  );

  test(
    'a failing head write rolls back data, all heads and the counter together',
    () async {
      final db = open();
      final initial = await db.readVpn();
      final before = heads(), counter = sequence();
      sql(
        "CREATE TRIGGER reject_head BEFORE INSERT ON sync_history WHEN (SELECT count(*) FROM sync_history)>2 BEGIN SELECT RAISE(ABORT, 'fixture_failure'); END",
      );
      await expectLater(
        db.writeVpn(
          fixtureVpn(initial.workspaceId!).encode(),
          expectedRevision: 0,
        ),
        throwsA(anything),
      );
      expect((await db.readVpn()).source, isNull);
      expect(heads(), before);
      expect(sequence(), counter);
      await db.close();
      sql('DROP TRIGGER reject_head');
      final reopened = open();
      await reopened.writeVpn(
        fixtureVpn(initial.workspaceId!).encode(),
        expectedRevision: 0,
      );
      expect(sequence(), heads().length);
      expect((await reopened.readVpn()).revision, 1);
    },
  );

  test(
    'each server, template and runner write/delete rolls back when the journal fails',
    () async {
      final db = open();
      final server = await db.openServer(fixtureServerId);
      await server.saveProfile(fixtureServer());
      await db.writeDraft('saved');
      await db.writeRunnerJournal(fixtureServerId, 'saved');
      final old = heads();
      sql(
        "CREATE TRIGGER reject_head BEFORE INSERT ON sync_history BEGIN SELECT RAISE(ABORT, 'fixture'); END",
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
      expect(heads(), old);
    },
  );

  test(
    'interrupted migration leaves v1 intact and retry seeds exactly once',
    () async {
      await createV1(path);
      sql('CREATE TABLE sync_history (fixture INTEGER)');
      final db = open();
      await expectLater(db.readWorkspaceIdentity(), throwsA(anything));
      raw((db) {
        expect(db.userVersion, 1);
        expect(
          db.select(
            "SELECT name FROM sqlite_master WHERE name='sync_identity'",
          ),
          isEmpty,
        );
        expect(db.select('SELECT revision FROM servers').single['revision'], 7);
      });
      sql('DROP TABLE sync_history');
      expect(
        (await db.readWorkspaceIdentity()).workspaceId,
        fixtureWorkspaceId,
      );
      final before = heads();
      await open().readWorkspaceIdentity();
      expect(heads(), before);
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
      expect(raw((db) => db.userVersion), 1);
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
      expect(raw((db) => db.userVersion), 7);
    },
  );

  test(
    'concurrent writers cannot lose heads; a retry keeps the counter exact',
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
      expect(heads().keys, containsAll(['server:one', 'server:two']));
      expect(sequence(), 3);
    },
  );

  test(
    'the journal stores no secret, neither plain nor encrypted, in DB or WAL',
    () async {
      await createV1(path);
      final db = open();
      await db.readWorkspaceIdentity();
      for (final file in directory.listSync().whereType<File>()) {
        final content = latin1.decode(await file.readAsBytes());
        for (final secret in [
          fixtureSecret,
          'private-ssh-fixture',
          'private-template-fixture',
          'private-yaml-fixture',
          'private-awg-key-fixture',
          'private-tt-password-fixture',
          'private-runner-fixture',
        ]) {
          expect(content, isNot(contains(secret)), reason: file.path);
        }
      }
      raw((db) {
        for (final table in ['sync_heads', 'sync_history']) {
          expect(
            db
                .select('PRAGMA table_info($table)')
                .map((r) => (r['type'] as String).toUpperCase()),
            everyElement(isNot('BLOB')),
          );
        }
      });
      expect(
        (await db.listServers()).single.profile.secrets[ServerSecret
            .sshPassword],
        fixtureSecret,
      );
    },
  );

  test(
    'process exit without close recovers committed WAL and the same heads',
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
      final before = heads();
      expect(before.keys, contains('template:default'));
      expect(sequence(), 2);
      await db.writeDraft('private-crash-fixture');
      expect(heads(), before);
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
      await db.readWorkspaceIdentity();
      final before = heads();
      expect(() => old.execute('DELETE FROM servers'), throwsA(anything));
      expect(() => old.execute('DELETE FROM documents'), throwsA(anything));
      expect((await db.listServers()).single.id, fixtureServerId);
      expect(heads(), before);
      await db.writeDraft('updated by current application');
      expect(heads()['template:default']!.revision, 2);
    },
  );

  test(
    'direct writes outside a journal transaction are refused by the guards',
    () async {
      final db = open();
      await db.writeDraft('initial-draft');
      final sid = db.newServerId();
      await (await db.openServer(sid)).saveProfile(fixtureServer());
      final direct = sqlite3.open(path);
      addTearDown(direct.dispose);
      final refused = throwsA(
        isA<SqliteException>().having(
          (e) => e.message,
          'message',
          contains('journal_writer_required'),
        ),
      );
      for (final statement in [
        "INSERT INTO servers VALUES ('rogue-server', X'010203', 1, 123456789)",
        "UPDATE documents SET payload=X'ffff' WHERE id='template-draft'",
        "DELETE FROM servers WHERE id='$sid'",
        "INSERT INTO vpn_user_overlay VALUES ('rogue', X'00', 1)",
      ]) {
        expect(() => direct.execute(statement), refused);
      }
    },
  );
}
