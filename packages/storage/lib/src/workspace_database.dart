import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'profile_codec.dart';
import 'secret_vault.dart';

Future<WorkspaceDatabase> openLocalWorkspace() async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/workspace');
  await directory.create(recursive: true);
  // Serialise key creation across processes, including first launch.
  final guard = await File(
    '${directory.path}/initialise.lock',
  ).open(mode: FileMode.append);
  WorkspaceDatabase? store;
  try {
    await guard.lock(FileLock.blockingExclusive);
    if (Platform.isLinux) await _chmod(directory.path, '700');
    final key = await _deviceKey(directory);
    store = WorkspaceDatabase.open(
      '${directory.path}/manager.sqlite',
      key: key,
      legacy: EncryptedSecretVault(
        files: LocalVaultFileStore(File('${support.path}/vault/v1.json')),
        keys: const PlatformVaultKeyStore(),
      ),
    );
    if (await store.readSetting('language') == null) {
      final old = await SharedPreferencesAsync().getString(
        'antirkn.language.v1',
      );
      await store.writeSetting('language', old ?? AppLanguage.system.name);
    }
    await store.inspectLegacy();
    return store;
  } catch (_) {
    await store?.close();
    rethrow;
  } finally {
    await guard.close();
  }
}

Future<void> _chmod(String path, String mode) async {
  final result = await Process.run('chmod', [mode, path]);
  if (result.exitCode != 0) throw const VaultFailure(VaultIssue.unavailable);
}

Future<SecretKeyData> _deviceKey(Directory directory) async {
  const keys = PlatformVaultKeyStore();
  const id = 'workspace-database-v1';
  final local = File('${directory.path}/device-key.json');
  String? encoded;
  if (await local.exists()) {
    // Linux without Secret Service: private OS-account file, never in SQLite.
    await _chmod(local.path, '600');
    encoded = await local.readAsString();
  } else {
    try {
      encoded = await keys.read(id);
      if (encoded == null) {
        if (await File('${directory.path}/manager.sqlite').exists()) {
          throw const VaultFailure(VaultIssue.missingKey);
        }
        encoded = base64Encode(
          await (await AesGcm.with256bits().newSecretKey()).extractBytes(),
        );
        await keys.write(id, encoded);
        if (await keys.read(id) != encoded) {
          throw const VaultFailure(VaultIssue.missingKey);
        }
      }
    } on VaultFailure {
      rethrow;
    } catch (_) {
      if (!Platform.isLinux) throw const VaultFailure(VaultIssue.unavailable);
      if (await File('${directory.path}/manager.sqlite').exists()) {
        throw const VaultFailure(VaultIssue.missingKey);
      }
      encoded = base64Encode(
        await (await AesGcm.with256bits().newSecretKey()).extractBytes(),
      );
      await local.writeAsString(encoded, flush: true);
      await _chmod(local.path, '600');
    }
  }
  final bytes = base64Decode(encoded);
  if (bytes.length != 32) throw const VaultFailure(VaultIssue.missingKey);
  return SecretKeyData(bytes, overwriteWhenDestroyed: true);
}

