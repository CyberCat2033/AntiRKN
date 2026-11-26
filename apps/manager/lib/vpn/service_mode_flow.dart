part of 'vpn_controller.dart';

/// Service mode of physical servers: entering and leaving it, and the client
/// access changes a server in it still receives.
///
/// Service mode is for testing and repair: no client is added to a server
/// in it, but its protocols still change at once. What reaches it is built
/// from a fresh readback: the desired resources with only the clients the
/// server already has, each in its current `enabled` state. So a protocol
/// set up there applies right away (a new server gets it without clients,
/// and its connection check uses the runner's temporary probe client), and
/// a client disabled (or enabled again) meanwhile changes only its own
/// state. The intent needs no record of its own: it is the synced
/// workspace against what the server last showed, so a restart or another
/// device picks it up from the first readback. A deletion still goes
/// through the revocation flow. None of this holds up publication or the
/// other servers.
extension ServiceModeFlow on VpnController {
  /// Puts [serverId] into service mode: a local, synced change only, with
  /// no server action. Its resources leave client profiles at once; its
  /// accesses stay on the server for the way back.
  ///
  /// Refused (`vpn_busy`) while a job is known to run on a reachable target
  /// of it: that job may still provision clients the person has just
  /// decided to keep off the server, and it ends in moments. An unreachable
  /// server is never refused: its job, if any, cannot be observed, and a
  /// broken server is exactly what service mode is for. Such a job only
  /// carries what was approved before; it keeps being polled, and the way
  /// back applies the desired state again anyway. Running revocations never
  /// refuse it: they only take access away.
  ///
  /// Residual risk: the entry reaches other devices with the sync delay.
  /// Until then a device with the older snapshot may still send a desired
  /// payload there (only what it was already allowed to provision). The
  /// runner cannot tell, and nothing synced is fresher than that snapshot.
  Future<void> enterServiceMode(String serverId) => _run((token) async {
    if (!loaded) return;
    if (!validServiceModeServerId(serverId)) {
      throw const FormatException('vpn_service_mode_invalid');
    }
    if (workspace.inServiceMode(serverId)) return;
    if (_serviceModeJobRunning(serverId)) {
      throw const FormatException('vpn_busy');
    }
    await _write(
      workspace.copy(
        serviceMode: {
          ...workspace.serviceMode,
          serverId: ServerServiceMode(
            state: ServerServiceState.active,
            since: DateTime.now(),
          ),
        },
      ),
    );
    _forgetServiceModeExit(serverId);
    plans = [
      for (final plan in plans)
        if (!_provisioningHeld(plan.serverId)) plan,
    ];
    _sendIssues.removeWhere((target, _) => vpnServerId(target) == serverId);
    // A background issue this server caused no longer holds publication.
    _dropServiceModeSyncIssue();
    await _profiles();
  });

  /// Starts, or retries, the way back of [serverId] from service mode. The
  /// state becomes `returning` with this device as its executor (synced)
  /// and the server stays out of profiles. Pending revocations on it finish
  /// first, then every target gets the current desired payload. Only a
  /// readback taken since the exit began that matches it removes the
  /// service mode entry. What is left (a job still running, a failure)
  /// continues with [reconcile]; why it waits is [serviceModeExitIssue].
  ///
  /// Only the executor resumes and retries an exit on its own. Calling this
  /// on another device takes the exit over: a job the previous executor
  /// left running is observed and waited for before anything new is sent.
  Future<void> exitServiceMode(String serverId) => _run((token) async {
    if (!loaded) return;
    final mode = workspace.serviceMode[serverId];
    if (mode == null) return;
    if (mode.state != ServerServiceState.returning ||
        mode.executor != _deviceId) {
      await _write(
        workspace.copy(
          serviceMode: {
            ...workspace.serviceMode,
            serverId: mode.withState(
              ServerServiceState.returning,
              executor: _deviceId,
            ),
          },
        ),
      );
    }
    _serviceModeExits.putIfAbsent(serverId, DateTime.now);
    _serviceModeExitIssues.remove(serverId);
    await _advanceServiceModeExit(serverId, token, connect: true);
    _scheduleReconcile();
  });

