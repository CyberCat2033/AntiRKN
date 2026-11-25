import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'profile_codec.dart';
import 'backup_envelope.dart';
import 'backup_file_store.dart';
import 'secret_vault.dart';
import 'google_session_store.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';

part 'workspace_journal.dart';
part 'workspace_backup.dart';
part 'workspace_sync.dart';
part 'workspace_merge.dart';
part 'workspace_auto_sync.dart';
part 'workspace_account_sync.dart';
part 'workspace_publications.dart';
part 'vpn_write_worker.dart';
part 'workspace_vpn_overlay.dart';
part 'workspace_db_worker.dart';

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
    store = await WorkspaceDatabase.openIsolated(
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
        PublicationRepository,
        PublicationStateBatchReader,
        RunnerJournalStore,
        ConditionalRunnerJournalStore,
        VpnRepository,
        VpnWorkspaceWriter,
        VpnUserWriter,
        VpnProfileWriter,
        ChangeJournalStore,
        SyncPacketStore,
        SyncMergeStore,
        SyncEffectGuard,
        WorkspaceBackupStore,
        WorkspaceRecoveryStore,
        SettingsStore,
        TemplateDraftStore,
        LanguagePreferenceStore {
  WorkspaceDatabase._(
    Database db,
    this._key,
    this._legacy,
    this._path,
    this._offloadVpnWrites,
  ) : _db = db;

  WorkspaceDatabase._proxy(this._key, this._legacy, this._path)
    : _offloadVpnWrites = false;
  factory WorkspaceDatabase.open(
    String path, {
    required SecretKeyData key,
    SecretVault? legacy,
    bool offloadVpnWrites = false,
  }) {
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = FULL');
      final version = db.userVersion;
      if (version > 6) throw const VaultFailure(VaultIssue.corrupt);
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
      return WorkspaceDatabase._(db, key, legacy, path, offloadVpnWrites);
    } catch (_) {
      db.dispose();
      key.destroy();
      rethrow;
    }
  }
  static Future<WorkspaceDatabase> openIsolated(
    String path, {
    required SecretKeyData key,
    SecretVault? legacy,
  }) async {
    final proxy = WorkspaceDatabase._proxy(key, legacy, path);
    try {
      proxy._worker = await _DbWorkerClient.start(
        path,
        key,
        () => proxy._localChanges.add(null),
      );
      return proxy;
    } catch (_) {
      key.destroy();
      await proxy._localChanges.close();
      rethrow;
    }
  }

  final String _path;
  final bool _offloadVpnWrites;
  _DbWorkerClient? _worker;

  _DbWorkerClient? get _dbWorker => _worker;
  Future<T> _remoteCall<T>(String action, [List<Object?> args = const []]) =>
      _dbWorker!.request<T>(action, args);

  /// Uses the device key and a separate file, so restore keeps this device's
  /// login and portable backup / E2EE never contains Google OAuth credentials.
  GoogleSessionStore googleSessionStore() => EncryptedGoogleSessionStore(
    file: File('$_path.google-session'),
    key: _key,
  );
  final _localChanges = StreamController<void>.broadcast();
  Stream<void> get localChanges => _localChanges.stream;
  late final Database _db;
  final SecretKeyData _key;
  final SecretVault? _legacy;
  static final _cipher = AesGcm.with256bits();
  late final _LocalChangeJournal _journal = _LocalChangeJournal(
    _db,
    _encrypt,
    _decrypt,
  );
  Future<void> _pending = Future.value();
  late final _WorkspaceSync _sync = _WorkspaceSync(this);
  late final _WorkspaceMerge _merge = _WorkspaceMerge(this);
  late final _VpnOverlay _vpnOverlay = _VpnOverlay(this);
  bool _closed = false;
  bool _restored = false;
  bool _initialized = false;
  final _documentCache = <String, (int, String)>{};
  int? _cachedWorkspaceRevision;
  VpnWorkspace? _cachedWorkspace;
  Future<_VpnWriteWorker>? _vpnWriter;
  @override
  bool needsLegacyPassword = false;

  Future<T> _serial<T>(FutureOr<T> Function() action, {bool migrate = true}) {
    final next = _pending.then((_) async {
      if (_closed || _restored) {
        throw const VaultFailure(VaultIssue.unavailable);
      }
      // Receiving an untrusted packet must not create a workspace key or
      // migrate a database. Normal repository initialization prepares the key.
      if (!migrate && _db.userVersion != 6) {
        throw const SyncPacketFailure(SyncPacketIssue.storage);
      }
      if (!_initialized) {
        await _journal.initialize();
        await _sync.initialize();
        await _merge.initialize();
        await _vpnOverlay.initialize();
        _initialized = true;
      }
      return action();
    });
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  T _transaction<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _journal.checkIdentity();
      final sequence = _db
          .select('SELECT sequence FROM sync_identity')
          .single['sequence'];
      _db.execute(
        'UPDATE sync_identity SET write_guard=1, writer_device=?, writer_version=6 WHERE singleton=1',
        [_journal.identity.deviceId],
      );
      final result = body();
      _db.execute(
        'UPDATE sync_identity SET write_guard=0, writer_device=NULL, writer_version=0 WHERE singleton=1',
      );
      _db.execute('COMMIT');
      if (_db.select('SELECT sequence FROM sync_identity').single['sequence'] !=
          sequence) {
        _localChanges.add(null);
      }
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
  Future<List<SavedServer>> listServers() => _dbWorker != null
      ? _remoteCall('listServers')
      : _serial(() async {
          final records = <SavedServer>[];
          for (final row in _db.select(
            'SELECT * FROM servers ORDER BY updated_at, id',
          )) {
            records.add(await _decode(row));
          }
          return records;
        });

  @override
  Future<SecretVault> openServer(String id) => _dbWorker != null
      ? _remoteCall<SavedServer?>('openServer', [
          id,
        ]).then((record) => _RemoteServerStore(this, id, record))
      : _serial(() async {
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
    final previous = _db.select('SELECT * FROM servers WHERE id=?', [id]);
    if (profile == null && previous.isEmpty) return null;
    if ((previous.firstOrNull?['revision'] ?? 0) != expected ||
        _journal.serverWasDeleted(id)) {
      throw const VaultFailure(VaultIssue.busy);
    }
    final oldSource = previous.isEmpty
        ? null
        : await _decrypt(
            'server:$id',
            expected,
            previous.single['payload'] as Uint8List,
          );
    final source = profile == null
        ? null
        : jsonEncode({...encodeProfile(profile), 'id': id});
    if (oldSource != null &&
        source != null &&
        canonicalJson(jsonDecode(oldSource)) ==
            canonicalJson(jsonDecode(source))) {
      return _transaction(() {
        _checkRevision('servers', id, expected);
        return SavedServer(id, profile!, expected);
      });
    }
    final revision = expected + 1;
    final payload = source == null
        ? null
        : await _encrypt('server:$id', revision, source);
    final changes = await _journal.prepare(
      _serverEntities(id, oldSource),
      _serverEntities(id, source),
    );
    return _transaction(() {
      final rows = _db.select('SELECT revision FROM servers WHERE id = ?', [
        id,
      ]);
      final current = rows.isEmpty ? 0 : rows.single['revision'] as int;
      if (current != expected) throw const VaultFailure(VaultIssue.busy);
      if (profile == null) {
        _db.execute('DELETE FROM servers WHERE id = ?', [id]);
        _journal.commit(changes);
        return null;
      }
      _db.execute(
        'INSERT INTO servers VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, revision=excluded.revision, updated_at=excluded.updated_at',
        [id, payload, revision, DateTime.now().millisecondsSinceEpoch],
      );
      _journal.commit(changes);
      return SavedServer(id, profile, revision);
    });
  });

  @override
  Future<void> deleteServers(
    List<SavedServer> expected, {
    bool detachJumpReferences = false,
  }) => _dbWorker != null
      ? _remoteCall('deleteServers', [expected, detachJumpReferences])
      : _serial(() async {
          _checkSyncEffectsNow();
          final ids = expected.map((s) => s.id).toSet();
          if (ids.isEmpty || ids.length != expected.length) {
            throw const VaultFailure(VaultIssue.busy);
          }
          final rows = _db.select('SELECT * FROM servers');
          final stamp = canonicalJson({
            for (final row in rows) row['id'] as String: row['revision'],
          });
          final sources = <String, String>{};
          final detached = <String, (int, String, Uint8List)>{};
          for (final row in rows) {
            final id = row['id'] as String;
            final source = await _decrypt(
              'server:$id',
              row['revision'] as int,
              row['payload'] as Uint8List,
            );
            final profile = decodeProfile(
              jsonDecode(source) as Map<String, dynamic>,
            );
            if (!ids.contains(id) && ids.contains(profile.jumpServerId)) {
              if (!detachJumpReferences) {
                throw const VaultFailure(VaultIssue.busy);
              }
              final revision = (row['revision'] as int) + 1;
              final updated = jsonEncode(
                encodeProfile(profile.withJumpServer(null)),
              );
              detached[id] = (
                revision,
                updated,
                await _encrypt('server:$id', revision, updated),
              );
              sources[id] = source;
            }
            if (ids.contains(id)) sources[id] = source;
          }
          for (final server in expected) {
            _checkRevision('servers', server.id, server.revision);
            if (!sources.containsKey(server.id) ||
                _journal.serverWasDeleted(server.id)) {
              throw const VaultFailure(VaultIssue.busy);
            }
          }
          final changes = await _journal.prepare(
            {
              for (final e in sources.entries)
                ..._serverEntities(e.key, e.value),
            },
            {
              for (final e in detached.entries)
                ..._serverEntities(e.key, e.value.$2),
            },
          );
          _transaction(() {
            final currentStamp = canonicalJson({
              for (final row in _db.select('SELECT id, revision FROM servers'))
                row['id'] as String: row['revision'],
            });
            if (stamp != currentStamp) {
              throw const VaultFailure(VaultIssue.busy);
            }
            _checkSyncEffectsNow();
            for (final server in expected) {
              _checkRevision('servers', server.id, server.revision);
            }
            for (final id in ids) {
              _db.execute('DELETE FROM servers WHERE id=?', [id]);
            }
            for (final entry in detached.entries) {
              _db.execute(
                'UPDATE servers SET payload=?, revision=?, updated_at=? WHERE id=?',
                [
                  entry.value.$3,
                  entry.value.$1,
                  DateTime.now().millisecondsSinceEpoch,
                  entry.key,
                ],
              );
            }
            _journal.commit(changes);
          });
        });

  @override
  Future<String?> readSetting(String key) => _dbWorker != null
      ? _remoteCall('readSetting', [key])
      : _serial(() {
          final rows = _db.select('SELECT value FROM settings WHERE key = ?', [
            key,
          ]);
          return rows.isEmpty ? null : rows.single['value'] as String;
        });
  @override
  Future<void> writeSetting(String key, String value) => _dbWorker != null
      ? _remoteCall('writeSetting', [key, value])
      : _serial(
          () => _transaction(() {
            _db.execute(
              'INSERT INTO settings VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
              [key, value],
            );
          }),
        );
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
  Future<String?> readPublicationDocument(String id) => _dbWorker != null
      ? _remoteCall('readPublicationDocument', [id])
      : _readDocument(_publicationId(id));
  @override
  Future<void> writePublicationDocument(
    String id,
    String source, {
    required String? expectedSource,
  }) {
    if (_dbWorker != null) {
      return _remoteCall('writePublicationDocument', [
        id,
        source,
        expectedSource,
      ]);
    }
    final key = _publicationId(id);
    _validatePublicationDocument(key, source);
    return _writeDocument(
      key,
      source,
      conditional: true,
      expectedSource: expectedSource,
    );
  }

  LocalVaultFileStore _publicationQueueFiles(String userId) {
    _publicationId('queue/$userId');
    return LocalVaultFileStore(File('$_path.publication-$userId.json'));
  }

  @override
  Future<String?> readPublicationQueue(String userId) => _dbWorker != null
      ? _remoteCall('readPublicationQueue', [userId])
      : _serial(() async {
          final source = await _publicationQueueFiles(userId).read();
          return source == null
              ? null
              : _decrypt('publication-queue/$userId', 1, base64Decode(source));
        });
  @override
  Future<Map<String, Map<String, String?>>> readPublicationStateBatch(
    List<String> userIds,
  ) => _dbWorker != null
      ? _remoteCall('readPublicationStateBatch', [userIds])
      : _serial(() async {
          final ids = userIds.toSet().toList();
          for (final id in ids) {
            _publicationId('queue/$id');
          }
          if (ids.isEmpty) return <String, Map<String, String?>>{};
          final result = <String, Map<String, String?>>{
            for (final id in ids)
              id: {'queue': null, 'result': null, 'binding': null},
          };
          // SQLite builds may have a 999-variable limit. Bound each query.
          for (var offset = 0; offset < ids.length; offset += 400) {
            final group = ids.skip(offset).take(400);
            final names = [
              for (final id in group) ...[
                'publication/result/$id',
                'publication/binding/$id',
              ],
            ];
            final placeholders = List.filled(names.length, '?').join(',');
            final rows = _db.select(
              'SELECT id, revision, payload FROM documents WHERE id IN ($placeholders)',
              names,
            );
            for (final row in rows) {
              final name = row['id'] as String;
              final id = name.split('/').last;
              final field = name.startsWith('publication/result/')
                  ? 'result'
                  : 'binding';
              result[id]![field] = await _decrypt(
                name,
                row['revision'] as int,
                row['payload'] as Uint8List,
              );
            }
          }
          for (final id in ids) {
            final source = await _publicationQueueFiles(id).read();
            if (source != null) {
              result[id]!['queue'] = await _decrypt(
                'publication-queue/$id',
                1,
                base64Decode(source),
              );
            }
          }
          return result;
        });
  @override
  Future<void> writePublicationQueue(
    String userId,
    String source, {
    required String? expectedSource,
  }) => _dbWorker != null
      ? _remoteCall('writePublicationQueue', [userId, source, expectedSource])
      : _serial(() async {
          if (utf8.encode(source).length > 65536) {
            throw const PublicationFailure(PublicationIssue.size);
          }
          final files = _publicationQueueFiles(userId);
          final before = await files.read();
          final plain = before == null
              ? null
              : await _decrypt(
                  'publication-queue/$userId',
                  1,
                  base64Decode(before),
                );
          if (plain != expectedSource) {
            throw const SyncMergeFailure(SyncMergeIssue.changed);
          }
          if (source == plain) return;
          await files.replace(
            before,
            base64Encode(
              await _encrypt('publication-queue/$userId', 1, source),
            ),
          );
        });

  Future<VpnWorkspace> _getVpnWorkspace() async {
    final projection = await _vpnOverlay.read();
    final rev = projection.revision;
    if (rev == _cachedWorkspaceRevision && _cachedWorkspace != null) {
      return _cachedWorkspace!;
    }
    final workspace = VpnWorkspace.decode(projection.source!);
    _cachedWorkspaceRevision = rev;
    _cachedWorkspace = workspace;
    return workspace;
  }

  @override
  Future<PublicationDraft?> readPublicationDraft(String userId) =>
      _dbWorker != null
      ? _remoteCall('readPublicationDraft', [userId])
      : _serial(() async {
          _publicationId('queue/$userId');
          _checkSyncEffectsNow();
          final row = _db.select('SELECT * FROM documents WHERE id=?', [
            'vpn-workspace-v1',
          ]).firstOrNull;
          if (row == null) return null;
          final workspace = await _getVpnWorkspace();
          final user = workspace.users
              .where((u) => u.id == userId && u.enabled)
              .firstOrNull;
          final profile = workspace.profiles[userId];
          if (user == null ||
              profile == null ||
              profile['yaml'] is! String ||
              profile['hash'] is! String) {
            return null;
          }
          final headId = _merge.preferredHead(ChangeEntityKind.profile, userId);
          if (headId == null) return null;
          final ancestors = await _merge.acceptedAncestors(headId);
          final previous = _db.select('SELECT * FROM documents WHERE id=?', [
            'publication/result/$userId',
          ]).firstOrNull;
          if (previous != null) {
            final result =
                jsonDecode(
                      await _decrypt(
                        'publication/result/$userId',
                        previous['revision'] as int,
                        previous['payload'] as Uint8List,
                      ),
                    )
                    as Map;
            if (result['head'] case final String publishedHead) {
              ancestors.add(publishedHead);
            }
          }
          final bytes = Uint8List.fromList(
            utf8.encode(profile['yaml'] as String),
          );
          final hash = (await Sha256().hash(
            bytes,
          )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
          if (hash != profile['hash']) {
            throw const PublicationFailure(PublicationIssue.invalid);
          }
          return PublicationDraft(
            workspaceId:
                profile['publicationWorkspaceId'] as String? ?? workspace.id,
            deviceId: _journal.identity.deviceId,
            userId: userId,
            name: user.login,
            headId: headId,
            hash: hash,
            bytes: bytes,
            ancestors: ancestors,
            stamp: _publicationInputStamp(),
          );
        });
  @override
  Future<void> checkPublicationDraft(PublicationDraft draft) =>
      _dbWorker != null
      ? _remoteCall('checkPublicationDraft', [draft])
      : _serial(() async {
          _journal.checkIdentity();
          _checkSyncEffectsNow();
          if (_journal.identity.deviceId != draft.deviceId) {
            throw const SyncMergeFailure(SyncMergeIssue.changed);
          }
          if (draft.stamp != _publicationInputStamp()) {
            throw const SyncMergeFailure(SyncMergeIssue.changed);
          }
          // Queue/result documents and unrelated server observations must not fence
          // a retained profile. Recheck its causal head, exact bytes and user instead.
          if (_merge.preferredHeads()[(
                ChangeEntityKind.profile,
                draft.userId,
              )] !=
              draft.headId) {
            throw const SyncMergeFailure(SyncMergeIssue.changed);
          }
          final workspace = await _getVpnWorkspace();
          if (!workspace.users.any(
                (u) =>
                    u.id == draft.userId && u.enabled && u.login == draft.name,
              ) ||
              workspace.profiles[draft.userId]?['hash'] != draft.hash ||
              (workspace.profiles[draft.userId]?['publicationWorkspaceId'] ??
                      workspace.id) !=
                  draft.workspaceId) {
            throw const SyncMergeFailure(SyncMergeIssue.changed);
          }
        });

  @override
  Future<String?> readDraft() => _dbWorker != null
      ? _remoteCall('readDraft')
      : _readDocument('template-draft');
  @override
  Future<VpnStoredDocument> readVpn() => _dbWorker != null
      ? _remoteCall('readVpn')
      : _serial(() async {
          final projection = await _vpnOverlay.read();
          return VpnStoredDocument(
            projection.source,
            projection.revision,
            workspaceId: _journal.identity.workspaceId,
          );
        });
  @override
  Future<int> writeVpn(String source, {required int expectedRevision}) =>
      _dbWorker != null
      ? _remoteCall('writeVpn', [source, expectedRevision])
      : _offloadVpnWrites
      ? _offloadVpnWrite(source, expectedRevision: expectedRevision)
      : _writeVpnLocal(source, expectedRevision: expectedRevision);

  @override
  Future<int> writeVpnWorkspace(
    VpnWorkspace workspace, {
    required int expectedRevision,
  }) => _dbWorker != null
      ? _remoteCall('writeVpnWorkspace', [workspace, expectedRevision])
      : _offloadVpnWrites
      ? _offloadVpnWrite(workspace, expectedRevision: expectedRevision)
      : _writeVpnLocal(workspace.encode(), expectedRevision: expectedRevision);

  @override
  Future<int> upsertVpnUser(VpnUser user, {required int expectedRevision}) =>
      _dbWorker != null
      ? _remoteCall('upsertVpnUser', [user, expectedRevision])
      : _offloadVpnWrites
      ? _offloadVpnWrite(user, expectedRevision: expectedRevision)
      : _upsertVpnUserLocal(user, expectedRevision: expectedRevision);

  @override
  Future<int> upsertVpnProfile(
    String userId,
    Map<String, dynamic> profile, {
    required int expectedRevision,
  }) => _dbWorker != null
      ? _remoteCall('upsertVpnProfile', [userId, profile, expectedRevision])
      : _offloadVpnWrites
      ? _offloadVpnWrite(
          _VpnProfilePatch(userId, profile),
          expectedRevision: expectedRevision,
        )
      : _serial(
          () => _vpnOverlay.upsertProfile(userId, profile, expectedRevision),
        );

  Future<int> _offloadVpnWrite(Object input, {required int expectedRevision}) =>
      _serial(() async {
        final writer = await _vpnWriteWorker();
        try {
          final updated = await writer.write(input, expectedRevision);
          _documentCache.remove('vpn-workspace-v1');
          _cachedWorkspaceRevision = null;
          _cachedWorkspace = null;
          if (updated != expectedRevision) _localChanges.add(null);
          return updated;
        } catch (_) {
          if (writer.terminated) {
            await writer.close();
            _vpnWriter = null;
          }
          rethrow;
        }
      });

  Future<_VpnWriteWorker> _vpnWriteWorker() async {
    final pending = _vpnWriter ??= _VpnWriteWorker.start(_path, _key);
    try {
      return await pending;
    } catch (_) {
      _vpnWriter = null;
      rethrow;
    }
  }

  Future<int> _writeVpnLocal(String source, {required int expectedRevision}) =>
      _serial(() => _writeVpnCore(source, expectedRevision: expectedRevision));

  Future<int> _upsertVpnUserLocal(
    VpnUser user, {
    required int expectedRevision,
  }) => _serial(() => _vpnOverlay.upsertUser(user, expectedRevision));

  Future<int> _writeVpnCore(
    String source, {
    required int expectedRevision,
    _EntityKey? only,
  }) async {
    if (utf8.encode(source).length > 8 * 1024 * 1024) {
      throw const VaultFailure(VaultIssue.writeFailed);
    }
    if (VpnWorkspace.decode(source).id != _journal.identity.workspaceId) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
    const id = 'vpn-workspace-v1';
    final projection = await _vpnOverlay.read();
    if (projection.revision != expectedRevision) {
      throw const VaultFailure(VaultIssue.busy);
    }
    final oldSource = projection.source;
    final suppliedSource = source;
    source = _withAccountNamespaces(source, oldSource);
    if (source != suppliedSource) only = null;
    if (oldSource == source) {
      return _transaction(() {
        _vpnOverlay._checkRevision(projection.baseRevision, expectedRevision);
        return expectedRevision;
      });
    }
    if (oldSource != null) {
      final next = VpnWorkspace.decode(source);
      if (VpnWorkspace.decode(oldSource).users.any(
        (u) => u.deleted && !next.users.any((v) => v.id == u.id && v.deleted),
      )) {
        throw const FormatException('vpn_user_deleted');
      }
    }
    final revision = expectedRevision + 1;
    final payload = await _encrypt(id, revision, source);
    final changes = await _journal.prepare(
      _documentEntities(id, oldSource, only: only),
      _documentEntities(id, source, only: only),
    );
    return _transaction(() {
      _vpnOverlay._checkRevision(projection.baseRevision, expectedRevision);
      _db.execute(
        'INSERT INTO documents VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, revision=excluded.revision',
        [id, payload, revision],
      );
      _db.execute('DELETE FROM vpn_user_overlay');
      _db.execute('DELETE FROM vpn_profile_overlay');
      _db.execute('DELETE FROM vpn_overlay_state');
      _journal.commit(changes);
      _documentCache[id] = (revision, source);
      _cachedWorkspaceRevision = null;
      _cachedWorkspace = null;
      return revision;
    });
  }

  @override
  Future<void> writeDraft(String source) => _dbWorker != null
      ? _remoteCall('writeDraft', [source])
      : _writeDocument('template-draft', source);
  @override
  Future<String?> readRunnerJournal(String serverId) => _dbWorker != null
      ? _remoteCall('readRunnerJournal', [serverId])
      : _readDocument('runner/$serverId');
  @override
  Future<void> writeRunnerJournal(String serverId, String source) =>
      _dbWorker != null
      ? _remoteCall('writeRunnerJournal', [serverId, source])
      : _writeDocument('runner/$serverId', source);

  @override
  Future<void> writeRunnerJournalIfUnchanged(
    String serverId,
    String source, {
    required String? expectedSource,
  }) => _dbWorker != null
      ? _remoteCall('writeRunnerJournalIfUnchanged', [
          serverId,
          source,
          expectedSource,
        ])
      : _writeDocument(
          'runner/$serverId',
          source,
          conditional: true,
          expectedSource: expectedSource,
        );

  Future<String?> _readDocument(String id) => _serial(() async {
    final rows = _db.select('SELECT * FROM documents WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final rev = rows.single['revision'] as int;
    if (_documentCache[id] case (
      final cachedRev,
      final cachedSource,
    ) when cachedRev == rev) {
      return cachedSource;
    }
    final source = await _decrypt(id, rev, rows.single['payload'] as Uint8List);
    _documentCache[id] = (rev, source);
    return source;
  });
  Future<void> _writeDocument(
    String id,
    String source, {
    bool conditional = false,
    String? expectedSource,
  }) => _serial(() async {
    if (utf8.encode(source).length > 256 * 1024) {
      throw const VaultFailure(VaultIssue.writeFailed);
    }
    final rows = _db.select('SELECT * FROM documents WHERE id=?', [id]);
    final expected = rows.isEmpty ? 0 : rows.single['revision'] as int;
    final oldSource = rows.isEmpty
        ? null
        : await _decrypt(id, expected, rows.single['payload'] as Uint8List);
    if (conditional && oldSource != expectedSource) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
    if (oldSource == source) {
      _transaction(() => _checkRevision('documents', id, expected));
      return;
    }
    final revision = expected + 1;
    final payload = await _encrypt(id, revision, source);
    final changes = await _journal.prepare(
      _documentEntities(id, oldSource),
      _documentEntities(id, source),
    );
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
      _journal.commit(changes);
      _documentCache[id] = (revision, source);
      if (id == 'vpn-workspace-v1') {
        _cachedWorkspaceRevision = null;
        _cachedWorkspace = null;
      }
    });
  });

  void _checkRevision(String table, String id, int expected) {
    final current = _db.select('SELECT revision FROM $table WHERE id=?', [id]);
    if ((current.firstOrNull?['revision'] ?? 0) != expected) {
      throw const VaultFailure(VaultIssue.busy);
    }
  }

  Future<void> inspectLegacy() async {
    if (_dbWorker != null
        ? await _remoteCall<bool>('legacyMigrated')
        : _db
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
  Future<void> migrateLegacy({String? password}) => _dbWorker != null
      ? _migrateLegacyRemote(password)
      : _serial(() async {
          if (_legacyMigrationDone()) {
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
            await _importLegacyProfile(profile);
          } finally {
            legacy?.lock();
          }
        });

  bool _legacyMigrationDone() => _db
      .select("SELECT 1 FROM migrations WHERE id = 'legacy-vault-v1'")
      .isNotEmpty;

  Future<void> _migrateLegacyRemote(String? password) async {
    if (await _remoteCall<bool>('legacyMigrated')) {
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
      await _remoteCall<void>('importLegacyProfile', [profile]);
      needsLegacyPassword = false;
    } finally {
      legacy?.lock();
    }
  }

  Future<void> _importLegacyProfile(SshProfile? profile) async {
    if (_legacyMigrationDone()) {
      needsLegacyPassword = false;
      return;
    }
    final id = newServerId();
    final source = profile == null
        ? null
        : jsonEncode({...encodeProfile(profile), 'id': id});
    final payload = source == null
        ? null
        : await _encrypt('server:$id', 1, source);
    final changes = await _journal.prepare({}, _serverEntities(id, source));
    _transaction(() {
      if (_legacyMigrationDone()) return;
      if (payload != null) {
        _db.execute('INSERT INTO servers VALUES (?, ?, 1, ?)', [
          id,
          payload,
          DateTime.now().millisecondsSinceEpoch,
        ]);
      }
      _db.execute("INSERT INTO migrations VALUES ('legacy-vault-v1')");
      _journal.commit(changes);
    });
    needsLegacyPassword = false;
  }

  @override
  Future<SyncMergeStatus> receiveSyncPackets(List<Uint8List> packets) {
    if (packets.length > 100 ||
        packets.fold<int>(0, (n, p) => n + p.length) > 32 * 1024 * 1024 ||
        packets.any((p) => p.length > syncMaxPacketBytes)) {
      return Future.error(const SyncMergeFailure(SyncMergeIssue.limit));
    }
    final owned = packets.map(Uint8List.fromList).toList();
    if (_dbWorker != null) return _remoteCall('receiveSyncPackets', [owned]);
    return _serial(() async {
      await _vpnOverlay.materialize();
      return _merge.receive(owned);
    }, migrate: false);
  }

  @override
  Future<SyncMergeStatus> readSyncMergeStatus() => _dbWorker != null
      ? _remoteCall('readSyncMergeStatus')
      : _serial(() => _merge.status());
  @override
  Future<SyncMergeStatus> retrySyncMerge() => _dbWorker != null
      ? _remoteCall('retrySyncMerge')
      : _serial(() async {
          await _vpnOverlay.materialize();
          await _merge.drain();
          return _merge.status();
        });
  @override
  Future<void> resolveSyncConflict(
    SyncConflict conflict,
    String selectedChangeId,
  ) => _dbWorker != null
      ? _remoteCall('resolveSyncConflict', [conflict, selectedChangeId])
      : _serial(() async {
          await _vpnOverlay.materialize();
          await _merge.resolve(conflict, selectedChangeId);
        });
  void clearSyncCache() {
    _merge.clearCache();
  }

  @override
  Future<void> checkSyncEffects() => _dbWorker != null
      ? _remoteCall('checkSyncEffects')
      : _serial(_checkSyncEffectsNow);
  void _checkSyncEffectsNow() {
    if (_db.select('SELECT 1 FROM sync_conflicts LIMIT 1').isNotEmpty ||
        _db
            .select('SELECT 1 FROM sync_incoming WHERE state=2 LIMIT 1')
            .isNotEmpty) {
      throw const SyncMergeFailure(SyncMergeIssue.conflict);
    }
  }

  @override
  Future<WorkspaceIdentity> readWorkspaceIdentity() => _dbWorker != null
      ? _remoteCall('readWorkspaceIdentity')
      : _serial(() => _journal.identity);

  @override
  Future<List<EncryptedChangePacket>> preparePendingPackets({
    int afterSequence = 0,
    int limit = 100,
  }) => _dbWorker != null
      ? _remoteCall('preparePendingPackets', [afterSequence, limit])
      : _serial(() => _sync.prepare(afterSequence, limit));

  @override
  Future<LocalChange> verifySyncPacket(Uint8List bytes) {
    if (bytes.length > syncMaxPacketBytes) {
      return Future.error(const SyncPacketFailure(SyncPacketIssue.tooLarge));
    }
    final owned = Uint8List.fromList(bytes);
    if (_dbWorker != null) return _remoteCall('verifySyncPacket', [owned]);
    return _serial(() => _sync.verify(owned), migrate: false);
  }

  @override
  Future<List<LocalChange>> readChanges({
    int afterSequence = 0,
    int limit = 100,
  }) => _dbWorker != null
      ? _remoteCall('readChanges', [afterSequence, limit])
      : _serial(
          () => _journal.read(
            pending: false,
            afterSequence: afterSequence,
            limit: limit,
          ),
        );

  @override
  Future<List<LocalChange>> readPendingChanges({
    int afterSequence = 0,
    int limit = 100,
  }) => _dbWorker != null
      ? _remoteCall('readPendingChanges', [afterSequence, limit])
      : _serial(
          () => _journal.read(
            pending: true,
            afterSequence: afterSequence,
            limit: limit,
          ),
        );

  @override
  Future<void> acknowledgeChanges(List<String> changeIds) {
    final ids = List<String>.of(changeIds);
    if (_dbWorker != null) return _remoteCall('acknowledgeChanges', [ids]);
    return _serial(() => _transaction(() => _journal.acknowledge(ids)));
  }

  @override
  Future<Uint8List> createBackup(String password) => _dbWorker != null
      ? _remoteCall('createBackup', [password])
      : _createBackup(this, password);

  @override
  Future<Set<String>> readRestoredTargets() => _dbWorker != null
      ? _remoteCall('readRestoredTargets')
      : _serial(() {
          final rows = _db.select(
            "SELECT value FROM settings WHERE key='backupRestoredTargets'",
          );
          return rows.isEmpty
              ? <String>{}
              : Set<String>.from(
                  jsonDecode(rows.single['value'] as String) as List,
                );
        });

  @override
  Future<void> approveRestoredTargets(Iterable<String> targets) {
    final approved = targets.toSet();
    if (_dbWorker != null) {
      return _remoteCall('approveRestoredTargets', [approved.toList()]);
    }
    return _serial(
      () => _transaction(() {
        final rows = _db.select(
          "SELECT value FROM settings WHERE key='backupRestoredTargets'",
        );
        final pending = rows.isEmpty
            ? <String>{}
            : Set<String>.from(
                jsonDecode(rows.single['value'] as String) as List,
              );
        pending.removeAll(approved);
        _db.execute(
          "INSERT INTO settings VALUES ('backupRestoredTargets',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [jsonEncode(pending.toList()..sort())],
        );
      }),
    );
  }

  @override
  Future<WorkspaceRestorePlan> prepareRestore(
    Uint8List bytes,
    String password,
  ) => bytes.length > maxWorkspaceBackupBytes
      ? Future.error(const BackupFailure(BackupIssue.tooLarge))
      : _dbWorker != null
      ? _remoteCall<(int, BackupSummary)>('prepareRestore', [
          Uint8List.fromList(bytes),
          password,
        ]).then((result) => _RemoteRestorePlan(this, result.$1, result.$2))
      : _prepareRestore(this, bytes, password);
  @override
  Future<void> restoreBackup(WorkspaceRestorePlan plan) {
    if (_dbWorker != null) {
      if (plan is! _RemoteRestorePlan ||
          !identical(plan.owner, this) ||
          plan.disposed) {
        return Future.error(const BackupFailure(BackupIssue.changed));
      }
      plan.disposed = true;
      return _remoteCall('restoreBackup', [plan.id]);
    }
    return _restoreBackup(this, plan);
  }

  Future<_CapturedSnapshot> _captureSnapshot() => _dbWorker != null
      ? _remoteCall('captureSnapshot')
      : _currentSnapshot(this);

  Future<void> _compactHistory() => _dbWorker != null
      ? _remoteCall('compactHistory')
      : _compactCurrentHistory(this);

  Future<({bool empty, int sequence, String workspaceId})>
  _snapshotLocalState() => _dbWorker != null
      ? _remoteCall('snapshotState')
      : _serial(
          () => (
            empty:
                _db.select('SELECT 1 FROM servers LIMIT 1').isEmpty &&
                _db.select('SELECT 1 FROM documents LIMIT 1').isEmpty,
            sequence:
                _db
                        .select(
                          'SELECT sequence FROM sync_identity WHERE singleton=1',
                        )
                        .single['sequence']
                    as int,
            workspaceId: _journal.identity.workspaceId,
          ),
        );

  Future<String> _snapshotStamp() => _dbWorker != null
      ? _remoteCall('snapshotStamp')
      : _serial(() => _backupStamp(this));

  Future<void> _restoreCloudSnapshot(
    _BackupSnapshot snapshot,
    String stamp,
    SyncRemoteFile file,
  ) => _dbWorker != null
      ? _remoteCall('restoreCloudSnapshot', [
          snapshot,
          stamp,
          file.id,
          file.version,
          file.etag,
        ])
      : _restoreCloudSnapshotInWorker(
          this,
          snapshot,
          stamp,
          file.id,
          file.version,
          file.etag,
        );

  Future<void> close() async {
    if (_closed) return;
    if (_dbWorker case final worker?) {
      _closed = true;
      try {
        await worker.close();
      } finally {
        _key.destroy();
        await _localChanges.close();
      }
      return;
    }
    await _pending;
    if (_closed) return;
    _closed = true;
    if (_vpnWriter case final pending?) {
      await (await pending).close();
    }
    _db.dispose();
    _key.destroy();
    await _localChanges.close();
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
