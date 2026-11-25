part of 'workspace_database.dart';

typedef _EntityKey = (ChangeEntityKind, String);
typedef _Entities = Map<_EntityKey, _EntitySnapshot>;
typedef _Crypt = Future<String> Function(String, int, List<int>);
typedef _Encrypt = Future<Uint8List> Function(String, int, String);

/// Schema written by this build. Every older version opens as this one.
const _schemaVersion = 7;

final class _EntitySnapshot {
  const _EntitySnapshot(this.source, {this.deleted = false});
  final String source;
  final bool deleted;
}

_Entities _serverEntities(String id, String? source) => {
  if (source != null)
    (ChangeEntityKind.server, id): _EntitySnapshot(
      canonicalJson(jsonDecode(source)),
    ),
};

/// Keeps each resource/user separate while retaining unknown fields and list
/// order. Server state includes observed credentials and operation records;
/// it remains data, never an instruction to submit an operation.
_Entities _documentEntities(String id, String? source, {_EntityKey? only}) {
  if (source == null) return {};
  if (id != 'vpn-workspace-v1') {
    final (kind, entityId) = id == 'template-draft'
        ? (ChangeEntityKind.template, 'default')
        : id.startsWith('runner/')
        ? (ChangeEntityKind.runnerState, id.substring(7))
        : (ChangeEntityKind.document, id);
    return {(kind, entityId): _EntitySnapshot(source)};
  }
  if (only == null) VpnWorkspace.decode(source);
  final value = jsonDecode(source) as Map<String, dynamic>;
  final root = Map<String, Object?>.from(value);
  final entities = <_EntityKey, _EntitySnapshot>{};
  for (final (field, kind, nested) in [
    ('users', ChangeEntityKind.vpnUser, false),
    ('inbounds', ChangeEntityKind.vlessInbound, true),
    ('awgInterfaces', ChangeEntityKind.awgInterface, true),
    ('ttEndpoints', ChangeEntityKind.ttEndpoint, true),
  ]) {
    final order = <String>[];
    for (final item in value[field] as List? ?? []) {
      final record = item as Map<String, dynamic>;
      final spec = nested ? record['spec'] as Map : record;
      final entityId = spec['id'] as String;
      order.add(entityId);
      if (only == null || only == (kind, entityId)) {
        entities[(kind, entityId)] = _EntitySnapshot(
          canonicalJson(record),
          deleted: spec['deleted'] == true,
        );
      }
    }
    // These are references, not copies of entity payloads.
    root[field] = order;
  }
  for (final (field, kind) in [
    ('servers', ChangeEntityKind.vpnServerState),
    ('profiles', ChangeEntityKind.profile),
  ]) {
    final records = value[field] as Map<String, dynamic>? ?? {};
    root[field] = records.keys.toList()..sort();
    for (final entry in records.entries) {
      if (only == null || only == (kind, entry.key)) {
        entities[(kind, entry.key)] = _EntitySnapshot(
          canonicalJson(entry.value),
        );
      }
    }
  }
  entities[(ChangeEntityKind.vpnWorkspace, value['id'] as String)] =
      _EntitySnapshot(canonicalJson(root));
  return entities;
}

/// Entities whose source or deletion differs, in a stable order.
List<_EntityKey> _changedEntities(_Entities before, _Entities after) =>
    {...before.keys, ...after.keys}
        .where(
          (key) =>
              before[key]?.source != after[key]?.source ||
              before[key]?.deleted != after[key]?.deleted,
        )
        .toList()
      ..sort(
        (a, b) => '${a.$1.name}:${a.$2}'.compareTo('${b.$1.name}:${b.$2}'),
      );

/// The local journal keeps no entity content: the rows in servers and
/// documents are the data, and the cloud snapshot carries them whole. Left
/// are the installation identity, a change counter (`sequence`, which tells
/// whether anything changed since the last upload) and, per entity, its head:
/// the id of its current version, its revision and whether it is deleted.
/// A deleted entity is never written again under the same id, and
/// publication fences a profile by its head and accepts a Drive file written
/// at one of the head's ancestors (`sync_history`: change id and the ids it
/// replaced). Recording happens inside the data transaction; a missing or
/// resurrected head fails the whole write.
final class _LocalChangeJournal {
  _LocalChangeJournal(this.db, this.encrypt, this.decrypt);
  final Database db;
  final _Encrypt encrypt;
  final _Crypt decrypt;
  WorkspaceIdentity? _identity;
  WorkspaceIdentity get identity => _identity!;

