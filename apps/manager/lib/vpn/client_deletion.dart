part of 'vpn_controller.dart';

extension ClientDeletion on VpnController {
  Iterable<VpnUser> get pendingDeletions =>
      workspace.users.where((u) => u.deleted && !u.deletionComplete);
  Iterable<VpnUser> get pendingRevocations =>
      pendingDeletions.where((u) => !u.revocationSettled);
  Iterable<VpnUser> get blockingRevocations =>
      pendingRevocations.where((u) => u.deletion?['hidden'] != true);
  bool hasPendingRevocation(String serverId) => pendingRevocations.any(
    (u) => (u.deletion!['targets'] as Map).entries.any(
      (e) =>
          vpnServerId(e.key as String) == serverId &&
          !vpnRevocationSettled(e.value),
    ),
  );
  bool hasBlockingRevocation(String serverId) => blockingRevocations.any(
    (u) => (u.deletion!['targets'] as Map).entries.any(
      (e) =>
          vpnServerId(e.key as String) == serverId &&
          !vpnRevocationSettled(e.value),
    ),
  );
  bool ownsDeletion(VpnUser user) => user.deletion?['executor'] == _deviceId;

  /// Whether an unsettled revocation on [target] holds up work beyond its
  /// own server. One on a server in service mode does not: it is retried on
  /// its own whenever that server is reachable, while publication, the
  /// Drive file and the other servers' plans go on. Work on the same
  /// physical server still waits for it ([hasPendingRevocation]).
  bool _revocationHoldsAll(String target, Object? record) =>
      !vpnRevocationSettled(record) && !workspace.inServiceMode(target);

  /// Pending revocations that are global barriers: at least one of their
  /// unsettled targets is outside service mode.
  Iterable<VpnUser> get _globalRevocations => pendingRevocations.where(
    (u) => (u.deletion!['targets'] as Map).entries.any(
      (e) => _revocationHoldsAll(e.key as String, e.value),
    ),
  );

  /// Whether a server [record] shows the app has something there: a
  /// readback with resources, a request sent or a payload applied.
  bool _hasServerState(Map<String, dynamic> record) =>
      (record['observed'] as List? ?? const []).isNotEmpty ||
      record['pending'] != null ||
      record['appliedPayload'] != null;

  Iterable<VpnUser> get visibleDeletions =>
      pendingDeletions.where((u) => u.deletion?['hidden'] != true);

  bool canForceDelete(VpnUser user) =>
      user.deleted &&
      !user.deletionComplete &&
      (user.deletion!['targets'] as Map).values.any(
        (t) =>
            !vpnRevocationSettled(t) &&
            (t['connectionAttempts'] as int? ?? 0) >= 3,
      );

  /// Hide the tombstone, never claim that an unreachable server revoked access.
  Future<void> forceDeleteClient(String userId) => _run((token) async {
    final user = workspace.users.singleWhere((u) => u.id == userId);
    if (!canForceDelete(user)) throw const FormatException('vpn_conflict');
    await _saveDeletion(userId, {...user.deletion!, 'hidden': true});
    await _reconcileDeletions(token, only: userId, force: true);
  });

