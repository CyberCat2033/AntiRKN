part of 'workspace_database.dart';

// The archive is a single materialized workspace. Event history never enters it.
final class _BackupSnapshot {
  _BackupSnapshot(this.data, this.summary);
  final Map<String, dynamic> data;
  final BackupSummary summary;
  List<dynamic> get documents => data['documents'] as List;
  @override
  String toString() => 'BackupSnapshot(<redacted>)';
}

final class _CapturedSnapshot {
  const _CapturedSnapshot(this.source, this.sequence);
  final String source;
  final int sequence;
}

final class _RestorePlan implements WorkspaceRestorePlan {
  _RestorePlan(this.owner, this.stamp, _BackupSnapshot snapshot)
    : _snapshot = snapshot,
      summary = snapshot.summary;
  final WorkspaceDatabase owner;
  final String stamp;
  _BackupSnapshot? _snapshot;
  bool cloudBound = false;
  String? remoteFileId, remoteVersion;
  @override
  final BackupSummary summary;
  @override
  void dispose() => _snapshot = null;
  @override
  String toString() => 'WorkspaceRestorePlan(<redacted>)';
}

String _backupStamp(WorkspaceDatabase store) => jsonEncode([
  ...store._db.select(
    'SELECT workspace_id,device_id,sequence FROM sync_identity',
  ),
  ...store._db.select('SELECT epoch FROM sync_merge_meta'),
]);

Future<_CapturedSnapshot> _currentSnapshot(
  WorkspaceDatabase store,
) => store._serial(() async {
  final captured = <String, List<Row>>{};
  late final int sequence;
  store._db.execute('BEGIN');
  try {
    store._journal.checkIdentity();
    if (store._db.select('SELECT 1 FROM sync_conflicts LIMIT 1').isNotEmpty ||
        store._db
            .select('SELECT 1 FROM sync_incoming WHERE state IN (0,2) LIMIT 1')
            .isNotEmpty ||
        store._db
            .select(
              'SELECT 1 FROM sync_branches GROUP BY entity_kind,entity_id HAVING COUNT(*)>1 LIMIT 1',
            )
            .isNotEmpty) {
      throw const BackupFailure(BackupIssue.changed);
    }
    for (final (name, sql) in [
      ('servers', 'SELECT * FROM servers ORDER BY id'),
      ('documents', 'SELECT * FROM documents ORDER BY id'),
    ]) {
      captured[name] = store._db.select(sql);
    }
    sequence =
        store._db
                .select('SELECT sequence FROM sync_identity WHERE singleton=1')
                .single['sequence']
            as int;
    store._db.execute('COMMIT');
  } catch (_) {
    store._db.execute('ROLLBACK');
    rethrow;
  }
  final data = <String, dynamic>{
    'version': 4,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'workspaceId': store._journal.identity.workspaceId,
    'servers': <Object?>[],
    'documents': <Object?>[],
  };
  var sourceBytes = 0;
  for (final table in ['servers', 'documents']) {
    for (final row in captured[table]!) {
      final id = row['id'] as String;
      var source = await store._decrypt(
        table == 'servers' ? 'server:$id' : id,
        row['revision'] as int,
        row['payload'] as Uint8List,
      );
      if (id == 'vpn-workspace-v1') {
        final vpn = jsonDecode(source) as Map<String, dynamic>;
        final profiles = vpn['profiles'] as Map<String, dynamic>?;
        if (profiles != null) {
          for (final value in profiles.values) {
            if (value is Map<String, dynamic>) value.remove('history');
          }
        }
        source = jsonEncode(vpn);
      } else if (id.startsWith('runner/')) {
        final journal = jsonDecode(source) as Map<String, dynamic>;
        final selected = journal['selected'];
        if (selected is Map<String, dynamic>) {
          selected['events'] = <Object>[];
        }
        source = jsonEncode(journal);
      }
      sourceBytes += utf8.encode(source).length;
      if (sourceBytes > maxWorkspaceBackupBytes) {
        throw const BackupFailure(BackupIssue.tooLarge);
      }
      (data[table] as List).add({
        'id': id,
        'revision': row['revision'],
        'source': source,
        if (table == 'servers') 'updatedAt': row['updated_at'],
      });
    }
  }
  final source = jsonEncode(data);
  await _validateBackupInBackground(source);
  return _CapturedSnapshot(source, sequence);
});

