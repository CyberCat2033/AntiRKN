part of 'workspace_database.dart';

// Logical snapshots contain plaintext only in memory. Neither a live SQLite
// file, its encryption key nor device-local preferences enter the archive.
final class _BackupSnapshot {
  _BackupSnapshot(this.data, this.summary, this.heads);
  final Map<String, dynamic> data;
  final BackupSummary summary;
  final Map<_EntityKey, ChangeHeader> heads;
  List<dynamic> get servers => data['servers'] as List;
  List<dynamic> get documents => data['documents'] as List;
  List<dynamic> get changes => data['changes'] as List;
  List<dynamic> get outbox => data['outbox'] as List;
  @override
  String toString() => 'BackupSnapshot(<redacted>)';
}

final class _RestorePlan implements WorkspaceRestorePlan {
  _RestorePlan(this.owner, this.stamp, _BackupSnapshot snapshot)
    : _snapshot = snapshot,
      summary = snapshot.summary;
  final WorkspaceDatabase owner;
  final String stamp;
  _BackupSnapshot? _snapshot;
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
  ...store._db.select('SELECT change_id FROM sync_outbox ORDER BY change_id'),
  ...store._db.select('SELECT hex(payload) AS key_stamp FROM sync_keys'),
  ...store._db.select('SELECT COUNT(*) AS packets FROM sync_packets'),
  ...store._db.select('SELECT epoch FROM sync_merge_meta'),
  ...store._db.select(
    'SELECT change_id,state FROM sync_incoming ORDER BY change_id',
  ),
]);