  static const _headsTable =
      'sync_heads (entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), change_id TEXT NOT NULL, deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), PRIMARY KEY(entity_kind,entity_id))';
  static const _historyTable =
      'CREATE TABLE sync_history (change_id TEXT PRIMARY KEY, parents TEXT NOT NULL)';
  static final _ddl = [
    'CREATE TABLE sync_identity (singleton INTEGER PRIMARY KEY CHECK(singleton=1), workspace_id TEXT NOT NULL, device_id TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>=0), proof BLOB NOT NULL, write_guard INTEGER NOT NULL DEFAULT 0 CHECK(write_guard IN (0,1)), writer_device TEXT, writer_version INTEGER NOT NULL DEFAULT 0)',
    'CREATE TABLE $_headsTable',
    _historyTable,
  ];

  /// Journals of schema 2–6: events with encrypted sources, outbox, packets,
  /// the packet key and the causal merge removed on 2026-09-24. Children
  /// first: some reference sync_changes.
  static const _legacyTables = [
    'sync_outbox',
    'sync_packets',
    'sync_keys',
    'sync_incoming',
    'sync_branches',
    'sync_conflicts',
    'sync_merge_meta',
  ];

  static const _guardedTables = [
    'servers',
    'documents',
    'vpn_overlay_state',
    'vpn_user_overlay',
    'vpn_profile_overlay',
  ];

  /// Data is written only inside [WorkspaceDatabase._transaction] of this
  /// schema. A process of an older build, still open during the migration,
  /// marks its transactions with its own version and is refused.
  static void installGuards(Database db) {
    for (final table in _guardedTables) {
      for (final action in ['insert', 'update', 'delete']) {
        db.execute('DROP TRIGGER IF EXISTS journal_guard_${table}_$action');
        db.execute(
          "CREATE TRIGGER journal_guard_${table}_$action BEFORE $action ON $table WHEN (SELECT write_guard != 1 OR writer_device IS NOT device_id OR writer_version != $_schemaVersion FROM sync_identity WHERE singleton=1) BEGIN SELECT RAISE(ABORT, 'journal_writer_required'); END",
        );
      }
    }
  }

  static void dropGuards(Database db) {
    for (final row in db.select(
      "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'journal_guard_%'",
    )) {
      db.execute('DROP TRIGGER "${row['name']}"');
    }
  }

  Future<void> initialize() async {
    if (_identity != null) {
      checkIdentity();
      return;
    }
    final version = db.userVersion;
    if (version == 1) {
      await _bootstrap();
    } else if (version > 1 && version < _schemaVersion) {
      await _verifyProof();
      _upgrade();
    }
    if (db.userVersion != _schemaVersion) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
    final row = await _verifyProof();
    _identity = WorkspaceIdentity(
      workspaceId: row['workspace_id'] as String,
      deviceId: row['device_id'] as String,
    );
    checkIdentity();
  }

  /// The identity is bound to the device key: a wrong key changes nothing.
  Future<Row> _verifyProof() async {
    final row = db.select('SELECT * FROM sync_identity').single;
    final proof = jsonDecode(
      await decrypt('journal-identity', 1, row['proof'] as Uint8List),
    );
    if (proof is! Map ||
        proof['version'] != 1 ||
        proof['workspaceId'] != row['workspace_id'] ||
        proof['deviceId'] != row['device_id']) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
    return row;
  }