Future<Uint8List> _createBackup(
  WorkspaceDatabase store,
  String password,
) async {
  try {
    return await BackupEnvelope.seal(
      (await _currentSnapshot(store)).source,
      password,
    );
  } on BackupFailure {
    rethrow;
  } catch (_) {
    throw const BackupFailure(BackupIssue.storage);
  }
}

Future<void> _compactCurrentHistory(
  WorkspaceDatabase store,
) => store._serial(() {
  store._transaction(() {
    if (store._db.select('SELECT 1 FROM sync_conflicts LIMIT 1').isNotEmpty ||
        store._db
            .select('SELECT 1 FROM sync_incoming WHERE state IN (0,2) LIMIT 1')
            .isNotEmpty ||
        store._db
            .select(
              'SELECT 1 FROM sync_branches GROUP BY entity_kind,entity_id HAVING COUNT(*)>1 LIMIT 1',
            )
            .isNotEmpty) {
      throw const BackupFailure(BackupIssue.changed);
    }
    store._db.execute('DELETE FROM sync_packets');
    store._db.execute('DELETE FROM sync_outbox');
    store._db.execute('DROP TRIGGER sync_changes_immutable_delete');
    store._db.execute('''
          DELETE FROM sync_changes
          WHERE change_id NOT IN (SELECT change_id FROM sync_heads)
        ''');
    store._db.execute(
      "CREATE TRIGGER sync_changes_immutable_delete BEFORE DELETE ON sync_changes BEGIN SELECT RAISE(ABORT, 'immutable_change'); END",
    );
    store._db.execute('''
          DELETE FROM sync_incoming
          WHERE change_id NOT IN (SELECT change_id FROM sync_heads)
        ''');
    store._merge.advance();
  });
  store._merge._decryptedEventCache.clear();
  return Future<void>.value();
});

Future<WorkspaceRestorePlan> _prepareRestore(
  WorkspaceDatabase store,
  Uint8List bytes,
  String password,
) async {
  final stamp = await store._serial(() => _backupStamp(store));
  final source = await BackupEnvelope.open(bytes, password);
  return _RestorePlan(store, stamp, await _validateBackupInBackground(source));
}

