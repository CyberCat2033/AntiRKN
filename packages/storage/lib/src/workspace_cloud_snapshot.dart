part of 'workspace_database.dart';

// Cloud snapshot v5 (schemas/cloud-snapshot-v5.json): the automatic sync
// snapshot carries intent only. Observations, compiled profiles, runner
// answers and publication results are this device's cache: they never leave
// it and survive a pull of the same workspace and the same server.

/// No job, or one the runner has finished: its status is read back later.
bool _terminalJob(Object? job) =>
    job == null || job is Map && runnerStatusTerminal(job['status']);

/// True while [journal] still drives a server operation.
bool _runnerUnfinished(Map journal) =>
    cloudRunnerUnfinished.any((key) => journal[key] != null) ||
    !_terminalJob(journal['selected']);

/// The intent part of one captured record, or null when it is cache only.
String? _cloudSource(String table, String id, String source) {
  if (table == 'servers') {
    final profile = jsonDecode(source) as Map<String, dynamic>
      ..removeWhere((key, _) => cloudServerCache.contains(key));
    return canonicalJson(profile);
  }
  if (cloudLocalDocument.hasMatch(id)) return null;
  if (id == 'vpn-workspace-v1') {
    return canonicalJson(_cloudVpn(jsonDecode(source) as Map<String, dynamic>));
  }
  if (id.startsWith('runner/')) {
    final journal = jsonDecode(source) as Map<String, dynamic>;
    if (!_runnerUnfinished(journal)) return null;
    journal.removeWhere((key, _) => !cloudRunnerKeep.contains(key));
    if (_terminalJob(journal['selected'])) {
      journal['selected'] = null;
      journal['cursor'] = 0;
    }
    return canonicalJson(journal);
  }
  return source;
}

Map<String, dynamic> _cloudVpn(Map<String, dynamic> vpn) {
  final servers = <String, Object?>{};
  for (final entry in (vpn['servers'] as Map).entries) {
    final record = Map<String, dynamic>.from(entry.value as Map);
    final settled = record['authorizedPayload'] == record['appliedPayload'];
    record.removeWhere(
      (key, value) =>
          cloudVpnServerCache.contains(key) ||
          settled && cloudVpnServerCacheWhenSettled.contains(key) ||
          cloudVpnServerCacheWhenTerminal.contains(key) && _terminalJob(value),
    );
    if (record.isNotEmpty) servers[entry.key as String] = record;
  }
  final profiles = <String, Object?>{};
  for (final entry in (vpn['profiles'] as Map? ?? {}).entries) {
    final profile = Map<String, dynamic>.from(entry.value as Map)
      ..removeWhere((key, _) => !cloudVpnProfileKeep.contains(key));
    if (profile.isNotEmpty) profiles[entry.key as String] = profile;
  }
  return {...vpn, 'servers': servers, 'profiles': profiles};
}

/// Rejects any local cache key in a v5 record; the check is by keys only.
void _checkCloudRecord(String table, String id, String source) {
  bool cached(Map value, Set<String> keys) => value.keys.any(keys.contains);
  if (table == 'servers') {
    if (cached(jsonDecode(source) as Map, cloudServerCache)) {
      throw const FormatException();
    }
    return;
  }
  if (!cloudSnapshotDocumentId.hasMatch(id)) throw const FormatException();
  if (id == 'vpn-workspace-v1') {
    final vpn = jsonDecode(source) as Map;
    for (final record in (vpn['servers'] as Map).values) {
      if (cached(record as Map, cloudVpnServerCache)) {
        throw const FormatException();
      }
    }
    for (final profile in (vpn['profiles'] as Map? ?? {}).values) {
      if ((profile as Map).keys.any((k) => !cloudVpnProfileKeep.contains(k))) {
        throw const FormatException();
      }
    }
  } else if (id.startsWith('runner/')) {
    final journal = jsonDecode(source) as Map;
    if (journal.keys.any((key) => !cloudRunnerKeep.contains(key)) ||
        !_runnerUnfinished(journal)) {
      throw const FormatException();
    }
  }
}