  /// Stops the way back of [serverId]: it stays in service mode (`active`).
  /// Refused (`vpn_busy`) while a job runs on it, as [enterServiceMode] is,
  /// and also while a desired payload sent on the way back may still run
  /// there unseen: a request whose fate is not known (the connection
  /// dropped after the runner accepted it) or another device's operation
  /// not observed as finished. Cancelling then would leave that job adding
  /// clients to a server marked as serviced.
  Future<void> cancelServiceModeExit(String serverId) => _run((token) async {
    final mode = workspace.serviceMode[serverId];
    if (!loaded || mode?.state != ServerServiceState.returning) return;
    if (_serviceModeJobRunning(serverId) ||
        _serviceModeExitInFlight(serverId)) {
      throw const FormatException('vpn_busy');
    }
    await _write(
      workspace.copy(
        serviceMode: {
          ...workspace.serviceMode,
          serverId: mode!.withState(ServerServiceState.active),
        },
      ),
    );
    _forgetServiceModeExit(serverId);
    plans = [
      for (final plan in plans)
        if (!_provisioningHeld(plan.serverId)) plan,
    ];
  });

  /// Sends the waiting access changes of [serverId] now, connecting first,
  /// instead of waiting for the next automatic attempt.
  Future<void> retryServiceAccess(String serverId) => _run((token) async {
    if (!loaded) return;
    for (final target in _serviceAccessTargets()) {
      if (vpnServerId(target) != serverId) continue;
      _serviceAccessSent.remove(target);
      await ensureConnected(target);
      token.check();
      await _syncServiceAccess(target, token);
    }
  });

  /// A person's apply of [targets] held by service mode: their resources
  /// are sent now, as [_syncServiceAccess] builds them, and the first issue
  /// becomes [error]. Work still in flight there is left to finish first;
  /// the automatic round sends the rest after it.
  Future<void> _applyServiceTargets(Set<String> targets) => _run((token) async {
    if (!loaded) return;
    for (final target in targets.toList()..sort()) {
      _serviceAccessSent.remove(target);
      await ensureConnected(target);
      token.check();
      await _syncServiceAccess(target, token);
      if (_serviceAccessIssues[target] case final issue?) {
        throw FormatException(issue);
      }
    }
  });

  /// Whether the way back of [serverId] is being applied on this device.
  bool serviceModeExiting(String serverId) =>
      workspace.serviceModeOf(serverId)?.state ==
          ServerServiceState.returning &&
      _serviceModeExits.containsKey(serverId);

  /// Whether the way back of [serverId] is applied by another device: this
  /// one only shows it until a person takes it over ([exitServiceMode]).
  bool serviceModeExitElsewhere(String serverId) =>
      workspace.serviceModeOf(serverId)?.state ==
          ServerServiceState.returning &&
      !_ownsServiceModeExit(serverId);

  /// Why the way back of [serverId] has not finished yet; null while it
  /// simply waits for work in flight.
  String? serviceModeExitIssue(String serverId) =>
      serviceModeExitElsewhere(serverId)
      ? 'vpn_service_mode_other_device'
      : workspace.inServiceMode(serverId)
      ? _serviceModeExitIssues[serverId]
      : null;

  /// Enabled clients that gain access on [serverId] when it returns: those
  /// its last readback lacks on some client-facing resource.
  int serviceModeExitNewClients(String serverId) {
    final users = workspace.users
        .where((u) => !u.deleted && u.enabled)
        .map((u) => u.id)
        .toSet();
    final added = <String>{};
    for (final target in _serviceModeTargets(serverId)) {
      final rows = (workspace.servers[target]?['observed'] as List? ?? const [])
          .whereType<Map>();
      for (final id in _resourceIds(target, deleted: false)) {
        if (workspace.inbounds.any((i) => i.id == id && i.internal)) continue;
        final row = rows
            .where(
              (r) =>
                  r['id'] == id &&
                  r['confirmed'] == true &&
                  !observationGone(r),
            )
            .firstOrNull;
        added.addAll(
          users.difference({
            for (final c
                in (row?['clients'] as List? ?? const []).whereType<Map>())
              c['id'],
          }),
        );
      }
    }
    return added.length;
  }