Future<void> _restoreBackup(
  WorkspaceDatabase store,
  WorkspaceRestorePlan plan,
) async {
  if (plan is! _RestorePlan ||
      !identical(plan.owner, store) ||
      plan._snapshot == null) {
    throw const BackupFailure(BackupIssue.changed);
  }
  final snapshot = plan._snapshot!;
  try {
    await store._serial(() async {
      if (_backupStamp(store) != plan.stamp) {
        throw const BackupFailure(BackupIssue.changed);
      }
      final deviceId = newVpnId();
      final workspaceId = snapshot.summary.workspaceId;
      final owner = WorkspaceIdentity(
        workspaceId: workspaceId,
        deviceId: deviceId,
      );
      final proof = await store._encrypt(
        'journal-identity',
        1,
        canonicalJson({
          'version': 1,
          'workspaceId': workspaceId,
          'deviceId': deviceId,
        }),
      );
      final syncKeyPayload = await store._encrypt(
        _WorkspaceSync.keyScope(workspaceId),
        1,
        canonicalJson(await _newSyncKey()),
      );
      final records = <String, List<List<Object?>>>{
        'servers': [],
        'documents': [],
      };
      final entities = <_EntityKey, _EntitySnapshot>{
        (ChangeEntityKind.workspace, workspaceId): _EntitySnapshot(
          canonicalJson({'id': workspaceId}),
        ),
      };
      for (final table in ['servers', 'documents']) {
        for (final dynamic row in snapshot.data[table] as List) {
          final id = row['id'] as String;
          final revision = row['revision'] as int;
          final source = row['source'] as String;
          records[table]!.add([
            id,
            await store._encrypt(
              table == 'servers' ? 'server:$id' : id,
              revision,
              source,
            ),
            revision,
            if (table == 'servers') row['updatedAt'],
          ]);
          entities.addAll(
            table == 'servers'
                ? _serverEntities(id, source)
                : _documentEntities(id, source),
          );
        }
      }
      // The current implementation still needs heads for local publication
      // guards. Recreate them from state; old changes and packets are discarded.
      final bootstrap = await store._journal._prepare(
        {},
        entities,
        owner,
        0,
        bootstrap: true,
      );
      store._transaction(() {
        if (_backupStamp(store) != plan.stamp || plan._snapshot == null) {
          throw const BackupFailure(BackupIssue.changed);
        }
        for (final table in ['servers', 'documents']) {
          for (final action in ['insert', 'update', 'delete']) {
            store._db.execute('DROP TRIGGER journal_guard_${table}_$action');
          }
        }
        store._db.execute('DELETE FROM servers');
        store._db.execute('DELETE FROM documents');
        for (final table in [
          'sync_incoming',
          'sync_branches',
          'sync_conflicts',
          'sync_merge_meta',
          'sync_packets',
          'sync_keys',
          'sync_outbox',
          'sync_heads',
          'sync_changes',
          'sync_identity',
        ]) {
          store._db.execute('DROP TABLE $table');
        }
        for (final sql in _LocalChangeJournal._ddl) {
          store._db.execute(sql);
        }
        store._db.execute(
          'ALTER TABLE sync_identity ADD COLUMN writer_device TEXT',
        );
        _WorkspaceSync.installSchema(store._db);
        _WorkspaceMerge.installSchema(store._db);
        store._db.execute('INSERT INTO sync_keys VALUES (1,?)', [
          syncKeyPayload,
        ]);
        store._db.execute(
          'INSERT INTO sync_identity VALUES (1, ?, ?, 0, ?, 1, ?, 5)',
          [workspaceId, deviceId, proof, deviceId],
        );
        for (final table in ['servers', 'documents']) {
          for (final row in records[table]!) {
            store._db.execute(
              'INSERT INTO $table VALUES (${List.filled(row.length, '?').join(',')})',
              row,
            );
          }
        }
        store._journal.commit(bootstrap);
        store._db.execute(
          "INSERT OR IGNORE INTO migrations VALUES ('legacy-vault-v1')",
        );
        if (plan.cloudBound) {
          store._db.execute(
            "INSERT INTO settings VALUES ('syncSnapshotBound',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [workspaceId],
          );
          for (final (key, value) in [
            ('syncSnapshotLocalSequence', '${bootstrap.changes.length}'),
            ('syncSnapshotRemoteFileId', plan.remoteFileId!),
            ('syncSnapshotRemoteVersion', plan.remoteVersion!),
          ]) {
            store._db.execute(
              'INSERT INTO settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
              [key, value],
            );
          }
        }
        store._db.execute(
          "INSERT INTO settings VALUES ('backupRestoredTargets',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [jsonEncode(_restoredTargets(snapshot.documents).toList()..sort())],
        );
        store._db.userVersion = 5;
      });
      store._restored = true;
      store.needsLegacyPassword = false;
    });
  } on BackupFailure {
    rethrow;
  } on VaultFailure catch (e) {
    throw BackupFailure(
      e.issue == VaultIssue.busy ? BackupIssue.changed : BackupIssue.storage,
    );
  } catch (_) {
    throw const BackupFailure(BackupIssue.storage);
  } finally {
    plan.dispose();
  }
}

Set<String> _restoredTargets(List<dynamic> documents) {
  final targets = <String>{};
  for (final dynamic row in documents) {
    if (row['id'] != 'vpn-workspace-v1') continue;
    final vpn = VpnWorkspace.decode(row['source'] as String);
    for (final user in vpn.users.where(
      (u) => u.deleted && !u.deletionComplete,
    )) {
      targets.addAll(
        (user.deletion!['targets'] as Map).entries
            .where((entry) => !vpnRevocationSettled(entry.value))
            .map((entry) => entry.key as String),
      );
    }
    for (final entry in vpn.servers.entries) {
      final record = entry.value;
      if (record['pending'] != null ||
          record['cancelRequested'] == true ||
          record['observingCancel'] == true ||
          record['authorizedPayload'] != null &&
              record['authorizedPayload'] != record['appliedPayload']) {
        targets.add(entry.key);
      }
    }
  }
  return targets;
}