void _checkCloudAuthor(Object? value) {
  if (value is! Map ||
      value.keys.any((key) => !cloudSnapshotAuthorKeys.contains(key)) ||
      value['deviceId'] is! String ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(value['deviceId'] as String)) {
    throw const FormatException();
  }
  final name = value['deviceName'];
  if (name != null &&
      (name is! String ||
          name.isEmpty ||
          name.length > cloudSnapshotAuthorNameMax ||
          name.contains(RegExp(r'[\x00-\x1f\x7f]')))) {
    throw const FormatException();
  }
}

/// Identifies what a snapshot says the user decided: the same intent gives
/// the same digest on any device, whatever its cache, revisions or clock.
String _intentDigest(Map<String, dynamic> data) {
  final records = [
    for (final table in ['servers', 'documents'])
      for (final dynamic row in data[table] as List)
        [table, row['id'], row['source']],
  ];
  return _hexBytes(
    const DartSha256()
        .hashSync(
          utf8.encode(
            jsonEncode([data['version'], data['workspaceId'], records]),
          ),
        )
        .bytes,
  );
}

/// `host|fingerprint`, the identity runner journals and VPN records use.
String? _serverIdentity(Map<String, dynamic>? profile) {
  final key = profile?['hostKey'];
  return key is Map && key['fingerprint'] is String
      ? '${profile!['host']}|${key['fingerprint']}'
      : null;
}