  /// Whether [target] in service mode lacks a resource as the workspace
  /// has it, per [observed] (its last readback when omitted): one never
  /// sent or changed since, or one deleted that the server still runs.
  /// With no readback yet, any resource the person keeps is due.
  bool _serviceResourcesDue(
    String target, [
    List<Map<String, dynamic>>? observed,
  ]) {
    final record = workspace.servers[target];
    final rows =
        observed ??
        (record?['verifiedAt'] == null
                ? null
                : (record!['observed'] as List? ?? const []))
            ?.whereType<Map>()
            .toList();
    final owner = workspace.resourceWorkspaceId(target);
    for (final spec in workspace.desiredResources(target)) {
      final row = rows?.where((r) => r['id'] == spec['id']).firstOrNull;
      if (spec['deleted'] == true) {
        if (row != null && !observationGone(row)) return true;
        continue;
      }
      if (row == null ||
          row['confirmed'] != true ||
          row['workspaceId'] != owner ||
          observationGone(row) ||
          canonicalJson(row['spec']) != canonicalJson(spec)) {
        return true;
      }
    }
    return false;
  }

  /// Clients whose access change still waits for [serverId] in service
  /// mode, as its last readback shows them.
  int serviceAccessWaiting(String serverId) => {
    for (final target in _serviceAccessTargets())
      if (vpnServerId(target) == serverId)
        ..._serviceAccessChanges(target).keys,
  }.length;

  /// Why the last access change sent to [serverId] in service mode did not
  /// land, if it did not. Never part of [serverSyncIssue].
  String? serviceAccessIssue(String serverId) {
    if (!workspace.inServiceMode(serverId)) return null;
    for (final target in [serverId, awgTarget(serverId), ttTarget(serverId)]) {
      if (_serviceAccessIssues[target] case final issue?) return issue;
    }
    return null;
  }

  /// On load every `returning` entry this device executes resumes here,
  /// with a new start: only a readback taken from now on may bring its
  /// server back. Another device's exit is only shown; should both still
  /// act (a takeover not synced yet), the usual guards hold: an operation
  /// owned by one executor is only observed by the others, and the plan
  /// fingerprint makes a runner refuse a payload planned on a stale state.
  void _resumeServiceModeExits() {
    _serviceModeExits.clear();
    _serviceModeExitIssues.clear();
    _serviceModeExitTried.clear();
    _serviceAccessSent.clear();
    _serviceAccessIssues.clear();
    _deletionConnected.clear();
    final now = DateTime.now();
    for (final serverId in workspace.serviceMode.keys) {
      if (_ownsServiceModeExit(serverId)) _serviceModeExits[serverId] = now;
    }
  }

  /// Whether this device executes the way back of [serverId].
  bool _ownsServiceModeExit(String serverId) {
    final mode = workspace.serviceModeOf(serverId);
    return mode?.state == ServerServiceState.returning &&
        mode?.executor == _deviceId;
  }

  void _forgetServiceModeExit(String serverId) {
    _serviceModeExits.remove(serverId);
    _serviceModeExitIssues.remove(serverId);
    _serviceModeExitTried.remove(serverId);
  }

  /// Whether a job is known to run on a reachable target of [serverId]:
  /// this device's or another device's that it observes.
  bool _serviceModeJobRunning(String serverId) {
    for (final target in [serverId, awgTarget(serverId), ttTarget(serverId)]) {
      final record = workspace.servers[target];
      if (record == null || remote(target) == null) continue;
      if (record['cancelRequested'] == true ||
          record['observingCancel'] == true ||
          currentJob(target)?.terminal == false) {
        return true;
      }
    }
    return false;
  }

  /// Whether a desired payload may still run unseen on a target of
  /// [serverId], reachable or not: a job not known to be finished, or a
  /// request (this device's or another's) sent without a known outcome. An
  /// access change built from a readback only narrows access and never
  /// counts.
  bool _serviceModeExitInFlight(String serverId) =>
      _serviceModeTargets(serverId).any((target) {
        final record = workspace.servers[target];
        if (record == null || record['serviceAccess'] == true) return false;
        if (record['cancelRequested'] == true ||
            record['observingCancel'] == true) {
          return true;
        }
        if (currentJob(target) case final job?) return !job.terminal;
        return record['pending'] != null && record['paused'] != true;
      });

  /// A request on [record] that is running or whose fate is not known yet.
  bool _inFlight(Map<String, dynamic>? record) =>
      VpnController._isTargetBusy(record) ||
      record?['pending'] != null && record?['paused'] != true;

