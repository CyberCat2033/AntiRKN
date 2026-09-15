part of 'workspace_database.dart';

typedef _EntityKey = (ChangeEntityKind, String);
typedef _Entities = Map<_EntityKey, _EntitySnapshot>;
typedef _Crypt = Future<String> Function(String, int, List<int>);
typedef _Encrypt = Future<Uint8List> Function(String, int, String);

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
_Entities _documentEntities(String id, String? source) {
  if (source == null) return {};
  if (id != 'vpn-workspace-v1') {
    final (kind, entityId) = id == 'template-draft'
        ? (ChangeEntityKind.template, 'default')
        : id.startsWith('runner/')
        ? (ChangeEntityKind.runnerState, id.substring(7))
        : (ChangeEntityKind.document, id);
    return {(kind, entityId): _EntitySnapshot(source)};
  }
  VpnWorkspace.decode(source);
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
      entities[(kind, entityId)] = _EntitySnapshot(
        canonicalJson(record),
        deleted: spec['deleted'] == true,
      );
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
      entities[(kind, entry.key)] = _EntitySnapshot(canonicalJson(entry.value));
    }
  }
  entities[(ChangeEntityKind.vpnWorkspace, value['id'] as String)] =
      _EntitySnapshot(canonicalJson(root));
  return entities;
}

final class _PreparedChange {
  const _PreparedChange(this.header, this.payload);
  final ChangeHeader header;
  final Uint8List payload;
}

final class _ChangeBatch {
  const _ChangeBatch(this.expectedSequence, this.changes, [this.expectedEpoch]);
  final int? expectedEpoch;
  final int expectedSequence;
  final List<_PreparedChange> changes;
}

/// All encryption happens before BEGIN IMMEDIATE. A transaction then checks
/// both the source revision and journal sequence before committing either.
final class _LocalChangeJournal {
  _LocalChangeJournal(this.db, this.encrypt, this.decrypt);
  final Database db;
  final _Encrypt encrypt;
  final _Crypt decrypt;
  WorkspaceIdentity? _identity;
  WorkspaceIdentity get identity => _identity!;

  static final _ddl = [
    'CREATE TABLE sync_identity (singleton INTEGER PRIMARY KEY CHECK(singleton=1), workspace_id TEXT NOT NULL, device_id TEXT NOT NULL, sequence INTEGER NOT NULL CHECK(sequence>=0), proof BLOB NOT NULL, write_guard INTEGER NOT NULL DEFAULT 0 CHECK(write_guard IN (0,1)))',
    'CREATE TABLE sync_changes (change_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL UNIQUE CHECK(sequence>0), header TEXT NOT NULL, payload BLOB NOT NULL)',
    'CREATE TABLE sync_heads (entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0), change_id TEXT NOT NULL REFERENCES sync_changes(change_id), deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), PRIMARY KEY(entity_kind,entity_id))',
    'CREATE TABLE sync_outbox (change_id TEXT PRIMARY KEY REFERENCES sync_changes(change_id))',
    "CREATE TRIGGER sync_changes_immutable_update BEFORE UPDATE ON sync_changes BEGIN SELECT RAISE(ABORT, 'immutable_change'); END",
    "CREATE TRIGGER sync_changes_immutable_delete BEFORE DELETE ON sync_changes BEGIN SELECT RAISE(ABORT, 'immutable_change'); END",
    for (final table in ['servers', 'documents'])
      for (final action in ['insert', 'update', 'delete'])
        "CREATE TRIGGER journal_guard_${table}_$action BEFORE $action ON $table WHEN (SELECT write_guard FROM sync_identity WHERE singleton=1) != 1 BEGIN SELECT RAISE(ABORT, 'journal_writer_required'); END",
  ];