  Future<void> _connectDeletionServers(
    CancellationToken token, {
    String? only,
    bool manual = false,
  }) async {
    final connect = connectForDeletion;
    if (connect == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final targets = <String, List<(String, String)>>{};
    for (final user in pendingRevocations) {
      if (only != null && user.id != only ||
          !manual &&
              (!ownsDeletion(user) || user.deletion?['hidden'] == true)) {
        continue;
      }
      for (final entry in (user.deletion!['targets'] as Map).entries) {
        final record = entry.value as Map;
        final target = entry.key as String;
        if (vpnRevocationSettled(record) ||
            remote(target) != null ||
            !manual &&
                ((record['connectionAttempts'] as int? ?? 0) >= 3 ||
                    (record['connectAfter'] as int? ?? 0) > now)) {
          continue;
        }
        (targets[vpnServerId(target)] ??= []).add((user.id, target));
      }
    }
    // Each physical server is contacted concurrently once per round, even with
    // many clients and protocols. A server in service mode is connected in
    // the background instead: it never delays the revocations of reachable
    // servers or the removal of the published file. Its result is recorded
    // by the next round; only a person's retry waits for it.
    final connectionResults = <String, bool?>{};
    final awaited = <String>[];
    for (final serverId in targets.keys) {
      if (manual || !workspace.inServiceMode(serverId)) {
        awaited.add(serverId);
      } else if (_deletionConnected.containsKey(serverId)) {
        connectionResults[serverId] = _deletionConnected.remove(serverId);
      } else if (_deletionConnecting.add(serverId)) {
        unawaited(() async {
          bool? connected;
          try {
            connected = await connect(serverId);
          } catch (_) {
            connected = false;
          }
          _deletionConnecting.remove(serverId);
          if (_disposed) return;
          _deletionConnected[serverId] = connected;
          _scheduleReconcile();
        }());
      }
    }
    await _mapServersBounded(awaited, (serverId) async {
      token.check();
      try {
        connectionResults[serverId] = await connect(serverId);
      } catch (_) {
        connectionResults[serverId] = false;
      }
    }, cancellation: token);
    token.check();
    final deletions = <String, Map<String, dynamic>>{};
    for (final entry in targets.entries) {
      final connected = connectionResults[entry.key];
      if (connected == null) continue;
      for (final target in entry.value) {
        final user = workspace.users.singleWhere((u) => u.id == target.$1);
        final deletion = deletions[user.id] ?? user.deletion!;
        final record = Map<String, dynamic>.from(
          (deletion['targets'] as Map)[target.$2] as Map,
        );
        if (vpnRevocationSettled(record)) continue;
        // A live SSH session is not enough: the runner must be current and,
        // for VLESS, the panel login verified. Name what is missing (or why
        // SSH refused) instead of waiting silently; a busy runner is
        // transient and keeps the previous reason.
        final issue = remote(target.$2) == null
            ? remoteIssue?.call(target.$2)
            : null;
        final error = !connected
            ? (issue != null && issue.startsWith('ssh:')
                  ? issue
                  : 'vpn_connection')
            : issue == 'vpn_runner_busy'
            ? record['error']
            : issue ??
                  (isVpnRemoteIssue(record['error']) ? null : record['error']);
        deletions[user.id] = {
          ...deletion,
          'targets': {
            ...deletion['targets'] as Map,
            target.$2: {
              ...record,
              'connectionAttempts': connected
                  ? 0
                  : ((manual ? 0 : record['connectionAttempts'] as int? ?? 0) +
                            1)
                        .clamp(0, 3),
              'connectAfter': DateTime.now().millisecondsSinceEpoch + 5000,
              if (error != record['error']) 'error': error,
            },
          },
        };
      }
    }
    if (deletions.isEmpty) return;
    token.check();
    // The connection results are one checkpoint. The revision check and the
    // entire set of changed tombstones commit together before any revocation.
    await _write(
      workspace.copy(
        users: [
          for (final user in workspace.users)
            if (deletions[user.id] case final deletion?)
              VpnUser(
                id: user.id,
                login: user.login,
                name: user.name,
                baseTemplate: user.baseTemplate,
                baseTemplateName: user.baseTemplateName,
                enabled: false,
                deletion: deletion,
              )
            else
              user,
        ],
      ),
    );
    _notify();
  }

  Future<void> _saveDeletion(
    String userId,
    Map<String, dynamic> deletion,
  ) async {
    final user = workspace.users.singleWhere(
      (u) => u.id == userId && u.deleted,
    );
    if (canonicalJson(user.deletion) == canonicalJson(deletion)) return;
    await _write(
      workspace.copy(
        users: [
          for (final u in workspace.users)
            if (u.id != userId)
              u
            else
              VpnUser(
                id: u.id,
                login: u.login,
                name: u.name,
                baseTemplate: u.baseTemplate,
                baseTemplateName: u.baseTemplateName,
                enabled: false,
                deletion: deletion,
              ),
        ],
      ),
    );
    _notify();
  }

  Future<void> _saveDeletionTargets(
    String userId,
    Map<String, Map<String, dynamic>> targetUpdates,
  ) async {
    final user = workspace.users.where((u) => u.id == userId).firstOrNull;
    if (user?.deletion == null) return;
    final deletion = user!.deletion!;
    final nextTargets = {
      ...deletion['targets'] as Map,
      for (final e in targetUpdates.entries) e.key: e.value,
    };
    await _saveDeletion(userId, {...deletion, 'targets': nextTargets});
  }

  Future<void> deleteUser(
    VpnUser expected, {
    Map<String, dynamic>? file,
    bool awaitReconcile = true,
  }) => deleteUsers(
    [expected],
    files: {expected.id: ?file},
    awaitReconcile: awaitReconcile,
  );

  Future<void> deleteUsers(
    List<VpnUser> expected, {
    Map<String, Map<String, dynamic>> files = const {},
    bool awaitReconcile = false,
  }) async {
    await _run((token) async {
      if (!loaded ||
          expected.isEmpty ||
          expected.map((u) => u.id).toSet().length != expected.length) {
        throw const FormatException('vpn_conflict');
      }
      for (final before in expected) {
        final user = workspace.users
            .where((u) => u.id == before.id)
            .firstOrNull;
        if (user == null ||
            user.deleted ||
            canonicalJson(user.toJson()) != canonicalJson(before.toJson())) {
          throw const FormatException('vpn_conflict');
        }
      }
      final targets = {
        ...workspace.serverIds,
        for (final e in workspace.servers.entries)
          if (_hasServerState(e.value)) e.key,
      };
      final deleted = {
        for (final user in expected)
          user.id: VpnUser(
            id: user.id,
            login: user.login,
            name: user.name,
            baseTemplate: user.baseTemplate,
            baseTemplateName: user.baseTemplateName,
            enabled: false,
            deletion: {
              'version': 1,
              'id': newVpnId(),
              'executor': _deviceId,
              'targets': {
                for (final id in targets)
                  id: {
                    'status': 'waiting',
                    'identity': workspace.servers[id]?['identity'],
                  },
              },
              if (files[user.id] case final file?)
                'file': {...file, 'status': 'waiting'},
            },
          ),
      };
      final profiles = {...workspace.profiles}
        ..removeWhere((id, _) => deleted.containsKey(id));
      final servers = {
        for (final e in workspace.servers.entries)
          e.key: {
            ...e.value,
            if (targets.contains(e.key) && e.value['pending'] == null) ...{
              'authorizedPayload': null,
              'paused': true,
            },
          },
      };
      // User tombstone, queued revocations and removal of cached YAML are one
      // transaction. A failed save must never revoke access or delete a file.
      await _write(
        workspace.copy(
          users: [for (final u in workspace.users) deleted[u.id] ?? u],
          profiles: profiles,
          servers: servers,
        ),
      );
      plans = [];
      results.removeWhere((id, _) => deleted.containsKey(id));
      if (deleted.containsKey(selectedUserId)) selectedUserId = null;
      _notify();
      if (awaitReconcile) {
        await _reconcileDeletions(token);
      }
    });
    if (!awaitReconcile && !_disposed) {
      unawaited(reconcile());
    }
  }

  Future<void> _deletionGuard(String userId, String deletionId) async {
    final current = workspace.users.singleWhere((u) => u.id == userId);
    if (!current.deleted ||
        current.deletion!['id'] != deletionId ||
        !ownsDeletion(current) ||
        (await repository.readVpn()).revision != revision) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
  }

  /// Another device may continue only after looking up every existing job ID.
  /// Running work stays with its executor; an offline server cannot be guessed.
  Future<void> retryDeletion(String userId) => _run((token) async {
    await _connectDeletionServers(token, only: userId, manual: true);
    final user = workspace.users.singleWhere(
      (u) => u.id == userId && u.deleted,
    );
    if (!ownsDeletion(user)) {
      for (final e in (user.deletion!['targets'] as Map).entries) {
        if (vpnRevocationSettled(e.value)) continue;
        final r = remote(e.key as String);
        if (r == null) throw const FormatException('vpn_connection');
        if (e.value['identity'] != null && e.value['identity'] != r.identity) {
          throw const FormatException('vpn_identity');
        }
        if (e.value['request'] case final Map request) {
          final response = await _request(
            r,
            RunnerRequest.status(request['id'] as String, 0),
            token,
            allowMissing: true,
          );
          if (response.code != 'missing' &&
              (response.jobs.length != 1 ||
                  response.jobs.single.id != request['id'] ||
                  !response.jobs.single.terminal)) {
            throw const FormatException('vpn_busy');
          }
        }
      }
      await _saveDeletion(userId, {...user.deletion!, 'executor': _deviceId});
    }
    await _approveRestored(
      (user.deletion!['targets'] as Map).keys.cast<String>(),
    );
    await _reconcileDeletions(token, only: userId, force: true);
  });

  Future<void> _reconcileDeletions(
    CancellationToken token, {
    String? only,
    bool force = false,
  }) async {
    _restoredTargets = await recovery?.readRestoredTargets() ?? {};
    await _connectDeletionServers(token, only: only);
    var refreshProfiles = false;
    for (final original in pendingDeletions.toList()) {
      if (only != null && original.id != only || !ownsDeletion(original)) {
        continue;
      }
      final deletionId = original.deletion!['id'] as String;
      final resumeHidden = force || original.deletion?['hidden'] == true;
      final targetsMap = original.deletion!['targets'] as Map;
      final targetsList = targetsMap.keys.cast<String>().where((target) {
        if (_restoredTargets.contains(target)) return false;
        final rec = targetsMap[target] as Map;
        if (vpnRevocationSettled(rec)) return false;
        if (!force &&
            (rec['retryAt'] as int? ?? 0) >
                DateTime.now().millisecondsSinceEpoch) {
          return false;
        }
        return remote(target) != null;
      }).toList();

      if (targetsList.isNotEmpty) {
        // Group targets by physical server host: targets on the same physical
        // server execute sequentially to preserve runner state consistency;
        // independent physical servers execute concurrently via worker pool.
        final physicalGroups = <String, List<String>>{};
        for (final target in targetsList) {
          physicalGroups.putIfAbsent(vpnServerId(target), () => []).add(target);
        }
        final groupList = physicalGroups.values.toList();

        // Phase 1 (Planning & Intent): Distinct servers contact runner daemons
        // concurrently to plan the revocation. Accumulate generated requests in-memory
        // and commit all request.json payloads in one atomic SQLite transaction before
        // apply requests are dispatched to remote runners.
        final phase1Updates = <String, Map<String, dynamic>>{};
        var nextGroupIndex = 0;
        await Future.wait([
          for (var i = 0; i < 4 && i < groupList.length; i++)
            () async {
              while (nextGroupIndex < groupList.length) {
                token.check();
                final targets = groupList[nextGroupIndex++];
                for (final target in targets) {
                  token.check();
                  var record = Map<String, dynamic>.from(
                    (workspace.users
                                .singleWhere((u) => u.id == original.id)
                                .deletion!['targets']
                            as Map)[target]
                        as Map,
                  );
                  if (record['request'] != null) continue;
                  final r = remote(target);
                  if (r == null) continue;
                  try {
                    await _deletionGuard(original.id, deletionId);
                    if (record['identity'] != null &&
                        record['identity'] != r.identity) {
                      throw const FormatException('vpn_identity');
                    }
                    // Drain or establish the fate of the old ordinary operation first.
                    final server =
                        workspace.servers[target] ?? <String, dynamic>{};
                    if (server['pending'] case final Map oldRequest) {
                      final old = await _request(
                        r,
                        RunnerRequest.status(oldRequest['id'] as String, 0),
                        token,
                        allowMissing: true,
                      );
                      if (old.code != 'missing' &&
                          (old.jobs.length != 1 ||
                              old.jobs.single.id != oldRequest['id'] ||
                              !old.jobs.single.terminal)) {
                        continue;
                      }
                      await _record(target, {
                        ...server,
                        'pending': null,
                        // Keep the drained job's real outcome, never the
                        // queued snapshot nobody polls again.
                        'job': old.code == 'missing'
                            ? null
                            : old.jobs.single
                                  .mergeEvents(
                                    server['job'] is Map
                                        ? RunnerJob.fromJson(
                                            Map<String, dynamic>.from(
                                              server['job'] as Map,
                                            ),
                                          )
                                        : null,
                                  )
                                  .toJson(),
                        'authorizedPayload': null,
                        'paused': true,
                        'cancelRequested': false,
                        'observingCancel': false,
                      });
                    }
                    final state = await _request(
                      r,
                      _stateRequest(target, r.panelId),
                      token,
                    );
                    final payload = _observedPayload(
                      target,
                      r.panelId,
                      _observations(state, target),
                      revoke: original,
                    );
                    final plan = await _request(
                      r,
                      _planRequest(target, r.panelId, payload),
                      token,
                    );
                    final preview = _preview(plan, target);
                    if (preview?['fingerprint'] is! String) {
                      throw const FormatException('vpn_failed');
                    }
                    final request = _applyRequest(
                      target,
                      vlessRevision({
                        'deletion': deletionId,
                        'target': target,
                        'generation': record['generation'] ?? 0,
                      }).substring(0, 32),
                      payload,
                      preview!['fingerprint'] as String,
                    );
                    record = {
                      ...record,
                      'identity': r.identity,
                      'status': 'waiting',
                      'request': request.json,
                      'error': null,
                    };
                    phase1Updates[target] = record;
                  } on SyncMergeFailure {
                    rethrow;
                  } on VaultFailure {
                    rethrow;
                  } catch (e) {
                    final issue = e is FormatException
                        ? e.message
                        : e is SshFailure
                        ? 'vpn_connection'
                        : 'vpn_runner';
                    phase1Updates[target] = {
                      ...record,
                      'status': 'error',
                      'error': issue,
                      'retryAt': DateTime.now().millisecondsSinceEpoch + 30000,
                    };
                  }
                }
              }
            }(),
        ]);

        if (phase1Updates.isNotEmpty) {
          await _saveDeletionTargets(original.id, phase1Updates);
        }

        // Phase 2 (Execution & Verification): Dispatch and monitor runner jobs
        // concurrently across physical servers. Accumulate verified terminal statuses
        // and commit all updated tombstone targets and observed server states.
        final phase2Updates = <String, Map<String, dynamic>>{};
        nextGroupIndex = 0;
        await Future.wait([
          for (var i = 0; i < 4 && i < groupList.length; i++)
            () async {
              while (nextGroupIndex < groupList.length) {
                token.check();
                final targets = groupList[nextGroupIndex++];
                for (final target in targets) {
                  token.check();
                  var record = Map<String, dynamic>.from(
                    (workspace.users
                                .singleWhere((u) => u.id == original.id)
                                .deletion!['targets']
                            as Map)[target]
                        as Map,
                  );
                  if (vpnRevocationSettled(record) ||
                      record['request'] == null) {
                    continue;
                  }
                  final r = remote(target);
                  if (r == null) continue;
                  try {
                    await _deletionGuard(original.id, deletionId);
                    if (record['identity'] != null &&
                        record['identity'] != r.identity) {
                      throw const FormatException('vpn_identity');
                    }
                    final request = RunnerRequest.fromJson(
                      Map<String, Object?>.from(record['request'] as Map),
                    );
                    final payload =
                        jsonDecode(request.json['payload'] as String) as Map;
                    if (!(payload['revokedUsers'] as List? ?? []).contains(
                          original.id,
                        ) ||
                        payload['workspaceId'] !=
                            workspace.resourceWorkspaceId(target)) {
                      throw const FormatException('vpn_conflict');
                    }
                    var response = await _request(
                      r,
                      RunnerRequest.status(request.id!, 0),
                      token,
                      allowMissing: true,
                    );
                    if (response.code == 'missing') {
                      await _deletionGuard(original.id, deletionId);
                      response = await _request(r, request, token);
                    }
                    if (response.jobs.length != 1 ||
                        response.jobs.single.id != request.id) {
                      throw const FormatException('vpn_failed');
                    }
                    final job = response.jobs.single;
                    record = {
                      ...record,
                      'job': job.toJson(),
                      'error': null,
                      'retryAt': 0,
                    };
                    if (job.status == 'succeeded') {
                      final state = await _request(
                        r,
                        _stateRequest(target, r.panelId),
                        token,
                      );
                      final observed = _observations(state, target);
                      final owned = observed
                          ?.where(
                            (o) =>
                                o['workspaceId'] ==
                                workspace.resourceWorkspaceId(target),
                          )
                          .toList();
                      final requested = (payload['resources'] as List)
                          .map((r) => r['id'])
                          .toSet();
                      if (owned == null ||
                          !requested.every(
                            (id) => owned.any((o) => o['id'] == id),
                          ) ||
                          owned.any(
                            (o) =>
                                o['confirmed'] != true ||
                                (o['clients'] as List).any(
                                  (c) =>
                                      c['id'] == original.id &&
                                      c['enabled'] == true,
                                ),
                          )) {
                        throw const FormatException('vpn_conflict');
                      }
                      await _record(target, {
                        ...workspace.servers[target] ?? <String, dynamic>{},
                        'identity': r.identity,
                        'panelId': r.panelId,
                        'observed': observed,
                        'error': null,
                        'verifiedAt': DateTime.now().toUtc().toIso8601String(),
                      });
                      record = {...record, 'status': 'revoked'};
                      refreshProfiles = true;
                    } else if (job.terminal) {
                      if (resumeHidden &&
                          job.status == 'failed' &&
                          job.checkpoint == 0) {
                        // No resource was applied. A fresh plan can recover a stale
                        // fingerprint; resuming the same immutable preview cannot.
                        record = {
                          ...record,
                          'status': 'waiting',
                          'request': null,
                          'generation': (record['generation'] as int? ?? 0) + 1,
                        };
                      } else if (resumeHidden &&
                          [
                            'failed',
                            'partially_applied',
                          ].contains(job.status)) {
                        await _deletionGuard(original.id, deletionId);
                        await _request(
                          r,
                          RunnerRequest.resume(request.id!),
                          token,
                        );
                        record = {...record, 'status': 'running'};
                      } else if (resumeHidden && job.status == 'cancelled') {
                        record = {
                          ...record,
                          'status': 'waiting',
                          'request': null,
                          'generation': (record['generation'] as int? ?? 0) + 1,
                        };
                      } else {
                        record = {
                          ...record,
                          'status': 'error',
                          'error': 'vpn_revocation_failed',
                          'retryAt':
                              DateTime.now().millisecondsSinceEpoch + 30000,
                        };
                      }
                    } else {
                      record = {...record, 'status': 'running'};
                    }
                    phase2Updates[target] = record;
                  } on SyncMergeFailure {
                    rethrow;
                  } on VaultFailure {
                    rethrow;
                  } catch (e) {
                    final issue = e is FormatException
                        ? e.message
                        : e is SshFailure
                        ? 'vpn_connection'
                        : 'vpn_runner';
                    phase2Updates[target] = {
                      ...record,
                      'status': 'error',
                      'error': issue,
                      'retryAt': DateTime.now().millisecondsSinceEpoch + 30000,
                    };
                  }
                }
              }
            }(),
        ]);

        if (phase2Updates.isNotEmpty) {
          await _saveDeletionTargets(original.id, phase2Updates);
        }
      }

      final user = workspace.users.singleWhere((u) => u.id == original.id);
      final file = user.deletion!['file'] as Map?;
      // A revocation left only on servers in service mode does not hold the
      // file: their resources are already out of every published profile,
      // and the tombstone keeps those targets until they are revoked.
      final canCleanupFile =
          user.deletion?['hidden'] == true ||
          !(user.deletion!['targets'] as Map).entries.any(
            (e) => _revocationHoldsAll(e.key as String, e.value),
          );
      if (canCleanupFile &&
          file != null &&
          file['status'] != 'deleted' &&
          (force ||
              (file['retryAt'] as int? ?? 0) <=
                  DateTime.now().millisecondsSinceEpoch)) {
        var next = Map<String, dynamic>.from(file);
        try {
          if (deletePublishedFile == null) {
            throw const PublicationFailure(PublicationIssue.unavailable);
          }
          await deletePublishedFile!(
            user,
            () => _deletionGuard(user.id, deletionId),
          );
          next = {...next, 'status': 'deleted', 'error': null, 'retryAt': 0};
        } on SyncMergeFailure {
          rethrow;
        } catch (e) {
          next = {
            ...next,
            'status': 'error',
            'error': e is PublicationFailure ? e.issue.name : 'network',
            'retryAt': DateTime.now().millisecondsSinceEpoch + 30000,
          };
        }
        await _saveDeletion(user.id, {...user.deletion!, 'file': next});
      }
    }
    if (refreshProfiles) await _profiles();
  }

  /// A payload for [target] built from its [observed] state instead of from
  /// `desired()`: every resource and client stays exactly as the server has
  /// it, except the clients in [enabled], which get that state, and
  /// [revoke], which is disabled and named in `revokedUsers`. Only a
  /// deletion revokes: the runner remembers a revoked ID for good.
  ///
  /// A resource the server no longer has is sent as deleted: its last spec
  /// would otherwise create it again. Its clients are not compared.
  ///
  /// One users list serves every resource, so nobody may gain access
  /// through it: a client enabled on one resource must be enabled on every
  /// one (else `vpn_conflict`). A client disabled where it exists and
  /// absent elsewhere is sent disabled: an AmneziaWG interface keeps a
  /// disabled record of a removed client that a newer one lacks, and
  /// adding it there disabled grants nothing. No client is enabled where
  /// the server lacks it. Unconfirmed access sets are refused as well.
  Map<String, Object?> _observedPayload(
    String target,
    String panel,
    List<Map<String, dynamic>>? observed, {
    Map<String, bool> enabled = const {},
    VpnUser? revoke,
  }) {
    if (observed == null) throw const FormatException('vpn_failed');
    final owned =
        observed
            .where(
              (o) => o['workspaceId'] == workspace.resourceWorkspaceId(target),
            )
            .toList()
          ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    if (owned.any((o) => o['confirmed'] != true)) {
      throw const FormatException('vpn_conflict');
    }
    final clients = <String, Map<String, Object?>>{};
    final presence = <String, int>{};
    var serving = 0;
    for (final resource in owned) {
      final spec = resource['spec'] as Map;
      if (observationGone(resource) || spec['internal'] == true) continue;
      serving++;
      for (final c in resource['clients'] as List) {
        if (c['id'] == revoke?.id) continue;
        final client = <String, Object?>{
          'id': c['id'],
          'enabled': enabled[c['id']] ?? c['enabled'],
          if (isTtTarget(target)) 'login': c['username'],
        };
        // A partial operation can leave different access sets. Do not
        // broaden anyone's access merely to fit a workspace-wide payload.
        final seen = clients[c['id'] as String];
        if (seen != null && canonicalJson(seen) != canonicalJson(client)) {
          throw const FormatException('vpn_conflict');
        }
        clients[c['id'] as String] = client;
        presence.update(c['id'] as String, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    if (clients.values.any(
      (c) => c['enabled'] == true && presence[c['id']] != serving,
    )) {
      throw const FormatException('vpn_conflict');
    }
    final otherUsers = clients.values.toList()
      ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    return {
      'version': 1,
      if (isAwgTarget(target)) 'protocol': 'awg',
      if (isTtTarget(target)) 'protocol': 'tt',
      'workspaceId': workspace.resourceWorkspaceId(target),
      'panelId': isAwgTarget(target) || isTtTarget(target)
          ? workspace.resourceWorkspaceId(target)
          : panel,
      'resources': [
        for (final o in owned)
          if (observationGone(o) && (o['spec'] as Map)['deleted'] != true)
            {...o['spec'] as Map, 'deleted': true, 'enabled': false}
          else
            o['spec'],
      ],
      'users': [
        ...otherUsers,
        if (revoke != null)
          {
            'id': revoke.id,
            'enabled': false,
            if (isTtTarget(target)) 'login': revoke.login,
          },
      ],
      if (revoke != null) 'revokedUsers': [revoke.id],
    };
  }
}
