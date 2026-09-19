import 'connection_checks.dart';
import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/foundation.dart';

part 'client_deletion.dart';

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

ProfileResult _compile((String, String, String) input) {
  final workspace = VpnWorkspace.decode(input.$1);
  try {
    return const ProfileCompiler().compile(
      template: input.$2,
      userId: input.$3,
      accesses: [
        ...vlessUserAccesses(workspace, input.$3),
        ...awgUserAccesses(workspace, input.$3),
        ...ttUserAccesses(workspace, input.$3),
      ],
    );
  } on FormatException catch (e) {
    return ProfileResult(
      groups: [],
      diagnostics: [ProfileDiagnostic(e.message, DiagnosticSeverity.error)],
    );
  }
}

/// A single workspace coordinator owns client -> all resources reconciliation.
/// Polling resumes only persisted, explicitly approved intentions.
class VpnController extends ChangeNotifier {
  VpnController({
    required this.repository,
    required this.remote,
    required this.template,
    this.serverIds,
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
  final Iterable<String> Function()? serverIds;

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
  set busy(bool value) => _busy = value;
  String? error;
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
      final compiled = await compute(_compile, (snapshot, source, userId));
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
    final updated = await repository.writeVpn(
      next.encode(),
      expectedRevision: revision,
    );
    revision = updated;
    workspace = next;
  }

  Future<void> _record(String id, Map<String, dynamic> record) =>
      _write(workspace.copy(servers: {...workspace.servers, id: record}));
  Future<void> _run(Future<void> Function(CancellationToken) action) async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    final token = CancellationToken();
    _token = token;
    _notify();
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
      _notify();
    }
  }

  Future<void> load() => _run((token) async {
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
            e.value['pending'] != null &&
            e.value['paused'] != true,
      );
  Future<void> saveUser(VpnUser user) => _run((token) async {
    if (!loaded) return;
    if (user.deleted ||
        workspace.users.any((u) => u.id == user.id && u.deleted)) {
      throw const FormatException('vpn_user_deleted');
    }
    final next = workspace.copy(
      users: [...workspace.users.where((u) => u.id != user.id), user],
    );
    await _write(next);
    plans = [];
    await _profiles();
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
      result = (await _request(
        r,
        RunnerRequest.awgDefaults(),
        token,
      )).awgDefaults;
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
      if (record?['pending'] != null) throw const FormatException('vpn_busy');
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
                .where((r) => r.serverId == server)
                .map((r) => r.spec)
          : isTtTarget(target)
          ? workspace.ttEndpoints
                .where((r) => r.serverId == server)
                .map((r) => r.spec)
          : workspace.inbounds
                .where((r) => r.serverId == server)
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
    if (pendingRevocations.isNotEmpty) throw const FormatException('vpn_busy');
    plans = [];
    final next = <VpnPlan>[];
    for (final id in workspace.serverIds) {
      if (serverIds != null && !serverIds.contains(id)) continue;
      await ensureConnected(id);
      token.check();
      final connection = remote(id);
      final previous = workspace.servers[id];
      if (previous?['pending'] != null &&
          (previous?['job'] == null ||
              !RunnerJob.fromJson(
                Map<String, dynamic>.from(previous!['job'] as Map),
              ).terminal ||
              previous['cancelRequested'] == true ||
              previous['observingCancel'] == true)) {
        throw const FormatException('vpn_busy');
      }
      final panelId = (isAwgTarget(id) || isTtTarget(id))
          ? workspace.resourceWorkspaceId(id)
          : connection?.panelId ?? previous?['panelId'] as String?;
      if (panelId == null) throw const FormatException('vpn_panel_required');
      final payload = workspace.desired(id, panelId);
      if (connection == null) {
        next.add(VpnPlan(id, payload, previous?['identity'] as String?, null));
        continue;
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
      next.add(
        VpnPlan(id, payload, connection.identity, _preview(response, id)),
      );
    }
    plans = next;
  });
  void dismissPlans() {
    if (!busy) {
      plans = [];
      _notify();
    }
  }

  Future<void> apply() => _run((token) async {
    if (pendingRevocations.isNotEmpty) throw const FormatException('vpn_busy');
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
  });
  bool diagnosticsPaused = false;
  Future<void> reconcile() async {
    if (!loaded || busy || _disposed || diagnosticsPaused) return;
    final work =
        workspace.servers.keys.any(
          (id) => observesOperation(id) && currentJob(id)?.terminal != true,
        ) ||
        workspace.servers.values.any(
          (r) =>
              r['cancelRequested'] == true ||
              r['observingCancel'] == true ||
              (r['paused'] != true &&
                  (r['pending'] != null ||
                      r['authorizedPayload'] != null &&
                          r['authorizedPayload'] != r['appliedPayload'])),
        );
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
    });
  }

  Future<void> _reconcile(CancellationToken token) async {
    _restoredTargets = await recovery?.readRestoredTargets() ?? {};
    var changed = false;
    for (final id in workspace.serverIds) {
      if (observesOperation(id)) {
        await _observeOperation(id, token);
        continue;
      }
      if (_restoredTargets.contains(id)) {
        if (remote(id) != null) await _reviewRestored(id, token);
        continue;
      }
      final connection = remote(id);
      if (connection == null) continue;
      var record = Map<String, dynamic>.from(workspace.servers[id] ?? {});
      if (record['identity'] != null &&
          record['identity'] != connection.identity) {
        if (record['error'] != 'vpn_identity') {
          await _record(id, {
            ...record,
            'error': 'vpn_identity',
            'paused': true,
          });
        }
        continue;
      }
      try {
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
            continue;
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
            continue;
          }
          record = {
            ...record,
            'cancelRequested': false,
            'observingCancel': true,
          };
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
              final ids = (payload['resources'] as List)
                  .map((r) => (r as Map)['id'])
                  .toSet();
              if (_observations(state, id) == null ||
                  !ids.every(
                    (rid) => _observations(state, id)!.any(
                      (r) =>
                          r['id'] == rid &&
                          r['workspaceId'] ==
                              workspace.resourceWorkspaceId(id) &&
                          r['confirmed'] == true &&
                          r['revision'] == expected,
                    ),
                  )) {
                throw const FormatException('vpn_conflict');
              }
              record = {
                ...record,
                'pending': null,
                'appliedPayload': request.json['payload'],
                'paused': false,
              };
            } else {
              record = {
                ...record,
                'paused': true,
                'error': 'vpn_${job.status}',
              };
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
    }
    if (changed) await _profiles();
  }

  Future<void> refreshServer(String id) => _run((token) async {
    await ensureConnected(id);
    token.check();
    await _refreshServer(id, token);
  });
  Future<void> _refreshServer(String id, CancellationToken token) async {
    final r = remote(id);
    if (r == null) throw const FormatException('vpn_connection');
    final current = workspace.servers[id] ?? {};
    if (current['identity'] != null && current['identity'] != r.identity) {
      throw const FormatException('vpn_identity');
    }
    final result = await _request(r, _stateRequest(id, r.panelId), token);
    await _record(id, {
      ...current,
      'identity': r.identity,
      'panelId': r.panelId,
      'observed': _observations(result, id),
      'verifiedAt': DateTime.now().toUtc().toIso8601String(),
    });
    if (isTtTarget(id)) {
      final recovered = (_observations(result, id) ?? [])
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
      await _profiles();
      return;
    }
    if (isAwgTarget(id)) {
      final recovered = (_observations(result, id) ?? [])
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
      await _profiles();
      return;
    }
    final recovered = (_observations(result, id) ?? [])
        .where(
          (o) =>
              o['workspaceId'] == workspace.resourceWorkspaceId(id) &&
              !workspace.inbounds.any((i) => i.id == o['id']),
        )
        .map(
          (o) => VlessInbound(
            serverId: id,
            spec: Map<String, Object?>.from(o['spec'] as Map),
          ),
        )
        .toList();
    if (recovered.isNotEmpty) {
      await _write(
        workspace.copy(inbounds: [...workspace.inbounds, ...recovered]),
      );
    }
    await _profiles();
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
      observedJobs[id] = response.code == 'missing'
          ? null
          : response.jobs.single;
      observationErrors.remove(id);
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
    if (status.jobs.length != 1 ||
        status.jobs.single.id != request['id'] ||
        !const {
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
  Future<void> _profiles() async {
    final source = template();
    _lastTemplate = source;
    final encoded = workspace.encode();
    final histories = {...workspace.profiles};
    var changed = false;
    for (final user in workspace.users) {
      if (user.deleted) {
        results.remove(user.id);
        changed = histories.remove(user.id) != null || changed;
        continue;
      }
      final result = await compute(_compile, (encoded, source, user.id));
      if (_disposed) return;
      results[user.id] = result;
      if (user.enabled &&
          result.yaml != null &&
          !result.hasBlockingErrors &&
          histories[user.id]?['hash'] != result.sha256Hash) {
        final previous = histories[user.id];
        final history = [
          if (previous != null)
            {
              'hash': previous['hash'],
              'yaml': previous['yaml'],
              'at': previous['at'],
            },
          ...?previous?['history'] as List?,
        ].take(5).toList();
        histories[user.id] = {
          'hash': result.sha256Hash,
          'yaml': result.yaml,
          'at': DateTime.now().toUtc().toIso8601String(),
          'history': history,
        };
        changed = true;
      }
    }
    if (changed) await _write(workspace.copy(profiles: histories));
  }

  @override
  void dispose() {
    connections.dispose();
    _coreCancellation?.cancel();
    _identityNoticeTimer?.cancel();
    _disposed = true;
    _timer?.cancel();
    _token?.cancel();
    super.dispose();
  }
}