  /// The targets of [serverId] that its way back applies and verifies:
  /// every one with a resource the person keeps and every one the app has
  /// any state for, as a client removal counts them. A protocol whose last
  /// resource was removed meanwhile still runs there until it gets the
  /// desired payload that retires it.
  List<String> _serviceModeTargets(String serverId) => {
    for (final target in workspace.serverIds)
      if (vpnServerId(target) == serverId) target,
    for (final e in workspace.servers.entries)
      if (vpnServerId(e.key) == serverId &&
          (_hasServerState(e.value) || e.value['authorizedPayload'] != null))
        e.key,
  }.toList()..sort();

  /// Targets of servers in service mode, `active` or `returning`: a client
  /// disabled meanwhile reaches every reachable one until the way back has
  /// brought the server back, also while that way back is stalled on
  /// another target of it.
  List<String> _serviceAccessTargets() => {
    ...workspace.serverIds,
    ...workspace.servers.keys,
  }.where(workspace.inServiceMode).toList()..sort();

  /// Clients the [observed] state of [target] (its last readback when
  /// omitted) shows with another `enabled` state than the workspace. Only
  /// clients the server has count: one it lacks is never added.
  Map<String, bool> _serviceAccessChanges(
    String target, [
    List<Map<String, dynamic>>? observed,
  ]) {
    final rows =
        (observed ??
                workspace.servers[target]?['observed'] as List? ??
                const [])
            .whereType<Map>();
    final owner = workspace.resourceWorkspaceId(target);
    final changes = <String, bool>{};
    for (final row in rows) {
      final spec = row['spec'];
      if (row['workspaceId'] != owner ||
          observationGone(row) ||
          spec is! Map ||
          spec['internal'] == true) {
        continue;
      }
      for (final client
          in (row['clients'] as List? ?? const []).whereType<Map>()) {
        final id = client['id'];
        final user = id is String ? workspace.userById(id) : null;
        if (user != null &&
            !user.deleted &&
            client['enabled'] != user.enabled) {
          changes[user.id] = user.enabled;
        }
      }
    }
    return changes;
  }

  /// Whether nothing else is applied on [target] or its physical server, so
  /// an access change may go there now. Revocations go first.
  bool _serviceAccessReady(String target) {
    if (hasPendingRevocation(vpnServerId(target)) ||
        _restoredTargets.contains(target)) {
      return false;
    }
    if (observesOperation(target)) return currentJob(target)?.terminal != false;
    return !_inFlight(workspace.servers[target]);
  }

  String _flowIssue(Object error) => error is FormatException
      ? error.message
      : error is SshFailure
      ? 'vpn_connection'
      : error is RunnerFailure
      ? 'vpn_runner'
      : 'vpn_failed';

  /// Runs after each [reconcile]: the way back of returning servers, then
  /// access changes for servers in service mode.
  Future<void> _serviceModeWork() async {
    await _advanceServiceModeExits();
    await _sendServiceAccess();
  }

  Future<void> _advanceServiceModeExits() async {
    if (_disposed || !loaded || busy) return;
    final now = DateTime.now();
    final due = <String>[];
    for (final serverId in _serviceModeExits.keys.toList()) {
      // Cancelled, finished, or taken over by another device.
      if (!_ownsServiceModeExit(serverId)) {
        _forgetServiceModeExit(serverId);
        continue;
      }
      final tried = _serviceModeExitTried[serverId];
      if (_serviceModeExitIssues.containsKey(serverId) &&
          tried != null &&
          now.difference(tried) < const Duration(seconds: 30)) {
        continue;
      }
      // Connecting may take long: it runs outside the workspace lock, and
      // the next round continues once the server is reachable.
      final targets = _serviceModeTargets(serverId);
      final offline = [
        if (targets.isEmpty) serverId,
        ...targets,
      ].where((target) => remote(target) == null).firstOrNull;
      if (offline != null) {
        _serviceModeExitTried[serverId] = now;
        _serviceModeExitIssues[serverId] =
            remoteIssue?.call(offline) ?? 'vpn_connection';
        unawaited(ensureConnected(offline).then((_) {}, onError: (_) {}));
        continue;
      }
      due.add(serverId);
    }
    if (due.isEmpty) return;
    await _run((token) async {
      for (final serverId in due) {
        await _advanceServiceModeExit(serverId, token);
      }
    }, background: true);
    _scheduleReconcile();
  }

