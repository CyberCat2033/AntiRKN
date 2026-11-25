import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/snapshot_fixture.dart';

/// Bytes SQLite holds after a checkpoint: database pages and the WAL.
int _storedBytes(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    final pages = db.select('PRAGMA page_count').single.values.first as int;
    final size = db.select('PRAGMA page_size').single.values.first as int;
    final free = db.select('PRAGMA freelist_count').single.values.first as int;
    return (pages - free) * size;
  } finally {
    db.dispose();
  }
}

/// Bytes of journal rows written per local save (events, packets, outbox).
int _journalBytes(String path) {
  final db = sqlite3.open(path);
  try {
    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((r) => r['name'] as String)
        .where((name) => name.startsWith('sync_'))
        .toList();
    var total = 0;
    for (final table in tables) {
      final columns = db
          .select('PRAGMA table_info($table)')
          .map((r) => r['name'] as String)
          .toList();
      final sum = columns.map((c) => 'COALESCE(LENGTH("$c"),0)').join('+');
      total +=
          db.select('SELECT COALESCE(SUM($sum),0) AS n FROM $table').single['n']
              as int;
    }
    return total;
  } finally {
    db.dispose();
  }
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('save-benchmark-');
  });
  tearDown(() => directory.delete(recursive: true));

  // Synthetic: 120 clients, 3 servers with VLESS, AWG and TT, compiled YAML.
  // Prints per-save time and storage growth; the numbers go to the report.
  test(
    'client saves: time and database growth per save (synthetic 120 clients)',
    () async {
      final path = '${directory.path}/bench.sqlite';
      final db = WorkspaceDatabase.open(
        path,
        key: SecretKeyData(List.filled(32, 61)),
      );
      final data = await fillSyntheticWorkspace(db);
      const edits = 60;
      final before = _storedBytes(path), journalBefore = _journalBytes(path);

      final initial = await db.readVpn();
      final workspace = VpnWorkspace.decode(initial.source!);
      var revision = initial.revision;
      // A client renamed in its editor: the user overlay path. Like the
      // controller, the caller keeps the revision and reads nothing.
      final users = Stopwatch()..start();
      for (var i = 0; i < edits; i++) {
        final id = data.userIds[i % data.userIds.length];
        revision = await db.upsertVpnUser(
          VpnUser(id: id, login: 'client$i', name: 'Renamed $i'),
          expectedRevision: revision,
        );
      }
      users.stop();
      // A recompiled client profile: the profile overlay path.
      final profiles = Stopwatch()..start();
      for (var i = 0; i < edits; i++) {
        final id = data.userIds[i % data.userIds.length];
        final profile = Map<String, dynamic>.of(workspace.profiles[id]!);
        profile['yaml'] = '${profile['yaml']}# edit $i\n';
        revision = await db.upsertVpnProfile(
          id,
          profile,
          expectedRevision: revision,
        );
      }
      profiles.stop();
      // A server observation written with the whole workspace.
      const fullEdits = 20;
      final vpn =
          jsonDecode((await db.readVpn()).source!) as Map<String, dynamic>;
      final record =
          (vpn['servers'] as Map)[data.serverIds.first] as Map<String, dynamic>;
      final full = Stopwatch()..start();
      for (var i = 0; i < fullEdits; i++) {
        record['verifiedAt'] = DateTime.utc(
          2026,
          11,
          25,
          0,
          i,
        ).toIso8601String();
        revision = await db.writeVpn(
          jsonEncode(vpn),
          expectedRevision: revision,
        );
      }
      full.stop();
      await db.close();
      final after = _storedBytes(path), journalAfter = _journalBytes(path);
      final perUser = users.elapsedMicroseconds / edits / 1000;
      final perProfile = profiles.elapsedMicroseconds / edits / 1000;
      final perFull = full.elapsedMicroseconds / fullEdits / 1000;
      final saves = edits * 2 + fullEdits;
      // ignore: avoid_print
      print(
        'save_benchmark user_ms=${perUser.toStringAsFixed(2)} '
        'profile_ms=${perProfile.toStringAsFixed(2)} '
        'full_ms=${perFull.toStringAsFixed(2)} '
        'saves=$saves '
        'db_growth_bytes=${after - before} '
        'journal_growth_bytes=${journalAfter - journalBefore} '
        'journal_bytes_per_save=${(journalAfter - journalBefore) ~/ saves}',
      );
      expect(after, greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