Future<_BackupSnapshot> _validateBackupInBackground(String source) =>
    Isolate.run(() => _validateBackup(source));

// Limit nesting before jsonDecode, including JSON strings embedded in records.
Object? _backupJson(String source) {
  var depth = 0, quoted = false, escaped = false;
  for (final c in source.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == 92) {
        escaped = true;
      } else if (c == 34) {
        quoted = false;
      }
    } else if (c == 34) {
      quoted = true;
    } else if (c == 123 || c == 91) {
      if (++depth > 64) throw const BackupFailure(BackupIssue.invalid);
    } else if (c == 125 || c == 93) {
      depth--;
    }
  }
  return jsonDecode(source);
}

_BackupSnapshot _validateBackup(String source) {
  try {
    if (utf8.encode(source).length > maxWorkspaceBackupBytes - 53) {
      throw const BackupFailure(BackupIssue.tooLarge);
    }
    final data = _backupJson(source) as Map<String, dynamic>;
    if (data['version'] != 4) {
      throw const BackupFailure(BackupIssue.version);
    }
    if (data.length != 5 ||
        !data.keys.toSet().containsAll({
          'version',
          'createdAt',
          'workspaceId',
          'servers',
          'documents',
        })) {
      throw const FormatException();
    }
    final workspaceId = data['workspaceId'] as String;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(workspaceId)) {
      throw const FormatException();
    }
    final createdAt = DateTime.parse(data['createdAt'] as String).toUtc();
    var users = 0;
    for (final table in ['servers', 'documents']) {
      final ids = <String>{};
      final records = data[table] as List;
      if (records.length > 100000) throw const FormatException();
      for (final dynamic row in records) {
        final record = row as Map<String, dynamic>;
        if (record.length != (table == 'servers' ? 4 : 3)) {
          throw const FormatException();
        }
        final id = record['id'] as String;
        final revision = record['revision'] as int;
        final source = record['source'] as String;
        if (id.isEmpty ||
            id.length > 256 ||
            id.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
            !ids.add(id) ||
            revision < 1 ||
            revision > 9007199254740991) {
          throw const FormatException();
        }
        if (table == 'servers') {
          if (record['updatedAt'] is! int ||
              utf8.encode(source).length > 256 * 1024) {
            throw const FormatException();
          }
          if (decodeProfile(_backupJson(source) as Map<String, Object?>).id !=
              id) {
            throw const FormatException();
          }
        } else {
          if (id != 'template-draft' &&
              id != 'vpn-workspace-v1' &&
              !id.startsWith('runner/') &&
              !_isPublicationDocument(id)) {
            throw const FormatException();
          }
          if (utf8.encode(source).length >
              (id == 'vpn-workspace-v1' ? 8 * 1024 * 1024 : 256 * 1024)) {
            throw const FormatException();
          }
          if (id != 'template-draft') _backupJson(source);
          if (_isPublicationDocument(id)) {
            _validatePublicationDocument(id, source);
          }
          if (id.startsWith('runner/')) {
            final selected = (_backupJson(source) as Map)['selected'];
            if (selected is Map &&
                selected['events'] is List &&
                (selected['events'] as List).isNotEmpty) {
              throw const FormatException();
            }
          }
          if (id == 'vpn-workspace-v1') {
            final vpn = VpnWorkspace.decode(source);
            if (vpn.id != workspaceId) throw const FormatException();
            if (vpn.profiles.values.any(
              (profile) => profile.containsKey('history'),
            )) {
              throw const FormatException();
            }
            users = vpn.users.length;
          }
        }
      }
    }
    return _BackupSnapshot(
      data,
      BackupSummary(
        createdAt: createdAt,
        workspaceId: workspaceId,
        servers: (data['servers'] as List).length,
        users: users,
      ),
    );
  } on BackupFailure {
    rethrow;
  } catch (_) {
    throw const BackupFailure(BackupIssue.invalid);
  }
}