  /// One step of the way back of [serverId]. Waiting for work in flight
  /// leaves no issue; anything else that stops it is kept per server and
  /// never reaches [serverSyncIssue].
  Future<void> _advanceServiceModeExit(
    String serverId,
    CancellationToken token, {
    bool connect = false,
  }) async {
    final startedAt = _serviceModeExits[serverId];
    if (startedAt == null || !_ownsServiceModeExit(serverId)) return;
    _serviceModeExitTried[serverId] = DateTime.now();
    void waiting() => _serviceModeExitIssues.remove(serverId);
    try {
      final targets = _serviceModeTargets(serverId);
      if (connect) {
        await ensureConnected(targets.firstOrNull ?? serverId);
        token.check();
      }
      for (final target in targets) {
        if (remote(target) == null) {
          throw FormatException(remoteIssue?.call(target) ?? 'vpn_connection');
        }
      }
      // 1. Revocations first: no client is provisioned on a server that
      // still owes one.
      if (hasPendingRevocation(serverId)) {
        await _reconcileDeletions(token);
        final unsettled = [
          for (final user in pendingRevocations)
            for (final e in (user.deletion!['targets'] as Map).entries)
              if (vpnServerId(e.key as String) == serverId &&
                  !vpnRevocationSettled(e.value))
                (user, e.value as Map),
        ];
        if (unsettled.isNotEmpty) {
          if (unsettled.any((u) => !ownsDeletion(u.$1))) {
            throw const FormatException('vpn_deletion_other_device');
          }
          if (unsettled.every((u) => u.$2['status'] == 'running')) {
            return waiting();
          }
          throw FormatException(
            unsettled
                    .map((u) => u.$2['error'])
                    .whereType<String>()
                    .firstOrNull ??
                'vpn_revocation_pending',
          );
        }
      }
      // 2. Work in flight there (an access change, an earlier step of this
      // exit) settles before anything new is planned.
      for (final target in targets) {
        if (observesOperation(target)) {
          await _observeOperation(target, token);
          if (observationErrors[target] case final issue?) {
            throw FormatException(issue);
          }
          if (currentJob(target)?.terminal == false) return waiting();
        } else if (_inFlight(workspace.servers[target])) {
          await _reconcileTarget(target, token);
          final record = workspace.servers[target];
          if (_inFlight(record)) {
            if (record?['error'] case final String issue) {
              throw FormatException(issue);
            }
            return waiting();
          }
        }
      }
      // 3. Read every target again; those that do not show the current
      // desired payload get it.
      for (final target in targets) {
        await _refreshServer(target, token, rebuildProfiles: false);
      }
      final stale = {
        for (final target in targets)
          if (!_exitVerified(target, startedAt)) target,
      };
      if (stale.isNotEmpty) {
        // A plan the person is reviewing for other servers stays.
        final reviewed = plans;
        try {
          await _prepare(token, serverIds: stale);
          await _apply(token);
        } finally {
          plans = [
            for (final plan in reviewed)
              if (!stale.contains(plan.serverId)) plan,
          ];
        }
        for (final target in stale) {
          final record = workspace.servers[target];
          if (!_inFlight(record)) continue;
          if (record?['error'] case final String issue) {
            throw FormatException(issue);
          }
          return waiting();
        }
      }
      // 4. Only a readback since the exit began that matches the current
      // desired payload brings the server back; an old one never does.
      for (final target in targets) {
        if (!_exitVerified(target, startedAt)) {
          throw FormatException(
            workspace.servers[target]?['error'] as String? ??
                'vpn_pending_readback',
          );
        }
      }
      await _write(
        workspace.copy(
          serviceMode: {
            for (final entry in workspace.serviceMode.entries)
              if (entry.key != serverId) entry.key: entry.value,
          },
        ),
      );
      _forgetServiceModeExit(serverId);
      await _profiles();
    } on SyncMergeFailure {
      rethrow;
    } on VaultFailure {
      rethrow;
    } catch (e) {
      _serviceModeExitIssues[serverId] = _flowIssue(e);
    }
  }

  bool _exitVerified(String target, DateTime since) {
    final at = DateTime.tryParse(
      workspace.servers[target]?['verifiedAt'] as String? ?? '',
    );
    return at != null && !at.isBefore(since) && _targetVerified(target);
  }

