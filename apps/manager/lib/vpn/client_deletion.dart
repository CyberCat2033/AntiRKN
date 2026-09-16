part of 'vpn_controller.dart';

extension ClientDeletion on VpnController {
  Iterable<VpnUser> get pendingDeletions =>
      workspace.users.where((u) => u.deleted && !u.deletionComplete);
  Iterable<VpnUser> get pendingRevocations =>
      pendingDeletions.where((u) => !u.revocationComplete);
  bool hasPendingRevocation(String serverId) => pendingRevocations.any(
    (u) => (u.deletion!['targets'] as Map).entries.any(
      (e) =>
          vpnServerId(e.key as String) == serverId &&
          e.value['status'] != 'revoked',
    ),
  );
  bool ownsDeletion(VpnUser user) => user.deletion?['executor'] == _deviceId;

  Iterable<VpnUser> get visibleDeletions =>
      pendingDeletions.where((u) => u.deletion?['hidden'] != true);

  bool canForceDelete(VpnUser user) =>
      user.deleted &&
      !user.deletionComplete &&
      (user.deletion!['targets'] as Map).values.any(
        (t) =>
            t['status'] != 'revoked' &&
            (t['connectionAttempts'] as int? ?? 0) >= 3,
      );

  /// Hide the tombstone, never claim that an unreachable server revoked access.
  Future<void> forceDeleteClient(String userId) => _run((token) async {
    await checkProfileEffects();
    final user = workspace.users.singleWhere((u) => u.id == userId);
    if (!canForceDelete(user)) throw const FormatException('vpn_conflict');
    await _saveDeletion(userId, {...user.deletion!, 'hidden': true});
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
        if (record['status'] == 'revoked' ||
            remote(target) != null ||
            !manual &&
                ((record['connectionAttempts'] as int? ?? 0) >= 3 ||
                    (record['connectAfter'] as int? ?? 0) > now)) {
          continue;
        }
        (targets[vpnServerId(target)] ??= []).add((user.id, target));
      }
    }
    // Each physical server is contacted once per round, even with many clients
    // and protocols. Persist failures before another automatic round can run.
    for (final entry in targets.entries) {
      token.check();
      await checkProfileEffects();
      bool? connected;
      try {
        connected = await connect(entry.key);
      } catch (_) {
        connected = false;
      }
      token.check();
      if (connected == null) continue;
      for (final target in entry.value) {
        final user = workspace.users.singleWhere((u) => u.id == target.$1);
        final record = Map<String, dynamic>.from(
          user.deletion!['targets'][target.$2] as Map,
        );
        if (record['status'] == 'revoked') continue;
        await _deletionTarget(user.id, target.$2, {
          ...record,
          'connectionAttempts': connected
              ? 0
              : ((manual ? 0 : record['connectionAttempts'] as int? ?? 0) + 1)
                    .clamp(0, 3),
          'connectAfter': DateTime.now().millisecondsSinceEpoch + 5000,
          if (!connected) 'error': 'vpn_connection',
          if (connected && record['error'] == 'vpn_connection') 'error': null,
        });
      }
    }
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
                enabled: false,
                deletion: deletion,
              ),
        ],
      ),
    );
    _notify();
  }

  Future<void> _deletionTarget(
    String userId,
    String target,
    Map<String, dynamic> record,
  ) async {
    final deletion = workspace.users
        .singleWhere((u) => u.id == userId)
        .deletion!;
    await _saveDeletion(userId, {
      ...deletion,
      'targets': {...deletion['targets'] as Map, target: record},
    });
  }

  Future<void> deleteUser(VpnUser expected, {Map<String, dynamic>? file}) =>
      deleteUsers([expected], files: {expected.id: ?file});

  Future<void> deleteUsers(
    List<VpnUser> expected, {
    Map<String, Map<String, dynamic>> files = const {},
  }) => _run((token) async {
    if (!loaded ||
        expected.isEmpty ||
        expected.map((u) => u.id).toSet().length != expected.length) {
      throw const FormatException('vpn_conflict');
    }
    for (final before in expected) {
      final user = workspace.users.where((u) => u.id == before.id).firstOrNull;
      if (user == null ||
          user.deleted ||
          canonicalJson(user.toJson()) != canonicalJson(before.toJson())) {
        throw const FormatException('vpn_conflict');
      }
    }
    await checkProfileEffects();
    final targets = {
      ...workspace.serverIds,
      for (final e in workspace.servers.entries)
        if ((e.value['observed'] as List? ?? []).isNotEmpty ||
            e.value['pending'] != null ||
            e.value['appliedPayload'] != null)
          e.key,
    };
    final deleted = {
      for (final user in expected)
        user.id: VpnUser(
          id: user.id,
          login: user.login,
          name: user.name,
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
    await _reconcileDeletions(token);
  });

  Future<void> _deletionGuard(String userId, String deletionId) async {
    await checkProfileEffects();
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
        if (e.value['status'] == 'revoked') continue;
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
      await checkProfileEffects();
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
      for (final target
          in (original.deletion!['targets'] as Map).keys.cast<String>()) {
        if (_restoredTargets.contains(target)) continue;
        var record = Map<String, dynamic>.from(
          workspace.users
                  .singleWhere((u) => u.id == original.id)
                  .deletion!['targets'][target]
              as Map,
        );
        if (record['status'] == 'revoked' ||
            !force &&
                (record['retryAt'] as int? ?? 0) >
                    DateTime.now().millisecondsSinceEpoch) {
          continue;
        }
        final r = remote(target);
        if (r == null) continue;
        try {
          await _deletionGuard(original.id, deletionId);
          if (record['identity'] != null && record['identity'] != r.identity) {
            throw const FormatException('vpn_identity');
          }
          // Drain or establish the fate of the old ordinary operation first.
          final server = workspace.servers[target] ?? <String, dynamic>{};
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
              'authorizedPayload': null,
              'paused': true,
              'cancelRequested': false,
              'observingCancel': false,
            });
          }
          if (record['request'] == null) {
            final state = await _request(
              r,
              _stateRequest(target, r.panelId),
              token,
            );
            final payload = _revocationPayload(
              target,
              r.panelId,
              original,
              _observations(state, target),
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
            await _deletionTarget(original.id, target, record);
          }
          final request = RunnerRequest.fromJson(
            Map<String, Object?>.from(record['request'] as Map),
          );
          final payload = jsonDecode(request.json['payload'] as String) as Map;
          if (!(payload['revokedUsers'] as List? ?? []).contains(original.id) ||
              payload['workspaceId'] != workspace.id) {
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
                ?.where((o) => o['workspaceId'] == workspace.id)
                .toList();
            final requested = (payload['resources'] as List)
                .map((r) => r['id'])
                .toSet();
            if (owned == null ||
                !requested.every((id) => owned.any((o) => o['id'] == id)) ||
                owned.any(
                  (o) =>
                      o['confirmed'] != true ||
                      (o['clients'] as List).any(
                        (c) => c['id'] == original.id && c['enabled'] == true,
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
            if (resumeHidden && job.status == 'failed' && job.checkpoint == 0) {
              // No resource was applied. A fresh plan can recover a stale
              // fingerprint; resuming the same immutable preview cannot.
              record = {
                ...record,
                'status': 'waiting',
                'request': null,
                'generation': (record['generation'] as int? ?? 0) + 1,
              };
            } else if (resumeHidden &&
                ['failed', 'partially_applied'].contains(job.status)) {
              await _deletionGuard(original.id, deletionId);
              await _request(r, RunnerRequest.resume(request.id!), token);
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
                'retryAt': DateTime.now().millisecondsSinceEpoch + 30000,
              };
            }
          } else {
            record = {...record, 'status': 'running'};
          }
          await _deletionTarget(original.id, target, record);
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
          await _deletionTarget(original.id, target, {
            ...record,
            'status': 'error',
            'error': issue,
            'retryAt': DateTime.now().millisecondsSinceEpoch + 30000,
          });
        }
      }
      final user = workspace.users.singleWhere((u) => u.id == original.id);
      final file = user.deletion!['file'] as Map?;
      if (user.revocationComplete &&
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

  Map<String, Object?> _revocationPayload(
    String target,
    String panel,
    VpnUser user,
    List<Map<String, dynamic>>? observed,
  ) {
    if (observed == null) throw const FormatException('vpn_failed');
    final owned =
        observed.where((o) => o['workspaceId'] == workspace.id).toList()
          ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    if (owned.any((o) => o['confirmed'] != true)) {
      throw const FormatException('vpn_conflict');
    }
    List<Map<String, Object?>>? otherUsers;
    for (final resource in owned) {
      final spec = resource['spec'] as Map;
      if (spec['deleted'] == true || spec['internal'] == true) continue;
      final users = [
        for (final c in resource['clients'] as List)
          if (c['id'] != user.id)
            <String, Object?>{
              'id': c['id'],
              'enabled': c['enabled'],
              if (isTtTarget(target)) 'login': c['username'],
            },
      ]..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      // A partial operation can leave different access sets. Do not broaden
      // anyone else's access merely to fit a workspace-wide apply payload.
      if (otherUsers != null &&
          canonicalJson(otherUsers) != canonicalJson(users)) {
        throw const FormatException('vpn_conflict');
      }
      otherUsers = users;
    }
    return {
      'version': 1,
      if (isAwgTarget(target)) 'protocol': 'awg',
      if (isTtTarget(target)) 'protocol': 'tt',
      'workspaceId': workspace.id,
      'panelId': isAwgTarget(target) || isTtTarget(target)
          ? workspace.id
          : panel,
      'resources': [for (final o in owned) o['spec']],
      'users': [
        ...?otherUsers,
        {
          'id': user.id,
          'enabled': false,
          if (isTtTarget(target)) 'login': user.login,
        },
      ],
      'revokedUsers': [user.id],
    };
  }
}