  /// Schema 2–6 to 7 in one transaction: data rows, identity and heads stay
  /// as they are; event sources, packets and merge state are dropped. A
  /// failure rolls everything back and the next launch starts again.
  void _upgrade() {
    db.execute('BEGIN IMMEDIATE');
    try {
      // Another process may have finished exactly this migration.
      final version = db.userVersion;
      if (version > 1 && version < _schemaVersion) {
        final tables = db
            .select("SELECT name FROM sqlite_master WHERE type='table'")
            .map((r) => r['name'] as String)
            .toSet();
        // Ancestors of heads: own events and accepted received ones.
        final history = <String, String>{};
        for (final (table, accepted) in [
          ('sync_changes', ''),
          ('sync_incoming', ' WHERE state=1'),
        ]) {
          if (!tables.contains(table)) continue;
          for (final row in db.select(
            'SELECT change_id,header FROM $table$accepted',
          )) {
            final header = ChangeHeader.fromJson(
              jsonDecode(row['header'] as String) as Map<String, dynamic>,
            );
            if (header.changeId != row['change_id']) {
              throw const VaultFailure(VaultIssue.corrupt);
            }
            history[header.changeId] = jsonEncode(header.parents);
          }
        }
        dropGuards(db);
        for (final table in _legacyTables) {
          db.execute('DROP TABLE IF EXISTS $table');
        }
        // Heads of schema 2–4 reference sync_changes: rebuild without it.
        db.execute(
          'CREATE TABLE ${_headsTable.replaceFirst('sync_heads', 'sync_heads_v7')}',
        );
        db.execute(
          'INSERT INTO sync_heads_v7 SELECT entity_kind,entity_id,revision,change_id,deleted FROM sync_heads',
        );
        db.execute('DROP TABLE sync_heads');
        db.execute('ALTER TABLE sync_heads_v7 RENAME TO sync_heads');
        db.execute('DROP TABLE sync_changes');
        db.execute(_historyTable);
        for (final head in db.select('SELECT change_id FROM sync_heads')) {
          history.putIfAbsent(head['change_id'] as String, () => '[]');
        }
        for (final entry in history.entries) {
          db.execute('INSERT INTO sync_history VALUES (?,?)', [
            entry.key,
            entry.value,
          ]);
        }
        final columns = db
            .select('PRAGMA table_info(sync_identity)')
            .map((r) => r['name'] as String)
            .toSet();
        if (!columns.contains('writer_device')) {
          db.execute('ALTER TABLE sync_identity ADD COLUMN writer_device TEXT');
        }
        if (!columns.contains('writer_version')) {
          db.execute(
            'ALTER TABLE sync_identity ADD COLUMN writer_version INTEGER NOT NULL DEFAULT 0',
          );
        }
        db.execute(
          'UPDATE sync_identity SET write_guard=0, writer_device=NULL, writer_version=0',
        );
        if (!tables.contains('vpn_overlay_state')) {
          for (final sql in _VpnOverlay.ddl) {
            db.execute(sql);
          }
        }
        installGuards(db);
        db.userVersion = _schemaVersion;
      } else if (version != _schemaVersion) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// A restore invalidates cached editors and other already-open processes.
  void checkIdentity() {
    final row = db
        .select(
          'SELECT workspace_id,device_id FROM sync_identity WHERE singleton=1',
        )
        .single;
    if (row['workspace_id'] != identity.workspaceId ||
        row['device_id'] != identity.deviceId) {
      throw const VaultFailure(VaultIssue.busy);
    }
  }

  List<Row> _servers() => db.select('SELECT * FROM servers ORDER BY id');
  List<Row> _documents() => db.select('SELECT * FROM documents ORDER BY id');

  // Exact ciphertext comparison detects another v1 writer during preparation,
  // including deletion/recreation and same-revision payload replacement.
  String _snapshot(List<Row> servers, List<Row> documents) => jsonEncode([
    for (final rows in [servers, documents])
      [
        for (final row in rows)
          {...row, 'payload': base64Encode(row['payload'] as Uint8List)},
      ],
  ]);

  /// Schema 1 to 7: one identity, and a head for every existing entity.
  Future<void> _bootstrap() async {
    final servers = _servers(), documents = _documents();
    final snapshot = _snapshot(servers, documents);
    final entities = <_EntityKey, _EntitySnapshot>{};
    String? workspaceId;
    for (final row in servers) {
      final id = row['id'] as String;
      final source = await decrypt(
        'server:$id',
        row['revision'] as int,
        row['payload'] as Uint8List,
      );
      // Refuse a corrupt old record before changing the schema or key.
      decodeProfile(jsonDecode(source) as Map<String, Object?>);
      entities.addAll(_serverEntities(id, source));
    }
    for (final row in documents) {
      final id = row['id'] as String;
      final source = await decrypt(
        id,
        row['revision'] as int,
        row['payload'] as Uint8List,
      );
      if (id == 'vpn-workspace-v1') {
        workspaceId = VpnWorkspace.decode(source).id;
      }
      entities.addAll(_documentEntities(id, source));
    }
    final initial = WorkspaceIdentity(
      workspaceId: workspaceId ?? newVpnId(),
      deviceId: newVpnId(),
    );
    entities[(ChangeEntityKind.workspace, initial.workspaceId)] =
        _EntitySnapshot(canonicalJson({'id': initial.workspaceId}));
    final proof = await encrypt(
      'journal-identity',
      1,
      canonicalJson({
        'version': 1,
        'workspaceId': initial.workspaceId,
        'deviceId': initial.deviceId,
      }),
    );
    db.execute('BEGIN IMMEDIATE');
    try {
      // A second process may have finished exactly the same migration.
      if (db.userVersion == 1) {
        if (_snapshot(_servers(), _documents()) != snapshot) {
          throw const VaultFailure(VaultIssue.busy);
        }
        for (final sql in [..._ddl, ..._VpnOverlay.ddl]) {
          db.execute(sql);
        }
        db.execute(
          'INSERT INTO sync_identity (singleton,workspace_id,device_id,sequence,proof) VALUES (1, ?, ?, 0, ?)',
          [initial.workspaceId, initial.deviceId, proof],
        );
        record({}, entities, bootstrap: true);
        installGuards(db);
        db.userVersion = _schemaVersion;
      } else if (db.userVersion != _schemaVersion) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Caller MUST hold the transaction that writes the data. Moves the head
  /// of every changed entity and the change counter; returns how many
  /// entities changed. With [bootstrap] (an empty journal) no head may exist.
  int record(_Entities before, _Entities after, {bool bootstrap = false}) {
    final keys = _changedEntities(before, after);
    if (keys.isEmpty) return 0;
    for (final key in keys) {
      final head = db.select(
        'SELECT revision,change_id,deleted FROM sync_heads WHERE entity_kind=? AND entity_id=?',
        [key.$1.name, key.$2],
      ).firstOrNull;
      if (!bootstrap && before.containsKey(key) && head == null) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      final next = after[key];
      // A deleted entity never comes back under the same id.
      if (head?['deleted'] == 1 && next != null && !next.deleted) {
        throw const VaultFailure(VaultIssue.busy);
      }
      final changeId = newVpnId();
      db.execute('INSERT INTO sync_history VALUES (?,?)', [
        changeId,
        jsonEncode([?head?['change_id'] as String?]),
      ]);
      db.execute(
        'INSERT INTO sync_heads VALUES (?, ?, ?, ?, ?) ON CONFLICT(entity_kind,entity_id) DO UPDATE SET revision=excluded.revision,change_id=excluded.change_id,deleted=excluded.deleted',
        [
          key.$1.name,
          key.$2,
          (head?['revision'] as int? ?? 0) + 1,
          changeId,
          next == null || next.deleted ? 1 : 0,
        ],
      );
    }
    db.execute(
      'UPDATE sync_identity SET sequence=sequence+? WHERE singleton=1',
      [keys.length],
    );
    return keys.length;
  }

  bool serverWasDeleted(String id) => db.select(
    "SELECT 1 FROM sync_heads WHERE entity_kind='server' AND entity_id=? AND deleted=1",
    [id],
  ).isNotEmpty;

  String? head(ChangeEntityKind kind, String entityId) =>
      db.select(
            'SELECT change_id FROM sync_heads WHERE entity_kind=? AND entity_id=?',
            [kind.name, entityId],
          ).firstOrNull?['change_id']
          as String?;

  /// [headId] and the versions it replaced that are still recorded. Older
  /// ones are dropped by [compact] after an upload.
  Set<String> ancestors(String headId) {
    final ancestors = <String>{};
    final waiting = <String>[headId];
    while (waiting.isNotEmpty) {
      final id = waiting.removeLast();
      if (!ancestors.add(id)) continue;
      final row = db.select(
        'SELECT parents FROM sync_history WHERE change_id=?',
        [id],
      ).firstOrNull;
      if (row == null) {
        if (id == headId) throw const SyncMergeFailure(SyncMergeIssue.changed);
        continue;
      }
      waiting.addAll(
        (jsonDecode(row['parents'] as String) as List).cast<String>(),
      );
    }
    return ancestors;
  }

  /// Keeps the history of current heads only. Caller holds a transaction.
  void compact() => db.execute(
    'DELETE FROM sync_history WHERE change_id NOT IN (SELECT change_id FROM sync_heads)',
  );

  /// The journal of a restored workspace: [owner], and a head per entity.
  /// Caller holds the restore transaction with the guards dropped.
  int restart(WorkspaceIdentity owner, Uint8List proof, _Entities entities) {
    db.execute('DELETE FROM sync_heads');
    db.execute('DELETE FROM sync_history');
    db.execute(
      'UPDATE sync_identity SET workspace_id=?, device_id=?, sequence=0, proof=?, write_guard=1, writer_device=?, writer_version=? WHERE singleton=1',
      [
        owner.workspaceId,
        owner.deviceId,
        proof,
        owner.deviceId,
        _schemaVersion,
      ],
    );
    return record({}, entities, bootstrap: true);
  }
}