  /// Sends due access changes to servers in service mode: one attempt per
  /// change and connection a few times, as [_sendMissing] does. An
  /// unreachable server is connected in the background, outside the
  /// workspace lock, so nothing waits for it.
  Future<void> _sendServiceAccess() async {
    if (_disposed || !loaded || busy) return;
    final now = DateTime.now();
    final due = <String>[];
    for (final target in _serviceAccessTargets()) {
      final changes = _serviceAccessChanges(target);
      if (changes.isEmpty && !_serviceResourcesDue(target)) {
        _serviceAccessSent.remove(target);
        _serviceAccessIssues.remove(target);
        continue;
      }
      final r = remote(target);
      if (r != null && !_serviceAccessReady(target)) continue;
      // A new connection is a new attempt, even without an observation key.
      final key =
          '${canonicalJson([changes, workspace.desiredResources(target)])}|${r == null ? 'offline' : 'online:${r.observationKey}'}';
      final last = _serviceAccessSent[target];
      if (last != null &&
          last.key == key &&
          (last.attempts >= 3 ||
              now.difference(last.at) < const Duration(seconds: 45))) {
        continue;
      }
      _serviceAccessSent[target] = (
        key: key,
        attempts: last?.key == key ? last!.attempts + 1 : 1,
        at: now,
      );
      if (r == null) {
        _serviceAccessIssues[target] =
            remoteIssue?.call(target) ?? 'vpn_connection';
        unawaited(ensureConnected(target).then((_) {}, onError: (_) {}));
        continue;
      }
      due.add(target);
    }
    if (due.isEmpty) {
      return;
    }
    await _run((token) async {
      for (final target in due) {
        await _syncServiceAccess(target, token);
      }
    }, background: true);
    _scheduleReconcile();
  }

  /// Reads [target] and, when it shows a client in another `enabled` state
  /// than the workspace or lacks a resource as the workspace has it,
  /// applies the desired resources with the clients the readback shows
  /// (see the class comment). The request is durable before it is
  /// submitted and then followed by ID like any other operation; success
  /// is the readback after the job.
  Future<void> _syncServiceAccess(
    String target,
    CancellationToken token,
  ) async {
    try {
      final r = remote(target);
      if (r == null) {
        throw FormatException(remoteIssue?.call(target) ?? 'vpn_connection');
      }
      // Back from service mode: the desired payload carries the change.
      if (!workspace.inServiceMode(target)) return;
      if (observesOperation(target)) {
        await _observeOperation(target, token);
        if (observationErrors[target] case final issue?) {
          throw FormatException(issue);
        }
      }
      if (!_serviceAccessReady(target)) return;
      final record = workspace.servers[target];
      if (record?['identity'] != null && record!['identity'] != r.identity) {
        throw const FormatException('vpn_identity');
      }
      final state = await _request(r, _stateRequest(target, r.panelId), token);
      final observed = _observations(state, target);
      if (observed == null) throw const FormatException('vpn_failed');
      await _applyServerObservations(target, r, observed);
      final changes = _serviceAccessChanges(target, observed);
      if (changes.isEmpty && !_serviceResourcesDue(target, observed)) {
        _serviceAccessIssues.remove(target);
        return;
      }
      final payload = {
        ..._observedPayload(target, r.panelId, observed, enabled: changes),
        'resources': workspace.desiredResources(target),
      };
      final plan = await _request(
        r,
        _planRequest(target, r.panelId, payload),
        token,
      );
      final fingerprint = _preview(plan, target)?['fingerprint'];
      if (fingerprint is! String) throw const FormatException('vpn_failed');
      final request = _applyRequest(target, newVpnId(), payload, fingerprint);
      await _record(target, {
        ...?workspace.servers[target],
        if (_deviceId != null)
          'operation': ServerOperation(
            operationId: request.id!,
            executorDeviceId: _deviceId!,
            expectedRevision: fingerprint,
          ).toJson(),
        'panelId': payload['panelId'],
        'identity': r.identity,
        'authorizedPayload': jsonEncode(payload),
        'paused': false,
        'error': null,
        'pending': request.json,
        'job': null,
        'cancelRequested': false,
        'observingCancel': false,
        'serviceAccess': true,
      });
      await _request(r, request, token);
      await _reconcileTarget(target, token);
      if (workspace.servers[target]?['error'] case final String issue) {
        _serviceAccessIssues[target] = issue;
      } else {
        _serviceAccessIssues.remove(target);
      }
    } on SyncMergeFailure {
      rethrow;
    } on VaultFailure {
      rethrow;
    } catch (e) {
      _serviceAccessIssues[target] = _flowIssue(e);
    }
  }
}
