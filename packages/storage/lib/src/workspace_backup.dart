part of 'workspace_database.dart';

// The archive is a single materialized workspace. Event history never enters it.
final class _BackupSnapshot {
  _BackupSnapshot(this.data, this.summary, this.intent);
  final Map<String, dynamic> data;
  final BackupSummary summary;

  /// [_intentDigest] of [data]: equal for the same intent on any device.
  final String intent;
  int get version => data['version'] as int;
  List<dynamic> get documents => data['documents'] as List;
  @override
  String toString() => 'BackupSnapshot(<redacted>)';
}

/// A validated capture: its source goes on without being checked again.
final class _CapturedSnapshot {
  const _CapturedSnapshot(
    this.source,
    this.sequence,
    this.workspaceId,
    this.intent,
    this.createdAt,
  );
  final String source;
  final int sequence;
  final String workspaceId, intent;
  final DateTime createdAt;
}

final class _RestorePlan implements WorkspaceRestorePlan {
  _RestorePlan(this.owner, this.stamp, _BackupSnapshot snapshot)
    : _snapshot = snapshot,
      summary = snapshot.summary;
  final WorkspaceDatabase owner;
  final String stamp;
  _BackupSnapshot? _snapshot;
  bool cloudBound = false;
  String? remoteFileId, remoteVersion, remoteEtag;

  /// The cloud's intent when the restored data differs from it: the device
  /// is bound to the cloud version and still has something to upload.
  String? boundIntent;
  @override
  final BackupSummary summary;
  @override
  void dispose() => _snapshot = null;
  @override
  String toString() => 'WorkspaceRestorePlan(<redacted>)';
}

String _backupStamp(WorkspaceDatabase store) => jsonEncode(
  store._db.select('SELECT workspace_id,device_id,sequence FROM sync_identity'),
);

