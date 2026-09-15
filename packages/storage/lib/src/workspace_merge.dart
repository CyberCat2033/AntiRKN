part of 'workspace_database.dart';

final class _MergeProjection {
  _MergeProjection(this.entities, this.heads, this.conflicts);
  final _Entities entities;
  final Map<_EntityKey, ChangeHeader> heads;
  final Set<_EntityKey> conflicts;
}

final class _WorkspaceMerge {
  _WorkspaceMerge(this.store);
  final WorkspaceDatabase store;
  Database get db => store._db;
  bool _ready = false;
  static final ddl = [
    'CREATE TABLE sync_incoming (change_id TEXT PRIMARY KEY, header TEXT NOT NULL, payload BLOB NOT NULL, state INTEGER NOT NULL CHECK(state IN (0,1,2,3)))',
    "CREATE TRIGGER sync_incoming_immutable BEFORE UPDATE OF change_id,header,payload ON sync_incoming BEGIN SELECT RAISE(ABORT, 'immutable_change'); END",
    'CREATE TABLE sync_branches (entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, change_id TEXT NOT NULL, PRIMARY KEY(entity_kind,entity_id,change_id))',
    'CREATE TABLE sync_conflicts (entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, PRIMARY KEY(entity_kind,entity_id))',
    'CREATE TABLE sync_merge_meta (singleton INTEGER PRIMARY KEY CHECK(singleton=1), epoch INTEGER NOT NULL)',
    'INSERT INTO sync_merge_meta VALUES (1,0)',
  ];
  static void installSchema(Database db) {
    // A head can now refer to an event in either immutable journal.
    db.execute(
      'CREATE TABLE sync_heads_new (entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), change_id TEXT NOT NULL, deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), PRIMARY KEY(entity_kind,entity_id))',
    );
    db.execute('INSERT INTO sync_heads_new SELECT * FROM sync_heads');
    db.execute('DROP TABLE sync_heads');
    db.execute('ALTER TABLE sync_heads_new RENAME TO sync_heads');
    for (final sql in ddl) {
      db.execute(sql);
    }
    db.execute(
      'INSERT INTO sync_branches SELECT entity_kind,entity_id,change_id FROM sync_heads',
    );
    for (final table in ['servers', 'documents']) {
      for (final action in ['insert', 'update', 'delete']) {
        db.execute('DROP TRIGGER journal_guard_${table}_$action');
        db.execute(
          "CREATE TRIGGER journal_guard_${table}_$action BEFORE $action ON $table WHEN (SELECT write_guard != 1 OR writer_device IS NOT device_id OR writer_version != 5 FROM sync_identity WHERE singleton=1) BEGIN SELECT RAISE(ABORT, 'journal_writer_required'); END",
        );
      }
    }
  }

