import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/foundation.dart';

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
    Timer Function(Duration, void Function(Timer))? timer,
  }) {
    _timer = (timer ?? Timer.periodic)(
      const Duration(seconds: 5),
      (_) => unawaited(reconcile()),
    );
  }
  final VpnRepository repository;
  final VpnRemote? Function(String) remote;
  final String Function() template;
  final Iterable<String> Function()? serverIds;
  final Map<String, String> _observedConnections = {};
  Timer? _timer;
  CancellationToken? _token;
  bool _disposed = false;
  bool busy = false, loaded = false;
  String? error;
  VpnWorkspace workspace = VpnWorkspace.empty();
  int revision = 0;
  List<VpnPlan> plans = [];
  final results = <String, ProfileResult>{};
  String? selectedUserId;
  String? _lastTemplate;
  void _notify() {
    if (!_disposed) notifyListeners();
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
      busy = false;
      _token = null;
      _notify();
    }
  }

  Future<void> load() => _run((token) async {
    final saved = await repository.readVpn();
    token.check();
    revision = saved.revision;
    workspace = saved.source == null
        ? VpnWorkspace.empty()
        : VpnWorkspace.decode(saved.source!);
    if (saved.source == null) await _write(workspace);
    loaded = true;
    plans = [];
    await _profiles();
  });
  bool get hasRunning => workspace.servers.values.any(
    (r) => r['pending'] != null && r['paused'] != true,
  );
  Future<void> saveUser(VpnUser user) => _run((token) async {
    if (!loaded) return;
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
    plans = [];
    await _profiles();
  });
  Future<Map<String, Object?>?> awgDefaults(String serverId) async {
    Map<String, Object?>? result;
    await _run((token) async {
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
    plans = [];
    await _profiles();
  });
  RunnerRequest _planRequest(
    String target,
    String panel,
    Map<String, Object?> payload,
  ) => isTtTarget(target)
      ? RunnerRequest.ttPlan(workspace.id, payload)
      : isAwgTarget(target)
      ? RunnerRequest.awgPlan(workspace.id, payload)
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
      ? RunnerRequest.ttState(workspace.id)
      : isAwgTarget(target)
      ? RunnerRequest.awgState(workspace.id)
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
    plans = [];
    await _profiles();
  });
  Future<RunnerResponse> _request(
    VpnRemote r,
    RunnerRequest request,
    CancellationToken token, {
    bool allowMissing = false,
  }) async {
    try {
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

  Future<void> prepare() => _run((token) async {
    plans = [];
    final next = <VpnPlan>[];
    for (final id in workspace.serverIds) {
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
          ? workspace.id
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
      records[plan.serverId] = {
        ...previous,
        'panelId': plan.payload['panelId'],
        'identity': plan.identity,
        'authorizedPayload': jsonEncode(plan.payload),
        'paused': false,
        'error': null,
        'pending': plan.preview == null
            ? null
            : _applyRequest(
                plan.serverId,
                newVpnId(),
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
    plans = [];
    await _reconcile(token);
  });
  Future<void> reconcile() async {
    if (!loaded || busy || _disposed) return;
    final work = workspace.servers.values.any(
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
    if (!work && fresh.isEmpty && template() == _lastTemplate) return;
    await _run((token) async {
      for (final id in fresh) {
        final connection = remote(id);
        if (connection == null) continue;
        await _refreshServer(id, token);
        _observedConnections[id] = connection.observationKey!;
      }
      if (work) await _reconcile(token);
      if (template() != _lastTemplate) await _profiles();
    });
  }

  Future<void> _reconcile(CancellationToken token) async {
    var changed = false;
    for (final id in workspace.serverIds) {
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
            newVpnId(),
            payload,
            _preview(preview, id)!['fingerprint'] as String,
          );
          record = {
            ...record,
            'pending': request.json,
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
          final response = await _request(
            connection,
            record['observingCancel'] == true
                ? RunnerRequest.status(request.id!, 0)
                : request,
            token,
          );
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
                          r['workspaceId'] == workspace.id &&
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

  Future<void> refreshServer(String id) =>
      _run((token) => _refreshServer(id, token));
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
                o['workspaceId'] == workspace.id &&
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
                o['workspaceId'] == workspace.id &&
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
              o['workspaceId'] == workspace.id &&
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

  Future<void> cancel(String id) => _run((token) async {
    final record = workspace.servers[id];
    if (record == null) return;
    final req = record['pending'] as Map?;
    if (req == null) {
      await _record(id, {...record, 'paused': true, 'authorizedPayload': null});
      return;
    }
    // Remember cancellation while offline and send it before any further
    // resubmission when the server becomes reachable.
    await _record(id, {...record, 'paused': true, 'cancelRequested': true});
    final r = remote(id);
    if (r == null) return;
    if (record['identity'] != null && record['identity'] != r.identity) {
      throw const FormatException('vpn_identity');
    }
    await _reconcile(token);
  });
  Future<void> resume(String id) => _run((token) async {
    final r = remote(id), record = workspace.servers[id];
    if (r == null || record == null) {
      throw const FormatException('vpn_connection');
    }
    final request = record['pending'] as Map?;
    if (request == null) return;
    if (record['identity'] != null && record['identity'] != r.identity) {
      throw const FormatException('vpn_identity');
    }
    await _request(r, RunnerRequest.resume(request['id'] as String), token);
    await _record(id, {
      ...record,
      'paused': false,
      'cancelRequested': false,
      'error': null,
    });
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
    _disposed = true;
    _timer?.cancel();
    _token?.cancel();
    super.dispose();
  }
}