/// A v5 snapshot of this workspace with this device's cache put back where
/// the server (id and pinned host key) is still the same. Returns the data to
/// restore and the physical servers whose cache must be read again.
Future<(Map<String, dynamic>, List<String>)> _withLocalCache(
  WorkspaceDatabase store,
  Map<String, dynamic> incoming,
) async {
  final data = {
    ...incoming,
    'servers': [
      for (final dynamic row in incoming['servers'] as List)
        Map<String, dynamic>.from(row as Map),
    ],
    'documents': [
      for (final dynamic row in incoming['documents'] as List)
        Map<String, dynamic>.from(row as Map),
    ],
  };
  final servers = data['servers'] as List<Map<String, dynamic>>;
  final documents = data['documents'] as List<Map<String, dynamic>>;
  final remoteProfiles = {
    for (final row in servers)
      row['id'] as String:
          jsonDecode(row['source'] as String) as Map<String, dynamic>,
  };
  Map<String, dynamic>? remoteVpn;
  for (final row in documents) {
    if (row['id'] == 'vpn-workspace-v1') {
      remoteVpn = jsonDecode(row['source'] as String) as Map<String, dynamic>;
    }
  }
  final physical = <String>{
    ...remoteProfiles.keys,
    for (final target in (remoteVpn?['servers'] as Map? ?? {}).keys)
      vpnServerId(target as String),
  };
  final local = store._db
      .select('SELECT workspace_id FROM sync_identity WHERE singleton=1')
      .single;
  if (local['workspace_id'] != data['workspaceId']) {
    return (data, physical.toList()..sort());
  }
  final localProfiles = <String, Map<String, dynamic>>{};
  for (final row in store._db.select('SELECT * FROM servers')) {
    final id = row['id'] as String;
    localProfiles[id] =
        jsonDecode(
              await store._decrypt(
                'server:$id',
                row['revision'] as int,
                row['payload'] as Uint8List,
              ),
            )
            as Map<String, dynamic>;
  }
  // The same machine: same saved server and the same pinned host key.
  String? same(String serverId) {
    final identity = _serverIdentity(remoteProfiles[serverId]);
    return identity != null &&
            identity == _serverIdentity(localProfiles[serverId])
        ? identity
        : null;
  }

  // Servers whose observations are not kept here must be read again.
  final stale = {
    for (final id in physical)
      if (same(id) == null) id,
  };
  for (final row in servers) {
    final id = row['id'] as String, localProfile = localProfiles[id];
    if (same(id) == null || localProfile == null) continue;
    final profile = remoteProfiles[id]!;
    for (final key in cloudServerCache) {
      if (localProfile[key] != null) profile[key] = localProfile[key];
    }
    row['source'] = canonicalJson(profile);
  }
  final localDocuments = <String, String>{};
  for (final row in store._db.select(
    "SELECT * FROM documents WHERE id LIKE 'runner/%' OR id LIKE 'publication/result/%'",
  )) {
    final id = row['id'] as String;
    localDocuments[id] = await store._decrypt(
      id,
      row['revision'] as int,
      row['payload'] as Uint8List,
    );
  }
  final localVpnSource = (await store._vpnOverlay.read()).source;
  if (localVpnSource == null) stale.addAll(physical);
  if (remoteVpn != null && localVpnSource != null) {
    final localVpn = jsonDecode(localVpnSource) as Map<String, dynamic>;
    final desired = VpnWorkspace.decode(jsonEncode(remoteVpn));
    final localServers = localVpn['servers'] as Map? ?? {};
    for (final entry in (remoteVpn['servers'] as Map).entries) {
      final target = entry.key as String, record = entry.value as Map;
      final cache = localServers[target] as Map?;
      final identity = same(vpnServerId(target));
      if (cache == null ||
          identity == null ||
          cache['identity'] != identity ||
          (record['identity'] ?? identity) != identity ||
          cache['verifiedAt'] == null) {
        stale.add(vpnServerId(target));
        continue;
      }
      for (final key in cloudVpnServerCache) {
        if (key != 'appliedPayload' && cache[key] != null) {
          record[key] = cache[key];
        }
      }
      // The last applied payload stays valid only for exactly this intent.
      final applied = cache['appliedPayload'];
      final panelId = record['panelId'] ?? cache['panelId'];
      if (record['authorizedPayload'] == null &&
          applied is String &&
          cache['authorizedPayload'] == applied &&
          panelId is String) {
        try {
          if (canonicalJson(jsonDecode(applied)) ==
              canonicalJson(desired.desired(target, panelId))) {
            record['authorizedPayload'] = applied;
            record['appliedPayload'] = applied;
          }
        } catch (_) {}
      }
      if (record['job'] == null && cache['job'] != null) {
        if (_terminalJob(cache['job'])) record['job'] = cache['job'];
      }
    }
    final users = {
      for (final dynamic user in remoteVpn['users'] as List)
        user['id'] as String: user as Map,
    };
    final localProfilesCache = localVpn['profiles'] as Map? ?? {};
    for (final entry in (remoteVpn['profiles'] as Map? ?? {}).entries) {
      final cache = localProfilesCache[entry.key] as Map?,
          profile = entry.value;
      if (cache == null ||
          users[entry.key]?['deleted'] == true ||
          cache['publicationWorkspaceId'] !=
              (profile as Map)['publicationWorkspaceId']) {
        continue;
      }
      for (final item in cache.entries) {
        profile.putIfAbsent(item.key, () => item.value);
      }
    }
    for (final row in documents) {
      if (row['id'] == 'vpn-workspace-v1') {
        row['source'] = canonicalJson(remoteVpn);
      }
    }
    // Verified results stay while the client and its binding are the same.
    final bindings = <String, String?>{
      for (final row in documents)
        if ((row['id'] as String).startsWith('publication/binding/'))
          (row['id'] as String).split('/').last:
              (jsonDecode(row['source'] as String) as Map)['id'] as String?,
    };
    for (final entry in localDocuments.entries) {
      if (!cloudLocalDocument.hasMatch(entry.key)) continue;
      final userId = entry.key.split('/').last;
      final result = jsonDecode(entry.value) as Map;
      if (users[userId] != null && result['binding'] == bindings[userId]) {
        documents.add({'id': entry.key, 'revision': 1, 'source': entry.value});
      }
    }
  }
  // Runner journals: the snapshot's unfinished operation wins; panel access,
  // discovery, egress and finished jobs come from this device's cache.
  final remoteRunners = {
    for (final row in documents)
      if ((row['id'] as String).startsWith('runner/')) row['id'] as String: row,
  };
  for (final entry in localDocuments.entries) {
    if (!entry.key.startsWith('runner/')) continue;
    final serverId = entry.key.substring('runner/'.length);
    final cache = jsonDecode(entry.value) as Map<String, dynamic>;
    final identity = same(serverId);
    final row = remoteRunners[entry.key];
    final journal = row == null
        ? null
        : jsonDecode(row['source'] as String) as Map<String, dynamic>;
    if (identity == null ||
        cache['identity'] != identity ||
        (journal?['identity'] ?? identity) != identity) {
      continue;
    }
    final merged =
        journal ??
        <String, dynamic>{
          'version': cache['version'],
          'identity': identity,
          'pending': null,
          'selected': _terminalJob(cache['selected'])
              ? cache['selected']
              : null,
          'cursor': _terminalJob(cache['selected']) ? cache['cursor'] : 0,
        };
    for (final item in cache.entries) {
      if (!cloudRunnerKeep.contains(item.key)) merged[item.key] = item.value;
    }
    final source = canonicalJson(merged);
    if (row == null) {
      documents.add({'id': entry.key, 'revision': 1, 'source': source});
    } else {
      row['source'] = source;
    }
  }
  documents.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  return (data, stale.toList()..sort());
}