Future<Uint8List> _createBackup(
  WorkspaceDatabase store,
  String password,
) async {
  try {
    final snapshot = await store._serial(() async {
      // Capture ALL ciphertext from the same SQLite read snapshot. No await
      // holds a transaction while another process needs the database.
      final captured = <String, List<Row>>{};
      store._db.execute('BEGIN');
      try {
        store._journal.checkIdentity();
        final size = store._db.select('''
          SELECT (SELECT COALESCE(SUM(length(payload)),0) FROM servers)
            + (SELECT COALESCE(SUM(length(payload)),0) FROM documents)
            + (SELECT COALESCE(SUM(length(payload)+length(header)),0) FROM sync_changes)
            + (SELECT COALESCE(SUM(length(payload)+length(header)),0) FROM sync_incoming) AS bytes,
            (SELECT COUNT(*) FROM sync_changes) AS changes
        ''').single;
        final packetBytes =
            store._db
                    .select(
                      'SELECT COALESCE(SUM(length(payload)),0) AS bytes FROM sync_packets',
                    )
                    .single['bytes']
                as int;
        if ((size['bytes'] as int) + packetBytes * 4 ~/ 3 >
                maxWorkspaceBackupBytes ||
            (size['changes'] as int) > 200000) {
          throw const BackupFailure(BackupIssue.tooLarge);
        }
        for (final (name, sql) in [
          ('servers', 'SELECT * FROM servers ORDER BY id'),
          ('documents', 'SELECT * FROM documents ORDER BY id'),
          ('changes', 'SELECT * FROM sync_changes ORDER BY sequence'),
          ('outbox', 'SELECT change_id FROM sync_outbox ORDER BY change_id'),
          ('heads', 'SELECT * FROM sync_heads ORDER BY entity_kind,entity_id'),
          ('syncKey', 'SELECT payload FROM sync_keys WHERE singleton=1'),
          ('syncPackets', 'SELECT * FROM sync_packets ORDER BY change_id'),
          ('incoming', 'SELECT * FROM sync_incoming ORDER BY change_id'),
        ]) {
          captured[name] = store._db.select(sql);
        }
        store._db.execute('COMMIT');
      } catch (_) {
        store._db.execute('ROLLBACK');
        rethrow;
      }
      final data = <String, dynamic>{
        'version': 3,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'workspaceId': store._journal.identity.workspaceId,
        'servers': <Object?>[],
        'documents': <Object?>[],
        'changes': <Object?>[],
        'incoming': <Object?>[],
        'heads': [
          for (final row in captured['heads']!) Map<String, dynamic>.from(row),
        ],
        'outbox': [for (final row in captured['outbox']!) row['change_id']],
        'syncKey': jsonDecode(
          await store._decrypt(
            _WorkspaceSync.keyScope(store._journal.identity.workspaceId),
            1,
            captured['syncKey']!.single['payload'] as Uint8List,
          ),
        ),
        'syncPackets': [
          for (final row in captured['syncPackets']!)
            {
              'changeId': row['change_id'],
              'packet': base64Encode(row['payload'] as Uint8List),
            },
        ],
      };
      var sourceBytes = 0;
      for (final table in ['servers', 'documents']) {
        for (final row in captured[table]!) {
          final id = row['id'] as String;
          final source = await store._decrypt(
            table == 'servers' ? 'server:$id' : id,
            row['revision'] as int,
            row['payload'] as Uint8List,
          );
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
      for (final row in captured['changes']!) {
        final header = ChangeHeader.fromJson(
          jsonDecode(row['header'] as String) as Map<String, dynamic>,
        );
        if (header.changeId != row['change_id'] ||
            header.sequence != row['sequence']) {
          throw const BackupFailure(BackupIssue.invalid);
        }
        final body =
            jsonDecode(
                  await store._decrypt(
                    _LocalChangeJournal._scope(header),
                    1,
                    row['payload'] as Uint8List,
                  ),
                )
                as Map;
        if (body.length != 1 || !body.containsKey('source')) {
          throw const BackupFailure(BackupIssue.invalid);
        }
        final source = body['source'] as String?;
        sourceBytes += source == null ? 0 : utf8.encode(source).length;
        if (sourceBytes > maxWorkspaceBackupBytes) {
          throw const BackupFailure(BackupIssue.tooLarge);
        }
        (data['changes'] as List).add({
          'header': header.toJson(),
          'source': source,
        });
      }
      for (final row in captured['incoming']!) {
        final h = ChangeHeader.fromJson(
          jsonDecode(row['header'] as String) as Map<String, dynamic>,
        );
        final body =
            jsonDecode(
                  await store._decrypt(
                    _LocalChangeJournal._scope(h),
                    1,
                    row['payload'] as Uint8List,
                  ),
                )
                as Map;
        if (h.changeId != row['change_id'] ||
            body.length != 1 ||
            !body.containsKey('source')) {
          throw const BackupFailure(BackupIssue.invalid);
        }
        (data['incoming'] as List).add({
          'header': h.toJson(),
          'source': body['source'],
          'state': row['state'],
        });
      }
      final source = jsonEncode(data);
      final checked = await _validateBackupInBackground(source);
      // A malformed local head must not silently become a valid backup.
      final actualHeads = [
        for (final row in captured['heads']!) Map<String, dynamic>.from(row),
      ];
      final expectedHeads =
          [
            for (final h in checked.heads.values)
              {
                'entity_kind': h.entityKind.name,
                'entity_id': h.entityId,
                'revision': h.revision,
                'change_id': h.changeId,
                'deleted': h.deleted ? 1 : 0,
              },
          ]..sort(
            (a, b) => '${a['entity_kind']}:${a['entity_id']}'.compareTo(
              '${b['entity_kind']}:${b['entity_id']}',
            ),
          );
      if (canonicalJson(actualHeads) != canonicalJson(expectedHeads)) {
        throw const BackupFailure(BackupIssue.invalid);
      }
      return source;
    });
    return await BackupEnvelope.seal(snapshot, password);
  } on BackupFailure {
    rethrow;
  } catch (_) {
    throw const BackupFailure(BackupIssue.storage);
  }
}

Future<WorkspaceRestorePlan> _prepareRestore(
  WorkspaceDatabase store,
  Uint8List bytes,
  String password,
) async {
  // Bind the preview to the destination BEFORE expensive decryption. An edit
  // during preparation or while the confirmation dialog is open invalidates it.
  final stamp = await store._serial(() => _backupStamp(store));
  final source = await BackupEnvelope.open(bytes, password);
  final snapshot = await _validateBackupInBackground(source);
  return _RestorePlan(store, stamp, snapshot);
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
      final proof = await store._encrypt(
        'journal-identity',
        1,
        canonicalJson({
          'version': 1,
          'workspaceId': snapshot.summary.workspaceId,
          'deviceId': deviceId,
        }),
      );
      final records = <String, List<List<Object?>>>{
        'servers': [],
        'documents': [],
        'changes': [],
        'incoming': [],
      };
      final syncKeyPayload = await store._encrypt(
        _WorkspaceSync.keyScope(snapshot.summary.workspaceId),
        1,
        canonicalJson(snapshot.data['syncKey'] ?? await _newSyncKey()),
      );
      for (final table in ['servers', 'documents']) {
        for (final dynamic row in snapshot.data[table] as List) {
          final id = row['id'] as String, revision = row['revision'] as int;
          records[table]!.add([
            id,
            await store._encrypt(
              table == 'servers' ? 'server:$id' : id,
              revision,
              row['source'] as String,
            ),
            revision,
            if (table == 'servers') row['updatedAt'],
          ]);
        }
      }
      for (final dynamic row in snapshot.changes) {
        final h = ChangeHeader.fromJson(row['header'] as Map<String, dynamic>);
        records['changes']!.add([
          h.changeId,
          h.sequence,
          canonicalJson(h.toJson()),
          await store._encrypt(
            _LocalChangeJournal._scope(h),
            1,
            jsonEncode({'source': row['source']}),
          ),
        ]);
      }
      for (final dynamic row in snapshot.data['incoming'] as List? ?? []) {
        final h = ChangeHeader.fromJson(row['header'] as Map<String, dynamic>);
        records['incoming']!.add([
          h.changeId,
          canonicalJson(h.toJson()),
          await store._encrypt(
            _LocalChangeJournal._scope(h),
            1,
            jsonEncode({'source': row['source']}),
          ),
          row['state'],
        ]);
      }
      store._transaction(() {
        if (_backupStamp(store) != plan.stamp || plan._snapshot == null) {
          throw const BackupFailure(BackupIssue.changed);
        }
        store._db.execute('DELETE FROM servers');
        store._db.execute('DELETE FROM documents');
        for (final table in ['servers', 'documents']) {
          for (final action in ['insert', 'update', 'delete']) {
            store._db.execute('DROP TRIGGER journal_guard_${table}_$action');
          }
        }
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
        for (final table in ['servers', 'documents']) {
          for (final action in ['insert', 'update', 'delete']) {
            store._db.execute('DROP TRIGGER journal_guard_${table}_$action');
            store._db.execute(_LocalChangeJournal._guard(table, action));
          }
        }
        _WorkspaceSync.installSchema(store._db);
        _WorkspaceMerge.installSchema(store._db);
        store._db.execute('INSERT INTO sync_keys VALUES (1,?)', [
          syncKeyPayload,
        ]);
        store._db.execute(
          'INSERT INTO sync_identity VALUES (1, ?, ?, ?, ?, 1, ?, 5)',
          [
            snapshot.summary.workspaceId,
            deviceId,
            snapshot.changes.length,
            proof,
            deviceId,
          ],
        );
        for (final table in ['servers', 'documents', 'changes', 'incoming']) {
          for (final row in records[table]!) {
            store._db.execute(
              'INSERT INTO ${table == 'changes'
                  ? 'sync_changes'
                  : table == 'incoming'
                  ? 'sync_incoming'
                  : table} VALUES (${List.filled(row.length, '?').join(',')})',
              row,
            );
          }
        }
        for (final h in snapshot.heads.values) {
          store._db.execute('INSERT INTO sync_heads VALUES (?,?,?,?,?)', [
            h.entityKind.name,
            h.entityId,
            h.revision,
            h.changeId,
            h.deleted ? 1 : 0,
          ]);
        }
        final restoredGraph = _snapshotGraph(snapshot.data);
        final restoredProjection = _projectMerge(restoredGraph, {
          for (final e in snapshot.heads.entries) e.key: e.value.changeId,
        });
        for (final entry in restoredGraph.tips.entries) {
          for (final id in entry.value) {
            store._db.execute('INSERT INTO sync_branches VALUES (?,?,?)', [
              entry.key.$1.name,
              entry.key.$2,
              id,
            ]);
          }
        }
        for (final key in restoredProjection.conflicts) {
          store._db.execute('INSERT INTO sync_conflicts VALUES (?,?)', [
            key.$1.name,
            key.$2,
          ]);
        }
        for (final id in snapshot.outbox) {
          store._db.execute('INSERT INTO sync_outbox VALUES (?)', [id]);
        }
        for (final dynamic record
            in snapshot.data['syncPackets'] as List? ?? []) {
          store._db.execute('INSERT INTO sync_packets VALUES (?,?)', [
            record['changeId'],
            base64Decode(record['packet'] as String),
          ]);
        }
        // Do not reimport an obsolete local vault after restoring another copy.
        store._db.execute(
          "INSERT OR IGNORE INTO migrations VALUES ('legacy-vault-v1')",
        );
        final restoredTargets = <String>{};
        for (final dynamic row in snapshot.documents) {
          if (row['id'] == 'vpn-workspace-v1') {
            final vpn = VpnWorkspace.decode(row['source'] as String);
            for (final entry in vpn.servers.entries) {
              final record = entry.value;
              if (record['pending'] != null ||
                  record['cancelRequested'] == true ||
                  record['observingCancel'] == true ||
                  record['authorizedPayload'] != null &&
                      record['authorizedPayload'] != record['appliedPayload']) {
                restoredTargets.add(entry.key);
              }
            }
          }
        }
        store._db.execute(
          "INSERT INTO settings VALUES ('backupRestoredTargets',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [jsonEncode(restoredTargets.toList()..sort())],
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

// Limit nesting before jsonDecode, including JSON strings embedded in records.
// Keep this closure outside database methods: a shared closure context must
// never capture the unsendable native SQLite handle.
Future<_BackupSnapshot> _validateBackupInBackground(String source) =>
    Isolate.run(() async {
      final snapshot = _validateBackup(source);
      await _validateBackupPackets(snapshot);
      return snapshot;
    });

Future<void> _validateBackupPackets(_BackupSnapshot snapshot) async {
  if (snapshot.data['version'] == 1) return;
  _SyncKey? key;
  try {
    key = _decodeSyncKey(snapshot.data['syncKey']);
    final codec = SyncPacketCodec(
      workspaceId: snapshot.summary.workspaceId,
      keyVersion: key.version,
      key: key.secret,
    );
    final events = {
      for (final dynamic record in snapshot.changes)
        (record['header'] as Map)['changeId']: record,
    };
    final ids = <String>{};
    for (final dynamic record in snapshot.data['syncPackets'] as List) {
      final value = record as Map;
      final id = value['changeId'] as String;
      final event = events[id];
      if (value.length != 2 || !ids.add(id) || event == null) {
        throw const FormatException();
      }
      final encoded = value['packet'] as String;
      if (encoded.length > (syncMaxPacketBytes + 2) ~/ 3 * 4) {
        throw const FormatException();
      }
      final bytes = base64Decode(encoded);
      if (base64Encode(bytes) != encoded) throw const FormatException();
      final change = await codec.open(bytes);
      if (canonicalJson(change.header.toJson()) !=
              canonicalJson(event['header']) ||
          change.source != event['source']) {
        throw const FormatException();
      }
    }
  } catch (_) {
    throw const BackupFailure(BackupIssue.invalid);
  } finally {
    key?.dispose();
  }
}

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
    if (![1, 2, 3].contains(data['version'])) {
      throw const BackupFailure(BackupIssue.version);
    }
    if (data.length !=
        (data['version'] == 1
            ? 7
            : data['version'] == 2
            ? 9
            : 11)) {
      throw const FormatException();
    }
    final workspaceId = data['workspaceId'] as String;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(workspaceId)) {
      throw const FormatException();
    }
    final createdAt = DateTime.parse(data['createdAt'] as String).toUtc();
    final entities = <_EntityKey, _EntitySnapshot>{
      (ChangeEntityKind.workspace, workspaceId): _EntitySnapshot(
        canonicalJson({'id': workspaceId}),
      ),
    };
    var users = 0;
    for (final table in ['servers', 'documents']) {
      final ids = <String>{};
      for (final dynamic row in data[table] as List) {
        final record = row as Map<String, dynamic>;
        if (record.length != (table == 'servers' ? 4 : 3)) {
          throw const FormatException();
        }
        final id = record['id'] as String, revision = record['revision'] as int;
        final text = record['source'] as String;
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
              utf8.encode(text).length > 256 * 1024) {
            throw const FormatException();
          }
          final profile = decodeProfile(
            _backupJson(text) as Map<String, Object?>,
          );
          if (profile.id != id) throw const FormatException();
          entities.addAll(_serverEntities(id, text));
        } else {
          if (id != 'template-draft' &&
              id != 'vpn-workspace-v1' &&
              !id.startsWith('runner/')) {
            throw const BackupFailure(BackupIssue.version);
          }
          if (utf8.encode(text).length >
              (id == 'vpn-workspace-v1' ? 8 * 1024 * 1024 : 256 * 1024)) {
            throw const FormatException();
          }
          if (id != 'template-draft') _backupJson(text);
          if (id == 'vpn-workspace-v1') {
            final vpn = VpnWorkspace.decode(text);
            if (vpn.id != workspaceId) throw const FormatException();
            users = vpn.users.length;
          }
          entities.addAll(_documentEntities(id, text));
        }
      }
    }
    if (data['version'] == 3) {
      return _validateMergeBackup(data, entities, createdAt, users);
    }
    final heads = <_EntityKey, ChangeHeader>{};
    final latest = <_EntityKey, _EntitySnapshot>{};
    final ids = <String>{}, transactions = <String>{};
    ChangeHeader? previous;
    final changes = data['changes'] as List;
    if (changes.isEmpty || changes.length > 200000) {
      throw const FormatException();
    }
    for (var i = 0; i < changes.length; i++) {
      final row = changes[i] as Map<String, dynamic>;
      if (row.length != 2 || !row.containsKey('source')) {
        throw const FormatException();
      }
      final h = ChangeHeader.fromJson(row['header'] as Map<String, dynamic>);
      final text = row['source'] as String?;
      if (h.workspaceId != workspaceId ||
          h.sequence != i + 1 ||
          !ids.add(h.changeId) ||
          (text == null && !h.deleted)) {
        throw const FormatException();
      }
      final key = (h.entityKind, h.entityId),
          base = heads[(h.entityKind, h.entityId)];
      if (h.baseRevision != (base?.revision ?? 0) ||
          h.baseChangeId != base?.changeId) {
        throw const FormatException();
      }
      if (h.transactionIndex == 0) {
        if (!transactions.add(h.transactionId) ||
            (previous != null &&
                previous.transactionIndex + 1 != previous.transactionSize)) {
          throw const FormatException();
        }
      } else if (previous == null ||
          previous.transactionId != h.transactionId ||
          previous.deviceId != h.deviceId ||
          previous.transactionIndex + 1 != h.transactionIndex ||
          previous.transactionSize != h.transactionSize) {
        throw const FormatException();
      }
      if (text == null) {
        latest.remove(key);
      } else {
        latest[key] = _EntitySnapshot(text, deleted: h.deleted);
      }
      heads[key] = h;
      previous = h;
    }
    if (previous!.transactionIndex + 1 != previous.transactionSize ||
        latest.length != entities.length) {
      throw const FormatException();
    }
    for (final entry in entities.entries) {
      if (latest[entry.key]?.source != entry.value.source ||
          latest[entry.key]?.deleted != entry.value.deleted) {
        throw const FormatException();
      }
    }
    final outbox = data['outbox'] as List;
    if (outbox.toSet().length != outbox.length ||
        outbox.any((id) => id is! String || !ids.contains(id))) {
      throw const FormatException();
    }
    return _BackupSnapshot(
      data,
      BackupSummary(
        createdAt: createdAt,
        workspaceId: workspaceId,
        servers: (data['servers'] as List).length,
        users: users,
        changes: changes.length,
        pending: outbox.length,
      ),
      heads,
    );
  } on BackupFailure {
    rethrow;
  } catch (_) {
    throw const BackupFailure(BackupIssue.invalid);
  }
}