  Future<void> initialize() async {
    if (_identity != null) {
      checkIdentity();
      return;
    }
    if (db.userVersion == 1) await _migrate();
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
    if (db.userVersion == 2) {
      db.execute('BEGIN IMMEDIATE');
      try {
        if (db.userVersion == 2) {
          db.execute('ALTER TABLE sync_identity ADD COLUMN writer_device TEXT');
          for (final table in ['servers', 'documents']) {
            for (final action in ['insert', 'update', 'delete']) {
              db.execute('DROP TRIGGER journal_guard_${table}_$action');
              db.execute(_guard(table, action));
            }
          }
          db.userVersion = 3;
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
    _identity = WorkspaceIdentity(
      workspaceId: row['workspace_id'] as String,
      deviceId: row['device_id'] as String,
    );
    checkIdentity();
  }

  static String _guard(String table, String action) =>
      "CREATE TRIGGER journal_guard_${table}_$action BEFORE $action ON $table WHEN (SELECT write_guard != 1 OR writer_device IS NOT device_id FROM sync_identity WHERE singleton=1) BEGIN SELECT RAISE(ABORT, 'journal_writer_required'); END";

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

  Future<void> _migrate() async {
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
    final batch = await _prepare({}, entities, initial, 0, bootstrap: true);
    db.execute('BEGIN IMMEDIATE');
    try {
      // A second process may have finished exactly the same migration.
      if (db.userVersion == 1) {
        if (_snapshot(_servers(), _documents()) != snapshot) {
          throw const VaultFailure(VaultIssue.busy);
        }
        for (final sql in _ddl) {
          db.execute(sql);
        }
        db.execute(
          'INSERT INTO sync_identity (singleton,workspace_id,device_id,sequence,proof) VALUES (1, ?, ?, 0, ?)',
          [initial.workspaceId, initial.deviceId, proof],
        );
        commit(batch);
        db.userVersion = 2;
      } else if (db.userVersion != 2 &&
          db.userVersion != 3 &&
          db.userVersion != 4 &&
          db.userVersion != 5) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<_ChangeBatch> prepare(_Entities before, _Entities after) => _prepare(
    before,
    after,
    identity,
    db
            .select('SELECT sequence FROM sync_identity WHERE singleton=1')
            .single['sequence']
        as int,
  );

  Future<_ChangeBatch> _prepare(
    _Entities before,
    _Entities after,
    WorkspaceIdentity owner,
    int sequence, {
    bool bootstrap = false,
  }) async {
    final keys =
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
    final epoch = !bootstrap && db.userVersion >= 5
        ? db.select('SELECT epoch FROM sync_merge_meta').single['epoch'] as int
        : null;
    final transactionId = newVpnId();
    final changes = <_PreparedChange>[];
    // Capture all heads before the first await. The sequence CAS in commit
    // rejects any other writer changing them during encryption.
    final heads = {
      for (final key in keys)
        key: bootstrap
            ? <Row>[]
            : db.select(
                'SELECT * FROM sync_heads WHERE entity_kind=? AND entity_id=?',
                [key.$1.name, key.$2],
              ),
    };
    for (final key in keys) {
      final head = heads[key]!.firstOrNull;
      if (!bootstrap && before.containsKey(key) && head == null) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      if (!bootstrap &&
          db.userVersion >= 5 &&
          db.select(
            'SELECT 1 FROM sync_conflicts WHERE entity_kind=? AND entity_id=?',
            [key.$1.name, key.$2],
          ).isNotEmpty) {
        throw const VaultFailure(VaultIssue.busy);
      }
      if (head?['deleted'] == 1 && after[key] != null && !after[key]!.deleted) {
        throw const VaultFailure(VaultIssue.busy);
      }
      final branches = !bootstrap && db.userVersion >= 5
          ? db
                .select(
                  'SELECT change_id FROM sync_branches WHERE entity_kind=? AND entity_id=? ORDER BY change_id',
                  [key.$1.name, key.$2],
                )
                .map((r) => r['change_id'] as String)
                .toList()
          : <String>[];
      // Equivalent/automatically merged branches are all acknowledged by edits.
      // The base must carry the highest parent revision.
      if (branches.length > 1) {
        final revisions = {
          for (final id in branches)
            id: ChangeHeader.fromJson(
              jsonDecode(
                    db.select(
                          'SELECT header FROM sync_changes WHERE change_id=? UNION ALL SELECT header FROM sync_incoming WHERE change_id=?',
                          [id, id],
                        ).single['header']
                        as String,
                  )
                  as Map<String, dynamic>,
            ).revision,
        };
        branches.sort(
          (a, b) => revisions[b] == revisions[a]
              ? a.compareTo(b)
              : revisions[b]!.compareTo(revisions[a]!),
        );
      }
      final base = branches.isNotEmpty
          ? ChangeHeader.fromJson(
              jsonDecode(
                    db.select(
                          'SELECT header FROM sync_changes WHERE change_id=? UNION ALL SELECT header FROM sync_incoming WHERE change_id=?',
                          [branches.first, branches.first],
                        ).single['header']
                        as String,
                  )
                  as Map<String, dynamic>,
            ).revision
          : head?['revision'] as int? ?? 0;
      final next = after[key];
      final header = ChangeHeader(
        workspaceId: owner.workspaceId,
        deviceId: owner.deviceId,
        changeId: newVpnId(),
        sequence: sequence + changes.length + 1,
        transactionId: transactionId,
        transactionIndex: changes.length,
        transactionSize: keys.length,
        entityKind: key.$1,
        entityId: key.$2,
        baseChangeId: branches.isNotEmpty
            ? branches.first
            : head?['change_id'] as String?,
        schemaVersion: bootstrap ? 1 : 2,
        mergeParents: branches.skip(1).toList(),
        baseRevision: base,
        revision: base + 1,
        deleted: next == null || next.deleted,
      );
      final payload = await encrypt(
        _scope(header),
        1,
        jsonEncode({'source': next?.source}),
      );
      changes.add(_PreparedChange(header, payload));
    }
    return _ChangeBatch(sequence, changes, epoch);
  }

  static String _scope(ChangeHeader header) =>
      'local-change:${canonicalJson(header.toJson())}';

  /// Caller MUST hold the same transaction as the application data update.
  void commit(_ChangeBatch batch) {
    if (batch.changes.isEmpty) return;
    final current = db
        .select('SELECT sequence FROM sync_identity WHERE singleton=1')
        .single['sequence'];
    if (current != batch.expectedSequence ||
        (batch.expectedEpoch != null &&
            db.select('SELECT epoch FROM sync_merge_meta').single['epoch'] !=
                batch.expectedEpoch)) {
      throw const VaultFailure(VaultIssue.busy);
    }
    for (final change in batch.changes) {
      final h = change.header;
      db.execute('INSERT INTO sync_changes VALUES (?, ?, ?, ?)', [
        h.changeId,
        h.sequence,
        canonicalJson(h.toJson()),
        change.payload,
      ]);
      db.execute(
        'INSERT INTO sync_heads VALUES (?, ?, ?, ?, ?) ON CONFLICT(entity_kind,entity_id) DO UPDATE SET revision=excluded.revision,change_id=excluded.change_id,deleted=excluded.deleted',
        [
          h.entityKind.name,
          h.entityId,
          h.revision,
          h.changeId,
          h.deleted ? 1 : 0,
        ],
      );
      db.execute('INSERT INTO sync_outbox VALUES (?)', [h.changeId]);
      if (db.userVersion >= 5) {
        db.execute(
          'DELETE FROM sync_branches WHERE entity_kind=? AND entity_id=?',
          [h.entityKind.name, h.entityId],
        );
        db.execute('INSERT INTO sync_branches VALUES (?,?,?)', [
          h.entityKind.name,
          h.entityId,
          h.changeId,
        ]);
      }
    }
    db.execute('UPDATE sync_identity SET sequence=? WHERE singleton=1', [
      batch.changes.last.header.sequence,
    ]);
  }

  bool serverWasDeleted(String id) => db.select(
    "SELECT 1 FROM sync_heads WHERE entity_kind='server' AND entity_id=? AND deleted=1",
    [id],
  ).isNotEmpty;

  Future<List<LocalChange>> read({
    required bool pending,
    required int afterSequence,
    required int limit,
  }) async {
    if (afterSequence < 0 || limit < 1 || limit > 1000) {
      throw ArgumentError('change_page');
    }
    final rows = db.select(
      'SELECT c.* FROM sync_changes c ${pending ? 'JOIN sync_outbox o ON o.change_id=c.change_id' : ''} WHERE c.sequence>? ORDER BY c.sequence LIMIT ?',
      [afterSequence, limit],
    );
    final changes = <LocalChange>[];
    try {
      for (final row in rows) {
        final header = ChangeHeader.fromJson(
          jsonDecode(row['header'] as String) as Map<String, dynamic>,
        );
        if (header.changeId != row['change_id'] ||
            header.sequence != row['sequence'] ||
            header.workspaceId != identity.workspaceId) {
          throw const VaultFailure(VaultIssue.corrupt);
        }
        final body =
            jsonDecode(
                  await decrypt(_scope(header), 1, row['payload'] as Uint8List),
                )
                as Map;
        if (body.length != 1 ||
            !body.containsKey('source') ||
            (body['source'] == null && !header.deleted)) {
          throw const VaultFailure(VaultIssue.corrupt);
        }
        changes.add(
          LocalChange(header: header, source: body['source'] as String?),
        );
      }
    } catch (_) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
    return List.unmodifiable(changes);
  }

  void acknowledge(List<String> ids) {
    if (ids.length > 1000) throw ArgumentError('change_acknowledgements');
    for (final id in ids.toSet()) {
      if (db.select('SELECT 1 FROM sync_changes WHERE change_id=?', [
        id,
      ]).isEmpty) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      db.execute('DELETE FROM sync_outbox WHERE change_id=?', [id]);
    }
  }
}