int _jsonBytes(Object? value) => utf8.encode(jsonEncode(value)).length;

/// Byte sizes of a captured snapshot by section. Only numbers leave here:
/// no ids, names or values, so it is safe to print for any database.
Map<String, int> _snapshotSectionSizes(String source) {
  final sizes = <String, int>{};
  void add(String section, int bytes) =>
      sizes[section] = (sizes[section] ?? 0) + bytes;
  final data = jsonDecode(source) as Map<String, dynamic>;
  for (final dynamic row in data['servers'] as List) {
    final profile = jsonDecode(row['source'] as String) as Map<String, dynamic>;
    for (final entry in profile.entries) {
      add(
        cloudServerCache.contains(entry.key)
            ? 'servers.cache'
            : 'servers.intent',
        _jsonBytes(entry.value),
      );
    }
  }
  for (final dynamic row in data['documents'] as List) {
    final id = row['id'] as String, text = row['source'] as String;
    if (id == 'template-draft') {
      add('template', utf8.encode(text).length);
    } else if (id == 'vpn-workspace-v1') {
      final vpn = jsonDecode(text) as Map<String, dynamic>;
      add('vpn.users', _jsonBytes(vpn['users']));
      add(
        'vpn.resources',
        _jsonBytes([vpn['inbounds'], vpn['awgInterfaces'], vpn['ttEndpoints']]),
      );
      for (final dynamic record in (vpn['servers'] as Map).values) {
        for (final entry in (record as Map).entries) {
          add(switch (entry.key) {
            'observed' => 'vpn.servers.observed',
            'authorizedPayload' || 'appliedPayload' => 'vpn.servers.payloads',
            _ => 'vpn.servers.state',
          }, _jsonBytes(entry.value));
        }
      }
      for (final dynamic profile in (vpn['profiles'] as Map? ?? {}).values) {
        for (final entry in (profile as Map).entries) {
          add(
            cloudVpnProfileKeep.contains(entry.key)
                ? 'vpn.profiles.intent'
                : 'vpn.profiles.yaml',
            _jsonBytes(entry.value),
          );
        }
      }
    } else if (id.startsWith('runner/')) {
      for (final entry in (jsonDecode(text) as Map).entries) {
        add(
          cloudRunnerKeep.contains(entry.key) ? 'runner.state' : 'runner.cache',
          _jsonBytes(entry.value),
        );
      }
    } else if (id.startsWith('publication/result/')) {
      add('publication.result', utf8.encode(text).length);
    } else if (id.startsWith('publication/binding/')) {
      add('publication.binding', utf8.encode(text).length);
    } else {
      add('publication.settings', utf8.encode(text).length);
    }
  }
  sizes['total'] = utf8.encode(source).length;
  return sizes;
}

extension WorkspaceSnapshotDiagnostics on WorkspaceDatabase {
  /// Section sizes in bytes of the snapshot this database would write: the
  /// file backup or, with [cloud], the automatic sync snapshot.
  @visibleForTesting
  Future<Map<String, int>> debugSnapshotSectionSizes({
    bool cloud = false,
  }) async => _snapshotSectionSizes(
    (await _currentSnapshot(this, cloud: cloud)).source,
  );

  /// Validates [source] as a file backup or, with [cloud], a sync snapshot.
  @visibleForTesting
  Future<void> debugValidateSnapshot(String source, {required bool cloud}) =>
      _validateBackupInBackground(source, cloud: cloud);
}

String? _executorOf(Object? operation) =>
    operation is Map && operation['executorDeviceId'] is String
    ? operation['executorDeviceId'] as String
    : null;

Map<String, dynamic>? _vpnRow(List<Map<String, dynamic>> rows) =>
    rows.where((row) => row['id'] == 'vpn-workspace-v1').firstOrNull;

