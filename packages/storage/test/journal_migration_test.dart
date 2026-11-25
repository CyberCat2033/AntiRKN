import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/journal_data.dart';

/// Tables of the journal removed in stage 5: nothing reads them any more.
const _legacyTables = [
  'sync_outbox',
  'sync_packets',
  'sync_keys',
  'sync_incoming',
  'sync_branches',
  'sync_conflicts',
  'sync_merge_meta',
  'sync_changes',
];

Set<String> _tables(Database raw) => raw
    .select("SELECT name FROM sqlite_master WHERE type='table'")
    .map((r) => r['name'] as String)
    .toSet();

void _guards(Database raw, String when) {
  for (final table in ['servers', 'documents']) {
    for (final action in ['insert', 'update', 'delete']) {
      raw.execute('DROP TRIGGER IF EXISTS journal_guard_${table}_$action');
      raw.execute(
        "CREATE TRIGGER journal_guard_${table}_$action BEFORE $action ON $table WHEN $when BEGIN SELECT RAISE(ABORT, 'journal_writer_required'); END",
      );
    }
  }
}

/// The v6 dump as the shipped builds of older schemas left it: v5 without the
/// client overlay, v4 without merge tables (heads still reference events),
/// v3 without packets and the sync key, v2 without the writer columns.
void _downgrade(Database raw, int version) {
  if (version <= 5) {
    for (final table in [
      'vpn_overlay_state',
      'vpn_user_overlay',
      'vpn_profile_overlay',
    ]) {
      for (final action in ['insert', 'update', 'delete']) {
        raw.execute('DROP TRIGGER journal_guard_${table}_$action');
      }
      raw.execute('DROP TABLE $table');
    }
    _guards(
      raw,
      '(SELECT write_guard != 1 OR writer_device IS NOT device_id OR writer_version != 5 FROM sync_identity WHERE singleton=1)',
    );
  }
  if (version <= 4) {
    for (final table in [
      'sync_incoming',
      'sync_branches',
      'sync_conflicts',
      'sync_merge_meta',
    ]) {
      raw.execute('DROP TABLE $table');
    }
    raw.execute(
      'CREATE TABLE sync_heads_old (entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), change_id TEXT NOT NULL REFERENCES sync_changes(change_id), deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), PRIMARY KEY(entity_kind,entity_id))',
    );
    raw.execute('INSERT INTO sync_heads_old SELECT * FROM sync_heads');
    raw.execute('DROP TABLE sync_heads');
    raw.execute('ALTER TABLE sync_heads_old RENAME TO sync_heads');
    _guards(
      raw,
      '(SELECT write_guard != 1 OR writer_device IS NOT device_id OR writer_version != 4 FROM sync_identity WHERE singleton=1)',
    );
  }
  if (version <= 3) {
    raw.execute('DROP TABLE sync_packets');
    raw.execute('DROP TABLE sync_keys');
    // Guards first: a trigger must not name a dropped column.
    _guards(
      raw,
      '(SELECT write_guard != 1 OR writer_device IS NOT device_id FROM sync_identity WHERE singleton=1)',
    );
    raw.execute('ALTER TABLE sync_identity DROP COLUMN writer_version');
  }
  if (version <= 2) {
    _guards(
      raw,
      '(SELECT write_guard FROM sync_identity WHERE singleton=1) != 1',
    );
    raw.execute('ALTER TABLE sync_identity DROP COLUMN writer_device');
  }
  raw.userVersion = version;
}

