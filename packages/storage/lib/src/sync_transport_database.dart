import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart';

/// Local-only sidecar: cursors/receipts must never travel with a workspace
/// backup. The caller supplies its local encryption key and a private path.
final class SyncTransportDatabase implements SyncTransportJournal {
  SyncTransportDatabase._(
    this._db,
    this._key,
    this.accountKey,
    this.workspaceId,
    this.deviceId,
  );

  static Future<SyncTransportDatabase> open(
    String path, {
    required SecretKeyData key,
    required String accountKey,
    required String workspaceId,
    required String deviceId,
  }) async {
    for (final value in [accountKey, workspaceId, deviceId]) {
      if (value.isEmpty || value.length > 256) {
        throw ArgumentError('transport_binding');
      }
    }
    final db = sqlite3.open(path);
    final store = SyncTransportDatabase._(
      db,
      key,
      accountKey,
      workspaceId,
      deviceId,
    );
    try {
      db.execute('PRAGMA busy_timeout=5000');
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=FULL');
      if (db.userVersion > 2) throw const FormatException();
      if (db.userVersion != 0) await store.readCursor();
      final payload = await store._encrypt('cursor', 1, {
        'start': null,
        'listing': true,
        'page': null,
        'last': null,
      });
      store._transaction(() {
        if (db.userVersion == 0) {
          db.execute(
            'CREATE TABLE transport_cursor (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, payload BLOB NOT NULL)',
          );
          db.execute(
            'CREATE TABLE transport_uploads (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload BLOB NOT NULL)',
          );
          db.execute(
            'CREATE TABLE transport_inbox (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, size INTEGER NOT NULL, payload BLOB NOT NULL)',
          );
          db.execute('INSERT INTO transport_cursor VALUES (1,1,?)', [payload]);
          db.userVersion = 1;
        }
        if (db.userVersion == 1) {
          db.execute(
            'CREATE TABLE transport_exports (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, delivered INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL)',
          );
          db.execute('CREATE TABLE transport_seen (id TEXT PRIMARY KEY)');
          db.execute(
            'CREATE TABLE transport_state (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, payload BLOB NOT NULL)',
          );
          db.userVersion = 2;
        }
      });
      // Bound AAD includes account/workspace/device, so another binding or key
      // fails before any write to an existing journal.
      await store.readCursor();
      return store;
    } catch (_) {
      db.dispose();
      key.destroy();
      throw const SyncTransportFailure(SyncTransportIssue.storage);
    }
  }

