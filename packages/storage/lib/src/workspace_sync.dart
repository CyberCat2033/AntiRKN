part of 'workspace_database.dart';

// Key material is wrapped by the installation's existing AES-GCM record
// protection. It never enters the entity journal or device-local preferences.
final class _SyncKey {
  _SyncKey(this.version, this.secret);
  final int version;
  final SecretKeyData secret;
  void dispose() => secret.destroy();
  @override
  String toString() => 'SyncKey(<redacted>)';
}

_SyncKey _decodeSyncKey(Object? input) {
  try {
    final value = input as Map;
    if (value.length != 3 ||
        value['version'] != 1 ||
        value['keyVersion'] is! int ||
        (value['keyVersion'] as int) < 1 ||
        (value['keyVersion'] as int) > 0x7fffffff) {
      throw const FormatException();
    }
    final encoded = value['key'] as String;
    final bytes = base64Decode(encoded);
    try {
      if (bytes.length != syncKeyBytes || base64Encode(bytes) != encoded) {
        throw const FormatException();
      }
      return _SyncKey(
        value['keyVersion'] as int,
        SecretKeyData(Uint8List.fromList(bytes), overwriteWhenDestroyed: true),
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  } catch (_) {
    throw const SyncPacketFailure(SyncPacketIssue.invalid);
  }
}

Future<Map<String, Object?>> _newSyncKey() async {
  final key = await Xchacha20.poly1305Aead().newSecretKey();
  try {
    return {
      'version': 1,
      'keyVersion': 1,
      'key': base64Encode(await key.extractBytes()),
    };
  } finally {
    key.destroy();
  }
}

final class _WorkspaceSync {
  _WorkspaceSync(this.store);
  final WorkspaceDatabase store;
  Database get db => store._db;
  String get workspaceId => store._journal.identity.workspaceId;
  bool _ready = false;

  static String keyScope(String workspaceId) =>
      'workspace-sync-key:$workspaceId';

  static void installSchema(Database db) {
    db.execute(
      'CREATE TABLE sync_keys (singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload BLOB NOT NULL)',
    );
    db.execute(
      'CREATE TABLE sync_packets (change_id TEXT PRIMARY KEY REFERENCES sync_changes(change_id), payload BLOB NOT NULL)',
    );
    db.execute(
      'ALTER TABLE sync_identity ADD COLUMN writer_version INTEGER NOT NULL DEFAULT 0',
    );
    for (final table in ['servers', 'documents']) {
      for (final action in ['insert', 'update', 'delete']) {
        db.execute('DROP TRIGGER journal_guard_${table}_$action');
        db.execute(
          "CREATE TRIGGER journal_guard_${table}_$action BEFORE $action ON $table WHEN (SELECT write_guard != 1 OR writer_device IS NOT device_id OR writer_version != 4 FROM sync_identity WHERE singleton=1) BEGIN SELECT RAISE(ABORT, 'journal_writer_required'); END",
        );
      }
    }
  }

  Future<void> initialize() async {
    if (_ready) return;
    if (db.userVersion == 3) {
      final payload = await store._encrypt(
        keyScope(workspaceId),
        1,
        canonicalJson(await _newSyncKey()),
      );
      db.execute('BEGIN IMMEDIATE');
      try {
        store._journal.checkIdentity();
        if (db.userVersion == 3) {
          installSchema(db);
          db.execute('INSERT INTO sync_keys VALUES (1,?)', [payload]);
          db.userVersion = 4;
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (db.userVersion != 4) throw const VaultFailure(VaultIssue.corrupt);
    final key = await readKey();
    key.dispose();
    _ready = true;
  }

  Future<_SyncKey> readKey() async {
    try {
      final row = db
          .select('SELECT payload FROM sync_keys WHERE singleton=1')
          .single;
      return _decodeSyncKey(
        jsonDecode(
          await store._decrypt(
            keyScope(workspaceId),
            1,
            row['payload'] as Uint8List,
          ),
        ),
      );
    } catch (_) {
      throw const SyncPacketFailure(SyncPacketIssue.storage);
    }
  }

  Future<LocalChange> verify(Uint8List bytes) async {
    final key = await readKey();
    try {
      return await _openPacketInBackground(
        workspaceId,
        key.version,
        Uint8List.fromList(await key.secret.extractBytes()),
        bytes,
      );
    } finally {
      key.dispose();
    }
  }

  Future<List<EncryptedChangePacket>> prepare(
    int afterSequence,
    int limit,
  ) async {
    if (afterSequence < 0 || limit < 1 || limit > 100) {
      throw ArgumentError('sync_page');
    }
    final key = await readKey();
    try {
      final prepared = <(LocalChange, Uint8List)>[];
      var cursor = afterSequence, total = 0;
      for (var i = 0; i < limit; i++) {
        final changes = await store._journal.read(
          pending: true,
          afterSequence: cursor,
          limit: 1,
        );
        if (changes.isEmpty) break;
        final change = changes.single;
        final cached = db.select(
          'SELECT payload FROM sync_packets WHERE change_id=?',
          [change.header.changeId],
        );
        final bytes = cached.isEmpty
            ? await _sealPacketInBackground(
                workspaceId,
                key.version,
                Uint8List.fromList(await key.secret.extractBytes()),
                change,
              )
            : Uint8List.fromList(cached.single['payload'] as Uint8List);
        if (total + bytes.length > 32 * 1024 * 1024) break;
        await _checkCached(key, change, bytes);
        total += bytes.length;
        prepared.add((change, bytes));
        cursor = change.header.sequence;
      }
      final result = store._transaction(() {
        final packets = <EncryptedChangePacket>[];
        for (final (change, bytes) in prepared) {
          final id = change.header.changeId;
          // Another writer may have acknowledged this event while encrypting.
          if (db.select('SELECT 1 FROM sync_outbox WHERE change_id=?', [
            id,
          ]).isEmpty) {
            continue;
          }
          db.execute('INSERT OR IGNORE INTO sync_packets VALUES (?,?)', [
            id,
            bytes,
          ]);
          packets.add(
            EncryptedChangePacket(
              changeId: id,
              sequence: change.header.sequence,
              bytes:
                  db.select(
                        'SELECT payload FROM sync_packets WHERE change_id=?',
                        [id],
                      ).single['payload']
                      as Uint8List,
            ),
          );
        }
        return List<EncryptedChangePacket>.unmodifiable(packets);
      });
      // A concurrent preparer wins by stored bytes. Validate those bytes too.
      final byId = {
        for (final entry in prepared) entry.$1.header.changeId: entry.$1,
      };
      for (final packet in result) {
        await _checkCached(key, byId[packet.changeId]!, packet.bytes);
      }
      return result;
    } finally {
      key.dispose();
    }
  }

  Future<void> _checkCached(
    _SyncKey key,
    LocalChange expected,
    Uint8List bytes,
  ) async {
    final actual = await _openPacketInBackground(
      workspaceId,
      key.version,
      Uint8List.fromList(await key.secret.extractBytes()),
      bytes,
    );
    if (canonicalJson(actual.header.toJson()) !=
            canonicalJson(expected.header.toJson()) ||
        actual.source != expected.source) {
      throw const SyncPacketFailure(SyncPacketIssue.invalid);
    }
  }
}

// Top-level helpers cannot capture a database/native handle in isolate closures.
Future<Uint8List> _sealPacketInBackground(
  String workspaceId,
  int version,
  Uint8List bytes,
  LocalChange change,
) async {
  try {
    return await Isolate.run(() async {
      final key = SecretKeyData(bytes, overwriteWhenDestroyed: true);
      try {
        return await SyncPacketCodec(
          workspaceId: workspaceId,
          keyVersion: version,
          key: key,
        ).seal(change);
      } finally {
        key.destroy();
      }
    });
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

Future<LocalChange> _openPacketInBackground(
  String workspaceId,
  int version,
  Uint8List bytes,
  Uint8List packet,
) async {
  try {
    return await Isolate.run(() async {
      final key = SecretKeyData(bytes, overwriteWhenDestroyed: true);
      try {
        return await SyncPacketCodec(
          workspaceId: workspaceId,
          keyVersion: version,
          key: key,
        ).open(packet);
      } finally {
        key.destroy();
      }
    });
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}
