import 'connection_checks.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/foundation.dart';

part 'client_deletion.dart';
part 'service_mode_flow.dart';
part 'vpn_attention.dart';

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
          canonicalJson(after.ttEndpoints.map((r) => r.toJson()).toList()) ||
      // Service mode decides which servers' resources a profile carries.
      !mapEquals(before.serviceMode, after.serviceMode)) {
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

/// What the profile compiler reads: the workspace without its profile
/// history. The YAML of every client is never encoded or copied for a build.
VpnWorkspace _compileInput(VpnWorkspace workspace) =>
    workspace.profiles.isEmpty ? workspace : workspace.copy(profiles: const {});

/// Documents above this size are decoded on a short-lived isolate; smaller
/// ones are cheaper to decode in place than to spawn one.
const _isolateDecodeThreshold = 256 * 1024;

Future<VpnWorkspace> _decodeWorkspace(String source) =>
    source.length < _isolateDecodeThreshold
    ? Future.value(VpnWorkspace.decode(source))
    : Isolate.run(() => VpnWorkspace.decode(source));

Map<String, ProfileResult> _compileBatch(
  (VpnWorkspace, String, List<String>, Map<String, String>) input,
) {
  final workspace = input.$1;
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
          skipServiceMode: true,
        ),
        ...awgUserAccesses(
          workspace,
          userId,
          serverNames: serverNames,
          onPending: pending.add,
          skipServiceMode: true,
        ),
        ...ttUserAccesses(
          workspace,
          userId,
          serverNames: serverNames,
          onPending: pending.add,
          skipServiceMode: true,
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
      final hidden = serviceModeProxyNames(
        workspace,
        userId,
        serverNames: serverNames,
      );
      results[userId] = prepared == null
          ? compiler.compile(
              template: template,
              userId: userId,
              accesses: accesses,
              hiddenProxies: hidden,
            )
          : compiler.compilePrepared(
              prepared: prepared,
              userId: userId,
              accesses: accesses,
              hiddenProxies: hidden,
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

/// The server no longer has this resource. VLESS state marks it at the top
/// level (`deleted`/`exists`); AmneziaWG and TrustTunnel keep the confirmed
/// deletion inside `spec`. Reading only the former made every successful AWG
/// or TT deletion look like "Server configuration has changed" and like a
/// deletion that never reached the server.
bool observationGone(Map o) =>
    o['deleted'] == true ||
    o['exists'] == false ||
    o['spec'] is Map && (o['spec'] as Map)['deleted'] == true;

/// Codes that say why a connected server cannot run VPN work yet.
const vpnRemoteIssues = {
  'vpn_runner_busy',
  'vpn_runner_not_ready',
  'vpn_panel_login',
};

/// A single workspace coordinator owns client -> all resources reconciliation.
/// Polling resumes only persisted, explicitly approved intentions.
class VpnController extends ChangeNotifier {
  VpnController({
    required this.repository,
    required this.remote,
    required this.template,
    this.pickTemplate,
    this.templateValidator,
    this.serverIds,
    this.serverName,
    this.connectForDeletion,
    this.connectForAction,
    this.remoteIssue,
    this.recovery,
    ConnectionProbeEngine? connectionProbe,
    SettingsStore? probeStore,
    this.enterConnectionTraffic,
    this.leaveConnectionTraffic,
    Timer Function(Duration, void Function(Timer))? timer,
  }) {
    connections = ConnectionChecks(this, connectionProbe, probeStore)
      ..addListener(_connectionsChanged);
    _timer = (timer ?? Timer.periodic)(const Duration(seconds: 5), (_) {
      if (_foreground) unawaited(reconcile());
    });
  }

  bool _foreground = true;

  /// A hidden or paused app does not poll servers every 5 s; it catches up
  /// as soon as it is in front again. Connection checks follow the same state.
  void setForeground(bool value) {
    connections.setForeground(value);
    if (_foreground == value) return;
    _foreground = value;
    if (value) unawaited(reconcile());
  }

  late final ConnectionChecks connections;
  final Future<bool> Function()? enterConnectionTraffic;
  final Future<void> Function()? leaveConnectionTraffic;
  final VpnRepository repository;
  final WorkspaceRecoveryStore? recovery;
  Set<String> _restoredTargets = {};
  bool needsRestoreReview(String id) => _restoredTargets.contains(id);
  Future<void> _approveRestored(Iterable<String> targets) async {
    final approved = targets.toSet();
    await recovery?.approveRestoredTargets(approved);
    _restoredTargets.removeAll(approved);
  }

  final VpnRemote? Function(String) remote;

  /// Why [remote] is null for a target while its SSH session may be up: one
  /// of [vpnRemoteIssues] or `vpn_connection`; null when [remote] is ready.
  final String? Function(String)? remoteIssue;
  final String Function() template;
  final Future<ImportedTemplate?> Function()? pickTemplate;

  /// Checks an added individual base config with the client core.
  final CoreConfigValidator? templateValidator;
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
  final Map<String, Future<bool>> _inFlightConnections = {};
  Future<bool> ensureConnected(String target) {
    if (remote(target) != null) return Future.value(true);
    final serverId = vpnServerId(target);
    return _inFlightConnections.putIfAbsent(serverId, () async {
      try {
        return await connectForAction?.call(serverId) == true;
      } finally {
        _inFlightConnections.remove(serverId);
      }
    });
  }

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
      (_busy && _backgroundReconcile == null) || _upgradeBusy;

  /// Whether a person's change (save, delete, apply) can start now.
  ///
  /// The same rule gates the UI and [_run]: a background reconcile is awaited
  /// and running connection checks are interrupted, so neither blocks a
  /// change. A change rejected anyway reports `vpn_busy` in [error].
  bool get canMutate => loaded && !_disposed && !foregroundBusy;

  Future<void> waitForBackgroundReconcile() async {
    await _backgroundReconcile?.future;
  }

  /// Waits until no VPN work runs, for at most 30 s.
  Future<void> _waitUntilIdle() async {
    await waitForBackgroundReconcile();
    for (var i = 0; busy && !_disposed && i < 150; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  set busy(bool value) => _busy = value;
  String? error;

  /// Blocks publication of retained profiles after a failed server check.
  String? get serverSyncIssue => _serverSyncIssue;
  set serverSyncIssue(String? issue) => _setServerSyncIssue(issue, null);
  String? _serverSyncIssue;

  /// The physical servers [serverSyncIssue] came from, when that is known.
  /// An issue caused only by servers now in service mode is dropped
  /// ([_dropServiceModeSyncIssue]); one of unknown origin stays.
  Set<String>? _serverSyncIssueServers;

  void _setServerSyncIssue(String? issue, Set<String>? servers) {
    _serverSyncIssue = issue;
    _serverSyncIssueServers = issue == null || servers == null
        ? null
        : servers.map(vpnServerId).toSet();
  }

  void _dropServiceModeSyncIssue() {
    final servers = _serverSyncIssueServers;
    if (servers != null &&
        servers.isNotEmpty &&
        servers.every(workspace.inServiceMode)) {
      _setServerSyncIssue(null, null);
    }
  }

  Timer? _identityNoticeTimer;
  bool _identityNoticeExpired = false;
  String? get visibleError =>
      error == 'vpn_identity' && _identityNoticeExpired ? null : error;
  VpnWorkspace workspace = VpnWorkspace.empty();
  int revision = 0;
  List<VpnPlan> plans = [];
  final results = <String, ProfileResult>{};
  String? selectedUserId;
  String? _lastTemplate;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _connectionsBusy = false;

  /// Check progress (each start, result and counter) is for the check
  /// widgets, which listen to [connections] themselves. Only a change of
  /// [busy], which this controller exposes, is forwarded.
  void _connectionsChanged() {
    final next = connections.busy;
    if (next == _connectionsBusy) return;
    _connectionsBusy = next;
    _notify();
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
    if (_disposed) return;
    if (background && busy) return;
    if (!background && workspaceBusy) {
      // Never drop a change silently: callers check [error] before
      // reporting success, closing a form or playing haptics.
      error = 'vpn_busy';
      _notify();
      return;
    }
    final backgroundDone = background ? Completer<void>() : null;
    _backgroundReconcile = backgroundDone;
    busy = true;
    // A background run must not erase an error the person has not seen yet.
    if (!background) error = null;
    final token = CancellationToken();
    _token = token;
    if (!background) _notify();
    try {
      // Checks only read the workspace; a change interrupts them and the
      // interrupted ones stay queued to run again afterwards. [busy] is
      // already set, so no new check starts meanwhile.
      if (!background && connections.busy) {
        await connections.yieldToChange();
      }
      await action(token);
    } on SyncMergeFailure {
      if (background) {
        serverSyncIssue = 'sync_conflict';
      } else {
        error = 'sync_conflict';
      }
    } on VaultFailure catch (e) {
      final issue = e.issue == VaultIssue.busy
          ? 'vpn_storage_conflict'
          : 'vpn_storage';
      if (background) {
        serverSyncIssue = issue;
      } else {
        error = issue;
      }
    } on FormatException catch (e) {
      if (background) {
        serverSyncIssue = e.message;
      } else {
        error = e.message;
      }
    } on SshFailure {
      if (background) {
        serverSyncIssue = 'vpn_connection';
      } else {
        error = 'vpn_connection';
      }
    } on RunnerFailure {
      if (background) {
        serverSyncIssue = 'vpn_runner';
      } else {
        error = 'vpn_runner';
      }
    } catch (_) {
      if (background) {
        serverSyncIssue = 'vpn_failed';
      } else {
        error = 'vpn_failed';
      }
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
    _deviceId = repository is WorkspaceIdentityStore
        ? (await (repository as WorkspaceIdentityStore).readWorkspaceIdentity())
              .deviceId
        : null;
    observedJobs.clear();
    observationErrors.clear();
    final saved = await repository.readVpn();
    token.check();
    revision = saved.revision;
    workspace = saved.source == null
        ? VpnWorkspace(id: saved.workspaceId ?? newVpnId())
        : await _decodeWorkspace(saved.source!);
    token.check();
    if (saved.source == null) await _write(workspace);
    _resumeServiceModeExits();
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

  bool get hasObservedRunning => _observedRunning(includeServiceMode: true);
  bool get hasRunning => _running(includeServiceMode: true);

  /// Without [includeServiceMode], targets of servers in service mode are
  /// left out: their work never holds up publication or the other servers.
  /// Global gates (sync replacement, diagnostics, server removal) use the
  /// public getters, which keep every target.
  bool _observedRunning({required bool includeServiceMode}) =>
      workspace.servers.keys.any(
        (id) =>
            (includeServiceMode || !workspace.inServiceMode(id)) &&
            observesOperation(id) &&
            currentJob(id)?.terminal == false,
      );

  bool _running({required bool includeServiceMode}) =>
      pendingRevocations.any(
        (u) =>
            ownsDeletion(u) &&
            (u.deletion!['targets'] as Map).entries.any(
              (e) =>
                  e.value['status'] == 'running' &&
                  (includeServiceMode ||
                      !workspace.inServiceMode(e.key as String)),
            ),
      ) ||
      workspace.servers.entries.any(
        (e) =>
            (includeServiceMode || !workspace.inServiceMode(e.key)) &&
            !observesOperation(e.key) &&
            !_restoredTargets.contains(e.key) &&
            _isTargetBusy(e.value),
      );

  /// Physical servers whose way back from service mode is being applied,
  /// with when this device started (or resumed) it: only a readback taken
  /// since then brings a server back. Only the exit flow adds to it: while
  /// a server is listed here, provisioning reaches it again, but profiles
  /// and publication still leave it out until its service mode entry is
  /// removed.
  final _serviceModeExits = <String, DateTime>{};

  /// Why the exit of a physical server did not finish yet, and when its
  /// last step ran; an exit with an issue is retried after a pause.
  final _serviceModeExitIssues = <String, String>{};
  final _serviceModeExitTried = <String, DateTime>{};

  /// Access changes (a client disabled or enabled again) sent to targets in
  /// service mode, per target: what was sent and how often, as [_autoSent].
  final _serviceAccessSent =
      <String, ({String key, int attempts, DateTime at})>{};
  final _serviceAccessIssues = <String, String>{};

  /// Connections to servers in service mode that a client removal started
  /// without waiting for them, and their results, which the next round
  /// records as it records the others.
  final _deletionConnecting = <String>{};
  final _deletionConnected = <String, bool?>{};

  /// The service mode of [serverId] (a catalog id or any target form).
  ServerServiceMode? serviceModeOf(String serverId) =>
      workspace.serviceModeOf(serverId);

  /// Whether nothing may be provisioned on [target]: no `desired()` payload
  /// is planned, sent, resent or resumed there while its server is in
  /// service mode, unless its exit flow is running.
  bool _provisioningHeld(String target) =>
      workspace.inServiceMode(target) &&
      !_serviceModeExits.containsKey(vpnServerId(target));

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
      ...workspace.serviceMode.keys,
    };
    return referenced.difference(available);
  }

  /// Derived from the immutable [workspace] alone, so it is computed once per
  /// workspace instance instead of on every notification.
  bool get hasUnappliedActiveAccess => _unappliedAccessTargets.isNotEmpty;

  /// The targets whose confirmed readback lacks an active client.
  Set<String> get _unappliedAccessTargets =>
      _unappliedAccess[workspace] ??= _computeUnappliedAccessTargets();
  final _unappliedAccess = Expando<Set<String>>('unappliedAccessTargets');

  Set<String> _computeUnappliedAccessTargets() {
    final users = workspace.users
        .where((user) => !user.deleted && user.enabled)
        .map((user) => user.id)
        .toSet();
    final targets = <String>{};
    if (users.isEmpty) return targets;
    void check(String serverId, String target, String resourceId) {
      if (workspace.inServiceMode(serverId)) return;
      final clients =
          (workspace.servers[target]?['observed'] as List? ?? const [])
              .whereType<Map>()
              .where(
                (row) => row['id'] == resourceId && row['confirmed'] == true,
              )
              .expand(
                (row) => (row['clients'] as List? ?? const []).whereType<Map>(),
              )
              .where((client) => client['enabled'] == true)
              .map((client) => client['id'])
              .toSet();
      if (!clients.containsAll(users)) targets.add(target);
    }

    for (final resource in workspace.inbounds.where(
      (resource) => resource.enabled && !resource.deleted && !resource.internal,
    )) {
      check(resource.serverId, resource.serverId, resource.id);
    }
    for (final resource in workspace.awgInterfaces.where(
      (resource) => resource.enabled && !resource.deleted,
    )) {
      check(resource.serverId, awgTarget(resource.serverId), resource.id);
    }
    for (final resource in workspace.ttEndpoints.where(
      (resource) => resource.enabled && !resource.deleted,
    )) {
      check(resource.serverId, ttTarget(resource.serverId), resource.id);
    }
    return targets;
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
  final _ttDefaultsCache = <String, Map<String, Object?>>{};
  final _awgDefaultsCache = <String, Map<String, Object?>>{};

  Future<Map<String, Object?>?> ttDefaults(
    String serverId, {
    bool force = false,
  }) async {
    if (!force && _ttDefaultsCache.containsKey(serverId)) {
      return Map<String, Object?>.from(_ttDefaultsCache[serverId]!);
    }
    Map<String, Object?>? result;
    await _run((token) async {
      await ensureConnected(ttTarget(serverId));
      final r = remote(ttTarget(serverId));
      if (r == null) throw const FormatException('vpn_connection');
      result = (await _request(r, RunnerRequest.ttDefaults(), token)).tt;
    });
    if (result != null) {
      _ttDefaultsCache[serverId] = Map<String, Object?>.from(result!);
    }
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

  Future<Map<String, Object?>?> awgDefaults(
    String serverId, {
    bool force = false,
  }) async {
    if (!force && _awgDefaultsCache.containsKey(serverId)) {
      return Map<String, Object?>.from(_awgDefaultsCache[serverId]!);
    }
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
    if (result != null) {
      _awgDefaultsCache[serverId] = Map<String, Object?>.from(result!);
    }
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
    if (!canMutate || hasRunning) return false;
    var saved = false;
    await _run((token) async {
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
    if (!canMutate || physical.isEmpty) return false;
    var saved = false;
    await _run((token) async {
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
          serviceMode: {
            for (final entry in workspace.serviceMode.entries)
              if (!physical.contains(entry.key)) entry.key: entry.value,
          },
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
                  response.code.startsWith('tt_') ||
                  // The runner refuses to expose or remove a relay inbound.
                  response.code == 'relay_disable_first')
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

  Future<void> prepareAndApply({
    Set<String>? serverIds,
    bool background = false,
  }) async {
    // A person's apply of a server in service mode sends its protocols
    // there at once, without adding clients (see [ServiceModeFlow]).
    final held = serverIds == null || background
        ? const <String>{}
        : serverIds.where(_provisioningHeld).toSet();
    if (held.isNotEmpty) {
      await _applyServiceTargets(held);
      serverIds = serverIds!.difference(held);
      if (serverIds.isEmpty || error != null) return;
    }
    await prepare(serverIds: serverIds, background: background);
    final issue = background ? serverSyncIssue : error;
    if (issue == null && plans.isNotEmpty) {
      await apply(background: background);
    }
  }

  /// A pending marker left by a finished job, or older than five minutes.
  /// Readers treat it as cleared; [reconcile] removes it from storage.
  bool _isStalePending(Map<String, dynamic>? record) {
    if (record == null || record['pending'] == null) return false;
    final jobStatus = (record['job'] as Map?)?['status'] as String?;
    if (jobStatus == 'failed' ||
        jobStatus == 'cancelled' ||
        jobStatus == 'partially_applied' ||
        jobStatus == 'succeeded') {
      return true;
    }
    if (record['pending'] case final Map pMap) {
      if (pMap['startedAt'] case final String started) {
        final start = DateTime.tryParse(started);
        if (start != null &&
            DateTime.now().difference(start) > const Duration(minutes: 5)) {
          return true;
        }
      }
    }
    return false;
  }

  /// The pending operation of [target] as the UI should see it. Pure: safe to
  /// call from `build`.
  Object? pendingOf(String target) {
    final record = workspace.servers[target];
    return _isStalePending(record) ? null : record?['pending'];
  }

  /// A stale marker that may be removed from storage. A request whose job
  /// failed or was partially applied stays: [resume] and automatic
  /// recovery still need it.
  bool _isRemovablePending(Map<String, dynamic>? record) {
    if (!_isStalePending(record)) return false;
    final status = (record!['job'] as Map?)?['status'];
    return status != 'failed' && status != 'partially_applied';
  }

  List<String> _stalePendingTargets() => [
    for (final entry in workspace.servers.entries)
      if (_isRemovablePending(entry.value)) entry.key,
  ];

  Future<void> _clearStalePending(List<String> targets) async {
    for (final target in targets) {
      final record = workspace.servers[target];
      if (!_isRemovablePending(record)) continue;
      await _record(target, {...record!, 'pending': null});
    }
  }

  final _boundRunners = <String, (Listenable, VoidCallback)>{};

  void bindRunner(
    String serverId,
    Listenable runnerEvents,
    bool Function() isIdleOrReset,
  ) {
    if (_boundRunners[serverId] case final existing?) {
      if (identical(existing.$1, runnerEvents)) return;
      existing.$1.removeListener(existing.$2);
      _boundRunners.remove(serverId);
    }
    void listener() {
      if (isIdleOrReset()) {
        onRunnerQueueReset(serverId);
      }
      // Changes approved while the runner was busy or the panel was not yet
      // verified are kept as an authorized payload. Nothing else retries
      // them once the connection becomes usable, so do it here. A finished
      // job may stay selected in the runner; that must not block VPN work.
      if (!_busy && _hasServerReconcileWork) unawaited(reconcile());
    }

    _boundRunners[serverId] = (runnerEvents, listener);
    runnerEvents.addListener(listener);
  }

  void onRunnerQueueReset(String serverId) {
    final targets = [serverId, awgTarget(serverId), ttTarget(serverId)];
    final updatedServers = Map<String, Map<String, dynamic>>.from(
      workspace.servers,
    );
    bool changed = false;
    for (final target in targets) {
      final rec = updatedServers[target];
      if (rec != null && rec['pending'] != null) {
        updatedServers[target] = {...rec, 'pending': null};
        changed = true;
        unawaited(_record(target, {...rec, 'pending': null}));
      }
    }
    if (changed) {
      workspace = workspace.copy(servers: updatedServers);
      notifyListeners();
    }
  }

  bool adoptionConfirmed(String target, String id) {
    return pendingOf(target) == null &&
        (workspace.servers[target]?['observed'] as List? ?? []).any(
          (row) => row['id'] == id && row['confirmed'] == true,
        );
  }

  Future<void> adoptResource({
    required String target,
    required String expectedIdentity,
    required Map<String, Object?> spec,
  }) async {
    var prepared = false;
    await _run((token) async {
      if (!loaded || hasRunning || _globalRevocations.isNotEmpty) {
        throw const FormatException('vpn_busy');
      }
      if (_provisioningHeld(target)) {
        throw const FormatException('vpn_service_mode');
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

  Future<void> prepare({Set<String>? serverIds, bool background = false}) =>
      _run(
        (token) =>
            _prepare(token, serverIds: serverIds, background: background),
        background: background,
      );

  Future<void> _prepare(
    CancellationToken token, {
    Set<String>? serverIds,
    bool background = false,
  }) async {
    plans = [];
    await _adoptIdentities();
    final availableTargets = serverIds ?? workspace.serverIds;
    final selected = availableTargets.where((id) {
      if (serverIds != null && !serverIds.contains(id)) return false;
      // Nothing is provisioned on a server in service mode: a bulk or
      // background plan leaves it out (also while it returns: its exit
      // flow plans it alone), a person's explicit one is refused.
      if ((serverIds == null || background) && workspace.inServiceMode(id)) {
        return false;
      }
      final server = vpnServerId(id);
      return this.serverIds == null ||
          this.serverIds!().map(vpnServerId).contains(server);
    }).toList();
    if (selected.any(_provisioningHeld)) {
      throw const FormatException('vpn_service_mode');
    }
    // A hidden revocation is retained honestly, but it must not become an
    // invisible permanent blocker. Once this explicit access change reconnects
    // the server, finish the old revocation before planning the current state.
    // One left only on servers in service mode finishes on its own.
    if (_globalRevocations.isNotEmpty) {
      final selectedServers = selected.map(vpnServerId).toSet().toList();
      await _mapServersBounded(
        selectedServers,
        (id) => ensureConnected(id),
        cancellation: token,
      );
      await _reconcileDeletions(token);
    }
    await _mapServersBounded(
      selected.map(vpnServerId).toSet().toList(),
      (id) => ensureConnected(id),
      cancellation: token,
    );
    final plansList = await _mapServersBounded(selected, (id) async {
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
  }

  void dismissPlans() {
    if (!busy) {
      plans = [];
      _notify();
    }
  }

  Future<void> apply({bool background = false}) =>
      _run(_apply, background: background);

  Future<void> _apply(CancellationToken token) async {
    if (plans.any(
      (p) =>
          p.preview != null && hasBlockingRevocation(vpnServerId(p.serverId)),
    )) {
      throw const FormatException('vpn_busy');
    }
    if (plans.isEmpty) return;
    if (plans.any((p) => _provisioningHeld(p.serverId))) {
      throw const FormatException('vpn_service_mode');
    }
    final records = {...workspace.servers};
    for (final plan in plans) {
      if (canonicalJson(plan.payload) !=
          canonicalJson(
            workspace.desired(plan.serverId, plan.payload['panelId'] as String),
          )) {
        throw const FormatException('vpn_conflict');
      }
      // A desired payload is not an access change from a readback.
      final previous = {...?records[plan.serverId]}..remove('serviceAccess');
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
  }

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
      // In the background the follow-up waits for [setForeground] too.
      if (_foreground) unawaited(reconcile());
    });
  }

  Future<void> reconcile() async {
    if (!loaded || busy || _disposed || diagnosticsPaused) return;
    final stale = _stalePendingTargets();
    if (stale.isNotEmpty) {
      await _run((_) => _clearStalePending(stale), background: true);
      if (busy || _disposed) return;
    }
    if (_staleIdentities().isNotEmpty) {
      await _run((_) => _adoptIdentities(), background: true);
      if (busy || _disposed) return;
    }
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
      await _sendMissing();
      await _serviceModeWork();
      return;
    }
    await _run((token) async {
      await _reconcileDeletions(token);
      var anyServerRefreshed = false;
      for (final id in fresh) {
        final connection = remote(id);
        if (connection == null) continue;
        if (!observesOperation(id)) {
          await _refreshServer(id, token, rebuildProfiles: false);
          anyServerRefreshed = true;
        }
        _observedConnections[id] = connection.observationKey!;
      }
      if (anyServerRefreshed) {
        await _profiles();
      }
      if (work || _restoredTargets.any((id) => remote(id) != null)) {
        await _reconcile(token);
      }
      if (template() != _lastTemplate) await _profiles();
    }, background: true);
    _scheduleReconcile();
    await _sendMissing();
    await _serviceModeWork();
  }

  bool _needsReconcile(String id, Map<String, dynamic> record) {
    if (remote(id) == null || _restoredTargets.contains(id)) return false;
    if (_canAutoResume(id, record) ||
        record['cancelRequested'] == true ||
        record['observingCancel'] == true ||
        (record['paused'] != true && record['pending'] != null)) {
      return true;
    }
    // An unfinished job snapshot whose request is gone is read again by ID.
    final job = record['job'];
    if (record['pending'] == null &&
        job is Map &&
        !runnerStatusTerminal(job['status'])) {
      return true;
    }
    final authorized = record['authorizedPayload'];
    if (record['paused'] == true ||
        authorized == null ||
        authorized == record['appliedPayload'] ||
        _provisioningHeld(id)) {
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
        _provisioningHeld(id) ||
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
      // A job snapshot left without its request (a client removal drains the
      // request first) is never polled by the pending path below: read the
      // job by ID until it is terminal, or drop it once the runner forgot it.
      if (record['pending'] == null && record['job'] is Map) {
        final stale = RunnerJob.fromJson(
          Map<String, dynamic>.from(record['job'] as Map),
        );
        if (!stale.terminal) {
          final status = await _request(
            connection,
            RunnerRequest.status(stale.id, 0),
            token,
            allowMissing: true,
          );
          if (status.code == 'missing' ||
              status.jobs.length == 1 && status.jobs.single.id == stale.id) {
            final fresh = status.code == 'missing'
                ? null
                : status.jobs.single.mergeEvents(stale);
            record = {...record, 'job': fresh?.toJson()};
            await _record(id, record);
            changed = true;
          }
        }
      }
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
          record['appliedPayload'] != authorized &&
          !_provisioningHeld(id)) {
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
        if (response.code == 'missing' &&
            record['observingCancel'] != true &&
            _provisioningHeld(id)) {
          // Never submitted, and its server is in service mode now: the
          // request waits, paused, for the exit flow to plan afresh. An
          // access change built from a readback is dropped instead: the
          // next round reads the server again and builds it anew.
          await _record(id, {
            ...record,
            'paused': true,
            if (record['serviceAccess'] == true) ...{
              'pending': null,
              'authorizedPayload': null,
            },
          });
          return true;
        }
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
                          observationGone(obs));
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

  /// [serverId] is now the machine with [identity]: reinstalled, replaced or
  /// moved. The SSH layer only connects to a host key the person trusted, so
  /// a new identity always carries their consent. What the app knew about the
  /// old machine's state no longer holds: jobs, applied payloads and
  /// observations are dropped and read again. The app's own resources stay;
  /// those the new machine lacks are sent again (see [missingOnServer]).
  /// Unfinished client revocations restart against the new machine.
  Future<void> rebindServer(String serverId, String identity) async {
    await _waitUntilIdle();
    await _run((token) async {
      if (loaded) await _rebindRecords(serverId, identity);
    });
    _scheduleReconcile();
  }

  Future<bool> _rebindRecords(String serverId, String identity) async {
    final targets = {serverId, awgTarget(serverId), ttTarget(serverId)};
    final servers = {...workspace.servers};
    var changed = false;
    for (final id in targets) {
      final saved = servers[id]?['identity'];
      if (saved == null || saved == identity) continue;
      servers[id] = {'identity': identity};
      observedJobs.remove(id);
      observationErrors.remove(id);
      _observedConnections.remove(id);
      _autoSent.remove(id);
      changed = true;
    }
    bool stale(MapEntry e) =>
        targets.contains(e.key) &&
        !vpnRevocationSettled(e.value) &&
        (e.value as Map)['identity'] != null &&
        (e.value as Map)['identity'] != identity;
    final users = [
      for (final user in workspace.users)
        if (user.deletion case final Map deletion
            when (deletion['targets'] as Map).entries.any(stale))
          user.copyWith(
            deletion: {
              ...Map<String, dynamic>.from(deletion),
              'targets': {
                for (final e in (deletion['targets'] as Map).entries)
                  e.key: stale(e)
                      ? {'status': 'waiting', 'identity': identity}
                      : e.value,
              },
            },
          )
        else
          user,
    ];
    final usersChanged = !users.indexed.every(
      (e) => identical(e.$2, workspace.users[e.$1]),
    );
    if (!changed && !usersChanged) return false;
    if (error == 'vpn_identity') error = null;
    if (serverSyncIssue == 'vpn_identity') serverSyncIssue = null;
    await _write(workspace.copy(servers: servers, users: users));
    return true;
  }

  /// Connected servers whose saved state (or an unfinished revocation)
  /// belongs to another machine's identity, with their current identity.
  Map<String, String> _staleIdentities() {
    final ids = {
      ...workspace.servers.keys,
      for (final user in workspace.users)
        if (user.deletion case final Map deletion)
          ...(deletion['targets'] as Map).keys.cast<String>(),
    };
    final stale = <String, String>{};
    for (final id in ids) {
      final r = remote(id);
      if (r == null) continue;
      final saved = workspace.servers[id]?['identity'];
      final revocation = workspace.users.any((u) {
        final t = (u.deletion?['targets'] as Map?)?[id];
        return t is Map &&
            t['identity'] != null &&
            t['identity'] != r.identity &&
            !vpnRevocationSettled(t);
      });
      if ((saved != null && saved != r.identity) || revocation) {
        stale[vpnServerId(id)] = r.identity;
      }
    }
    return stale;
  }

  /// Rebinds every connected server whose saved identity is another
  /// machine's (see [rebindServer]) before anything compares identities.
  Future<void> _adoptIdentities() async {
    for (final e in _staleIdentities().entries) {
      await _rebindRecords(e.key, e.value);
    }
  }

  /// Automatic sends per target: what was sent (desired payload and server
  /// state) and how often. A transient refusal (a component still installing,
  /// a panel not verified yet) is retried a few times with a pause; a lasting
  /// one stays visible with its reason and a manual retry instead of looping.
  final _autoSent = <String, ({String key, int attempts, DateTime at})>{};
  final _sendIssues = <String, String>{};

  /// Why the last automatic send for [target] did not land, if it did not.
  String? sendIssue(String target) => _sendIssues[target];

  /// Sends what the person already saved but the server does not reflect
  /// (resources it lacks, deletions it never received): a never-sent
  /// resource, a lost deletion or a reinstalled server heals without the
  /// person having to find a button.
  Future<void> _sendMissing() async {
    if (_disposed || !loaded || busy || _running(includeServiceMode: false)) {
      return;
    }
    final now = DateTime.now();
    for (final id in workspace.servers.keys.toList()) {
      // A server in service mode, even on its way back, gets only its own
      // flows and never feeds the shared background issue.
      if (workspace.inServiceMode(id) ||
          missingOnServer(id) == 0 && unappliedDeletions(id) == 0) {
        _sendIssues.remove(id);
        continue;
      }
      final r = remote(id);
      if (r == null) continue;
      final panel = (isAwgTarget(id) || isTtTarget(id))
          ? workspace.resourceWorkspaceId(id)
          : r.panelId;
      final key =
          '${canonicalJson(workspace.desired(id, panel))}|${r.observationKey}';
      final last = _autoSent[id];
      if (last != null &&
          last.key == key &&
          (last.attempts >= 3 ||
              now.difference(last.at) < const Duration(seconds: 45))) {
        continue;
      }
      _autoSent[id] = (
        key: key,
        attempts: last?.key == key ? last!.attempts + 1 : 1,
        at: now,
      );
      // The background issue is shared by every server; an old refusal for
      // another target must neither block this send nor be blamed on it.
      final previous = serverSyncIssue,
          previousServers = _serverSyncIssueServers;
      serverSyncIssue = null;
      await prepareAndApply(serverIds: {id}, background: true);
      final issue = serverSyncIssue;
      if (issue != null) {
        _setServerSyncIssue(issue, {id});
      } else {
        _setServerSyncIssue(previous, previousServers);
      }
      if (issue != null) {
        _sendIssues[id] = issue;
      } else {
        _sendIssues.remove(id);
      }
      _notify();
      return;
    }
  }

  /// How many of the app's resources for [target] the server does not have,
  /// once its state was read and nothing is being applied: never sent, lost
  /// with a reinstalled server or removed outside the app.
  int missingOnServer(String target) {
    // A server in service mode is not offered resources until it returns.
    if (workspace.inServiceMode(target)) return 0;
    final observed = _settledObservations(target);
    if (observed == null) return 0;
    return _resourceIds(target, deleted: false)
        .where(
          (id) => !observed.any((o) => o['id'] == id && o['confirmed'] == true),
        )
        .length;
  }

  /// Resources deleted in the app that the server still has, once its state
  /// was read and nothing is being applied: the deletion never reached it.
  int unappliedDeletions(String target) {
    final observed = _settledObservations(target);
    if (observed == null) return 0;
    return _resourceIds(target, deleted: true)
        .where(
          (id) => observed.any((o) => o['id'] == id && !observationGone(o)),
        )
        .length;
  }

  /// The server state read for [target], or null while it is unknown or an
  /// operation is in flight.
  Iterable<Map>? _settledObservations(String target) {
    final record = workspace.servers[target];
    if (record == null ||
        record['verifiedAt'] == null ||
        record['pending'] != null ||
        record['error'] == 'vpn_identity') {
      return null;
    }
    if (record['job'] case final Map job
        when !RunnerJob.fromJson(Map<String, dynamic>.from(job)).terminal) {
      return null;
    }
    return (record['observed'] as List? ?? const []).whereType<Map>();
  }

  Iterable<String> _resourceIds(String target, {required bool deleted}) {
    final server = vpnServerId(target);
    return isAwgTarget(target)
        ? workspace.awgInterfaces
              .where((r) => r.serverId == server && r.deleted == deleted)
              .map((r) => r.id)
        : isTtTarget(target)
        ? workspace.ttEndpoints
              .where((r) => r.serverId == server && r.deleted == deleted)
              .map((r) => r.id)
        : workspace.inbounds
              .where((r) => r.serverId == target && r.deleted == deleted)
              .map((r) => r.id);
  }

  Iterable<MapEntry<String, Map<String, dynamic>>> _physicalRecords(
    String serverId,
  ) => workspace.servers.entries.where(
    (entry) => vpnServerId(entry.key) == serverId,
  );

  /// Whether every saved target of [serverId] was read from the server at or
  /// after [since]. A server without targets has nothing to read.
  bool serverObservedSince(String serverId, DateTime since) =>
      _physicalRecords(serverId).every((entry) {
        final at = DateTime.tryParse(
          entry.value['verifiedAt'] as String? ?? '',
        );
        return at != null && !at.isBefore(since);
      });

  /// The oldest saved read of [serverId]: the date its cached state shows.
  /// Null when some target of it was never read on this device.
  DateTime? serverObservedAt(String serverId) {
    DateTime? oldest;
    for (final entry in _physicalRecords(serverId)) {
      final at = DateTime.tryParse(entry.value['verifiedAt'] as String? ?? '');
      if (at == null) return null;
      if (oldest == null || at.isBefore(oldest)) oldest = at;
    }
    return oldest;
  }

  /// Reads the state of connected [serverIds] again with the read-only state
  /// request and rebuilds profiles, in the background like reconciliation:
  /// the interface is not marked busy and nothing is submitted.
  /// Waits out other VPN work first: a background run started while one is
  /// in progress is dropped, and several servers are read in parallel after
  /// a cloud pull, so all but the first would be reported as not answering.
  Future<void> refreshConnectedInBackground(Iterable<String> serverIds) async {
    final ids = serverIds.toSet();
    await _waitUntilIdle();
    return _run((token) async {
      final targets = [
        for (final entry in workspace.servers.entries)
          if (ids.contains(vpnServerId(entry.key)) &&
              remote(entry.key) != null &&
              !observesOperation(entry.key))
            entry.key,
      ]..sort();
      // A target that did not answer keeps its dated cache; the caller
      // learns it from serverObservedSince, not from a global issue.
      if (targets.isNotEmpty) await _refreshTargets(targets, token);
    }, background: true);
  }

  Future<void> refreshServer(String id) => _run((token) async {
    if (error == 'vless_conflict' ||
        error == 'vpn_conflict' ||
        error == 'vpn_adoption_conflict') {
      error = null;
    }
    await ensureConnected(id);
    token.check();
    await _adoptIdentities();
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
              !observationGone(o),
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
      if (obs.isNotEmpty && observationGone(obs)) {
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
      final job = response.code == 'missing' ? null : response.jobs.single;
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
    // A revocation on the same physical server always goes first, also one
    // on a server returning from service mode.
    if (_globalRevocations.isNotEmpty ||
        hasPendingRevocation(vpnServerId(id))) {
      throw const FormatException('vpn_busy');
    }
    if (_provisioningHeld(id)) throw const FormatException('vpn_service_mode');
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

  /// Clients with access on [serverId]: every enabled client gets each
  /// client-facing protocol, so a server without one serves nobody (UI-75).
  int clientCountOn(String serverId) {
    final w = workspace;
    // A server in service mode serves nobody through client profiles.
    if (w.inServiceMode(serverId)) return 0;
    final serves =
        w.inbounds.any(
          (r) =>
              r.serverId == serverId && r.enabled && !r.deleted && !r.internal,
        ) ||
        w.awgInterfaces.any(
          (r) => r.serverId == serverId && r.enabled && !r.deleted,
        ) ||
        w.ttEndpoints.any(
          (r) => r.serverId == serverId && r.enabled && !r.deleted,
        );
    return serves ? w.users.where((u) => !u.deleted && u.enabled).length : 0;
  }

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
    }.where((target) => !workspace.inServiceMode(target)).toList()..sort();
    error = (await _refreshTargets(targets, token)).issue;
  });

  /// A saved verification may be reused only while every desired target and
  /// compiled profile still matches its last confirmed server readback.
  bool get hasCurrentVerifiedProfiles {
    if (!loaded ||
        busy ||
        serverSyncIssue != null ||
        _lastTemplate != template() ||
        _restoredTargets.isNotEmpty ||
        _globalRevocations.isNotEmpty ||
        _running(includeServiceMode: false) ||
        _observedRunning(includeServiceMode: false) ||
        hasUnappliedActiveAccess) {
      return false;
    }
    // A target removed from the desired catalog may still have an applied
    // resource to retire. Do not treat its absence from serverIds as success.
    // Servers in service mode are not in profiles and are not verified here.
    if (workspace.servers.keys.any(
      (target) =>
          !workspace.inServiceMode(target) &&
          !workspace.serverIds.contains(target) &&
          (workspace.servers[target]?['appliedPayload'] != null ||
              workspace.servers[target]?['authorizedPayload'] != null),
    )) {
      return false;
    }
    for (final target in workspace.serverIds) {
      if (workspace.inServiceMode(target)) continue;
      if (!_targetVerified(target)) return false;
    }
    for (final user in workspace.users.where((u) => u.enabled && !u.deleted)) {
      final result = results[user.id];
      if (result == null ||
          result.hasBlockingErrors ||
          result.yaml == null ||
          result.sha256Hash == null ||
          workspace.profiles[user.id]?['hash'] != result.sha256Hash) {
        return false;
      }
    }
    return true;
  }

  /// Whether [target] settled on the desired state: nothing in flight, the
  /// applied payload is the approved one and its confirmed readback equals
  /// the desired payload.
  bool _targetVerified(String target) {
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
    return _readbackMatchesDesired(target, panelId, applied, record);
  }

  /// Whether [target]'s applied payload and confirmed readback equal the
  /// desired state. Every input lives in the immutable [workspace], so the
  /// two canonical encodings per target run once per workspace instance.
  bool _readbackMatchesDesired(
    String target,
    String panelId,
    String applied,
    Map<String, dynamic> record,
  ) {
    final cache = _readbackMatches[workspace] ??= <String, bool>{};
    return cache[target] ??= () {
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
                !observationGone(row),
          )) {
            return false;
          }
        }
        return true;
      } catch (_) {
        return false;
      }
    }();
  }

  final _readbackMatches = Expando<Map<String, bool>>('readbackMatches');

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

    if (!loaded || workspaceBusy) {
      return ServerProfileSyncResult(revision: revision, issue: 'vpn_busy');
    }
    // A template edit changes local YAML, not the confirmed server payload.
    if (allowVerifiedSnapshot && _lastTemplate != template()) {
      await refreshProfiles();
      if (error != null) return failed(error!);
    }
    if (allowVerifiedSnapshot && hasCurrentVerifiedProfiles) {
      try {
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
    // Read every target first and apply only to those whose confirmed
    // readback differs from the desired state: an apply of an unchanged
    // server still restarts its core and drops live sessions.
    Set<String> refreshFailed = const {};
    await _run((token) async {
      final refreshed = await _refreshTargets(_syncReadTargets(), token);
      error = refreshed.issue;
      refreshFailed = refreshed.failed;
    });
    final readIssue = error;
    String? applyIssue;
    final unsettled = _unsettledTargets(refreshFailed);
    final applied =
        unsettled ??
        workspace.serverIds.where((t) => !workspace.inServiceMode(t)).toSet();
    if (applied.isNotEmpty) {
      try {
        await prepareAndApply(serverIds: unsettled);
        applyIssue = error ?? await _awaitApplied(applied);
      } catch (_) {
        applyIssue = 'vpn_failed';
      }
    }
    final issue = applyIssue ?? readIssue;
    error = issue;
    // Only a failed read names its servers; a plan or apply issue does not.
    _setServerSyncIssue(issue, applyIssue == null ? refreshFailed : null);
    _notify();
    return ServerProfileSyncResult(revision: revision, issue: issue);
  }

  /// Every target a full server check reads. A server in service mode is
  /// neither read nor blamed here.
  List<String> _syncReadTargets() => <String>{
    for (final resource in workspace.inbounds)
      if (resource.enabled && !resource.deleted && !resource.internal)
        resource.serverId,
    for (final resource in workspace.awgInterfaces)
      if (resource.enabled && !resource.deleted) awgTarget(resource.serverId),
    for (final resource in workspace.ttEndpoints)
      if (resource.enabled && !resource.deleted) ttTarget(resource.serverId),
    for (final serverId in workspace.serverIds) ...[
      serverId,
      if (workspace.awgInterfaces.any((i) => i.serverId == serverId))
        awgTarget(serverId),
      if (workspace.ttEndpoints.any((i) => i.serverId == serverId))
        ttTarget(serverId),
    ],
  }.where((target) => !workspace.inServiceMode(target)).toList()..sort();

  /// The targets a full server check must apply after a fresh read: those
  /// not settled on the desired state or missing an active client. A target
  /// whose read just failed is left out: it cannot be planned now and its
  /// failure is reported. Null means every target, as before this check:
  /// pending revocations and restored targets are planned all together.
  Set<String>? _unsettledTargets(Set<String> unreadable) {
    if (_globalRevocations.isNotEmpty) return null;
    final missingAccess = _unappliedAccessTargets;
    return {
      for (final target in workspace.serverIds)
        if (!workspace.inServiceMode(target) &&
            !unreadable.contains(target) &&
            (_restoredTargets.contains(target) ||
                missingAccess.contains(target) ||
                !_targetVerified(target)))
          target,
    };
  }

  /// How long a full server check waits for its submitted jobs.
  static const _appliedWait = Duration(seconds: 90);

  /// Follows the jobs submitted for [targets] until they finish, so the
  /// check reports the confirmed readback the finished job read instead of
  /// a read taken while the job (or its core restart) is still running.
  /// Null when no job failed.
  Future<String?> _awaitApplied(Set<String> targets) async {
    bool running() => targets.any(
      (target) =>
          remote(target) != null && _isTargetBusy(workspace.servers[target]),
    );
    final deadline = DateTime.now().add(_appliedWait);
    while (running() && !_disposed) {
      if (DateTime.now().isAfter(deadline)) return 'vpn_busy';
      await Future<void>.delayed(const Duration(seconds: 1));
      await _run(_reconcile);
      if (error != null) return error;
    }
    // A job that failed or paused names its issue; an unreachable target
    // is reported by its failed read.
    for (final target in targets) {
      final record = workspace.servers[target];
      if (remote(target) == null || record == null) continue;
      if (record['error'] case final String issue) return issue;
      if (record['paused'] == true) return 'vpn_failed';
    }
    return null;
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

  /// Reads [targets] and rebuilds profiles. The first issue is returned
  /// with every target that failed.
  Future<({String? issue, Set<String> failed})> _refreshTargets(
    List<String> targets,
    CancellationToken token,
  ) async {
    const none = (issue: null, failed: <String>{});
    if (targets.isEmpty) {
      await _profiles();
      return none;
    }

    // 1. Pre-connect all distinct physical servers concurrently
    final physicalServers = targets.map(vpnServerId).toSet().toList()..sort();
    await _mapServersBounded(physicalServers, (serverId) async {
      try {
        await ensureConnected(serverId);
      } catch (_) {}
    }, cancellation: token);
    if (_disposed) return none;
    token.check();

    // 2. Poll all targets concurrently
    final results = await Future.wait(
      targets.map((target) => _pollTarget(target, token)),
    );
    if (_disposed) return none;

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
    final failed = <String>{};
    var serverChanges = false;

    for (final res in results) {
      if (res.error != null) {
        firstIssue ??= res.error;
        failed.add(res.target);
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
    return (issue: firstIssue, failed: failed);
  }

  Future<void> _profiles({String? onlyUserId}) async {
    final source = template();
    if (onlyUserId != null && source != _lastTemplate) onlyUserId = null;
    _lastTemplate = source;
    final input = _compileInput(workspace);
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
        input,
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
    for (final entry in _boundRunners.values) {
      entry.$1.removeListener(entry.$2);
    }
    _boundRunners.clear();
    connections.dispose();
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