void main() {
  late Directory directory;
  late String path;
  final stores = <WorkspaceDatabase>[];
  WorkspaceDatabase open([SecretKeyData? key]) {
    final db = WorkspaceDatabase.open(path, key: key ?? fixtureKey());
    stores.add(db);
    return db;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('journal-migration-');
    path = '${directory.path}/workspace.sqlite';
    createV6Legacy(path);
  });
  tearDown(() async {
    for (final db in stores) {
      await db.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  for (final version in [6, 5, 4, 3, 2]) {
    test(
      'schema v$version with merge leftovers opens as v7: data, secrets, identity and publication heads stay',
      () async {
        var raw = sqlite3.open(path);
        _downgrade(raw, version);
        final servers = raw.select('SELECT * FROM servers');
        final documents = raw.select('SELECT * FROM documents ORDER BY id');
        final heads = raw.select('SELECT * FROM sync_heads ORDER BY 1,2');
        raw.dispose();

        final db = open();
        final identity = await db.readWorkspaceIdentity();
        expect(identity.workspaceId, legacyWorkspaceId);
        expect(identity.deviceId, legacyDeviceId);
        final server = (await db.listServers()).single;
        expect(server.id, fixtureServerId);
        expect(server.profile.secrets, fixtureServer().secrets);
        expect(await db.readDraft(), 'private-template-fixture');
        expect(
          await db.readRunnerJournal(fixtureServerId),
          contains('private-runner-fixture'),
        );
        expect(await db.readSetting('language'), 'ru');
        final vpn = VpnWorkspace.decode((await db.readVpn()).source!);
        expect(
          vpn.users.single.name,
          version == 6 ? 'Overlay rename' : 'Fixture client',
        );
        expect(
          jsonDecode(
            (await db.readPublicationDocument('result/$fixtureUserId'))!,
          )['head'],
          legacyProfileHead,
        );
        // Publication guards keep their heads across the migration.
        final draft = (await db.readPublicationDraft(fixtureUserId))!;
        expect(draft.headId, legacyProfileHead);
        expect(draft.ancestors, containsAll(legacyProfileAncestors));
        await db.checkPublicationDraft(draft);
        // A deleted server keeps its tombstone.
        await expectLater(
          (await db.openServer(
            'deleted-server-fixture',
          )).saveProfile(fixtureServer('gone.example')),
          throwsA(isA<VaultFailure>()),
        );

        raw = sqlite3.open(path);
        expect(raw.userVersion, 7);
        expect(_tables(raw).intersection(_legacyTables.toSet()), isEmpty);
        expect(raw.select('SELECT * FROM servers'), servers);
        expect(raw.select('SELECT * FROM documents ORDER BY id'), documents);
        expect(raw.select('SELECT * FROM sync_heads ORDER BY 1,2'), heads);
        raw.dispose();

        // Edits after the migration move heads; reopening changes nothing.
        await db.upsertVpnUser(
          VpnUser(id: fixtureUserId, login: 'fixture-client', name: 'Edited'),
          expectedRevision: (await db.readVpn()).revision,
        );
        await db.close();
        final again = open();
        expect(
          VpnWorkspace.decode(
            (await again.readVpn()).source!,
          ).users.single.name,
          'Edited',
        );
        expect(
          (await again.readPublicationDraft(fixtureUserId))!.headId,
          legacyProfileHead,
        );
        raw = sqlite3.open(path);
        expect(raw.userVersion, 7);
        expect(_tables(raw).intersection(_legacyTables.toSet()), isEmpty);
        raw.dispose();
      },
    );
  }

  test(
    'a migration that fails midway leaves v6 untouched; the next launch finishes it',
    () async {
      var raw = sqlite3.open(path);
      final before = [
        for (final table in [..._legacyTables, 'servers', 'documents'])
          raw.select('SELECT * FROM $table'),
      ];
      // Something the migration must create already exists: it fails late.
      raw.execute('CREATE TABLE sync_history (fixture INTEGER)');
      raw.dispose();
      await expectLater(open().readWorkspaceIdentity(), throwsA(anything));
      raw = sqlite3.open(path);
      expect(raw.userVersion, 6);
      expect(_tables(raw), containsAll(_legacyTables));
      expect([
        for (final table in [..._legacyTables, 'servers', 'documents'])
          raw.select('SELECT * FROM $table'),
      ], before);
      raw.execute('DROP TABLE sync_history');
      raw.dispose();
      final db = open();
      expect((await db.readWorkspaceIdentity()).deviceId, legacyDeviceId);
      expect((await db.listServers()).single.profile.secrets, isNotEmpty);
      raw = sqlite3.open(path);
      expect(raw.userVersion, 7);
      raw.dispose();
    },
  );

  test('a wrong device key cannot migrate the old schema', () async {
    final wrong = open(SecretKeyData(List.filled(32, 8)));
    await expectLater(
      wrong.readWorkspaceIdentity(),
      throwsA(isA<VaultFailure>()),
    );
    final raw = sqlite3.open(path);
    expect(raw.userVersion, 6);
    expect(_tables(raw), containsAll(_legacyTables));
    raw.dispose();
  });

  test(
    'an old build still open during the migration cannot write past the journal',
    () async {
      final old = sqlite3.open(path);
      addTearDown(old.dispose);
      final db = open();
      await db.readWorkspaceIdentity();
      // The v6 writer protocol: mark its transaction, then write data.
      for (final statement in [
        "INSERT INTO documents VALUES ('template-draft', x'00', 99) ON CONFLICT(id) DO UPDATE SET revision=99",
        'DELETE FROM servers',
        'DELETE FROM vpn_user_overlay',
      ]) {
        old.execute('BEGIN IMMEDIATE');
        try {
          old.execute(
            'UPDATE sync_identity SET write_guard=1, writer_device=device_id, writer_version=6',
          );
          expect(() => old.execute(statement), throwsA(anything));
        } finally {
          old.execute('ROLLBACK');
        }
      }
      expect(await db.readDraft(), 'private-template-fixture');
      expect((await db.listServers()).single.id, fixtureServerId);
    },
  );

  test(
    'a client save prepares no encrypted event: only the counter and heads move',
    () async {
      final db = open();
      await db.readWorkspaceIdentity();
      Map<String, Object?> journal() {
        final raw = sqlite3.open(path);
        try {
          return {
            for (final table in _tables(
              raw,
            ).where((name) => name.startsWith('sync_')))
              table: raw.select('SELECT * FROM $table').toString(),
          };
        } finally {
          raw.dispose();
        }
      }

      final before = journal();
      await db.upsertVpnUser(
        VpnUser(id: fixtureUserId, login: 'fixture-client', name: 'Saved'),
        expectedRevision: (await db.readVpn()).revision,
      );
      final after = journal();
      expect(after.keys.toSet(), {
        'sync_identity',
        'sync_heads',
        'sync_history',
      });
      final raw = sqlite3.open(path);
      try {
        // No journal table stores an entity source, ciphertext or not.
        for (final table in ['sync_heads', 'sync_history']) {
          expect(
            raw
                .select('PRAGMA table_info($table)')
                .map((r) => (r['type'] as String).toUpperCase()),
            everyElement(isNot('BLOB')),
          );
        }
        final user = raw.select(
          "SELECT * FROM sync_heads WHERE entity_kind='vpnUser' AND entity_id=?",
          [fixtureUserId],
        ).single;
        expect(
          raw.select('SELECT parents FROM sync_history WHERE change_id=?', [
            user['change_id'],
          ]).single['parents'],
          isNotEmpty,
        );
      } finally {
        raw.dispose();
      }
      expect(after['sync_heads'], isNot(before['sync_heads']));
    },
  );
}
