part of 'workspace_database.dart';

final class _VpnProjection {
  const _VpnProjection(
    this.source,
    this.revision,
    this.baseRevision,
    this.dirty,
  );
  final String? source;
  final int revision, baseRevision;
  final bool dirty;
}

/// Keeps single-client edits durable without replacing the encrypted VPN blob.
/// The blob is materialized at snapshot and full-document boundaries.
final class _VpnOverlay {
  _VpnOverlay(this.store);
  final WorkspaceDatabase store;
  Database get db => store._db;

  static const ddl = [
    'CREATE TABLE vpn_overlay_state (singleton INTEGER PRIMARY KEY CHECK(singleton=1), base_revision INTEGER NOT NULL CHECK(base_revision>0), revision INTEGER NOT NULL CHECK(revision>base_revision))',
    'CREATE TABLE vpn_user_overlay (user_id TEXT PRIMARY KEY, payload BLOB NOT NULL, revision INTEGER NOT NULL CHECK(revision>0))',
    'CREATE TABLE vpn_profile_overlay (user_id TEXT PRIMARY KEY, payload BLOB NOT NULL, revision INTEGER NOT NULL CHECK(revision>0))',
  ];

  /// The schema is created by the journal migration; this only checks it.
  void initialize() {
    if (db
            .select(
              "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('vpn_overlay_state','vpn_user_overlay','vpn_profile_overlay')",
            )
            .length !=
        3) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
  }

  int _baseRevision() =>
      db
              .select(
                "SELECT revision FROM documents WHERE id='vpn-workspace-v1'",
              )
              .firstOrNull?['revision']
          as int? ??
      0;

  int _logicalRevision() =>
      db
              .select(
                'SELECT revision FROM vpn_overlay_state WHERE singleton=1',
              )
              .firstOrNull?['revision']
          as int? ??
      _baseRevision();

  void _checkRevision(int base, int logical) {
    if (_baseRevision() != base || _logicalRevision() != logical) {
      throw const VaultFailure(VaultIssue.busy);
    }
  }

  // Every publication check reads the projection; decrypting the whole
  // document and each patch again is the dominant cost, so the last result is
  // kept while [_stamp] proves the stored rows did not change.
  (String, _VpnProjection)? _cached;
  (_VpnProjection, VpnWorkspace)? _decoded;
  var _generation = 0;
  var loads = 0;

  /// Called by every write of this connection that can change the projection.
  void invalidate() {
    _generation++;
    _cached = null;
    _decoded = null;
  }

  /// Revisions and payload sizes change with every write of this connection
  /// (each one bumps the document or overlay revision); `data_version`
  /// changes with every commit of any other connection — the VPN write
  /// worker or another process — including a restore that reuses revisions.
  /// Reads no payload bytes. Call inside the read transaction of the rows.
  String _stamp() {
    final version = db.select('PRAGMA data_version').single.values.single;
    final row = db
        .select(
          "SELECT (SELECT revision||':'||length(payload) FROM documents WHERE id='vpn-workspace-v1') AS document, "
          "(SELECT base_revision||':'||revision FROM vpn_overlay_state WHERE singleton=1) AS state, "
          "(SELECT group_concat(entry, ',') FROM (SELECT user_id||':'||revision||':'||length(payload) AS entry FROM vpn_user_overlay ORDER BY user_id)) AS users, "
          "(SELECT group_concat(entry, ',') FROM (SELECT user_id||':'||revision||':'||length(payload) AS entry FROM vpn_profile_overlay ORDER BY user_id)) AS profiles",
        )
        .single;
    return jsonEncode([
      version,
      row['document'],
      row['state'],
      row['users'],
      row['profiles'],
    ]);
  }

  /// The decoded workspace of the current projection; requires the document.
  Future<VpnWorkspace> workspace() async {
    final projection = await read();
    if (_decoded case (
      final cached,
      final workspace,
    ) when identical(cached, projection)) {
      return workspace;
    }
    final workspace = VpnWorkspace.decode(projection.source!);
    _decoded = (projection, workspace);
    return workspace;
  }