  final Database _db;
  final SecretKeyData _key;
  @override
  final String accountKey, workspaceId, deviceId;
  bool _closed = false;
  Future<void> _pending = Future.value();
  static final _cipher = AesGcm.with256bits();
  static const maxStagedBytes = 64 * 1024 * 1024;
  static const maxStagedObjects = 10000;

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _pending.then((_) async {
      if (_closed) throw const SyncTransportFailure(SyncTransportIssue.storage);
      try {
        return await action();
      } on SyncTransportFailure {
        rethrow;
      } catch (_) {
        throw const SyncTransportFailure(SyncTransportIssue.storage);
      }
    });
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  T _transaction<T>(T Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<int> _aad(String id, int revision) => utf8.encode(
    jsonEncode([
      'antirkn-drive-local-v1',
      accountKey,
      workspaceId,
      deviceId,
      id,
      revision,
    ]),
  );

  Future<Uint8List> _encrypt(
    String id,
    int revision,
    Map<String, Object?> value,
  ) async {
    final bytes = utf8.encode(jsonEncode(value));
    try {
      return (await _cipher.encrypt(
        bytes,
        secretKey: _key,
        aad: _aad(id, revision),
      )).concatenation();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<Map<String, dynamic>> _decrypt(
    String id,
    int revision,
    Uint8List payload,
  ) async {
    final bytes = await _cipher.decrypt(
      SecretBox.fromConcatenation(payload, nonceLength: 12, macLength: 16),
      secretKey: _key,
      aad: _aad(id, revision),
    );
    try {
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  @override
  Future<SyncTransportCursor> readCursor() => _serial(() async {
    final row = _db.select('SELECT * FROM transport_cursor WHERE id=1').single;
    final revision = row['revision'] as int;
    final value = await _decrypt(
      'cursor',
      revision,
      row['payload'] as Uint8List,
    );
    return SyncTransportCursor(
      revision: revision,
      startToken: value['start'] as String?,
      listing: value['listing'] as bool,
      pageToken: value['page'] as String?,
      lastDownloadAt: value['last'] == null
          ? null
          : DateTime.parse(value['last'] as String),
    );
  });

  @override
  Future<void> saveCursor(
    SyncTransportCursor cursor, {
    required int expectedRevision,
  }) => _serial(() async {
    if (cursor.startToken == null ||
        cursor.startToken!.length > 4096 ||
        (cursor.pageToken?.length ?? 0) > 4096 ||
        (!cursor.listing && cursor.pageToken != null)) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    final revision = expectedRevision + 1;
    final payload = await _encrypt('cursor', revision, {
      'start': cursor.startToken,
      'listing': cursor.listing,
      'page': cursor.pageToken,
      'last': cursor.lastDownloadAt?.toUtc().toIso8601String(),
    });
    _transaction(() {
      _db.execute(
        'UPDATE transport_cursor SET revision=?, payload=? WHERE id=1 AND revision=?',
        [revision, payload, expectedRevision],
      );
      if (_db.updatedRows != 1) {
        throw const SyncTransportFailure(SyncTransportIssue.changed);
      }
    });
  });

  Future<SyncUploadReceipt?> _readUpload(String changeId) async {
    final rows = _db.select('SELECT * FROM transport_uploads WHERE id=?', [
      changeId,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final value = await _decrypt(
      'upload:$changeId',
      row['revision'] as int,
      row['payload'] as Uint8List,
    );
    return SyncUploadReceipt(
      changeId: changeId,
      fileId: value['file'] as String,
      digest: value['digest'] as String,
      size: value['size'] as int,
      confirmed: value['confirmed'] as bool,
    );
  }

  @override
  Future<SyncUploadReceipt?> readUpload(String changeId) =>
      _serial(() => _readUpload(changeId));

  Map<String, Object?> _receipt(SyncUploadReceipt receipt, bool confirmed) => {
    'file': receipt.fileId,
    'digest': receipt.digest,
    'size': receipt.size,
    'confirmed': confirmed,
  };

  @override
  Future<SyncUploadReceipt> reserveUpload(SyncUploadReceipt receipt) =>
      _serial(() async {
        if (receipt.changeId.isEmpty ||
            receipt.changeId.length > 256 ||
            !RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(receipt.fileId) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(receipt.digest) ||
            receipt.size < 1 ||
            receipt.size > syncTransportPacketLimit ||
            receipt.confirmed) {
          throw const SyncTransportFailure(SyncTransportIssue.invalid);
        }
        final payload = await _encrypt(
          'upload:${receipt.changeId}',
          1,
          _receipt(receipt, false),
        );
        _transaction(
          () => _db.execute(
            'INSERT OR IGNORE INTO transport_uploads VALUES (?,1,?)',
            [receipt.changeId, payload],
          ),
        );
        final stored = (await _readUpload(receipt.changeId))!;
        if (stored.digest != receipt.digest || stored.size != receipt.size) {
          throw const SyncTransportFailure(SyncTransportIssue.conflict);
        }
        return stored;
      });

  @override
  Future<void> confirmUpload(SyncUploadReceipt receipt) => _serial(() async {
    final row = _db.select('SELECT * FROM transport_uploads WHERE id=?', [
      receipt.changeId,
    ]).single;
    final revision = row['revision'] as int;
    final current = await _decrypt(
      'upload:${receipt.changeId}',
      revision,
      row['payload'] as Uint8List,
    );
    if (current['file'] != receipt.fileId ||
        current['digest'] != receipt.digest ||
        current['size'] != receipt.size) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
    if (current['confirmed'] == true) return;
    final payload = await _encrypt(
      'upload:${receipt.changeId}',
      revision + 1,
      _receipt(receipt, true),
    );
    _transaction(() {
      _db.execute(
        'UPDATE transport_uploads SET revision=?,payload=? WHERE id=? AND revision=?',
        [revision + 1, payload, receipt.changeId, revision],
      );
      if (_db.updatedRows != 1) {
        throw const SyncTransportFailure(SyncTransportIssue.changed);
      }
    });
  });

  @override
  Future<void> stageObject(StagedSyncObject object) => _serial(() async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(object.fileId) ||
        object.version.isEmpty ||
        object.version.length > 256 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(object.digest) ||
        object.bytes.length > syncTransportPacketLimit ||
        (object.removed != object.bytes.isEmpty)) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    final hash = (await Sha256().hash(
      object.bytes,
    )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    if (hash != object.digest) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    final id = jsonEncode([
      object.fileId,
      object.version,
      object.digest,
      object.removed,
    ]);
    if (_db.select('SELECT 1 FROM transport_seen WHERE id=?', [
          id,
        ]).isNotEmpty ||
        _db.select('SELECT 1 FROM transport_inbox WHERE id=?', [
          id,
        ]).isNotEmpty) {
      return;
    }
    final payload = await _encrypt('inbox:$id', 1, {
      'file': object.fileId,
      'version': object.version,
      'digest': object.digest,
      'removed': object.removed,
      'bytes': base64Encode(object.bytes),
    });
    _transaction(() {
      if (_db.select('SELECT 1 FROM transport_seen WHERE id=?', [
            id,
          ]).isNotEmpty ||
          _db.select('SELECT 1 FROM transport_inbox WHERE id=?', [
            id,
          ]).isNotEmpty) {
        return;
      }
      final totals = _db
          .select(
            'SELECT COUNT(*) AS count, COALESCE(SUM(size),0) AS bytes FROM transport_inbox',
          )
          .single;
      if ((totals['count'] as int) >= maxStagedObjects ||
          (totals['bytes'] as int) + object.bytes.length > maxStagedBytes) {
        throw const SyncTransportFailure(SyncTransportIssue.limit);
      }
      _db.execute(
        'INSERT INTO transport_inbox (id,size,payload) VALUES (?,?,?)',
        [id, object.bytes.length, payload],
      );
    });
  });

  @override
  Future<List<StagedSyncObject>> readStagedObjects({
    int afterSequence = 0,
    int limit = 100,
  }) => _serial(() async {
    if (afterSequence < 0 || limit < 1 || limit > 100) {
      throw ArgumentError('transport_page');
    }
    final rows = _db.select(
      'SELECT * FROM transport_inbox WHERE sequence>? ORDER BY sequence LIMIT ?',
      [afterSequence, limit],
    );
    final result = <StagedSyncObject>[];
    var total = 0;
    for (final row in rows) {
      if (total + (row['size'] as int) > 32 * 1024 * 1024) break;
      final value = await _decrypt(
        'inbox:${row['id']}',
        1,
        row['payload'] as Uint8List,
      );
      final bytes = base64Decode(value['bytes'] as String);
      total += bytes.length;
      result.add(
        StagedSyncObject(
          fileId: value['file'] as String,
          version: value['version'] as String,
          digest: value['digest'] as String,
          removed: value['removed'] as bool,
          bytes: bytes,
          sequence: row['sequence'] as int,
        ),
      );
    }
    return List.unmodifiable(result);
  });

  Future<Set<String>> exportedIds() => _serial(
    () async => _db
        .select('SELECT id FROM transport_exports')
        .map((r) => r['id'] as String)
        .toSet(),
  );

  /// Revisit packets skipped by the older manual-pairing implementation.
  Future<void> rescanAccountPackets() => _serial(() async {
    final row = _db
        .select('SELECT revision FROM transport_cursor WHERE id=1')
        .single;
    final revision = row['revision'] as int;
    final payload = await _encrypt('cursor', revision + 1, {
      'start': null,
      'listing': true,
      'page': null,
      'last': null,
    });
    _transaction(() {
      _db.execute(
        'UPDATE transport_cursor SET revision=?,payload=? WHERE id=1 AND revision=?',
        [revision + 1, payload, revision],
      );
      if (_db.updatedRows != 1) {
        throw const SyncTransportFailure(SyncTransportIssue.changed);
      }
      _db.execute('DELETE FROM transport_seen');
    });
  });

  Future<void> enqueue(
    String changeId,
    Uint8List bytes, {
    bool delivered = false,
  }) => _serial(() async {
    if (bytes.isEmpty ||
        bytes.length > syncTransportPacketLimit ||
        changeId.isEmpty ||
        changeId.length > 256) {
      throw const SyncTransportFailure(SyncTransportIssue.invalid);
    }
    final payload = await _encrypt('export:$changeId', 1, {
      'bytes': base64Encode(bytes),
    });
    _transaction(() {
      _db.execute(
        'INSERT OR IGNORE INTO transport_exports (id,delivered,payload) VALUES (?,?,?)',
        [changeId, delivered ? 1 : 0, payload],
      );
    });
  });

  Future<List<EncryptedChangePacket>> pendingExports({
    int afterSequence = 0,
    int limit = 20,
  }) => _serial(() async {
    if (limit < 1 || limit > 100 || afterSequence < 0) {
      throw ArgumentError('export_page');
    }
    final result = <EncryptedChangePacket>[];
    var size = 0;
    for (final row in _db.select(
      'SELECT * FROM transport_exports WHERE delivered=0 AND sequence>? ORDER BY sequence LIMIT ?',
      [afterSequence, limit],
    )) {
      final value = await _decrypt(
        "export:${row['id']}",
        1,
        row['payload'] as Uint8List,
      );
      final bytes = base64Decode(value['bytes'] as String);
      if (size + bytes.length > 32 * 1024 * 1024) break;
      size += bytes.length;
      result.add(
        EncryptedChangePacket(
          changeId: row['id'] as String,
          sequence: row['sequence'] as int,
          bytes: bytes,
        ),
      );
    }
    return result;
  });

  Future<void> deliveredExports(List<String> ids) => _serial(() async {
    _transaction(() {
      for (final id in ids) {
        _db.execute('UPDATE transport_exports SET delivered=1 WHERE id=?', [
          id,
        ]);
      }
    });
  });

  Future<Map<String, dynamic>> readState() => _serial(() async {
    final rows = _db.select('SELECT * FROM transport_state');
    if (rows.isEmpty) return <String, dynamic>{};
    final row = rows.single;
    return _decrypt(
      'state',
      row['revision'] as int,
      row['payload'] as Uint8List,
    );
  });

  Future<void> saveState(Map<String, Object?> value) => _serial(() async {
    final rows = _db.select('SELECT revision FROM transport_state');
    final previous = rows.isEmpty ? 0 : rows.single['revision'] as int;
    final payload = await _encrypt('state', previous + 1, value);
    _transaction(() {
      if (previous == 0) {
        _db.execute('INSERT INTO transport_state VALUES (1,1,?)', [payload]);
      } else {
        _db.execute(
          'UPDATE transport_state SET revision=?,payload=? WHERE id=1 AND revision=?',
          [previous + 1, payload, previous],
        );
        if (_db.updatedRows != 1) {
          throw const SyncTransportFailure(SyncTransportIssue.changed);
        }
      }
    });
  });

  /// After the workspace commit. A crash before this point replays a verified
  /// immutable event; the merge store deduplicates it. Keep small seen markers
  /// so a cursor replay cannot fill the quarantine with consumed bytes again.
  Future<void> consumeObject(StagedSyncObject object) => _serial(() async {
    final id = jsonEncode([
      object.fileId,
      object.version,
      object.digest,
      object.removed,
    ]);
    _transaction(() {
      if ((_db.select('SELECT COUNT(*) AS n FROM transport_seen').single['n']
              as int) >=
          200000) {
        throw const SyncTransportFailure(SyncTransportIssue.limit);
      }
      _db.execute('INSERT OR IGNORE INTO transport_seen VALUES (?)', [id]);
      _db.execute('DELETE FROM transport_inbox WHERE id=?', [id]);
    });
  });

  Future<void> close() async {
    await _pending;
    if (_closed) return;
    _closed = true;
    _db.dispose();
    _key.destroy();
  }
}
