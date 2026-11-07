import 'connection_checks.dart';
import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/foundation.dart';

part 'client_deletion.dart';

/// Starts at most four independent physical-server operations at a time.
/// The input order is retained for callers that apply results to the workspace.
Future<List<T>> _mapServersBounded<T>(
  List<String> servers,
  Future<T> Function(String) action, {
  CancellationToken? cancellation,
}) async {
  final results = List<T?>.filled(servers.length, null);
  var next = 0;
  Object? failure;
  StackTrace? failureStack;
  Future<void> worker() async {
    while (failure == null && next < servers.length) {
      try {
        cancellation?.check();
        final index = next++;
        results[index] = await action(servers[index]);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
  }

  await Future.wait([
    for (var i = 0; i < 4 && i < servers.length; i++) worker(),
  ]);
  if (failure case final error?) {
    Error.throwWithStackTrace(error, failureStack!);
  }
  return [for (final result in results) result as T];
}

/// Returns changed client IDs when only per-client server bindings changed.
/// A null result means shared profile inputs changed and every profile needs
/// a fresh compile. Runner revisions and job metadata are not YAML inputs.
Set<String>? _changedProfileClients(
  VpnWorkspace before,
  VpnWorkspace after,
  String beforeTemplate,
  String afterTemplate,
  Map<String, String> beforeNames,
  Map<String, String> afterNames,
) {
  if (beforeTemplate != afterTemplate ||
      canonicalJson(beforeNames) != canonicalJson(afterNames) ||
      canonicalJson(before.users.map((u) => u.toJson()).toList()) !=
          canonicalJson(after.users.map((u) => u.toJson()).toList()) ||
      canonicalJson(before.inbounds.map((r) => r.toJson()).toList()) !=
          canonicalJson(after.inbounds.map((r) => r.toJson()).toList()) ||
      canonicalJson(before.awgInterfaces.map((r) => r.toJson()).toList()) !=
          canonicalJson(after.awgInterfaces.map((r) => r.toJson()).toList()) ||
      canonicalJson(before.ttEndpoints.map((r) => r.toJson()).toList()) !=
          canonicalJson(after.ttEndpoints.map((r) => r.toJson()).toList())) {
    return null;
  }

  (Map<String, Object?>, Map<String, String>)? projection(VpnWorkspace value) {
    final shared = <String, Object?>{};
    final clients = <String, String>{};
    try {
      for (final entry in value.servers.entries) {
        final rows = <Map<String, dynamic>>[];
        for (final raw in entry.value['observed'] as List? ?? const []) {
          final row = Map<String, dynamic>.from(raw as Map);
          final bindings = row.remove('clients') as List? ?? const [];
          row.remove('revision');
          rows.add(row);
          for (final rawClient in bindings) {
            final client = Map<String, dynamic>.from(rawClient as Map);
            final userId = client['id'];
            if (userId is! String) return null;
            final key = '${entry.key}|${row['id']}|$userId';
            if (clients.containsKey(key)) return null;
            clients[key] = canonicalJson(client);
          }
        }
        shared[entry.key] = {
          'error': entry.value['error'],
          'resourceWorkspaceId': entry.value['resourceWorkspaceId'],
          'observed': rows,
        };
      }
    } catch (_) {
      return null;
    }
    return (shared, clients);
  }

  final oldState = projection(before), newState = projection(after);
  if (oldState == null ||
      newState == null ||
      canonicalJson(oldState.$1) != canonicalJson(newState.$1)) {
    return null;
  }
  return {
    for (final key in {...oldState.$2.keys, ...newState.$2.keys})
      if (oldState.$2[key] != newState.$2[key]) key.split('|').last,
  };
}

final class VpnRemote {
  const VpnRemote({
    required this.transport,
    required this.panelId,
    required this.identity,
    this.password,
    this.onSshFailure,
    this.observationKey,
  });
  final RunnerTransport transport;
  final String panelId, identity;
  final String? observationKey;
  final String? password;
  final void Function(SshIssue)? onSshFailure;
}

final class VpnPlan {
  const VpnPlan(this.serverId, this.payload, this.identity, this.preview);
  final String serverId;
  final Map<String, Object?> payload;
  final String? identity;
  final Map<String, dynamic>? preview;
}

final class ServerProfileSyncResult {
  const ServerProfileSyncResult({
    required this.revision,
    this.issue,
    this.usedSavedVerification = false,
  });
  final int revision;
  final String? issue;
  final bool usedSavedVerification;
  bool get verified => issue == null;
}

ProfileResult _compile((String, String, String, Map<String, String>) input) {
  final workspace = VpnWorkspace.decode(input.$1);
  try {
    final pending = <ProfileAccessException>[];
    final accesses = [
      ...vlessUserAccesses(
        workspace,
        input.$3,
        serverNames: input.$4,
        onPending: pending.add,
      ),
      ...awgUserAccesses(
        workspace,
        input.$3,
        serverNames: input.$4,
        onPending: pending.add,
      ),
      ...ttUserAccesses(
        workspace,
        input.$3,
        serverNames: input.$4,
        onPending: pending.add,
      ),
    ];
    if (pending.isNotEmpty) {
      return ProfileResult(
        groups: [],
        diagnostics: [
          for (final issue in pending)
            ProfileDiagnostic(
              issue.code,
              DiagnosticSeverity.error,
              subject: issue.subject,
            ),
        ],
      );
    }
    return const ProfileCompiler().compile(
      template: workspace.users
          .singleWhere((user) => user.id == input.$3)
          .profileTemplate(input.$2),
      userId: input.$3,
      accesses: accesses,
    );
  } on ProfileAccessException catch (e) {
    return ProfileResult(
      groups: [],
      diagnostics: [
        ProfileDiagnostic(e.code, DiagnosticSeverity.error, subject: e.subject),
      ],
    );
  } on FormatException catch (e) {
    return ProfileResult(
      groups: [],
      diagnostics: [ProfileDiagnostic(e.message, DiagnosticSeverity.error)],
    );
  }
}

Map<String, ProfileResult> _compileBatch(
  (String, String, List<String>, Map<String, String>) input,
) {
  final workspace = VpnWorkspace.decode(input.$1);
  final userIds = input.$3;
  final serverNames = input.$4;
  final results = <String, ProfileResult>{};
  const compiler = ProfileCompiler();
  final templates = <String, PreparedProfileTemplate?>{};
  final users = {for (final user in workspace.users) user.id: user};

  for (final userId in userIds) {
    try {
      final template = users[userId]!.profileTemplate(input.$2);
      if (!templates.containsKey(template)) {
        try {
          templates[template] = compiler.prepare(template);
        } catch (_) {
          // Preserve per-user diagnostics for a malformed template.
          templates[template] = null;
        }
      }
      final prepared = templates[template];
      final pending = <ProfileAccessException>[];
      final accesses = [
        ...vlessUserAccesses(
          workspace,
          userId,
          serverNames: serverNames,
          onPending: pending.add,
        ),
        ...awgUserAccesses(
          workspace,
          userId,
          serverNames: serverNames,
          onPending: pending.add,
        ),
        ...ttUserAccesses(
          workspace,
          userId,
          serverNames: serverNames,
          onPending: pending.add,
        ),
      ];
      if (pending.isNotEmpty) {
        results[userId] = ProfileResult(
          groups: [],
          diagnostics: [
            for (final issue in pending)
              ProfileDiagnostic(
                issue.code,
                DiagnosticSeverity.error,
                subject: issue.subject,
              ),
          ],
        );
        continue;
      }
      results[userId] = prepared == null
          ? compiler.compile(
              template: template,
              userId: userId,
              accesses: accesses,
            )
          : compiler.compilePrepared(
              prepared: prepared,
              userId: userId,
              accesses: accesses,
            );
    } on ProfileAccessException catch (e) {
      results[userId] = ProfileResult(
        groups: [],
        diagnostics: [
          ProfileDiagnostic(
            e.code,
            DiagnosticSeverity.error,
            subject: e.subject,
          ),
        ],
      );
    } on FormatException catch (e) {
      results[userId] = ProfileResult(
        groups: [],
        diagnostics: [ProfileDiagnostic(e.message, DiagnosticSeverity.error)],
      );
    }
  }
  return results;
}

/// A single workspace coordinator owns client -> all resources reconciliation.
/// Polling resumes only persisted, explicitly approved intentions.
class VpnController extends ChangeNotifier {
  VpnController({
    required this.repository,
    required this.remote,
    required this.template,
    this.pickTemplate,
    this.serverIds,
    this.serverName,
    this.connectForDeletion,
    this.connectForAction,
    this.recovery,
    this.coreValidator,
    ConnectionProbeEngine? connectionProbe,
    SettingsStore? probeStore,
    this.enterConnectionTraffic,
    this.leaveConnectionTraffic,
    Timer Function(Duration, void Function(Timer))? timer,
  }) {
    connections = ConnectionChecks(this, connectionProbe, probeStore)
      ..addListener(_notify);
    _timer = (timer ?? Timer.periodic)(
      const Duration(seconds: 5),
      (_) => unawaited(reconcile()),
    );
  }
  late final ConnectionChecks connections;
  final Future<bool> Function()? enterConnectionTraffic;
  final Future<void> Function()? leaveConnectionTraffic;
  final VpnRepository repository;
  final CoreConfigValidator? coreValidator;
  final WorkspaceRecoveryStore? recovery;
  Set<String> _restoredTargets = {};
  bool needsRestoreReview(String id) => _restoredTargets.contains(id);
  Future<void> _approveRestored(Iterable<String> targets) async {
    final approved = targets.toSet();
    await recovery?.approveRestoredTargets(approved);
    _restoredTargets.removeAll(approved);
  }

  final VpnRemote? Function(String) remote;
  final String Function() template;
  final Future<ImportedTemplate?> Function()? pickTemplate;
  final Iterable<String> Function()? serverIds;
  final String Function(String)? serverName;

  String _profileServerName(String id) {
    final name = serverName?.call(id).trim();
    return name == null || name.isEmpty ? id : name;
  }

  Map<String, String> get profileServerNames => {
    for (final id in <String>{
      ...workspace.inbounds.map((resource) => resource.serverId),
      ...workspace.awgInterfaces.map((resource) => resource.serverId),
      ...workspace.ttEndpoints.map((resource) => resource.serverId),
      ...(serverIds?.call() ?? const <String>[]).map(vpnServerId),
    })
      id: _profileServerName(id),
  };

  /// true: connected, false: connection failed, null: another action is busy.
  final Future<bool?> Function(String serverId)? connectForDeletion;
  final Future<bool> Function(String serverId)? connectForAction;
  Future<bool> ensureConnected(String target) async =>
      remote(target) != null ||
      await connectForAction?.call(vpnServerId(target)) == true;
  final Map<String, String> _observedConnections = {};
  String? _deviceId;
  Future<void> Function(VpnUser, Future<void> Function())? deletePublishedFile;
  final observedJobs = <String, RunnerJob?>{};
  final observationErrors = <String, String>{};
  ServerOperation? operation(String id) {
    final value = workspace.servers[id]?['operation'];
    if (value == null) return null;
    final parsed = ServerOperation.fromJson(value as Map);
    parsed.validatePending(workspace.servers[id]?['pending'] as Map?);
    return parsed;
  }

  bool observesOperation(String id) =>
      operation(id) != null && operation(id)!.executorDeviceId != _deviceId;
  RunnerJob? currentJob(String id) =>
      observesOperation(id) && observedJobs.containsKey(id)
      ? observedJobs[id]
      : workspace.servers[id]?['job'] == null
      ? null
      : RunnerJob.fromJson(
          Map<String, dynamic>.from(workspace.servers[id]!['job'] as Map),
        );

  Timer? _timer;
  Timer? _reconcileRetry;
  Completer<void>? _backgroundReconcile;
  CancellationToken? _token;
  bool _disposed = false;
  bool _busy = false, loaded = false;
  bool _upgradeBusy = false;
  bool get upgradeBusy => _upgradeBusy;
  set upgradeBusy(bool value) {
    _upgradeBusy = value;
    _notify();
  }

  bool get busy => _busy || connections.busy || _upgradeBusy;
  bool get workspaceBusy => _busy || _upgradeBusy;
  bool get foregroundBusy =>
      (_busy && _backgroundReconcile == null) ||
      connections.busy ||
      _upgradeBusy;

  Future<void> waitForBackgroundReconcile() async {
    await _backgroundReconcile?.future;
  }

  set busy(bool value) => _busy = value;
  String? error;

  /// Blocks publication of retained profiles after a failed server check.
  String? serverSyncIssue;
  Timer? _identityNoticeTimer;
  bool _identityNoticeExpired = false;
  String? get visibleError =>
      error == 'vpn_identity' && _identityNoticeExpired ? null : error;
  VpnWorkspace workspace = VpnWorkspace.empty();
  int revision = 0;
  List<VpnPlan> plans = [];
  final results = <String, ProfileResult>{};
  final _coreChecks = <String, CoreConfigCheck>{};
  CancellationToken? _coreCancellation;
  String? coreCheckingUser;
  bool get coreValidationBusy => _coreCancellation != null;

  CoreConfigCheck? coreCheckFor(String userId) {
    final check = _coreChecks[userId];
    if (check == null ||
        check.profileHash != results[userId]?.sha256Hash ||
        _lastTemplate != template() ||
        !workspace.users.any(
          (u) => u.id == userId && !u.deleted && u.enabled,
        )) {
      return null;
    }
    if (check.status != CoreConfigStatus.invalid &&
        DateTime.now().difference(check.checkedAt) >
            const Duration(minutes: 5)) {
      return null;
    }
    return check;
  }

  void cancelCoreValidation() => _coreCancellation?.cancel();

  Future<void> validateCoreProfile(String userId) async {
    if (coreValidationBusy || busy || !loaded) return;
    final token = CancellationToken();
    _coreCancellation = token;
    coreCheckingUser = userId;
    notifyListeners();
    try {
      // Compile a fresh snapshot without writing profile history or publishing.
      final source = template();
      final snapshot = workspace.encode();
      final compiled = await compute(_compile, (
        snapshot,
        source,
        userId,
        profileServerNames,
      ));
      if (_disposed || token.isCancelled) return;
      final yaml = compiled.yaml, hash = compiled.sha256Hash;
      if (yaml == null || hash == null || compiled.hasBlockingErrors) return;
      final check = coreValidator == null
          ? CoreConfigCheck(
              status: CoreConfigStatus.unavailable,
              code: 'runtime_unavailable',
              profileHash: hash,
              checkedAt: DateTime.now().toUtc(),
            )
          : await coreValidator!.validate(yaml, token);
      if (!_disposed &&
          source == template() &&
          snapshot == workspace.encode() &&
          results[userId]?.sha256Hash == hash &&
          check.profileHash == hash) {
        _coreChecks[userId] = check;
      }
    } catch (_) {
      // No YAML, native errors or credentials are exposed by the controller.
    } finally {
      _coreCancellation = null;
      coreCheckingUser = null;
      if (!_disposed) notifyListeners();
    }
  }

  String? selectedUserId;
  String? _lastTemplate;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> checkProfileEffects() async {
    if (repository case final SyncEffectGuard guard) {
      await guard.checkSyncEffects();
    }
  }

  Future<void> _write(VpnWorkspace next) async {
    final updated = repository is VpnWorkspaceWriter
        ? await (repository as VpnWorkspaceWriter).writeVpnWorkspace(
            next,
            expectedRevision: revision,
          )
        : await repository.writeVpn(next.encode(), expectedRevision: revision);
    revision = updated;
    workspace = next;
  }

  Future<void> _recordTail = Future<void>.value();
  Future<void> _record(String id, Map<String, dynamic> record) {
    // Independent servers can finish network requests together. Build each
    // write from the latest workspace after the previous write commits.
    final write = _recordTail.then(
      (_) =>
          _write(workspace.copy(servers: {...workspace.servers, id: record})),
    );
    _recordTail = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  Future<void> _run(
    Future<void> Function(CancellationToken) action, {
    bool background = false,
  }) async {
    if (!background) await waitForBackgroundReconcile();
    if (busy || _disposed) return;
    final backgroundDone = background ? Completer<void>() : null;
    _backgroundReconcile = backgroundDone;
    busy = true;
    error = null;
    final token = CancellationToken();
    _token = token;
    if (!background) _notify();
    try {
      await action(token);
    } on SyncMergeFailure {
      error = 'sync_conflict';
    } on VaultFailure catch (e) {
      error = e.issue == VaultIssue.busy
          ? 'vpn_storage_conflict'
          : 'vpn_storage';
    } on FormatException catch (e) {
      error = e.message;
    } on SshFailure {
      error = 'vpn_connection';
    } on RunnerFailure {
      error = 'vpn_runner';
    } catch (_) {
      error = 'vpn_failed';
    } finally {
      if (error == 'vpn_identity' && _identityNoticeTimer == null) {
        _identityNoticeTimer = Timer(const Duration(seconds: 15), () {
          _identityNoticeExpired = true;
          _notify();
        });
      }
      busy = false;
      _token = null;
      _backgroundReconcile = null;
      _notify();
      backgroundDone?.complete();
    }
  }

  Future<void> load() => _run((token) async {
    serverSyncIssue = null;
    _restoredTargets = await recovery?.readRestoredTargets() ?? {};
    _deviceId = repository is ChangeJournalStore
        ? (await (repository as ChangeJournalStore).readWorkspaceIdentity())
              .deviceId
        : null;
    observedJobs.clear();
    observationErrors.clear();
    final saved = await repository.readVpn();
    token.check();
    revision = saved.revision;
    workspace = saved.source == null
        ? VpnWorkspace(id: saved.workspaceId ?? newVpnId())
        : VpnWorkspace.decode(saved.source!);
    if (saved.source == null) await _write(workspace);
    loaded = true;
    plans = [];
    await _profiles();
  });

  static bool _isTargetBusy(Map<String, dynamic>? record) {
    if (record == null) return false;
    if (record['cancelRequested'] == true ||
        record['observingCancel'] == true) {
      return true;
    }
    if (record['paused'] == true) return false;
    if (record['job'] case final Map jobMap) {
      return !RunnerJob.fromJson(Map<String, dynamic>.from(jobMap)).terminal;
    }
    return record['pending'] != null && record['error'] == null;
  }

  bool get hasObservedRunning => workspace.servers.keys.any(
    (id) => observesOperation(id) && currentJob(id)?.terminal == false,
  );

  bool get hasRunning =>
      pendingRevocations.any(
        (u) =>
            ownsDeletion(u) &&
            (u.deletion!['targets'] as Map).values.any(
              (t) => t['status'] == 'running',
            ),
      ) ||
      workspace.servers.entries.any(
        (e) =>
            !observesOperation(e.key) &&
            !_restoredTargets.contains(e.key) &&
            _isTargetBusy(e.value),
      );

  bool hasLocalServerState(String serverId) {
    if (workspace.inbounds.any(
          (resource) => resource.serverId == serverId && !resource.deleted,
        ) ||
        workspace.awgInterfaces.any(
          (resource) => resource.serverId == serverId && !resource.deleted,
        ) ||
        workspace.ttEndpoints.any(
          (resource) => resource.serverId == serverId && !resource.deleted,
        ) ||
        hasPendingRevocation(serverId)) {
      return true;
    }
    return workspace.servers.entries.any((entry) {
      if (vpnServerId(entry.key) != serverId) return false;
      final record = entry.value;
      return record['pending'] != null ||
          record['job'] != null ||
          record['operation'] != null ||
          record['authorizedPayload'] != null ||
          record['appliedPayload'] != null ||
          (record['observed'] as List? ?? []).isNotEmpty;
    });
  }

  Set<String> orphanedPhysicalServerIds(Iterable<String> availableServerIds) {
    final available = availableServerIds.map(vpnServerId).toSet();
    final referenced = <String>{
      for (final resource in workspace.inbounds)
        if (!resource.deleted) resource.serverId,
      for (final resource in workspace.awgInterfaces)
        if (!resource.deleted) resource.serverId,
      for (final resource in workspace.ttEndpoints)
        if (!resource.deleted) resource.serverId,
      for (final user in pendingRevocations)
        for (final entry in (user.deletion!['targets'] as Map).entries)
          if (!vpnRevocationSettled(entry.value))
            vpnServerId(entry.key as String),
      for (final entry in workspace.servers.entries)
        if (entry.value['pending'] != null ||
            entry.value['job'] != null ||
            entry.value['operation'] != null ||
            entry.value['authorizedPayload'] != null ||
            entry.value['appliedPayload'] != null ||
            (entry.value['observed'] as List? ?? []).isNotEmpty)
          vpnServerId(entry.key),
    };
    return referenced.difference(available);
  }

  bool get hasUnappliedActiveAccess {
    final users = workspace.users
        .where((user) => !user.deleted && user.enabled)
        .map((user) => user.id)
        .toSet();
    if (users.isEmpty) return false;
    bool missing(Iterable<Map> observations, String resourceId) {
      final clients = observations
          .where((row) => row['id'] == resourceId && row['confirmed'] == true)
          .expand(
            (row) => (row['clients'] as List? ?? const []).whereType<Map>(),
          )
          .where((client) => client['enabled'] == true)
          .map((client) => client['id'])
          .toSet();
      return !clients.containsAll(users);
    }

    for (final resource in workspace.inbounds.where(
      (resource) => resource.enabled && !resource.deleted && !resource.internal,
    )) {
      if (missing(
        (workspace.servers[resource.serverId]?['observed'] as List? ?? const [])
            .whereType<Map>(),
        resource.id,
      )) {
        return true;
      }
    }
    for (final resource in workspace.awgInterfaces.where(
      (resource) => resource.enabled && !resource.deleted,
    )) {
      if (missing(
        (workspace.servers[awgTarget(resource.serverId)]?['observed']
                    as List? ??
                const [])
            .whereType<Map>(),
        resource.id,
      )) {
        return true;
      }
    }
    for (final resource in workspace.ttEndpoints.where(
      (resource) => resource.enabled && !resource.deleted,
    )) {
      if (missing(
        (workspace.servers[ttTarget(resource.serverId)]?['observed'] as List? ??
                const [])
            .whereType<Map>(),
        resource.id,
      )) {
        return true;
      }
    }
    return false;
  }

  /// Repairs the legacy state where a force-hidden revocation prevented a
  /// subsequently saved client from ever being prepared for the server.
  Future<void> recoverHiddenPendingAccessChanges() async {
    if (!loaded ||
        busy ||
        !pendingRevocations.any((user) => user.deletion?['hidden'] == true) ||
        !hasUnappliedActiveAccess) {
      return;
    }
    await prepareAndApply();
  }

  Future<void> saveUser(VpnUser user) => _run((token) async {
    if (!loaded) return;
    if (user.deleted ||
        workspace.users.any((u) => u.id == user.id && u.deleted)) {
      throw const FormatException('vpn_user_deleted');
    }
    final next = workspace.copy(
      users: [
        for (final current in workspace.users)
          current.id == user.id ? user : current,
        if (!workspace.users.any((current) => current.id == user.id)) user,
      ],
    );
    if (repository case final VpnUserWriter writer) {
      revision = await writer.upsertVpnUser(user, expectedRevision: revision);
      workspace = next;
    } else {
      await _write(next);
    }
    plans = [];
    await _profiles(onlyUserId: user.id);
  });
  Future<Map<String, Object?>?> ttDefaults(String serverId) async {
    Map<String, Object?>? result;
    await _run((token) async {
      await ensureConnected(ttTarget(serverId));
      final r = remote(ttTarget(serverId));
      if (r == null) throw const FormatException('vpn_connection');
      result = (await _request(r, RunnerRequest.ttDefaults(), token)).tt;
    });
    return result;
  }

  Future<void> saveTt(TrustTunnelEndpoint resource) => _run((token) async {
    if (!loaded) return;
    await _write(
      workspace.copy(
        ttEndpoints: [
          ...workspace.ttEndpoints.where((r) => r.id != resource.id),
          resource,
        ],
      ),
    );
    await connections.mark((
      target: ttTarget(resource.serverId),
      resource: resource.id,
    ));
    plans = [];
    await _profiles();
  });
  Future<Map<String, Object?>?> awgDefaults(String serverId) async {
    Map<String, Object?>? result;
    await _run((token) async {
      await ensureConnected(awgTarget(serverId));
      final r = remote(awgTarget(serverId));
      if (r == null) throw const FormatException('vpn_connection');
      final defaults = (await _request(
        r,
        RunnerRequest.awgDefaults(),
        token,
      )).awgDefaults;
      result = defaults != null ? {...defaults, 'keepalive': 0} : null;
    });
    return result;
  }

  Future<void> saveAwg(AwgInterface resource) => _run((token) async {
    if (!loaded) return;
    await _write(
      workspace.copy(
        awgInterfaces: [
          ...workspace.awgInterfaces.where((r) => r.id != resource.id),
          resource,
        ],
      ),
    );
    await connections.mark((
      target: awgTarget(resource.serverId),
      resource: resource.id,
    ));
    plans = [];
    await _profiles();
  });
  RunnerRequest _planRequest(
    String target,
    String panel,
    Map<String, Object?> payload,
  ) => isTtTarget(target)
      ? RunnerRequest.ttPlan(workspace.resourceWorkspaceId(target), payload)
      : isAwgTarget(target)
      ? RunnerRequest.awgPlan(workspace.resourceWorkspaceId(target), payload)
      : RunnerRequest.vlessPlan(panel, payload);
  RunnerRequest _applyRequest(
    String target,
    String id,
    Map<String, Object?> payload,
    String fingerprint,
  ) => isTtTarget(target)
      ? RunnerRequest.ttApply(id, payload, fingerprint)
      : isAwgTarget(target)
      ? RunnerRequest.awgApply(id, payload, fingerprint)
      : RunnerRequest.vlessApply(id, payload, fingerprint);
  RunnerRequest _stateRequest(String target, String panel) => isTtTarget(target)
      ? RunnerRequest.ttState(workspace.resourceWorkspaceId(target))
      : isAwgTarget(target)
      ? RunnerRequest.awgState(workspace.resourceWorkspaceId(target))
      : RunnerRequest.vlessState(panel);
  Map<String, dynamic>? _preview(RunnerResponse r, String target) =>
      isTtTarget(target)
      ? r.tt
      : isAwgTarget(target)
      ? r.awgPlan
      : r.vlessPlan;
  List<Map<String, dynamic>>? _observations(RunnerResponse r, String target) =>
      isTtTarget(target)
      ? (r.tt?['resources'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList()
      : isAwgTarget(target)
      ? r.awgState
      : r.vlessState;
  Future<void> saveInbound(VlessInbound inbound) => _run((token) async {
    if (!loaded) return;
    if (error == 'vless_conflict' ||
        error == 'vpn_conflict' ||
        error == 'vpn_adoption_conflict') {
      error = null;
    }
    await _write(
      workspace.copy(
        inbounds: [
          ...workspace.inbounds.where((r) => r.id != inbound.id),
          inbound,
        ],
      ),
    );
    await connections.mark((target: inbound.serverId, resource: inbound.id));
    plans = [];
    await _profiles();
  });

  Future<void> deleteInbounds(List<VlessInbound> expected) => _run((
    token,
  ) async {
    if (!loaded || hasRunning || expected.isEmpty) {
      throw const FormatException('vpn_busy');
    }
    for (final inbound in expected) {
      final current = workspace.inbounds
          .where((r) => r.id == inbound.id && r.serverId == inbound.serverId)
          .firstOrNull;
      if (current == null ||
          current.deleted ||
          canonicalJson(current.spec) != canonicalJson(inbound.spec)) {
        throw const FormatException('vless_conflict');
      }
    }
    final ids = expected.map((r) => r.id).toSet();
    await _write(
      workspace.copy(
        inbounds: [
          for (final r in workspace.inbounds)
            if (ids.contains(r.id))
              VlessInbound(
                serverId: r.serverId,
                spec: {...r.spec, 'deleted': true, 'enabled': false},
              )
            else
              r,
        ],
      ),
    );
    plans = [];
    await _profiles();
  });

  Future<bool> retireProtocol(String serverId, String protocol) async {
    if (busy || hasRunning || !loaded) return false;
    var saved = false;
    await _run((token) async {
      await checkProfileEffects();
      final target = protocol == 'amneziawg'
          ? awgTarget(serverId)
          : protocol == 'trusttunnel'
          ? ttTarget(serverId)
          : serverId;
      final record = workspace.servers[target];
      if (_isTargetBusy(record)) throw const FormatException('vpn_busy');
      await _write(
        workspace.copy(
          inbounds: [
            for (final r in workspace.inbounds)
              if (protocol == 'vless' && r.serverId == serverId)
                VlessInbound.fromJson({
                  ...r.toJson(),
                  'spec': {...r.spec, 'deleted': true, 'enabled': false},
                })
              else
                r,
          ],
          awgInterfaces: [
            for (final r in workspace.awgInterfaces)
              if (protocol == 'amneziawg' && r.serverId == serverId)
                AwgInterface.fromJson({
                  ...r.toJson(),
                  'spec': {...r.spec, 'deleted': true, 'enabled': false},
                })
              else
                r,
          ],
          ttEndpoints: [
            for (final r in workspace.ttEndpoints)
              if (protocol == 'trusttunnel' && r.serverId == serverId)
                TrustTunnelEndpoint.fromJson({
                  ...r.toJson(),
                  'spec': {...r.spec, 'deleted': true, 'enabled': false},
                })
              else
                r,
          ],
          servers: {
            ...workspace.servers,
            target: {
              if (record != null) ...record,
              'paused': true,
              'authorizedPayload': null,
              'pending': null,
              'observed': <dynamic>[],
              'verifiedAt': null,
            },
          },
        ),
      );
      plans = [];
      await _profiles();
      saved = true;
    });
    return saved;
  }

  /// Stops tracking inaccessible physical servers without contacting them.
  /// Remote access may still exist, so queued client revocations are retained
  /// as explicit `abandoned` audit records rather than reported as revoked.
  Future<bool> forgetServersLocally(Iterable<String> serverIds) async {
    final physical = serverIds.toSet();
    if (busy || !loaded || physical.isEmpty) return false;
    var saved = false;
    await _run((token) async {
      await checkProfileEffects();
      token.check();
      final targets = <String>{
        for (final id in physical) id,
        for (final id in physical) awgTarget(id),
        for (final id in physical) ttTarget(id),
        for (final id in workspace.servers.keys)
          if (physical.contains(vpnServerId(id))) id,
      };
      final abandonedAt = DateTime.now().toUtc().toIso8601String();
      final nextUsers = <VpnUser>[
        for (final user in workspace.users)
          if (!user.deleted ||
              !(user.deletion!['targets'] as Map).keys.any(
                (target) => physical.contains(vpnServerId(target as String)),
              ))
            user
          else
            VpnUser(
              id: user.id,
              login: user.login,
              name: user.name,
              baseTemplate: user.baseTemplate,
              baseTemplateName: user.baseTemplateName,
              enabled: false,
              deletion: {
                ...user.deletion!,
                'targets': {
                  for (final entry
                      in (user.deletion!['targets'] as Map).entries)
                    entry.key:
                        physical.contains(vpnServerId(entry.key as String)) &&
                            !vpnRevocationSettled(entry.value)
                        ? {
                            ...entry.value as Map,
                            'status': 'abandoned',
                            'abandonedAt': abandonedAt,
                            'request': null,
                            'job': null,
                            'error': null,
                            'retryAt': 0,
                          }
                        : entry.value,
                },
              },
            ),
      ];
      await _write(
        workspace.copy(
          users: nextUsers,
          inbounds: [
            for (final resource in workspace.inbounds)
              if (physical.contains(resource.serverId))
                VlessInbound.fromJson({
                  ...resource.toJson(),
                  'spec': {...resource.spec, 'enabled': false, 'deleted': true},
                })
              else
                resource,
          ],
          awgInterfaces: [
            for (final resource in workspace.awgInterfaces)
              if (physical.contains(resource.serverId))
                AwgInterface.fromJson({
                  ...resource.toJson(),
                  'spec': {...resource.spec, 'enabled': false, 'deleted': true},
                })
              else
                resource,
          ],
          ttEndpoints: [
            for (final resource in workspace.ttEndpoints)
              if (physical.contains(resource.serverId))
                TrustTunnelEndpoint.fromJson({
                  ...resource.toJson(),
                  'spec': {...resource.spec, 'enabled': false, 'deleted': true},
                })
              else
                resource,
          ],
          servers: {
            for (final entry in workspace.servers.entries)
              entry.key: !targets.contains(entry.key)
                  ? entry.value
                  : {
                      ...entry.value,
                      'paused': true,
                      'authorizedPayload': null,
                      'appliedPayload': null,
                      'pending': null,
                      'job': null,
                      'operation': null,
                      'error': null,
                      'cancelRequested': false,
                      'observingCancel': false,
                      'observed': <dynamic>[],
                      'verifiedAt': null,
                      'forgottenLocallyAt': abandonedAt,
                    },
          },
        ),
      );
      plans = [];
      observedJobs.removeWhere((id, _) => targets.contains(id));
      observationErrors.removeWhere((id, _) => targets.contains(id));
      await connections.forgetServers(physical);
      await _approveRestored(targets);
      await _profiles();
      serverSyncIssue = null;
      saved = true;
    });
    return saved && error == null;
  }

  Future<RunnerResponse> _request(
    VpnRemote r,
    RunnerRequest request,
    CancellationToken token, {
    bool allowMissing = false,
  }) async {
    try {
      if (request.json['action'] != 'status') await checkProfileEffects();
      if (const {
        'submit',
        'resume',
        'cancel',
      }.contains(request.json['action'])) {
        if ((await repository.readVpn()).revision != revision) {
          throw const SyncMergeFailure(SyncMergeIssue.changed);
        }
      }
      token.check();
      final response = await r.transport.request(
        request,
        token,
        sudoPassword: r.password,
      );
      token.check();
      if (response.code != 'ok' &&
          !(allowMissing && response.code == 'missing')) {
        throw FormatException(
          (response.code.startsWith('vless_') ||
                  response.code.startsWith('vpn_adoption_') ||
                  response.code.startsWith('awg_') ||
                  response.code.startsWith('tt_'))
              ? response.code
              : 'vpn_${response.code}',
        );
      }
      return response;
    } on SshFailure catch (e) {
      r.onSshFailure?.call(e.issue);
      rethrow;
    }
  }

  Future<void> prepareAndApply({Set<String>? serverIds}) async {
    await prepare(serverIds: serverIds);
    if (error == null && plans.isNotEmpty) await apply();
  }

  bool adoptionConfirmed(String target, String id) =>
      workspace.servers[target]?['pending'] == null &&
      (workspace.servers[target]?['observed'] as List? ?? []).any(
        (row) => row['id'] == id && row['confirmed'] == true,
      );

  Future<void> adoptResource({
    required String target,
    required String expectedIdentity,
    required Map<String, Object?> spec,
  }) async {
    var prepared = false;
    await _run((token) async {
      if (!loaded || hasRunning || pendingRevocations.isNotEmpty) {
        throw const FormatException('vpn_busy');
      }
      await ensureConnected(target);
      token.check();
      final connection = remote(target);
      if (connection == null ||
          connection.identity != expectedIdentity ||
          workspace.servers[target]?['identity'] != null &&
              workspace.servers[target]!['identity'] != expectedIdentity) {
        throw const FormatException('vpn_identity');
      }
      final server = vpnServerId(target);
      final source = (spec['adoption'] as Map)['sourceId'];
      final existing = isAwgTarget(target)
          ? workspace.awgInterfaces
                .where((r) => r.serverId == server && !r.deleted)
                .map((r) => r.spec)
          : isTtTarget(target)
          ? workspace.ttEndpoints
                .where((r) => r.serverId == server && !r.deleted)
                .map((r) => r.spec)
          : workspace.inbounds
                .where((r) => r.serverId == server && !r.deleted)
                .map((r) => r.spec);
      if (existing.any((s) => (s['adoption'] as Map?)?['sourceId'] == source)) {
        throw const FormatException('vpn_adoption_conflict');
      }
      final candidate = isAwgTarget(target)
          ? workspace.copy(
              awgInterfaces: [
                ...workspace.awgInterfaces,
                AwgInterface(serverId: server, spec: spec),
              ],
            )
          : isTtTarget(target)
          ? workspace.copy(
              ttEndpoints: [
                ...workspace.ttEndpoints,
                TrustTunnelEndpoint(serverId: server, spec: spec),
              ],
            )
          : workspace.copy(
              inbounds: [
                ...workspace.inbounds,
                VlessInbound(serverId: server, spec: spec),
              ],
            );
      final panel = isAwgTarget(target) || isTtTarget(target)
          ? workspace.resourceWorkspaceId(target)
          : connection.panelId;
      final payload = candidate.desired(target, panel);
      final response = await _request(
        connection,
        _planRequest(target, panel, payload),
        token,
      );
      final preview = _preview(response, target);
      if (preview == null) throw const FormatException('vpn_adoption_failed');
      await _write(candidate);
      plans = [VpnPlan(target, payload, connection.identity, preview)];
      prepared = true;
    });
    if (prepared && error == null) await apply();
  }

  Future<void> prepare({Set<String>? serverIds}) => _run((token) async {
    if (blockingRevocations.isNotEmpty) {
      throw const FormatException('vpn_busy');
    }
    plans = [];
    final availableTargets = serverIds ?? workspace.serverIds;
    final selected = availableTargets.where((id) {
      if (serverIds != null && !serverIds.contains(id)) return false;
      final server = vpnServerId(id);
      return this.serverIds == null ||
          this.serverIds!().map(vpnServerId).contains(server);
    }).toList();
    // A hidden revocation is retained honestly, but it must not become an
    // invisible permanent blocker. Once this explicit access change reconnects
    // the server, finish the old revocation before planning the current state.
    if (pendingRevocations.isNotEmpty) {
      for (final id in selected) {
        await ensureConnected(id);
        token.check();
      }
      await _reconcileDeletions(token);
    }
    if (blockingRevocations.isNotEmpty) {
      throw const FormatException('vpn_busy');
    }
    await _mapServersBounded(
      selected.map(vpnServerId).toSet().toList(),
      (id) => ensureConnected(id),
      cancellation: token,
    );
    final plansList = await _mapServersBounded(selected, (id) async {
      await ensureConnected(id);
      token.check();
      final connection = remote(id);
      final previous = workspace.servers[id];
      if (observesOperation(id)) {
        if (!observedJobs.containsKey(id) && connection != null) {
          await _observeOperation(id, token);
        }
        if (currentJob(id)?.terminal == false) {
          throw const FormatException('vpn_busy');
        }
      } else if (_isTargetBusy(previous)) {
        throw const FormatException('vpn_busy');
      }
      final panelId = (isAwgTarget(id) || isTtTarget(id))
          ? workspace.resourceWorkspaceId(id)
          : connection?.panelId ?? previous?['panelId'] as String?;
      if (panelId == null) throw const FormatException('vpn_panel_required');
      final payload = workspace.desired(id, panelId);
      if (connection == null || hasPendingRevocation(vpnServerId(id))) {
        return VpnPlan(
          id,
          payload,
          connection?.identity ?? previous?['identity'] as String?,
          null,
        );
      }
      if (previous?['identity'] != null &&
          previous?['identity'] != connection.identity) {
        throw const FormatException('vpn_identity');
      }
      final response = await _request(
        connection,
        _planRequest(id, panelId, payload),
        token,
      );
      if (_preview(response, id) == null) {
        throw const FormatException('vpn_failed');
      }
      return VpnPlan(id, payload, connection.identity, _preview(response, id));
    }, cancellation: token);
    plans = plansList;
  });
  void dismissPlans() {
    if (!busy) {
      plans = [];
      _notify();
    }
  }

  Future<void> apply() => _run((token) async {
    if (blockingRevocations.isNotEmpty) {
      throw const FormatException('vpn_busy');
    }
    if (plans.isEmpty) return;
    final records = {...workspace.servers};
    for (final plan in plans) {
      if (canonicalJson(plan.payload) !=
          canonicalJson(
            workspace.desired(plan.serverId, plan.payload['panelId'] as String),
          )) {
        throw const FormatException('vpn_conflict');
      }
      final previous = records[plan.serverId] ?? <String, dynamic>{};
      final operationId = newVpnId();
      records[plan.serverId] = {
        ...previous,
        if (_deviceId != null)
          'operation': ServerOperation(
            operationId: operationId,
            executorDeviceId: _deviceId!,
            expectedRevision: plan.preview?['fingerprint'] as String?,
          ).toJson(),
        'panelId': plan.payload['panelId'],
        'identity': plan.identity,
        'authorizedPayload': jsonEncode(plan.payload),
        'paused': false,
        'error': null,
        'pending': plan.preview == null
            ? null
            : _applyRequest(
                plan.serverId,
                operationId,
                plan.payload,
                plan.preview!['fingerprint'] as String,
              ).json,
        'job': null,
        'cancelRequested': false,
        'observingCancel': false,
      };
    }
    // Every server's intent is durable before the first remote submission.
    await _write(workspace.copy(servers: records));
    await _approveRestored(plans.map((p) => p.serverId));
    plans = [];
    await _reconcile(token);
    _scheduleReconcile();
  });
  bool diagnosticsPaused = false;

  bool get _hasServerReconcileWork => workspace.servers.entries.any(
    (entry) =>
        remote(entry.key) != null &&
        (observesOperation(entry.key) &&
                currentJob(entry.key)?.terminal != true ||
            _needsReconcile(entry.key, entry.value)),
  );

  void _scheduleReconcile() {
    if (_disposed ||
        _reconcileRetry?.isActive == true ||
        !_hasServerReconcileWork) {
      return;
    }
    _reconcileRetry = Timer(const Duration(seconds: 1), () {
      _reconcileRetry = null;
      unawaited(reconcile());
    });
  }

  Future<void> reconcile() async {
    if (!loaded || busy || _disposed || diagnosticsPaused) return;
    final work = _hasServerReconcileWork;
    final fresh = (serverIds?.call() ?? const <String>[]).where((id) {
      final connection = remote(id);
      return connection?.observationKey != null &&
          _observedConnections[id] != connection!.observationKey;
    }).toList();
    if (!work &&
        !_restoredTargets.any((id) => remote(id) != null) &&
        fresh.isEmpty &&
        template() == _lastTemplate &&
        pendingDeletions.isEmpty) {
      return;
    }
    await _run((token) async {
      await _reconcileDeletions(token);
      for (final id in fresh) {
        final connection = remote(id);
        if (connection == null) continue;
        if (!observesOperation(id)) await _refreshServer(id, token);
        _observedConnections[id] = connection.observationKey!;
      }
      if (work || _restoredTargets.any((id) => remote(id) != null)) {
        await _reconcile(token);
      }
      if (template() != _lastTemplate) await _profiles();
    }, background: true);
    _scheduleReconcile();
  }

  bool _needsReconcile(String id, Map<String, dynamic> record) {
    if (remote(id) == null || _restoredTargets.contains(id)) return false;
    if (_canAutoResume(id, record) ||
        record['cancelRequested'] == true ||
        record['observingCancel'] == true ||
        (record['paused'] != true && record['pending'] != null)) {
      return true;
    }
    final authorized = record['authorizedPayload'];
    if (record['paused'] == true ||
        authorized == null ||
        authorized == record['appliedPayload']) {
      return false;
    }
    try {
      return canonicalJson(jsonDecode(authorized as String)) ==
          canonicalJson(workspace.desired(id, remote(id)!.panelId));
    } catch (_) {
      return false;
    }
  }

  bool _canAutoResume(String id, Map<String, dynamic> record) {
    final pending = record['pending'];
    final job = record['job'];
    final connection = remote(id);
    if (record['paused'] != true ||
        record['cancelRequested'] == true ||
        observesOperation(id) ||
        _restoredTargets.contains(id) ||
        hasPendingRevocation(vpnServerId(id)) ||
        connection == null ||
        record['identity'] != connection.identity ||
        pending is! Map ||
        pending['kind'] != 'vless_apply' ||
        pending['id'] is! String ||
        pending['id'] == record['autoResumeAttemptedId'] ||
        pending['payload'] is! String ||
        record['authorizedPayload'] is! String ||
        job is! Map ||
        job['id'] != pending['id'] ||
        job['kind'] != 'vless_apply' ||
        job['status'] != 'partially_applied') {
      return false;
    }
    try {
      final authorized = jsonDecode(record['authorizedPayload'] as String);
      return canonicalJson(authorized) ==
              canonicalJson(jsonDecode(pending['payload'] as String)) &&
          canonicalJson(authorized) ==
              canonicalJson(workspace.desired(id, connection.panelId));
    } catch (_) {
      return false;
    }
  }

  Future<void> _reconcile(CancellationToken token) async {
    final beforeProfiles = workspace;
    final beforeTemplate = template();
    final beforeNames = profileServerNames;
    _restoredTargets = await recovery?.readRestoredTargets() ?? {};
    final reconcileTargets =
        {
          ...workspace.serverIds,
          for (final e in workspace.servers.entries)
            if (e.value['pending'] != null ||
                e.value['job'] != null ||
                e.value['operation'] != null)
              e.key,
        }.where((id) {
          final server = vpnServerId(id);
          return serverIds == null ||
              serverIds!().map(vpnServerId).contains(server);
        }).toList();
    final groups = <String, List<String>>{};
    for (final id in reconcileTargets) {
      groups.putIfAbsent(vpnServerId(id), () => []).add(id);
    }
    final groupList = groups.values.toList();
    var next = 0;
    final changed = await Future.wait(
      List.generate(groupList.length < 4 ? groupList.length : 4, (_) async {
        var anyChanged = false;
        while (next < groupList.length) {
          final targets = groupList[next++];
          for (final id in targets) {
            if (await _reconcileTarget(id, token)) anyChanged = true;
          }
        }
        return anyChanged;
      }),
    );
    if (changed.contains(true)) {
      final affected = _changedProfileClients(
        beforeProfiles,
        workspace,
        beforeTemplate,
        template(),
        beforeNames,
        profileServerNames,
      );
      if (affected == null || affected.length > 1) {
        await _profiles();
      } else if (affected.isNotEmpty) {
        await _profiles(onlyUserId: affected.single);
      }
    }
  }

  Future<bool> _reconcileTarget(String id, CancellationToken token) async {
    var changed = false;
    // A force-hidden revocation and the current desired payload may coexist
    // durably, but must never execute concurrently on the physical server.
    if (hasPendingRevocation(vpnServerId(id))) return false;
    if (observesOperation(id)) {
      await _observeOperation(id, token);
      return false;
    }
    if (_restoredTargets.contains(id)) return false;
    final connection = remote(id);
    if (connection == null) return false;
    var record = Map<String, dynamic>.from(workspace.servers[id] ?? {});
    if (record['identity'] != null &&
        record['identity'] != connection.identity) {
      if (record['error'] != 'vpn_identity') {
        await _record(id, {...record, 'error': 'vpn_identity', 'paused': true});
      }
      return false;
    }
    try {
      if (_canAutoResume(id, record)) {
        final requestId = (record['pending'] as Map)['id'] as String;
        final status = await _request(
          connection,
          RunnerRequest.status(requestId, 0),
          token,
        );
        if (status.jobs.length != 1 || status.jobs.single.id != requestId) {
          throw const FormatException('vpn_conflict');
        }
        if (status.jobs.single.status == 'partially_applied') {
          // Save the attempt before the remote call. A lost reply or a real
          // conflict must never cause an endless automatic resume loop.
          record = {...record, 'autoResumeAttemptedId': requestId};
          await _record(id, record);
          await _request(connection, RunnerRequest.resume(requestId), token);
        } else if (!const {
          'running',
          'succeeded',
        }.contains(status.jobs.single.status)) {
          throw const FormatException('vpn_conflict');
        }
        record = {...record, 'paused': false, 'error': null};
        await _record(id, record);
      }
      final authorized = record['authorizedPayload'] as String?;
      if (record['pending'] == null &&
          record['paused'] != true &&
          authorized != null &&
          record['appliedPayload'] != authorized) {
        final payload = Map<String, Object?>.from(
          jsonDecode(authorized) as Map,
        );
        // New unapproved edits invalidate the old authorization.
        if (canonicalJson(payload) !=
            canonicalJson(workspace.desired(id, connection.panelId))) {
          return false;
        }
        final preview = await _request(
          connection,
          _planRequest(id, connection.panelId, payload),
          token,
        );
        final request = _applyRequest(
          id,
          operation(id)?.operationId ?? newVpnId(),
          payload,
          _preview(preview, id)!['fingerprint'] as String,
        );
        record = {
          ...record,
          'pending': request.json,
          if (_deviceId != null)
            'operation': ServerOperation(
              operationId: request.id!,
              executorDeviceId: _deviceId!,
              expectedRevision: request.json['fingerprint'] as String?,
            ).toJson(),
          'identity': connection.identity,
          'panelId': connection.panelId,
        };
        await _record(id, record);
      }
      final pending = record['pending'];
      if (pending != null && record['cancelRequested'] == true) {
        final cancellation = await _request(
          connection,
          RunnerRequest.cancel((pending as Map)['id'] as String),
          token,
          allowMissing: true,
        );
        if (cancellation.code == 'missing') {
          await _record(id, {
            ...record,
            'pending': null,
            'authorizedPayload': null,
            'paused': true,
            'cancelRequested': false,
            'observingCancel': false,
            'error': null,
          });
          changed = true;
          return true;
        }
        record = {...record, 'cancelRequested': false, 'observingCancel': true};
        await _record(id, record);
      }
      if (pending != null &&
          (record['paused'] != true || record['observingCancel'] == true)) {
        final request = RunnerRequest.fromJson(
          Map<String, Object?>.from(pending as Map),
        );
        // After an uncertain response, establish the existing job's fate
        // before any retry. Never issue a new ID to bypass a conflict.
        var response = await _request(
          connection,
          RunnerRequest.status(request.id!, 0),
          token,
          allowMissing: true,
        );
        if (response.code == 'missing' && record['observingCancel'] != true) {
          final payload = Map<String, Object?>.from(
            jsonDecode(request.json['payload'] as String) as Map,
          );
          if (canonicalJson(payload) !=
              canonicalJson(workspace.desired(id, connection.panelId))) {
            throw const FormatException('vpn_conflict');
          }
          response = await _request(connection, request, token);
        }
        if (response.jobs.isEmpty) throw const FormatException('vpn_failed');
        final before = record['job'] == null
            ? null
            : RunnerJob.fromJson(
                Map<String, dynamic>.from(record['job'] as Map),
              );
        final job = response.jobs.single.mergeEvents(before);
        record = {...record, 'job': job.toJson(), 'error': null};
        if (job.terminal) {
          record = {...record, 'observingCancel': false};
          final state = await _request(
            connection,
            _stateRequest(id, connection.panelId),
            token,
          );
          record = {
            ...record,
            'observed': _observations(state, id),
            'verifiedAt': DateTime.now().toUtc().toIso8601String(),
          };
          if (job.status == 'succeeded') {
            final payload = Map<String, Object?>.from(
              jsonDecode(request.json['payload'] as String) as Map,
            );
            final expected = vlessRevision(payload);
            final activeIds = (payload['resources'] as List)
                .where((r) => (r as Map)['deleted'] != true)
                .map((r) => (r as Map)['id'])
                .toSet();
            final deletedIds = (payload['resources'] as List)
                .where((r) => (r as Map)['deleted'] == true)
                .map((r) => (r as Map)['id'])
                .toSet();
            final observations = _observations(state, id);
            if (observations == null ||
                !activeIds.every(
                  (rid) => observations.any(
                    (r) =>
                        r['id'] == rid &&
                        r['workspaceId'] == workspace.resourceWorkspaceId(id) &&
                        r['confirmed'] == true &&
                        r['revision'] == expected,
                  ),
                ) ||
                !deletedIds.every((rid) {
                  final obs = observations
                      .where((r) => r['id'] == rid)
                      .firstOrNull;
                  return obs == null ||
                      (obs['workspaceId'] ==
                              workspace.resourceWorkspaceId(id) &&
                          obs['confirmed'] == true &&
                          (obs['deleted'] == true || obs['exists'] == false));
                })) {
              throw const FormatException('vpn_conflict');
            }
            record = {
              ...record,
              'pending': null,
              'appliedPayload': request.json['payload'],
              'paused': false,
            };
          } else {
            record = {...record, 'paused': true, 'error': 'vpn_${job.status}'};
          }
        }
        await _record(id, record);
        changed = true;
      }
    } on SshFailure {
      // Keep the same operation ID after an uncertain response. Reconnect
      // reads/submits idempotently; it never fabricates a successful result.
      await _record(id, {...record, 'error': 'vpn_connection'});
    } on FormatException catch (e) {
      await _record(id, {
        ...record,
        'error': e.message == 'vpn_busy' ? null : e.message,
        'paused': e.message != 'vpn_busy',
      });
    } on RunnerFailure {
      await _record(id, {...record, 'error': 'vpn_runner'});
    }
    return changed;
  }

  Future<void> refreshServer(String id) => _run((token) async {
    if (error == 'vless_conflict' ||
        error == 'vpn_conflict' ||
        error == 'vpn_adoption_conflict') {
      error = null;
    }
    await ensureConnected(id);
    token.check();
    await _refreshServer(id, token);
  });
  Future<void> _refreshServer(
    String id,
    CancellationToken token, {
    bool rebuildProfiles = true,
  }) async {
    final r = remote(id);
    if (r == null) throw const FormatException('vpn_connection');
    final current = workspace.servers[id] ?? {};
    if (current['identity'] != null && current['identity'] != r.identity) {
      throw const FormatException('vpn_identity');
    }
    final result = await _request(r, _stateRequest(id, r.panelId), token);
    final observations = _observations(result, id) ?? [];
    await _applyServerObservations(id, r, observations);
    if (rebuildProfiles) await _profiles();
  }

  Future<void> _applyServerObservations(
    String id,
    VpnRemote r,
    List<Map<String, dynamic>> observations,
  ) async {
    final current = workspace.servers[id] ?? {};
    await _record(id, {
      ...current,
      'identity': r.identity,
      'panelId': r.panelId,
      'observed': observations,
      'error':
          (current['error'] == 'vless_conflict' ||
              current['error'] == 'vpn_conflict' ||
              current['error'] == 'vpn_adoption_conflict')
          ? null
          : current['error'],
      if (current['error'] == 'vless_conflict' ||
          current['error'] == 'vpn_conflict' ||
          current['error'] == 'vpn_adoption_conflict')
        'paused': false,
      'verifiedAt': DateTime.now().toUtc().toIso8601String(),
    });
    if (isTtTarget(id)) {
      final recovered = observations
          .where(
            (o) =>
                o['workspaceId'] == workspace.resourceWorkspaceId(id) &&
                !workspace.ttEndpoints.any((i) => i.id == o['id']),
          )
          .map(
            (o) => TrustTunnelEndpoint(
              serverId: vpnServerId(id),
              spec: Map<String, Object?>.from(o['spec'] as Map),
            ),
          )
          .toList();
      if (recovered.isNotEmpty) {
        await _write(
          workspace.copy(ttEndpoints: [...workspace.ttEndpoints, ...recovered]),
        );
      }
      return;
    }
    if (isAwgTarget(id)) {
      final recovered = observations
          .where(
            (o) =>
                o['workspaceId'] == workspace.resourceWorkspaceId(id) &&
                !workspace.awgInterfaces.any((i) => i.id == o['id']),
          )
          .map(
            (o) => AwgInterface(
              serverId: vpnServerId(id),
              spec: Map<String, Object?>.from(o['spec'] as Map),
            ),
          )
          .toList();
      if (recovered.isNotEmpty) {
        await _write(
          workspace.copy(
            awgInterfaces: [...workspace.awgInterfaces, ...recovered],
          ),
        );
      }
      return;
    }
    final recovered = observations
        .where(
          (o) =>
              o['workspaceId'] == workspace.resourceWorkspaceId(id) &&
              !workspace.inbounds.any((i) => i.id == o['id']) &&
              o['deleted'] != true &&
              o['exists'] != false,
        )
        .map(
          (o) => VlessInbound(
            serverId: id,
            spec: Map<String, Object?>.from(o['spec'] as Map),
          ),
        )
        .toList();
    var changed = false;
    final updatedInbounds = workspace.inbounds.map((ib) {
      if (ib.serverId != id || ib.deleted) return ib;
      final obs = observations.firstWhere(
        (o) => o['id'] == ib.id,
        orElse: () => <String, dynamic>{},
      );
      if (obs.isNotEmpty &&
          (obs['deleted'] == true || obs['exists'] == false)) {
        changed = true;
        return VlessInbound(
          serverId: id,
          spec: {...ib.spec, 'deleted': true, 'enabled': false},
        );
      }
      return ib;
    }).toList();
    if (recovered.isNotEmpty || changed) {
      await _write(
        workspace.copy(inbounds: [...updatedInbounds, ...recovered]),
      );
    }
  }

  Future<void> _observeOperation(String id, CancellationToken token) async {
    final connection = remote(id), op = operation(id);
    if (connection == null || op == null) {
      observationErrors[id] = 'vpn_connection';
      return;
    }
    if (workspace.servers[id]?['identity'] != null &&
        workspace.servers[id]!['identity'] != connection.identity) {
      observationErrors[id] = 'vpn_identity';
      return;
    }
    try {
      final response = await _request(
        connection,
        RunnerRequest.status(op.operationId, 0),
        token,
        allowMissing: true,
      );
      if (response.code != 'missing' &&
          (response.jobs.length != 1 ||
              response.jobs.single.id != op.operationId)) {
        throw const FormatException('vpn_failed');
      }
      final job = response.code == 'missing'
          ? null
          : response.jobs.single;
      observedJobs[id] = job;
      observationErrors.remove(id);
      if (job != null && job.terminal) {
        final current = workspace.servers[id];
        if (current != null &&
            (current['pending'] != null ||
                current['job']?['status'] != job.status)) {
          final state = await _request(
            connection,
            _stateRequest(id, connection.panelId),
            token,
          );
          await _record(id, {
            ...current,
            'job': job.toJson(),
            'pending': job.status == 'succeeded' ? null : current['pending'],
            'observed': _observations(state, id),
            'verifiedAt': DateTime.now().toUtc().toIso8601String(),
            if (job.status != 'succeeded') 'paused': true,
          });
          await _approveRestored([id]);
          await _profiles();
        }
      }
      // Observation is local UI state; do not create competing sync events
      // for every poll of another device's operation.
    } on SshFailure {
      observationErrors[id] = 'vpn_connection';
    } on FormatException catch (e) {
      observationErrors[id] = e.message;
    }
  }

  /// Explicit handoff. Query the previous operation ID first, preserve its
  /// request/precondition and commit ownership before contacting the runner.
  Future<void> takeOver(String id) => _run((token) async {
    final op = operation(id), connection = remote(id);
    if (op == null || _deviceId == null || connection == null) {
      throw const FormatException('vpn_connection');
    }
    await _observeOperation(id, token);
    if (observationErrors[id] case final String error) {
      throw FormatException(error);
    }
    final record = workspace.servers[id]!;
    final job = observedJobs[id];
    if (job != null) {
      // Existing work is observed; failed jobs have a separate resume action.
      return;
    }
    final payload = record['authorizedPayload'] as String?;
    if (payload != null &&
        canonicalJson(jsonDecode(payload)) !=
            canonicalJson(workspace.desired(id, connection.panelId))) {
      throw const FormatException('vpn_conflict');
    }
    await checkProfileEffects();
    await _record(id, {
      ...record,
      'operation': op.withExecutor(_deviceId!).toJson(),
    });
    await _approveRestored([id]);
    observedJobs.remove(id);
    observationErrors.remove(id);
    await _reconcile(token);
  });

  Future<void> cancel(String id) => _run((token) async {
    final record = workspace.servers[id];
    if (record == null) return;
    final req = record['pending'] as Map?;
    if (req == null) {
      await _record(id, {...record, 'paused': true, 'authorizedPayload': null});
      await _approveRestored([id]);
      return;
    }
    // Remember cancellation while offline and send it before any further
    // resubmission when the server becomes reachable.
    if (observesOperation(id)) {
      await _observeOperation(id, token);
      if (!observedJobs.containsKey(id) || observationErrors.containsKey(id)) {
        throw const FormatException('vpn_connection');
      }
    }
    await _record(id, {
      ...record,
      'paused': true,
      'cancelRequested': true,
      if (operation(id) != null && _deviceId != null)
        'operation': operation(id)!.withExecutor(_deviceId!).toJson(),
    });
    await _approveRestored([id]);
    final r = remote(id);
    if (r == null) return;
    if (record['identity'] != null && record['identity'] != r.identity) {
      throw const FormatException('vpn_identity');
    }
    await _reconcile(token);
  });

  /// A restored request is only inspected here. Missing jobs are not submitted.
  Future<void> reviewRestored(String id) =>
      _run((token) => _reviewRestored(id, token));

  Future<void> _reviewRestored(String id, CancellationToken token) async {
    if (!_restoredTargets.contains(id)) return;
    final connection = remote(id);
    if (connection == null) throw const FormatException('vpn_connection');
    final old = workspace.servers[id];
    if (old == null) return;
    if (old['identity'] != null && old['identity'] != connection.identity) {
      throw const FormatException('vpn_identity');
    }
    await _refreshServer(id, token);
    final record = workspace.servers[id]!;
    final request = record['pending'] as Map?;
    RunnerJob? job;
    if (request != null) {
      final response = await _request(
        connection,
        RunnerRequest.status(request['id'] as String, 0),
        token,
        allowMissing: true,
      );
      if (response.code != 'missing') {
        if (response.jobs.length != 1 ||
            response.jobs.single.id != request['id']) {
          throw const FormatException('vpn_failed');
        }
        job = response.jobs.single;
      }
    }
    await _record(id, {
      ...record,
      'paused': true,
      'authorizedPayload': null,
      'cancelRequested': false,
      'observingCancel': false,
      'pending':
          job == null || job.status == 'succeeded' || job.status == 'cancelled'
          ? null
          : request,
      'job': job?.toJson(),
      'error': null,
    });
    await _approveRestored([id]);
  }

  Future<void> resume(String id) => _run((token) async {
    if (pendingRevocations.isNotEmpty) throw const FormatException('vpn_busy');
    final r = remote(id), record = workspace.servers[id];
    if (r == null || record == null) {
      throw const FormatException('vpn_connection');
    }
    final request = record['pending'] as Map?;
    if (request == null) return;
    if (record['identity'] != null && record['identity'] != r.identity) {
      throw const FormatException('vpn_identity');
    }
    final status = await _request(
      r,
      RunnerRequest.status(request['id'] as String, 0),
      token,
    );
    if (status.jobs.length != 1 || status.jobs.single.id != request['id']) {
      throw const FormatException('vpn_conflict');
    }
    if (status.jobs.single.status == 'succeeded') {
      await _record(id, {
        ...workspace.servers[id]!,
        'paused': false,
        'cancelRequested': false,
        'error': null,
      });
      await _approveRestored([id]);
      await _reconcile(token);
      return;
    }
    if (!const {
      'failed',
      'partially_applied',
    }.contains(status.jobs.single.status)) {
      throw const FormatException('vpn_conflict');
    }
    await _record(id, {
      ...record,
      if (operation(id) != null && _deviceId != null)
        'operation': operation(id)!.withExecutor(_deviceId!).toJson(),
    });
    await _request(r, RunnerRequest.resume(request['id'] as String), token);
    await _record(id, {
      ...workspace.servers[id]!,
      'paused': false,
      'cancelRequested': false,
      'error': null,
    });
    await _approveRestored([id]);
    await _reconcile(token);
  });
  Future<void> refreshProfiles() => _run((token) async {
    if (loaded) await _profiles();
  });

  /// Re-reads every active access resource before rebuilding [userId]'s
  /// profile. This is intentionally read-only: it never submits a new access
  /// plan from a profile/share action.
  Future<void> regenerateProfile(String userId) => _run((token) async {
    if (!loaded ||
        !workspace.users.any(
          (user) => user.id == userId && !user.deleted && user.enabled,
        )) {
      return;
    }
    final targets = <String>{
      for (final resource in workspace.inbounds)
        if (resource.enabled && !resource.deleted && !resource.internal)
          resource.serverId,
      for (final resource in workspace.awgInterfaces)
        if (resource.enabled && !resource.deleted) awgTarget(resource.serverId),
      for (final resource in workspace.ttEndpoints)
        if (resource.enabled && !resource.deleted) ttTarget(resource.serverId),
    }.toList()..sort();
    error = await _refreshTargets(targets, token);
  });

  /// A saved verification may be reused only while every desired target and
  /// compiled profile still matches its last confirmed server readback.
  bool get hasCurrentVerifiedProfiles {
    if (!loaded ||
        busy ||
        serverSyncIssue != null ||
        _lastTemplate != template() ||
        _restoredTargets.isNotEmpty ||
        pendingRevocations.isNotEmpty ||
        hasRunning ||
        hasObservedRunning ||
        hasUnappliedActiveAccess) {
      return false;
    }
    // A target removed from the desired catalog may still have an applied
    // resource to retire. Do not treat its absence from serverIds as success.
    if (workspace.servers.keys.any(
      (target) =>
          !workspace.serverIds.contains(target) &&
          (workspace.servers[target]?['appliedPayload'] != null ||
              workspace.servers[target]?['authorizedPayload'] != null),
    )) {
      return false;
    }
    for (final target in workspace.serverIds) {
      final record = workspace.servers[target];
      final connection = remote(target);
      final panelId = record?['panelId'];
      final applied = record?['appliedPayload'];
      if (record == null ||
          panelId is! String ||
          applied is! String ||
          record['verifiedAt'] == null ||
          record['observed'] is! List ||
          record['identity'] == null ||
          record['pending'] != null ||
          record['paused'] == true ||
          record['error'] != null ||
          record['cancelRequested'] == true ||
          record['observingCancel'] == true ||
          (connection != null && connection.identity != record['identity']) ||
          record['authorizedPayload'] != applied) {
        return false;
      }
      try {
        final desired = workspace.desired(target, panelId);
        if (canonicalJson(jsonDecode(applied)) != canonicalJson(desired)) {
          return false;
        }
        final expectedRevision = vlessRevision(desired);
        final observations = (record['observed'] as List).whereType<Map>();
        for (final resource in desired['resources'] as List) {
          final spec = resource as Map;
          if (spec['deleted'] == true) continue;
          if (!observations.any(
            (row) =>
                row['id'] == spec['id'] &&
                row['workspaceId'] == workspace.resourceWorkspaceId(target) &&
                row['confirmed'] == true &&
                row['revision'] == expectedRevision &&
                row['deleted'] != true &&
                row['exists'] != false,
          )) {
            return false;
          }
        }
      } catch (_) {
        return false;
      }
    }
    for (final user in workspace.users.where((u) => u.enabled && !u.deleted)) {
      final result = results[user.id];
      if (result == null ||
          result.hasBlockingErrors ||
          result.yaml == null ||
          result.sha256Hash == null ||
          workspace.profiles[user.id]?['hash'] != result.sha256Hash ||
          coreCheckFor(user.id)?.status == CoreConfigStatus.invalid) {
        return false;
      }
    }
    return true;
  }

  /// Reads server observations before publication when saved verification is
  /// unavailable or a fresh server check was explicitly requested.
  Future<ServerProfileSyncResult> syncAllServersAndProfiles({
    bool allowVerifiedSnapshot = false,
  }) async {
    await waitForBackgroundReconcile();
    ServerProfileSyncResult failed(String issue) {
      error = issue;
      serverSyncIssue = issue;
      _notify();
      return ServerProfileSyncResult(revision: revision, issue: issue);
    }

    if (!loaded || busy) {
      return ServerProfileSyncResult(revision: revision, issue: 'vpn_busy');
    }
    // A template edit changes local YAML, not the confirmed server payload.
    if (allowVerifiedSnapshot && _lastTemplate != template()) {
      await refreshProfiles();
      if (error != null) return failed(error!);
    }
    if (allowVerifiedSnapshot && hasCurrentVerifiedProfiles) {
      try {
        await checkProfileEffects();
        if ((await repository.readVpn()).revision != revision) {
          return failed('sync_conflict');
        }
      } on SyncMergeFailure {
        return failed('sync_conflict');
      } on VaultFailure {
        return failed('vpn_storage');
      } catch (_) {
        return failed('vpn_failed');
      }
      if (!hasCurrentVerifiedProfiles) {
        return failed('vpn_busy');
      }
      return ServerProfileSyncResult(
        revision: revision,
        usedSavedVerification: true,
      );
    }
    String? applyIssue;
    try {
      if (workspace.serverIds.isNotEmpty) {
        await prepareAndApply();
        applyIssue = error;
      }
    } catch (_) {
      applyIssue = 'vpn_failed';
    }
    await _run((token) async {
      final targets = <String>{
        for (final resource in workspace.inbounds)
          if (resource.enabled && !resource.deleted && !resource.internal)
            resource.serverId,
        for (final resource in workspace.awgInterfaces)
          if (resource.enabled && !resource.deleted)
            awgTarget(resource.serverId),
        for (final resource in workspace.ttEndpoints)
          if (resource.enabled && !resource.deleted)
            ttTarget(resource.serverId),
        for (final serverId in workspace.serverIds) ...[
          serverId,
          if (workspace.awgInterfaces.any((i) => i.serverId == serverId))
            awgTarget(serverId),
          if (workspace.ttEndpoints.any((i) => i.serverId == serverId))
            ttTarget(serverId),
        ],
      }.toList()..sort();
      error = await _refreshTargets(targets, token);
    });
    final issue = applyIssue ?? error;
    error = issue;
    serverSyncIssue = issue;
    _notify();
    return ServerProfileSyncResult(revision: revision, issue: issue);
  }

  Future<_TargetPollResult> _pollTarget(
    String target,
    CancellationToken token,
  ) async {
    try {
      if (!await ensureConnected(target)) {
        return _TargetPollResult.error(target, 'vpn_connection');
      }
      token.check();
      final r = remote(target);
      if (r == null) {
        return _TargetPollResult.error(target, 'vpn_connection');
      }
      final current = workspace.servers[target] ?? {};
      if (current['identity'] != null && current['identity'] != r.identity) {
        return _TargetPollResult.error(target, 'vpn_identity');
      }
      final result = await _request(r, _stateRequest(target, r.panelId), token);
      final observations = _observations(result, target) ?? [];
      return _TargetPollResult.success(target, r, observations);
    } on SyncMergeFailure catch (e) {
      return _TargetPollResult.fatal(target, e);
    } on VaultFailure catch (e) {
      return _TargetPollResult.fatal(target, e);
    } on SshFailure {
      return _TargetPollResult.error(target, 'vpn_connection');
    } on RunnerFailure {
      return _TargetPollResult.error(target, 'vpn_runner');
    } on FormatException catch (e) {
      return _TargetPollResult.error(target, e.message);
    } catch (_) {
      return _TargetPollResult.error(target, 'vpn_connection');
    }
  }

  Future<String?> _refreshTargets(
    List<String> targets,
    CancellationToken token,
  ) async {
    if (targets.isEmpty) {
      await _profiles();
      return null;
    }

    // 1. Pre-connect all distinct physical servers concurrently
    final physicalServers = targets.map(vpnServerId).toSet().toList()..sort();
    await _mapServersBounded(physicalServers, (serverId) async {
      try {
        await ensureConnected(serverId);
      } catch (_) {}
    }, cancellation: token);
    if (_disposed) return null;
    token.check();

    // 2. Poll all targets concurrently
    final results = await Future.wait(
      targets.map((target) => _pollTarget(target, token)),
    );
    if (_disposed) return null;

    // 3. Rethrow fatal merge/storage failures
    for (final res in results) {
      if (res.rethrowError case final error?) {
        throw error;
      }
    }

    // 4. Accumulate server observations in memory & write once to SQLite
    final updatedServers = {...workspace.servers};
    final recoveredAwg = <AwgInterface>[];
    final recoveredTt = <TrustTunnelEndpoint>[];
    String? firstIssue;
    var serverChanges = false;

    for (final res in results) {
      if (res.error != null) {
        firstIssue ??= res.error;
        continue;
      }
      final id = res.target;
      final r = res.remote!;
      final observations = res.observations!;
      final current = updatedServers[id] ?? {};
      updatedServers[id] = {
        ...current,
        'identity': r.identity,
        'panelId': r.panelId,
        'observed': observations,
        'error':
            (current['error'] == 'vless_conflict' ||
                current['error'] == 'vpn_conflict' ||
                current['error'] == 'vpn_adoption_conflict')
            ? null
            : current['error'],
        if (current['error'] == 'vless_conflict' ||
            current['error'] == 'vpn_conflict' ||
            current['error'] == 'vpn_adoption_conflict')
          'paused': false,
        'verifiedAt': DateTime.now().toUtc().toIso8601String(),
      };
      serverChanges = true;

      if (isTtTarget(id)) {
        final recovered = observations
            .where(
              (o) =>
                  o['workspaceId'] == workspace.resourceWorkspaceId(id) &&
                  !workspace.ttEndpoints.any((i) => i.id == o['id']) &&
                  !recoveredTt.any((i) => i.id == o['id']),
            )
            .map(
              (o) => TrustTunnelEndpoint(
                serverId: vpnServerId(id),
                spec: Map<String, Object?>.from(o['spec'] as Map),
              ),
            );
        recoveredTt.addAll(recovered);
      } else if (isAwgTarget(id)) {
        final recovered = observations
            .where(
              (o) =>
                  o['workspaceId'] == workspace.resourceWorkspaceId(id) &&
                  !workspace.awgInterfaces.any((i) => i.id == o['id']) &&
                  !recoveredAwg.any((i) => i.id == o['id']),
            )
            .map(
              (o) => AwgInterface(
                serverId: vpnServerId(id),
                spec: Map<String, Object?>.from(o['spec'] as Map),
              ),
            );
        recoveredAwg.addAll(recovered);
      }
    }

    if (serverChanges || recoveredAwg.isNotEmpty || recoveredTt.isNotEmpty) {
      await _write(
        workspace.copy(
          servers: updatedServers,
          awgInterfaces: [...workspace.awgInterfaces, ...recoveredAwg],
          ttEndpoints: [...workspace.ttEndpoints, ...recoveredTt],
        ),
      );
    }

    // 5. Rebuild client profiles once for all refreshed servers
    await _profiles();
    return firstIssue;
  }

  Future<void> _profiles({String? onlyUserId}) async {
    final source = template();
    if (onlyUserId != null && source != _lastTemplate) onlyUserId = null;
    _lastTemplate = source;
    final encoded = workspace.encode();
    final histories = {...workspace.profiles};
    var changed = false;
    final activeUserIds = <String>[];
    for (final user in workspace.users) {
      if (onlyUserId != null && user.id != onlyUserId) continue;
      if (user.deleted) {
        results.remove(user.id);
        changed = histories.remove(user.id) != null || changed;
      } else {
        activeUserIds.add(user.id);
      }
    }
    if (activeUserIds.isNotEmpty) {
      final batchResults = await compute(_compileBatch, (
        encoded,
        source,
        activeUserIds,
        profileServerNames,
      ));
      if (_disposed) return;
      await Future<void>.delayed(Duration.zero);
      for (final user in workspace.users) {
        if (onlyUserId != null && user.id != onlyUserId) continue;
        if (user.deleted) continue;
        final result = batchResults[user.id];
        if (result == null) continue;
        results[user.id] = result;
        if (user.enabled &&
            result.yaml != null &&
            !result.hasBlockingErrors &&
            histories[user.id]?['hash'] != result.sha256Hash) {
          histories[user.id] = {
            'hash': result.sha256Hash,
            'yaml': result.yaml,
            'at': DateTime.now().toUtc().toIso8601String(),
            'publicationWorkspaceId':
                histories[user.id]?['publicationWorkspaceId'] ?? workspace.id,
          };
          changed = true;
        }
      }
    }
    if (changed) {
      await Future<void>.delayed(Duration.zero);
      if (onlyUserId != null &&
          histories[onlyUserId] != null &&
          repository is VpnProfileWriter) {
        revision = await (repository as VpnProfileWriter).upsertVpnProfile(
          onlyUserId,
          histories[onlyUserId]!,
          expectedRevision: revision,
        );
        workspace = workspace.copy(profiles: histories);
        notifyListeners();
      } else {
        await _write(workspace.copy(profiles: histories));
      }
    }
  }

  @override
  void dispose() {
    connections.dispose();
    _coreCancellation?.cancel();
    _identityNoticeTimer?.cancel();
    _disposed = true;
    _timer?.cancel();
    _reconcileRetry?.cancel();
    _token?.cancel();
    super.dispose();
  }
}

final class _TargetPollResult {
  const _TargetPollResult.success(this.target, this.remote, this.observations)
    : error = null,
      rethrowError = null;

  const _TargetPollResult.error(this.target, this.error)
    : remote = null,
      observations = null,
      rethrowError = null;

  const _TargetPollResult.fatal(this.target, this.rethrowError)
    : remote = null,
      observations = null,
      error = null;

  final String target;
  final VpnRemote? remote;
  final List<Map<String, dynamic>>? observations;
  final String? error;
  final Object? rethrowError;
}