  Future<_VpnProjection> read() async {
    final generation = _generation;
    late final String stamp;
    Row? row, state;
    late final List<Row> userPatches, profilePatches;
    db.execute('BEGIN');
    try {
      stamp = _stamp();
      if (_cached case (
        final cachedStamp,
        final projection,
      ) when cachedStamp == stamp) {
        db.execute('COMMIT');
        return projection;
      }
      row = db
          .select("SELECT * FROM documents WHERE id='vpn-workspace-v1'")
          .firstOrNull;
      state = db
          .select('SELECT * FROM vpn_overlay_state WHERE singleton=1')
          .firstOrNull;
      userPatches = db.select(
        'SELECT * FROM vpn_user_overlay ORDER BY user_id',
      );
      profilePatches = db.select(
        'SELECT * FROM vpn_profile_overlay ORDER BY user_id',
      );
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    final (projection, workspace) = await _project(
      row,
      state,
      userPatches,
      profilePatches,
    );
    if (generation == _generation) {
      _cached = (stamp, projection);
      _decoded = workspace == null ? null : (projection, workspace);
    }
    return projection;
  }

  Future<(_VpnProjection, VpnWorkspace?)> _project(
    Row? row,
    Row? state,
    List<Row> userPatches,
    List<Row> profilePatches,
  ) async {
    if (row == null) {
      if (state != null ||
          userPatches.isNotEmpty ||
          profilePatches.isNotEmpty) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      return (const _VpnProjection(null, 0, 0, false), null);
    }
    final base = row['revision'] as int;
    if (state != null && state['base_revision'] != base) {
      throw const VaultFailure(VaultIssue.busy);
    }
    final logical = state?['revision'] as int? ?? base;
    loads++;
    final source = await store._decrypt(
      'vpn-workspace-v1',
      base,
      row['payload'] as Uint8List,
    );
    if (state == null) {
      if (userPatches.isNotEmpty || profilePatches.isNotEmpty) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      return (_VpnProjection(source, base, base, false), null);
    }
    if (!userPatches.any((patch) => patch['revision'] == logical) &&
        !profilePatches.any((patch) => patch['revision'] == logical)) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
    final value = jsonDecode(source) as Map<String, dynamic>;
    final users = (value['users'] as List).cast<Map>().toList();
    for (final patch in userPatches) {
      final id = patch['user_id'] as String;
      final revision = patch['revision'] as int;
      if (revision > logical || revision <= base) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      final replacement =
          jsonDecode(
                await store._decrypt(
                  'vpn-user-overlay:$id',
                  revision,
                  patch['payload'] as Uint8List,
                ),
              )
              as Map<String, dynamic>;
      if (replacement['id'] != id) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      final index = users.indexWhere((user) => user['id'] == id);
      if (index < 0) {
        users.add(replacement);
      } else {
        users[index] = replacement;
      }
    }
    value['users'] = users;
    final profiles = value['profiles'] as Map<String, dynamic>;
    for (final patch in profilePatches) {
      final id = patch['user_id'] as String;
      final revision = patch['revision'] as int;
      if (revision > logical || revision <= base) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      profiles[id] =
          jsonDecode(
                await store._decrypt(
                  'vpn-profile-overlay:$id',
                  revision,
                  patch['payload'] as Uint8List,
                ),
              )
              as Map<String, dynamic>;
    }
    final projected = jsonEncode(value);
    return (
      _VpnProjection(projected, logical, base, true),
      VpnWorkspace.decode(projected),
    );
  }

  Future<int> upsertUser(VpnUser user, int expectedRevision) async {
    final projection = await read();
    if (projection.revision != expectedRevision) {
      throw const VaultFailure(VaultIssue.busy);
    }
    final current = projection.source == null
        ? VpnWorkspace(id: store._journal.identity.workspaceId)
        : VpnWorkspace.decode(projection.source!);
    if (current.users.any((old) => old.id == user.id && old.deleted) &&
        !user.deleted) {
      throw const FormatException('vpn_user_deleted');
    }
    final value = projection.source == null
        ? jsonDecode(current.encode()) as Map<String, dynamic>
        : jsonDecode(projection.source!) as Map<String, dynamic>;
    final users = (value['users'] as List).cast<Map>().toList();
    final index = users.indexWhere((old) => old['id'] == user.id);
    if (index < 0) {
      users.add(user.toJson());
    } else {
      users[index] = user.toJson();
    }
    value['users'] = users;
    final nextSource = jsonEncode(value);
    if (utf8.encode(nextSource).length > 8 * 1024 * 1024) {
      throw const VaultFailure(VaultIssue.writeFailed);
    }
    VpnWorkspace.decode(nextSource);
    // Old snapshots may need namespace repair. That changes other entities,
    // so the regular full-document path must prepare their journal events.
    if (_withAccountNamespaces(nextSource, projection.source) != nextSource) {
      return store._writeVpnCore(
        nextSource,
        expectedRevision: expectedRevision,
      );
    }
    final target = (ChangeEntityKind.vpnUser, user.id);
    final before = _documentEntities(
      'vpn-workspace-v1',
      projection.source,
      only: target,
    );
    final after = _documentEntities(
      'vpn-workspace-v1',
      nextSource,
      only: target,
    );
    if (index >= 0) {
      before.remove((ChangeEntityKind.vpnWorkspace, current.id));
      after.remove((ChangeEntityKind.vpnWorkspace, current.id));
    }
    if (_changedEntities(before, after).isEmpty) {
      return store._transaction(() {
        _checkRevision(projection.baseRevision, expectedRevision);
        return expectedRevision;
      });
    }
    if (projection.baseRevision == 0) {
      return store._writeVpnCore(
        nextSource,
        expectedRevision: expectedRevision,
      );
    }
    final revision = expectedRevision + 1;
    final payload = await store._encrypt(
      'vpn-user-overlay:${user.id}',
      revision,
      jsonEncode(user.toJson()),
    );
    return store._transaction(() {
      _checkRevision(projection.baseRevision, expectedRevision);
      db.execute(
        'INSERT INTO vpn_overlay_state VALUES (1,?,?) ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision',
        [projection.baseRevision, revision],
      );
      db.execute(
        'INSERT INTO vpn_user_overlay VALUES (?,?,?) ON CONFLICT(user_id) DO UPDATE SET payload=excluded.payload,revision=excluded.revision',
        [user.id, payload, revision],
      );
      store._journal.record(before, after);
      store._documentCache.remove('vpn-workspace-v1');
      invalidate();
      return revision;
    });
  }

  Future<int> upsertProfile(
    String userId,
    Map<String, dynamic> profile,
    int expectedRevision,
  ) async {
    final projection = await read();
    if (projection.revision != expectedRevision) {
      throw const VaultFailure(VaultIssue.busy);
    }
    if (projection.source == null) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
    final value = jsonDecode(projection.source!) as Map<String, dynamic>;
    final profiles = value['profiles'] as Map<String, dynamic>;
    final existed = profiles.containsKey(userId);
    profiles[userId] = profile;
    final nextSource = jsonEncode(value);
    if (utf8.encode(nextSource).length > 8 * 1024 * 1024) {
      throw const VaultFailure(VaultIssue.writeFailed);
    }
    VpnWorkspace.decode(nextSource);
    if (_withAccountNamespaces(nextSource, projection.source) != nextSource) {
      return store._writeVpnCore(
        nextSource,
        expectedRevision: expectedRevision,
      );
    }
    final target = (ChangeEntityKind.profile, userId);
    final before = _documentEntities(
      'vpn-workspace-v1',
      projection.source,
      only: target,
    );
    final after = _documentEntities(
      'vpn-workspace-v1',
      nextSource,
      only: target,
    );
    if (existed) {
      final root = (ChangeEntityKind.vpnWorkspace, value['id'] as String);
      before.remove(root);
      after.remove(root);
    }
    if (_changedEntities(before, after).isEmpty) {
      return store._transaction(() {
        _checkRevision(projection.baseRevision, expectedRevision);
        return expectedRevision;
      });
    }
    final revision = expectedRevision + 1;
    final payload = await store._encrypt(
      'vpn-profile-overlay:$userId',
      revision,
      jsonEncode(profile),
    );
    return store._transaction(() {
      _checkRevision(projection.baseRevision, expectedRevision);
      db.execute(
        'INSERT INTO vpn_overlay_state VALUES (1,?,?) ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision',
        [projection.baseRevision, revision],
      );
      db.execute(
        'INSERT INTO vpn_profile_overlay VALUES (?,?,?) ON CONFLICT(user_id) DO UPDATE SET payload=excluded.payload,revision=excluded.revision',
        [userId, payload, revision],
      );
      store._journal.record(before, after);
      store._documentCache.remove('vpn-workspace-v1');
      invalidate();
      return revision;
    });
  }

  Future<void> materialize() async {
    final state = db
        .select('SELECT revision FROM vpn_overlay_state WHERE singleton=1')
        .firstOrNull;
    if (state == null) return;
    final projection = await read();
    if (!projection.dirty) return;
    final payload = await store._encrypt(
      'vpn-workspace-v1',
      projection.revision,
      projection.source!,
    );
    store._transaction(() {
      _checkRevision(projection.baseRevision, projection.revision);
      db.execute(
        "UPDATE documents SET payload=?,revision=? WHERE id='vpn-workspace-v1'",
        [payload, projection.revision],
      );
      db.execute('DELETE FROM vpn_user_overlay');
      db.execute('DELETE FROM vpn_profile_overlay');
      db.execute('DELETE FROM vpn_overlay_state');
      store._documentCache.remove('vpn-workspace-v1');
      invalidate();
    });
  }
}