/// SQLite owns all current entities/preferences. Credentials and template text
/// enter SQLite only after AEAD encryption. No login or password in SQL/logs.
final class WorkspaceDatabase
    implements
        ServerRepository,
        RunnerJournalStore,
        SettingsStore,
        TemplateDraftStore,
        LanguagePreferenceStore {
  WorkspaceDatabase._(this._db, this._key, this._legacy);
  factory WorkspaceDatabase.open(
    String path, {
    required SecretKeyData key,
    SecretVault? legacy,
  }) {
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = FULL');
      final version = db.userVersion;
      if (version > 1) throw const VaultFailure(VaultIssue.corrupt);
      if (version == 0) {
        db.execute('BEGIN IMMEDIATE');
        try {
          db.execute(
            'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          db.execute(
            'CREATE TABLE servers (id TEXT PRIMARY KEY, payload BLOB NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), updated_at INTEGER NOT NULL)',
          );
          db.execute(
            'CREATE TABLE documents (id TEXT PRIMARY KEY, payload BLOB NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0))',
          );
          db.execute('CREATE TABLE migrations (id TEXT PRIMARY KEY)');
          db.userVersion = 1;
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      }
      return WorkspaceDatabase._(db, key, legacy);
    } catch (_) {
      db.dispose();
      key.destroy();
      rethrow;
    }
  }
  final Database _db;
  final SecretKeyData _key;
  final SecretVault? _legacy;
  static final _cipher = AesGcm.with256bits();
  Future<void> _pending = Future.value();
  bool _closed = false;
  @override
  bool needsLegacyPassword = false;

  Future<T> _serial<T>(FutureOr<T> Function() action) {
    final next = _pending.then((_) {
      if (_closed) throw const VaultFailure(VaultIssue.unavailable);
      return action();
    });
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  T _transaction<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<Uint8List> _encrypt(String scope, int revision, String text) async {
    final plain = utf8.encode(text);
    try {
      return (await _cipher.encrypt(
        plain,
        secretKey: _key,
        aad: utf8.encode('antirkn:1:$scope:$revision'),
      )).concatenation();
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  Future<String> _decrypt(String scope, int revision, List<int> payload) async {
    try {
      final plain = await _cipher.decrypt(
        SecretBox.fromConcatenation(payload, nonceLength: 12, macLength: 16),
        secretKey: _key,
        aad: utf8.encode('antirkn:1:$scope:$revision'),
      );
      try {
        return utf8.decode(plain);
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
    } catch (_) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
  }

  @override
  String newServerId() =>
      base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256)));

  Future<SavedServer> _decode(Row row) async => SavedServer(
    row['id'] as String,
    decodeProfile(
      jsonDecode(
            await _decrypt(
              'server:${row['id']}',
              row['revision'] as int,
              row['payload'] as Uint8List,
            ),
          )
          as Map<String, Object?>,
    ),
    row['revision'] as int,
  );

  @override
  Future<List<SavedServer>> listServers() => _serial(() async {
    final records = <SavedServer>[];
    for (final row in _db.select(
      'SELECT * FROM servers ORDER BY updated_at, id',
    )) {
      records.add(await _decode(row));
    }
    return records;
  });

  @override
  Future<SecretVault> openServer(String id) => _serial(() async {
    final rows = _db.select('SELECT * FROM servers WHERE id = ?', [id]);
    return _ServerStore(
      this,
      id,
      rows.isEmpty ? null : await _decode(rows.single),
    );
  });

  Future<SavedServer?> _save(
    String id,
    SshProfile? profile,
    int expected,
  ) => _serial(() async {
    if (profile != null && !profile.valid) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
    final revision = expected + 1;
    final payload = profile == null
        ? null
        : await _encrypt(
            'server:$id',
            revision,
            jsonEncode({...encodeProfile(profile), 'id': id}),
          );
    return _transaction(() {
      final rows = _db.select('SELECT revision FROM servers WHERE id = ?', [
        id,
      ]);
      final current = rows.isEmpty ? 0 : rows.single['revision'] as int;
      if (current != expected) throw const VaultFailure(VaultIssue.busy);
      if (profile == null) {
        _db.execute('DELETE FROM servers WHERE id = ?', [id]);
        return null;
      }
      _db.execute(
        'INSERT INTO servers VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, revision=excluded.revision, updated_at=excluded.updated_at',
        [id, payload, revision, DateTime.now().millisecondsSinceEpoch],
      );
      return SavedServer(id, profile, revision);
    });
  });

  @override
  Future<String?> readSetting(String key) => _serial(() {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.single['value'] as String;
  });
  @override
  Future<void> writeSetting(String key, String value) => _serial(() {
    _db.execute(
      'INSERT INTO settings VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [key, value],
    );
  });
  @override
  Future<AppLanguage> readLanguage() async {
    final value = await readSetting('language');
    return AppLanguage.values.where((e) => e.name == value).firstOrNull ??
        AppLanguage.system;
  }

  @override
  Future<void> writeLanguage(AppLanguage language) =>
      writeSetting('language', language.name);

  @override
  Future<String?> readDraft() => _readDocument('template-draft');
  @override
  Future<void> writeDraft(String source) =>
      _writeDocument('template-draft', source);
  @override
  Future<String?> readRunnerJournal(String serverId) =>
      _readDocument('runner/$serverId');
  @override
  Future<void> writeRunnerJournal(String serverId, String source) =>
      _writeDocument('runner/$serverId', source);

  Future<String?> _readDocument(String id) => _serial(() async {
    final rows = _db.select('SELECT * FROM documents WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    return _decrypt(
      id,
      rows.single['revision'] as int,
      rows.single['payload'] as Uint8List,
    );
  });
  Future<void> _writeDocument(String id, String source) => _serial(() async {
    if (utf8.encode(source).length > 256 * 1024) {
      throw const VaultFailure(VaultIssue.writeFailed);
    }
    final rows = _db.select('SELECT revision FROM documents WHERE id=?', [id]);
    final expected = rows.isEmpty ? 0 : rows.single['revision'] as int;
    final revision = expected + 1;
    final payload = await _encrypt(id, revision, source);
    _transaction(() {
      final current = _db.select('SELECT revision FROM documents WHERE id=?', [
        id,
      ]);
      if ((current.isEmpty ? 0 : current.single['revision']) != expected) {
        throw const VaultFailure(VaultIssue.busy);
      }
      _db.execute(
        'INSERT INTO documents VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, revision=excluded.revision',
        [id, payload, revision],
      );
    });
  });

  Future<void> inspectLegacy() async {
    if (_db
        .select("SELECT id FROM migrations WHERE id = 'legacy-vault-v1'")
        .isNotEmpty) {
      return;
    }
    try {
      needsLegacyPassword =
          await _legacy?.inspect() == VaultMode.masterPassword;
    } catch (_) {
      return;
    } // Catalog offers retry while new data remains usable.
    // Migration errors stay actionable in the catalog; never replace old data.
    if (!needsLegacyPassword) {
      try {
        await migrateLegacy();
      } catch (_) {
        /* retried in catalog */
      }
    }
  }

  @override
  Future<void> migrateLegacy({String? password}) => _serial(() async {
    if (_db
        .select("SELECT id FROM migrations WHERE id = 'legacy-vault-v1'")
        .isNotEmpty) {
      needsLegacyPassword = false;
      return;
    }
    final legacy = _legacy;
    SshProfile? profile;
    try {
      if (legacy != null && await legacy.inspect() != null) {
        await legacy.unlock(password: password);
        profile = legacy.profile;
      }
      final id = newServerId();
      final payload = profile == null
          ? null
          : await _encrypt(
              'server:$id',
              1,
              jsonEncode({...encodeProfile(profile), 'id': id}),
            );
      _transaction(() {
        if (_db
            .select("SELECT id FROM migrations WHERE id = 'legacy-vault-v1'")
            .isNotEmpty) {
          return;
        }
        if (payload != null) {
          _db.execute('INSERT INTO servers VALUES (?, ?, 1, ?)', [
            id,
            payload,
            DateTime.now().millisecondsSinceEpoch,
          ]);
        }
        _db.execute("INSERT INTO migrations VALUES ('legacy-vault-v1')");
      });
      needsLegacyPassword = false;
    } finally {
      legacy?.lock();
    }
  });

  Future<void> close() async {
    await _pending;
    if (_closed) return;
    _closed = true;
    _db.dispose();
    _key.destroy();
  }
}

/// Session adapter: transparent storage, one stable server ID per SSH editor.
/// Legacy unlock/create methods remain only for the existing SSH contract.
final class _ServerStore implements SecretVault {
  _ServerStore(this.database, this.id, this.record);
  final WorkspaceDatabase database;
  final String id;
  SavedServer? record;
  bool _unlocked = true;
  @override
  bool get isUnlocked => _unlocked;
  @override
  SshProfile? get profile => record?.profile;
  @override
  Future<VaultMode?> inspect() async => VaultMode.system;
  @override
  Future<void> create(VaultMode mode, {String? password}) async {
    _unlocked = true;
  }

  @override
  Future<void> unlock({String? password}) async {
    _unlocked = true;
  }

  @override
  Future<void> saveProfile(SshProfile? profile) async {
    if (!_unlocked) throw const VaultFailure(VaultIssue.locked);
    record = await database._save(id, profile, record?.revision ?? 0);
  }

  @override
  void lock() {
    _unlocked = false;
  }
}