/// The file backup keeps format 4 with everything this device knows; with
/// [cloud] the automatic sync snapshot v5 carries intent only.
Future<_CapturedSnapshot> _currentSnapshot(
  WorkspaceDatabase store, {
  bool cloud = false,
}) => store._serial(() async {
  await store._vpnOverlay.materialize();
  final captured = <String, List<Row>>{};
  late final int sequence;
  store._db.execute('BEGIN');
  try {
    store._journal.checkIdentity();
    // Backup v4 contains the current materialized workspace.
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
    'version': cloud ? cloudSnapshotVersion : 4,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'workspaceId': store._journal.identity.workspaceId,
    if (cloud)
      'author': {
        'deviceId': store._journal.identity.deviceId,
        'deviceName': ?_localDeviceName(),
      },
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
      if (cloud) {
        final intent = _cloudSource(table, id, source);
        if (intent == null) continue;
        source = intent;
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
  final validated = await _validateBackupInBackground(source, cloud: cloud);
  return _CapturedSnapshot(
    source,
    sequence,
    validated.summary.workspaceId,
    validated.intent,
    validated.summary.createdAt,
  );
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

/// After a confirmed upload only the current heads are kept.
Future<void> _compactCurrentHistory(WorkspaceDatabase store) =>
    store._serial(() => store._transaction(store._journal.compact));

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
      // A cloud v5 snapshot replaces intent; this device's cache of the same
      // workspace and server stays. Format 4 already carries its own cache.
      final (
        data,
        staleServers,
      ) = plan.cloudBound && snapshot.version == cloudSnapshotVersion
          ? await _withLocalCache(store, snapshot.data)
          : (snapshot.data, const <String>[]);
      final workspaceId = snapshot.summary.workspaceId;
      // A cloud pull replaces data, not the installation: operations this
      // device executes keep their executor. A backup file may come from
      // another installation, so restoring one starts a new device identity.
      final local = store._db
          .select(
            'SELECT workspace_id,device_id FROM sync_identity WHERE singleton=1',
          )
          .single;
      final deviceId = plan.cloudBound
          ? local['device_id'] as String
          : newVpnId();
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
        for (final dynamic row in data[table] as List) {
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
      store._transaction(() {
        if (_backupStamp(store) != plan.stamp || plan._snapshot == null) {
          throw const BackupFailure(BackupIssue.changed);
        }
        _LocalChangeJournal.dropGuards(store._db);
        store._db.execute('DELETE FROM vpn_user_overlay');
        store._db.execute('DELETE FROM vpn_profile_overlay');
        store._db.execute('DELETE FROM vpn_overlay_state');
        store._db.execute('DELETE FROM servers');
        store._db.execute('DELETE FROM documents');
        store._vpnOverlay.invalidate();
        for (final table in ['servers', 'documents']) {
          for (final row in records[table]!) {
            store._db.execute(
              'INSERT INTO $table VALUES (${List.filled(row.length, '?').join(',')})',
              row,
            );
          }
        }
        // Publication guards need heads: one per entity of the restored state.
        final heads = store._journal.restart(owner, proof, entities);
        store._db.execute(
          "INSERT OR IGNORE INTO migrations VALUES ('legacy-vault-v1')",
        );
        if (plan.cloudBound) {
          store._db.execute(
            "INSERT INTO settings VALUES ('syncSnapshotBound',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [workspaceId],
          );
          for (final (key, value) in [
            (
              'syncSnapshotLocalSequence',
              plan.boundIntent == null ? '$heads' : '',
            ),
            ('syncSnapshotRemoteFileId', plan.remoteFileId!),
            ('syncSnapshotRemoteVersion', plan.remoteVersion!),
            ('syncSnapshotRemoteEtag', plan.remoteEtag ?? ''),
            ('syncSnapshotIntent', plan.boundIntent ?? snapshot.intent),
            ('syncSnapshotUnsupported', ''),
            ('syncCacheRefresh', jsonEncode(staleServers)),
          ]) {
            store._db.execute(
              'INSERT INTO settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
              [key, value],
            );
          }
        }
        // Whatever divergence was waiting is answered by this restore.
        store._db.execute(
          "INSERT INTO settings VALUES ('syncSnapshotDivergence','') ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        );
        // This installation's own work, received back from the cloud, is
        // not foreign: it continues without a review. A backup file always
        // starts a new device, so all its work is reviewed.
        store._db.execute(
          "INSERT INTO settings VALUES ('backupRestoredTargets',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [
            jsonEncode(
              _restoredTargets(
                data['documents'] as List,
                own: plan.cloudBound ? deviceId : null,
              ).toList()..sort(),
            ),
          ],
        );
        _LocalChangeJournal.installGuards(store._db);
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

/// Targets with unfinished work to review after a restore; work whose
/// executor is [own] is this device's and is left out.
Set<String> _restoredTargets(List<dynamic> documents, {String? own}) {
  final targets = <String>{};
  for (final dynamic row in documents) {
    if (row['id'] != 'vpn-workspace-v1') continue;
    final vpn = VpnWorkspace.decode(row['source'] as String);
    for (final user in vpn.users.where(
      (u) =>
          u.deleted &&
          !u.deletionComplete &&
          (own == null || u.deletion!['executor'] != own),
    )) {
      targets.addAll(
        (user.deletion!['targets'] as Map).entries
            .where((entry) => !vpnRevocationSettled(entry.value))
            .map((entry) => entry.key as String),
      );
    }
    for (final entry in vpn.servers.entries) {
      final record = entry.value;
      final operation = record['operation'];
      if (own != null &&
          operation is Map &&
          operation['executorDeviceId'] == own) {
        continue;
      }
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

/// A file backup is always format 4; a [cloud] snapshot may also be v5.
Future<_BackupSnapshot> _validateBackupInBackground(
  String source, {
  bool cloud = false,
}) => Isolate.run(() => _validateBackup(source, cloud: cloud));

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

_BackupSnapshot _validateBackup(String source, {bool cloud = false}) {
  try {
    if (utf8.encode(source).length > maxWorkspaceBackupBytes - 53) {
      throw const BackupFailure(BackupIssue.tooLarge);
    }
    final data = _backupJson(source) as Map<String, dynamic>;
    final version = data['version'];
    if (version != 4 &&
        !(cloud &&
            version is int &&
            cloudSnapshotReadableVersions.contains(version))) {
      throw const BackupFailure(BackupIssue.version);
    }
    final v5 = version == cloudSnapshotVersion;
    final keys = v5
        ? cloudSnapshotKeys
        : const {'version', 'createdAt', 'workspaceId', 'servers', 'documents'};
    if (data.length != keys.length || !data.keys.toSet().containsAll(keys)) {
      throw const FormatException();
    }
    if (v5) _checkCloudAuthor(data['author']);
    final workspaceId = data['workspaceId'] as String;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(workspaceId)) {
      throw const FormatException();
    }
    final createdAt = DateTime.parse(data['createdAt'] as String).toUtc();
    var users = 0;
    for (final table in ['servers', 'documents']) {
      final ids = <String>{};
      final records = data[table] as List;
      if (records.length > cloudSnapshotMaxRecords) {
        throw const FormatException();
      }
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
        if (v5) _checkCloudRecord(table, id, source);
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
      _intentDigest(data),
    );
  } on BackupFailure {
    rethrow;
  } catch (_) {
    throw const BackupFailure(BackupIssue.invalid);
  }
}