/// A copy of [into] with the unfinished work of [from] whose executor device
/// [owns] accepts: VPN target records with an operation, runner journals with
/// one, and client deletions not yet complete. Choosing a version never
/// drops or orphans such work, and never brings back a client it deletes.
/// Where [into] holds other unfinished work on the same target, the chosen
/// version keeps it. Null when nothing had to be carried.
Map<String, dynamic>? _carryOperations(
  Map<String, dynamic> into,
  Map<String, dynamic> from,
  bool Function(String executor) owns,
) {
  // Records carried into a v5 snapshot keep its intent-only shape.
  final intent = into['version'] == cloudSnapshotVersion;
  final documents = [
    for (final dynamic row in into['documents'] as List)
      Map<String, dynamic>.from(row as Map),
  ];
  final source = [
    for (final dynamic row in from['documents'] as List)
      Map<String, dynamic>.from(row as Map),
  ];
  var changed = false;
  final intoRow = _vpnRow(documents), fromRow = _vpnRow(source);
  if (intoRow != null && fromRow != null) {
    final intoVpn = jsonDecode(intoRow['source'] as String) as Map;
    final fromVpn = jsonDecode(fromRow['source'] as String) as Map;
    final servers = Map<String, dynamic>.from(intoVpn['servers'] as Map);
    var vpnChanged = false;
    for (final entry in (fromVpn['servers'] as Map).entries) {
      final target = entry.key as String;
      final executor = _executorOf((entry.value as Map)['operation']);
      if (executor == null || !owns(executor)) continue;
      final other = _executorOf((servers[target] as Map?)?['operation']);
      if (other != null && other != executor) continue;
      var record = Map<String, dynamic>.from(entry.value as Map);
      if (intent) {
        final cleaned = _cloudVpn({
          'servers': {target: record},
          'profiles': const <String, Object?>{},
        })['servers'];
        record = Map<String, dynamic>.from((cleaned as Map)[target] as Map);
      }
      if (servers[target] != null &&
          canonicalJson(servers[target]) == canonicalJson(record)) {
        continue;
      }
      servers[target] = record;
      vpnChanged = true;
    }
    final users = [
      for (final dynamic user in intoVpn['users'] as List)
        Map<String, dynamic>.from(user as Map),
    ];
    final fromUsers = {
      for (final dynamic user in fromVpn['users'] as List)
        user['id'] as String: Map<String, dynamic>.from(user as Map),
    };
    for (final user in VpnWorkspace.decode(fromRow['source'] as String).users) {
      final executor = user.deletion?['executor'];
      if (!user.deleted ||
          user.deletionComplete ||
          executor is! String ||
          !owns(executor)) {
        continue;
      }
      final index = users.indexWhere((value) => value['id'] == user.id);
      if (index >= 0 && users[index]['deleted'] == true) continue;
      if (index >= 0) {
        users[index] = fromUsers[user.id]!;
      } else {
        users.add(fromUsers[user.id]!);
      }
      vpnChanged = true;
    }
    if (vpnChanged) {
      intoRow['source'] = canonicalJson({
        ...intoVpn,
        'servers': servers,
        'users': users,
      });
      changed = true;
    }
  }
  for (final row in source) {
    final id = row['id'] as String;
    if (!id.startsWith('runner/')) continue;
    final journal = jsonDecode(row['source'] as String) as Map;
    final executor = _executorOf(journal['operation']);
    if (!_runnerUnfinished(journal) || executor == null || !owns(executor)) {
      continue;
    }
    final index = documents.indexWhere((value) => value['id'] == id);
    if (index >= 0) {
      final current = jsonDecode(documents[index]['source'] as String) as Map;
      final other = _executorOf(current['operation']);
      if (_runnerUnfinished(current) && other != null && other != executor) {
        continue;
      }
    }
    final carried = intent
        ? _cloudSource('documents', id, row['source'] as String)!
        : row['source'] as String;
    if (index >= 0) {
      if (documents[index]['source'] == carried) continue;
      documents[index] = {...documents[index], 'source': carried};
    } else {
      documents.add({'id': id, 'revision': 1, 'source': carried});
    }
    changed = true;
  }
  if (!changed) return null;
  documents.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  return {...into, 'documents': documents};
}