LocalChange _snapshotEvent(dynamic row) => LocalChange(
  header: ChangeHeader.fromJson(row['header'] as Map<String, dynamic>),
  source: row['source'] as String?,
);
CausalGraph _snapshotGraph(Map<String, dynamic> data) => CausalGraph([
  for (final row in data['changes'] as List) _snapshotEvent(row),
  for (final dynamic row in data['incoming'] as List? ?? [])
    if (row['state'] == 1) _snapshotEvent(row),
]);

_BackupSnapshot _validateMergeBackup(
  Map<String, dynamic> data,
  _Entities actual,
  DateTime createdAt,
  int users,
) {
  final local = data['changes'] as List, remote = data['incoming'] as List;
  if (local.isEmpty || local.length + remote.length > 200000) {
    throw const FormatException();
  }
  final all = <String, LocalChange>{}, accepted = <String, LocalChange>{};
  for (final (rows, incoming) in [(local, false), (remote, true)]) {
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i] as Map<String, dynamic>,
          event = _snapshotEvent(rows[i]),
          h = event.header;
      if (row.length != (incoming ? 3 : 2) ||
          !row.containsKey('source') ||
          h.workspaceId != data['workspaceId'] ||
          all.containsKey(h.changeId) ||
          (!incoming && h.sequence != i + 1) ||
          (incoming && ![0, 1, 2, 3].contains(row['state']))) {
        throw const FormatException();
      }
      _validateSyncChange(event);
      all[h.changeId] = event;
      if (!incoming || row['state'] == 1) accepted[h.changeId] = event;
    }
  }
  _validateEventIdentities(all.values);
  final groups = <String, List<LocalChange>>{};
  for (final e in accepted.values) {
    groups.putIfAbsent(e.header.transactionId, () => []).add(e);
  }
  if (groups.values.any((g) => g.length != g.first.header.transactionSize)) {
    throw const FormatException();
  }
  final graph = CausalGraph(accepted.values);
  final preferred = <_EntityKey, String>{};
  for (final dynamic row in data['heads'] as List) {
    final key = (
          ChangeEntityKind.values.byName(row['entity_kind'] as String),
          row['entity_id'] as String,
        ),
        id = row['change_id'] as String;
    final h = graph.events[id]?.header;
    if (row.length != 5 ||
        preferred.containsKey(key) ||
        h == null ||
        !graph.tips[key]!.contains(id) ||
        h.revision != row['revision'] ||
        (h.deleted ? 1 : 0) != row['deleted']) {
      throw const FormatException();
    }
    preferred[key] = id;
  }
  if (preferred.length != graph.tips.length) throw const FormatException();
  final projection = _projectMerge(graph, preferred);
  final docs = _materializedDocuments(
    projection.entities,
    data['workspaceId'] as String,
    projection.heads,
  );
  final expected = <_EntityKey, _EntitySnapshot>{
    (ChangeEntityKind.workspace, data['workspaceId'] as String):
        _EntitySnapshot(canonicalJson({'id': data['workspaceId']})),
    for (final e in projection.entities.entries.where(
      (e) => e.key.$1 == ChangeEntityKind.server,
    ))
      e.key: e.value,
    for (final e in docs.entries) ..._documentEntities(e.key, e.value),
  };
  if (expected.length != actual.length) throw const FormatException();
  for (final e in expected.entries) {
    final found = actual[e.key];
    if (found == null ||
        found.deleted != e.value.deleted ||
        (e.key.$1 == ChangeEntityKind.template
            ? found.source != e.value.source
            : canonicalJson(_backupJson(found.source)) !=
                  canonicalJson(_backupJson(e.value.source)))) {
      throw const FormatException();
    }
  }
  final outbox = data['outbox'] as List,
      localIds = local.map((dynamic row) => row['header']['changeId']).toSet();
  if (outbox.toSet().length != outbox.length ||
      outbox.any((id) => !localIds.contains(id))) {
    throw const FormatException();
  }
  return _BackupSnapshot(
    data,
    BackupSummary(
      createdAt: createdAt,
      workspaceId: data['workspaceId'] as String,
      servers: (data['servers'] as List).length,
      users: users,
      changes: all.length,
      pending: outbox.length,
    ),
    projection.heads,
  );
}