  Future<void> initialize() async {
    if (_ready) return;
    if (db.userVersion == 4) {
      db.execute('BEGIN IMMEDIATE');
      try {
        store._journal.checkIdentity();
        if (db.userVersion == 4) {
          installSchema(db);
          db.userVersion = 5;
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
    if (db.userVersion != 5) throw const VaultFailure(VaultIssue.corrupt);
    _ready = true;
  }

  String stamp() => jsonEncode([
    db.select('SELECT sequence FROM sync_identity').single['sequence'],
    db.select('SELECT epoch FROM sync_merge_meta').single['epoch'],
  ]);
  void checkStamp(String expected) {
    if (stamp() != expected) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
  }

  void advance() => db.execute('UPDATE sync_merge_meta SET epoch=epoch+1');

  Future<Map<String, LocalChange>> events({bool includeWaiting = false}) async {
    final result = <String, LocalChange>{};
    for (final table in ['sync_changes', 'sync_incoming']) {
      final rows = db.select(
        'SELECT change_id,header,payload FROM $table ${table == 'sync_incoming' && !includeWaiting ? 'WHERE state=1' : ''}',
      );
      for (final row in rows) {
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
            h.workspaceId != store._journal.identity.workspaceId ||
            body.length != 1 ||
            !body.containsKey('source') ||
            (body['source'] == null && !h.deleted) ||
            result.containsKey(h.changeId)) {
          throw const SyncMergeFailure(SyncMergeIssue.invalid);
        }
        result[h.changeId] = LocalChange(
          header: h,
          source: body['source'] as String?,
        );
      }
    }
    return result;
  }

  Map<_EntityKey, String> preferredHeads() => {
    for (final r in db.select('SELECT * FROM sync_heads'))
      (
        ChangeEntityKind.values.byName(r['entity_kind'] as String),
        r['entity_id'] as String,
      ): r['change_id'] as String,
  };

  Future<SyncMergeStatus> receive(List<Uint8List> packets) async {
    final expected = stamp();
    final known = await events(includeWaiting: true);
    final added = <LocalChange>[];
    for (final packet in packets) {
      final event = await store._sync.verify(packet);
      _validateSyncChange(event);
      final old = known[event.header.changeId];
      if (old != null) {
        if (!_sameChange(old, event)) {
          throw const SyncMergeFailure(SyncMergeIssue.invalid);
        }
      } else {
        known[event.header.changeId] = event;
        added.add(event);
      }
    }
    _validateEventIdentities(known.values);
    if (known.length > 200000) {
      throw const SyncMergeFailure(SyncMergeIssue.limit);
    }
    final encrypted = <(LocalChange, Uint8List)>[];
    for (final event in added) {
      encrypted.add((
        event,
        await store._encrypt(
          _LocalChangeJournal._scope(event.header),
          1,
          jsonEncode({'source': event.source}),
        ),
      ));
    }
    store._transaction(() {
      checkStamp(expected);
      for (final (event, payload) in encrypted) {
        db.execute('INSERT INTO sync_incoming VALUES (?,?,?,0)', [
          event.header.changeId,
          canonicalJson(event.header.toJson()),
          payload,
        ]);
      }
      if (encrypted.isNotEmpty) advance();
    });
    await drain();
    return status();
  }

  Future<void> drain() async {
    var again = true;
    while (again) {
      again = false;
      final expected = stamp();
      final all = await events(includeWaiting: true);
      final accepted = await events();
      final rejectedIds = db
          .select('SELECT change_id FROM sync_incoming WHERE state=3')
          .map((r) => r['change_id'])
          .toSet();
      final pending = <String, List<LocalChange>>{};
      for (final e in all.values.where(
        (e) =>
            !accepted.containsKey(e.header.changeId) &&
            !rejectedIds.contains(e.header.changeId),
      )) {
        pending.putIfAbsent(e.header.transactionId, () => []).add(e);
      }
      for (final group in pending.values) {
        group.sort(
          (a, b) =>
              a.header.transactionIndex.compareTo(b.header.transactionIndex),
        );
        if (group.length != group.first.header.transactionSize) continue;
        final groupIds = group.map((e) => e.header.changeId).toSet();
        if (group.any(
          (e) => e.header.parents.any(
            (p) => !accepted.containsKey(p) && !groupIds.contains(p),
          ),
        )) {
          continue;
        }
        final next = {...accepted, for (final e in group) e.header.changeId: e};
        _MergeProjection projection;
        CausalGraph graph;
        try {
          graph = CausalGraph(next.values);
          projection = _projectMerge(graph, preferredHeads());
          _materializedDocuments(
            projection.entities,
            store._journal.identity.workspaceId,
            projection.heads,
          );
        } on FormatException {
          store._transaction(() {
            checkStamp(expected);
            for (final e in group) {
              db.execute('UPDATE sync_incoming SET state=2 WHERE change_id=?', [
                e.header.changeId,
              ]);
            }
          });
          continue;
        } on SyncMergeFailure catch (e) {
          final failureState = e.issue == SyncMergeIssue.limit ? 2 : 3;
          store._transaction(() {
            checkStamp(expected);
            for (final e in group) {
              db.execute('UPDATE sync_incoming SET state=? WHERE change_id=?', [
                failureState,
                e.header.changeId,
              ]);
            }
          });
          continue;
        }
        final writes = await prepareWrites(projection);
        store._transaction(() {
          checkStamp(expected);
          for (final e in group) {
            db.execute('UPDATE sync_incoming SET state=1 WHERE change_id=?', [
              e.header.changeId,
            ]);
          }
          commitProjection(graph, projection, writes);
          advance();
        });
        again = true;
        break;
      }
    }
  }

  Future<SyncMergeStatus> status() async {
    final expected = stamp();
    final graph = CausalGraph((await events()).values);
    final conflicts = <SyncConflict>[];
    for (final row in db.select(
      'SELECT * FROM sync_conflicts ORDER BY entity_kind,entity_id',
    )) {
      final key = (
        ChangeEntityKind.values.byName(row['entity_kind'] as String),
        row['entity_id'] as String,
      );
      final ids = graph.tips[key]!;
      conflicts.add(
        SyncConflict(
          kind: key.$1,
          entityId: key.$2,
          variants: ids.map((id) => graph.events[id]!).toList(),
          ancestor: graph.commonAncestor(ids),
        ),
      );
    }
    final all = await events(includeWaiting: true);
    final blockedChanges = <LocalChange>[];
    final missing = <String>{},
        waiting = <String>{},
        blocked = <String>{},
        rejected = <String>{};
    for (final row in db.select(
      'SELECT change_id,state FROM sync_incoming WHERE state!=1',
    )) {
      final event = all[row['change_id']]!;
      if (row['state'] == 3) {
        rejected.add(event.header.transactionId);
        continue;
      }
      (row['state'] == 2 ? blocked : waiting).add(event.header.transactionId);
      if (row['state'] == 2) blockedChanges.add(event);
      missing.addAll(event.header.parents.where((id) => !all.containsKey(id)));
    }
    checkStamp(expected);
    return SyncMergeStatus(
      conflicts: conflicts,
      missingChangeIds: missing.toList()..sort(),
      waitingGroups: waiting.length,
      blockedGroups: blocked.length,
      rejectedGroups: rejected.length,
      blockedChanges: blockedChanges,
    );
  }

  Future<void> resolve(SyncConflict conflict, String choice) async {
    final expected = stamp();
    final graph = CausalGraph((await events()).values);
    final key = (conflict.kind, conflict.entityId);
    final ids = graph.tips[key] ?? [];
    if (canonicalJson(ids) != canonicalJson(conflict.changeIds) ||
        !ids.contains(choice) ||
        db.select(
          'SELECT 1 FROM sync_conflicts WHERE entity_kind=? AND entity_id=?',
          [key.$1.name, key.$2],
        ).isEmpty) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
    final chosen = graph.events[choice]!;
    final parents = ids.map((id) => graph.events[id]!.header).toList()
      ..sort(
        (a, b) => b.revision == a.revision
            ? a.changeId.compareTo(b.changeId)
            : b.revision.compareTo(a.revision),
      );
    final identity = store._journal.identity;
    final sequence =
        db.select('SELECT sequence FROM sync_identity').single['sequence']
            as int;
    final header = ChangeHeader(
      workspaceId: identity.workspaceId,
      deviceId: identity.deviceId,
      changeId: newVpnId(),
      sequence: sequence + 1,
      transactionId: newVpnId(),
      transactionIndex: 0,
      transactionSize: 1,
      entityKind: key.$1,
      entityId: key.$2,
      baseChangeId: parents.first.changeId,
      baseRevision: parents.first.revision,
      revision: parents.first.revision + 1,
      deleted: chosen.header.deleted,
      schemaVersion: 2,
      mergeParents: parents.skip(1).map((h) => h.changeId).toList(),
    );
    final event = LocalChange(header: header, source: chosen.source);
    final next = CausalGraph([...graph.events.values, event]);
    final projection = _projectMerge(next, preferredHeads());
    final writes = await prepareWrites(projection);
    final payload = await store._encrypt(
      _LocalChangeJournal._scope(header),
      1,
      jsonEncode({'source': event.source}),
    );
    store._transaction(() {
      checkStamp(expected);
      db.execute('INSERT INTO sync_changes VALUES (?,?,?,?)', [
        header.changeId,
        header.sequence,
        canonicalJson(header.toJson()),
        payload,
      ]);
      db.execute('INSERT INTO sync_outbox VALUES (?)', [header.changeId]);
      db.execute('UPDATE sync_identity SET sequence=?', [header.sequence]);
      commitProjection(next, projection, writes);
      advance();
    });
    await drain();
  }

  Future<List<(String, String, int, Uint8List?)>> prepareWrites(
    _MergeProjection projection,
  ) async {
    final documents = _materializedDocuments(
      projection.entities,
      store._journal.identity.workspaceId,
      projection.heads,
    );
    final sources = <String, Map<String, String>>{
      'servers': {
        for (final e in projection.entities.entries.where(
          (e) => e.key.$1 == ChangeEntityKind.server,
        ))
          e.key.$2: e.value.source,
      },
      'documents': documents,
    };
    final writes = <(String, String, int, Uint8List?)>[];
    for (final table in sources.keys) {
      final current = {
        for (final row in db.select('SELECT * FROM $table'))
          row['id'] as String: row,
      };
      for (final id in {...current.keys, ...sources[table]!.keys}) {
        final row = current[id], source = sources[table]![id];
        final revision = row?['revision'] as int? ?? 0;
        final old = row == null
            ? null
            : await store._decrypt(
                table == 'servers' ? 'server:$id' : id,
                revision,
                row['payload'] as Uint8List,
              );
        if (old == source ||
            (old != null &&
                source != null &&
                id != 'template-draft' &&
                canonicalJson(_backupJson(old)) ==
                    canonicalJson(_backupJson(source)))) {
          continue;
        }
        writes.add((
          table,
          id,
          revision + 1,
          source == null
              ? null
              : await store._encrypt(
                  table == 'servers' ? 'server:$id' : id,
                  revision + 1,
                  source,
                ),
        ));
      }
    }
    return writes;
  }

  void commitProjection(
    CausalGraph graph,
    _MergeProjection projection,
    List<(String, String, int, Uint8List?)> writes,
  ) {
    final changedTargets = <String>{};
    for (final entry in graph.tips.entries.where(
      (e) => e.key.$1 == ChangeEntityKind.vpnServerState,
    )) {
      final before = db
          .select(
            'SELECT change_id FROM sync_branches WHERE entity_kind=? AND entity_id=? ORDER BY change_id',
            [entry.key.$1.name, entry.key.$2],
          )
          .map((r) => r['change_id'])
          .toList();
      if (canonicalJson(before) != canonicalJson(entry.value)) {
        changedTargets.add(entry.key.$2);
      }
    }
    for (final (table, id, revision, payload) in writes) {
      if (payload == null) {
        db.execute('DELETE FROM $table WHERE id=?', [id]);
      } else if (table == 'servers') {
        db.execute(
          'INSERT INTO servers VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revision=excluded.revision,updated_at=excluded.updated_at',
          [id, payload, revision, DateTime.now().millisecondsSinceEpoch],
        );
      } else {
        db.execute(
          'INSERT INTO documents VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revision=excluded.revision',
          [id, payload, revision],
        );
      }
    }
    db.execute('DELETE FROM sync_heads');
    db.execute('DELETE FROM sync_branches');
    db.execute('DELETE FROM sync_conflicts');
    for (final h in projection.heads.values) {
      db.execute('INSERT INTO sync_heads VALUES (?,?,?,?,?)', [
        h.entityKind.name,
        h.entityId,
        h.revision,
        h.changeId,
        h.deleted ? 1 : 0,
      ]);
    }
    for (final e in graph.tips.entries) {
      for (final id in e.value) {
        db.execute('INSERT INTO sync_branches VALUES (?,?,?)', [
          e.key.$1.name,
          e.key.$2,
          id,
        ]);
      }
    }
    for (final key in projection.conflicts) {
      db.execute('INSERT INTO sync_conflicts VALUES (?,?)', [
        key.$1.name,
        key.$2,
      ]);
    }
    // Receiving an operation records intent, never permission to execute it.
    final targets = <String>{};
    final old = db.select(
      "SELECT value FROM settings WHERE key='backupRestoredTargets'",
    );
    if (old.isNotEmpty) {
      targets.addAll(
        List<String>.from(jsonDecode(old.single['value'] as String) as List),
      );
    }
    for (final entry in projection.entities.entries) {
      if (entry.key.$1 != ChangeEntityKind.vpnServerState ||
          !changedTargets.contains(entry.key.$2)) {
        continue;
      }
      final tips = graph.tips[entry.key]!;
      if (tips.any(
        (id) => db.select('SELECT 1 FROM sync_incoming WHERE change_id=?', [
          id,
        ]).isNotEmpty,
      )) {
        targets.add(entry.key.$2);
      }
    }
    db.execute(
      "INSERT INTO settings VALUES ('backupRestoredTargets',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      [jsonEncode(targets.toList()..sort())],
    );
  }
}

bool _sameChange(LocalChange a, LocalChange b) =>
    a.source == b.source &&
    canonicalJson(a.header.toJson()) == canonicalJson(b.header.toJson());

void _validateEventIdentities(Iterable<LocalChange> events) {
  final sequences = <(String, int), String>{},
      transactions = <String, List<ChangeHeader>>{};
  for (final e in events) {
    final h = e.header;
    if (sequences.containsKey((h.deviceId, h.sequence))) {
      throw const SyncMergeFailure(SyncMergeIssue.invalid);
    }
    sequences[(h.deviceId, h.sequence)] = h.changeId;
    transactions.putIfAbsent(h.transactionId, () => []).add(h);
  }
  for (final group in transactions.values) {
    final first = group.first;
    final indexes = <int>{}, entities = <_EntityKey>{};
    for (final h in group) {
      if (h.transactionSize > 10000 ||
          h.deviceId != first.deviceId ||
          h.transactionSize != first.transactionSize ||
          h.sequence - h.transactionIndex !=
              first.sequence - first.transactionIndex ||
          !indexes.add(h.transactionIndex) ||
          !entities.add((h.entityKind, h.entityId))) {
        throw const SyncMergeFailure(SyncMergeIssue.invalid);
      }
    }
  }
}

void _validateSyncChange(LocalChange e) {
  final h = e.header, text = e.source;
  if (h.entityKind == ChangeEntityKind.document ||
      (h.entityKind == ChangeEntityKind.template && h.entityId != 'default')) {
    throw const SyncMergeFailure(SyncMergeIssue.invalid);
  }
  if (text == null) {
    if (!h.deleted ||
        h.entityKind == ChangeEntityKind.workspace ||
        h.entityKind == ChangeEntityKind.vpnWorkspace) {
      throw const SyncMergeFailure(SyncMergeIssue.invalid);
    }
    return;
  }
  if (utf8.encode(text).length >
      ([
            ChangeEntityKind.template,
            ChangeEntityKind.server,
            ChangeEntityKind.runnerState,
          ].contains(h.entityKind)
          ? 256 * 1024
          : 8 * 1024 * 1024)) {
    throw const SyncMergeFailure(SyncMergeIssue.limit);
  }
  if (h.entityKind == ChangeEntityKind.template) {
    if (h.entityId != 'default' || h.deleted) {
      throw const SyncMergeFailure(SyncMergeIssue.invalid);
    }
    return;
  }
  try {
    final data = _backupJson(text) as Map<String, dynamic>;
    switch (h.entityKind) {
      case ChangeEntityKind.server:
        if (decodeProfile(data).id != h.entityId || h.deleted) {
          throw const FormatException();
        }
      case ChangeEntityKind.workspace:
        if (canonicalJson(data) != canonicalJson({'id': h.workspaceId}) ||
            h.entityId != h.workspaceId ||
            h.deleted) {
          throw const FormatException();
        }
      case ChangeEntityKind.vpnWorkspace:
        if (data['id'] != h.workspaceId ||
            h.entityId != h.workspaceId ||
            h.deleted ||
            ![1, 2, 3].contains(data['version'])) {
          throw const FormatException();
        }
        for (final field in _vpnCollections.keys) {
          final ids = List<String>.from(data[field] as List? ?? []);
          if (ids.toSet().length != ids.length) throw const FormatException();
        }
      case ChangeEntityKind.vpnUser:
        if (VpnUser.fromJson(data).id != h.entityId || h.deleted) {
          throw const FormatException();
        }
      case ChangeEntityKind.vlessInbound:
        final resource = VlessInbound.fromJson(data);
        if (resource.id != h.entityId ||
            resource.spec['deleted'] != h.deleted) {
          throw const FormatException();
        }
      case ChangeEntityKind.awgInterface:
        final resource = AwgInterface.fromJson(data);
        if (resource.id != h.entityId ||
            resource.spec['deleted'] != h.deleted) {
          throw const FormatException();
        }
      case ChangeEntityKind.ttEndpoint:
        final resource = TrustTunnelEndpoint.fromJson(data);
        if (resource.id != h.entityId ||
            resource.spec['deleted'] != h.deleted) {
          throw const FormatException();
        }
      case ChangeEntityKind.runnerState:
        if (data['version'] != 1 || data['cursor'] is! int || h.deleted) {
          throw const FormatException();
        }
      case ChangeEntityKind.vpnServerState:
      case ChangeEntityKind.profile:
        if (h.deleted) throw const FormatException();
      case ChangeEntityKind.document:
      case ChangeEntityKind.template:
        throw const FormatException();
    }
  } catch (_) {
    throw const SyncMergeFailure(SyncMergeIssue.invalid);
  }
}

const _vpnCollections = {
  'users': ChangeEntityKind.vpnUser,
  'inbounds': ChangeEntityKind.vlessInbound,
  'awgInterfaces': ChangeEntityKind.awgInterface,
  'ttEndpoints': ChangeEntityKind.ttEndpoint,
  'servers': ChangeEntityKind.vpnServerState,
  'profiles': ChangeEntityKind.profile,
};

String? _mergeRoot(CausalGraph graph, List<String> ids) {
  final values = ids
      .map(
        (id) => _backupJson(graph.events[id]!.source!) as Map<String, dynamic>,
      )
      .toList();
  final ancestor = graph.commonAncestor(ids);
  final base = ancestor == null
      ? <String, dynamic>{}
      : _backupJson(ancestor.source!) as Map<String, dynamic>;
  final result = Map<String, dynamic>.from(values.first);
  for (final field in {...base.keys, ...values.expand((v) => v.keys)}) {
    if (_vpnCollections.containsKey(field)) {
      final original = Set<String>.from(base[field] as List? ?? []);
      final sets = values
          .map((v) => Set<String>.from(v[field] as List? ?? []))
          .toList();
      final removed = {for (final set in sets) ...original.difference(set)};
      result[field] = ({
        for (final set in sets) ...set,
      }..removeAll(removed)).toList()..sort();
    } else {
      final changed = values
          .where((v) => canonicalJson(v[field]) != canonicalJson(base[field]))
          .map((v) => canonicalJson(v[field]))
          .toSet();
      if (changed.length > 1) return null;
      result[field] = changed.isEmpty
          ? base[field]
          : jsonDecode(changed.single);
    }
  }
  return canonicalJson(result);
}

_MergeProjection _projectMerge(
  CausalGraph graph,
  Map<_EntityKey, String> preferred,
) {
  final entities = <_EntityKey, _EntitySnapshot>{},
      heads = <_EntityKey, ChangeHeader>{},
      conflicts = <_EntityKey>{};
  for (final entry in graph.tips.entries) {
    final ids = entry.value;
    var chosen =
        graph.events[ids.contains(preferred[entry.key])
            ? preferred[entry.key]!
            : ids.first]!;
    String? merged;
    if (ids.length > 1 && !graph.equivalent(ids)) {
      if (entry.key.$1 == ChangeEntityKind.vpnWorkspace) {
        merged = _mergeRoot(graph, ids);
      }
      if (merged == null) {
        conflicts.add(entry.key);
        final deleted = ids
            .map((id) => graph.events[id]!)
            .where((e) => e.header.deleted);
        if (deleted.isNotEmpty) chosen = deleted.first;
      }
    }
    heads[entry.key] = chosen.header;
    final source = merged ?? chosen.source;
    if (source != null) {
      entities[entry.key] = _EntitySnapshot(
        source,
        deleted: chosen.header.deleted,
      );
    }
  }
  return _MergeProjection(entities, heads, conflicts);
}

Map<String, String> _materializedDocuments(
  _Entities entities,
  String workspaceId,
  Map<_EntityKey, ChangeHeader> heads,
) {
  final documents = <String, String>{};
  for (final entry in entities.entries) {
    switch (entry.key.$1) {
      case ChangeEntityKind.template:
        documents['template-draft'] = entry.value.source;
      case ChangeEntityKind.runnerState:
        documents['runner/${entry.key.$2}'] = entry.value.source;
      default:
        break;
    }
  }
  final root = entities[(ChangeEntityKind.vpnWorkspace, workspaceId)];
  if (root != null) {
    final value = Map<String, dynamic>.from(_backupJson(root.source) as Map);
    for (final field in _vpnCollections.keys) {
      final ids = List<String>.from(value[field] as List? ?? []),
          items = <String, Object?>{};
      for (final id in ids) {
        final entity = entities[(_vpnCollections[field]!, id)];
        // A retained tombstone wins over stale collection membership.
        if (entity != null) {
          items[id] = _backupJson(entity.source);
        } else if (heads[(_vpnCollections[field]!, id)]?.deleted != true) {
          throw const FormatException('sync_reference');
        }
      }
      value[field] = ['servers', 'profiles'].contains(field)
          ? items
          : items.values.toList();
    }
    final source = canonicalJson(value);
    if (VpnWorkspace.decode(source).id != workspaceId) {
      throw const FormatException();
    }
    documents['vpn-workspace-v1'] = source;
  }
  return documents;
}
