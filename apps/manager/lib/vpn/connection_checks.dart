import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/foundation.dart';
import 'vpn_controller.dart';

typedef ConnectionTarget = ({String target, String resource});

enum InboundReadinessState {
  ready,
  pendingOperation,
  unconfirmedReadback,
  connectivityFailed,
}

class InboundReadinessResult {
  final InboundReadinessState state;
  final String? diagnosticReason;
  const InboundReadinessResult(this.state, [this.diagnosticReason]);
}

class _Entry {
  _Entry(this.signature, this.check);
  final String signature;
  final ConnectionCheck check;
}

/// Device-local intentions run only after the exact resource has been read back.
class ConnectionChecks extends ChangeNotifier {
  ConnectionChecks(this.owner, this.engine, this.store) {
    owner.addListener(_changed);
    unawaited(_restore());
  }
  final VpnController owner;
  final ConnectionProbeEngine? engine;
  final SettingsStore? store;
  final _pending = <ConnectionTarget>{};
  final _external =
      <ConnectionTarget, ({Map<String, Object?> spec, String identity})>{};
  final _results = <ConnectionTarget, _Entry>{};
  final _busyBackoff = <ConnectionTarget, DateTime>{};
  final _activeTargets = <ConnectionTarget>{};
  final _activeTokens = <ConnectionTarget, CancellationToken>{};
  CancellationToken? _token;
  ConnectionTarget? _explicitCurrent;
  ConnectionTarget? get current =>
      _explicitCurrent ?? _activeTargets.firstOrNull;
  set current(ConnectionTarget? value) => _explicitCurrent = value;
  bool _disposed = false, _scheduled = false, foreground = true;
  bool get busy =>
      _activeTargets.isNotEmpty || _token != null || current != null;
  bool isTargetRunning(ConnectionTarget key) =>
      _activeTargets.contains(key) || current == key;
  Future<void> _writes = Future.value();
  static const _key = 'mihomo.pendingConnectionChecks';

  Future<void> _restore() async {
    try {
      final text = await store?.readSetting(_key);
      if (text != null) {
        for (final row in (jsonDecode(text) as List).take(256)) {
          if (row is List &&
              row.length == 2 &&
              row[0] is String &&
              row[1] is String) {
            _pending.add((
              target: row[0] as String,
              resource: row[1] as String,
            ));
          }
        }
      }
    } catch (_) {}
    _changed();
  }

  Future<void> _save() {
    if (store == null) return Future.value();
    final value = jsonEncode([
      for (final key in _pending) [key.target, key.resource],
    ]);
    _writes = _writes
        .then((_) async {
          await store?.writeSetting(_key, value);
        })
        .catchError((Object _) {});
    return _writes;
  }

  Map<String, Object?>? spec(ConnectionTarget key) {
    if (_external[key] case final row?) return row.spec;
    final workspace = owner.workspace;
    if (isAwgTarget(key.target)) {
      return workspace.awgInterfaces
          .where(
            (r) =>
                r.serverId == vpnServerId(key.target) && r.id == key.resource,
          )
          .firstOrNull
          ?.spec;
    }
    if (isTtTarget(key.target)) {
      return workspace.ttEndpoints
          .where(
            (r) =>
                r.serverId == vpnServerId(key.target) && r.id == key.resource,
          )
          .firstOrNull
          ?.spec;
    }
    return workspace.inbounds
        .where((r) => r.serverId == key.target && r.id == key.resource)
        .firstOrNull
        ?.spec;
  }

  Map? _observed(ConnectionTarget key) =>
      (owner.workspace.servers[key.target]?['observed'] as List? ?? [])
          .whereType<Map>()
          .where((r) => r['id'] == key.resource)
          .firstOrNull;
  String? _identity(ConnectionTarget key) =>
      _external[key]?.identity ??
      owner.workspace.servers[key.target]?['identity'] as String?;
  ConnectionTarget registerExternal(
    String target,
    Map<String, Object?> spec,
    String identity,
  ) {
    final key = (target: target, resource: spec['id'] as String);
    if (_external.length >= 256 && !_external.containsKey(key)) {
      _external.remove(_external.keys.first);
    }
    _external[key] = (spec: Map.of(spec), identity: identity);
    return key;
  }

  InboundReadinessResult evaluateReadiness(ConnectionTarget key) {
    if (_external[key] case final row?) {
      if (row.spec['deleted'] == true) {
        return const InboundReadinessResult(
          InboundReadinessState.unconfirmedReadback,
          'vpn_user_deleted',
        );
      }
      if (row.spec['enabled'] != true) {
        return const InboundReadinessResult(
          InboundReadinessState.unconfirmedReadback,
          'vpn_disabled',
        );
      }
      if (owner.remote(key.target)?.identity != row.identity) {
        return const InboundReadinessResult(
          InboundReadinessState.connectivityFailed,
          'target_unavailable',
        );
      }
      return const InboundReadinessResult(InboundReadinessState.ready);
    }

    final wanted = spec(key);
    if (wanted == null || wanted['deleted'] == true) {
      return const InboundReadinessResult(
        InboundReadinessState.unconfirmedReadback,
        'missing_spec',
      );
    }
    if (wanted['enabled'] != true) {
      return const InboundReadinessResult(
        InboundReadinessState.unconfirmedReadback,
        'vpn_disabled',
      );
    }

    owner.cleanStalePending(key.target);
    final record = owner.workspace.servers[key.target];
    if (record?['error'] != null) {
      return InboundReadinessResult(
        InboundReadinessState.connectivityFailed,
        record!['error'].toString(),
      );
    }
    if (record?['pending'] != null) {
      return const InboundReadinessResult(
        InboundReadinessState.pendingOperation,
        'vpn_pending',
      );
    }

    final observed = _observed(key);
    if (observed == null || observed['confirmed'] != true) {
      // The server state was read and this resource is not there: it was
      // never sent or the server was reinstalled. Waiting will not help.
      return InboundReadinessResult(
        InboundReadinessState.unconfirmedReadback,
        observed == null && record?['verifiedAt'] != null
            ? 'vpn_missing'
            : 'vpn_pending_readback',
      );
    }
    if (observed['workspaceId'] !=
            owner.workspace.resourceWorkspaceId(key.target) ||
        canonicalJson(observed['spec']) != canonicalJson(wanted)) {
      return const InboundReadinessResult(
        InboundReadinessState.unconfirmedReadback,
        'vpn_conflict',
      );
    }
    return const InboundReadinessResult(InboundReadinessState.ready);
  }

  bool _ready(ConnectionTarget key) =>
      evaluateReadiness(key).state == InboundReadinessState.ready;

  VpnWorkspace _isolated(ConnectionTarget key) {
    if (_external[key] case final row?) {
      return owner.workspace.copy(
        inbounds: isAwgTarget(key.target) || isTtTarget(key.target)
            ? []
            : [VlessInbound(serverId: key.target, spec: row.spec)],
        awgInterfaces: isAwgTarget(key.target)
            ? [AwgInterface(serverId: vpnServerId(key.target), spec: row.spec)]
            : [],
        ttEndpoints: isTtTarget(key.target)
            ? [
                TrustTunnelEndpoint(
                  serverId: vpnServerId(key.target),
                  spec: row.spec,
                ),
              ]
            : [],
      );
    }
    return owner.workspace.copy(
      inbounds: isAwgTarget(key.target) || isTtTarget(key.target)
          ? []
          : owner.workspace.inbounds
                .where((r) => r.id == key.resource && r.serverId == key.target)
                .toList(),
      awgInterfaces: isAwgTarget(key.target)
          ? owner.workspace.awgInterfaces
                .where(
                  (r) =>
                      r.id == key.resource &&
                      r.serverId == vpnServerId(key.target),
                )
                .toList()
          : [],
      ttEndpoints: isTtTarget(key.target)
          ? owner.workspace.ttEndpoints
                .where(
                  (r) =>
                      r.id == key.resource &&
                      r.serverId == vpnServerId(key.target),
                )
                .toList()
          : [],
    );
  }

  PreparedProxy? _proxy(
    VpnWorkspace workspace,
    String userId,
    ConnectionTarget key,
  ) {
    final nodes = isAwgTarget(key.target)
        ? awgUserAccesses(
            workspace,
            userId,
            serverNames: owner.profileServerNames,
          )
        : isTtTarget(key.target)
        ? ttUserAccesses(
            workspace,
            userId,
            serverNames: owner.profileServerNames,
          )
        : vlessUserAccesses(
            workspace,
            userId,
            serverNames: owner.profileServerNames,
          );
    return nodes.where((node) => node.identity.id == key.resource).firstOrNull;
  }

  PreparedProxy? _existing(ConnectionTarget key) {
    if (_external.containsKey(key)) return null;
    for (final user in owner.workspace.users.where(
      (u) => u.enabled && !u.deleted,
    )) {
      try {
        final proxy = _proxy(_isolated(key), user.id, key);
        if (proxy != null) return proxy;
      } catch (_) {}
    }
    return null;
  }

  String signature(ConnectionTarget key) => _signature(key);

  Map<String, Object?> diagnosticPayload(ConnectionTarget key) => {
    'protocol': isAwgTarget(key.target)
        ? 'awg'
        : isTtTarget(key.target)
        ? 'tt'
        : 'vless',
    'resource': key.resource,
    if (_external.containsKey(key)) 'external': true,
    'workspace': owner.workspace.resourceWorkspaceId(key.target),
    'spec': spec(key),
  };

  PreparedProxy? compileDiagnostic(ConnectionTarget key, Map access) {
    final user = VpnUser.fromJson(
      Map<String, dynamic>.from(access['user'] as Map),
    );
    final isolated = _isolated(key);
    final temporary = isolated.copy(
      users: [user],
      servers: {
        ...isolated.servers,
        key.target: {
          ...?isolated.servers[key.target],
          'observed': [access['observation']],
          'pending': null,
          'error': null,
        },
      },
    );
    return _proxy(temporary, user.id, key);
  }

  String _signature(ConnectionTarget key) => canonicalJson([
    spec(key),
    _identity(key),
    _observed(key)?['revision'],
    _existing(key)?.fields,
  ]);
  ConnectionCheck? result(ConnectionTarget key) {
    final entry = _results[key];
    if (entry == null ||
        !_ready(key) ||
        entry.signature != _signature(key) ||
        DateTime.now().difference(entry.check.at) >
            (entry.check.code == 'busy'
                ? const Duration(seconds: 15)
                : const Duration(minutes: 5))) {
      return null;
    }
    return entry.check;
  }

  final skipped = <ConnectionTarget>{};
  int completed = 0, total = 0;
  bool available(ConnectionTarget key) =>
      evaluateReadiness(key).state == InboundReadinessState.ready;

  String? unavailableReasonCode(ConnectionTarget key) {
    final res = evaluateReadiness(key);
    return res.state == InboundReadinessState.ready ? null : res.diagnosticReason;
  }
  bool _queue = false;
  bool get queueRunning => _queue;
  Future<void> checkAll(Iterable<ConnectionTarget> keys) async {
    if (owner.busy) {
      final idle = Completer<void>();
      void onBusyChanged() {
        if (!owner.busy && !idle.isCompleted) idle.complete();
      }
      owner.addListener(onBusyChanged);
      try {
        await idle.future.timeout(const Duration(seconds: 15));
      } catch (_) {
        if (owner.busy) return;
      } finally {
        owner.removeListener(onBusyChanged);
      }
    }
    if (_queue || busy || _disposed || !foreground) return;
    _queue = true;
    skipped.clear();
    completed = 0;
    final queue = keys.toSet().toList();
    total = queue.length;
    final deadline = Timer(const Duration(minutes: 10), cancel);
    notifyListeners();
    try {
      final items = queue.take(64).toList();
      var cursor = 0;
      const concurrency = 4;
      Future<void> worker() async {
        var skippedBatch = false;
        while (_queue && foreground && !_disposed) {
          if (cursor >= items.length) break;
          final key = items[cursor++];
          if (!_ready(key)) {
            skipped.add(key);
            skippedBatch = true;
          } else {
            if (skippedBatch) {
              notifyListeners();
              skippedBatch = false;
            }
            await check(key, fromQueue: true);
          }
          completed++;
        }
        if (skippedBatch && !_disposed) {
          notifyListeners();
        }
      }
      final workerCount = items.length < concurrency ? items.length : concurrency;
      await Future.wait(List.generate(workerCount, (_) => worker()));
      skipped.addAll(queue.skip(completed));
    } finally {
      deadline.cancel();
      _queue = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> mark(ConnectionTarget key) async {
    _results.remove(key);
    _busyBackoff.remove(key);
    final value = spec(key);
    if (value?['enabled'] == true && value?['deleted'] != true) {
      _pending.add(key);
    } else {
      _pending.remove(key);
    }
    await _save();
  }

  Future<void> forgetServers(Set<String> serverIds) async {
    bool belongs(ConnectionTarget key) =>
        serverIds.contains(vpnServerId(key.target));
    _pending.removeWhere(belongs);
    _external.removeWhere((key, _) => belongs(key));
    _results.removeWhere((key, _) => belongs(key));
    _busyBackoff.removeWhere((key, _) => belongs(key));
    skipped.removeWhere(belongs);
    await _save();
    if (!_disposed) notifyListeners();
  }

  void setForeground(bool value) {
    foreground = value;
    if (!value) {
      cancel(retryOnResume: true);
    } else {
      _changed();
    }
  }

  void cancel({bool retryOnResume = false}) {
    if (!retryOnResume && current != null) {
      _pending.remove(current);
      unawaited(_save());
    }
    _queue = false;
    for (final token in _activeTokens.values) {
      token.cancel();
    }
    _activeTokens.clear();
    _activeTargets.clear();
    current = null;
    _token?.cancel();
    _token = null;
  }

  void _changed() {
    if (_disposed ||
        _scheduled ||
        _queue ||
        busy ||
        !foreground ||
        engine == null ||
        !owner.loaded ||
        owner.coreValidationBusy ||
        owner.busy) {
      return;
    }
    _scheduled = true;
    scheduleMicrotask(() async {
      _scheduled = false;
      if (_disposed ||
          busy ||
          !foreground ||
          owner.busy ||
          owner.coreValidationBusy) {
        return;
      }
      final missing = _pending
          .where((k) => spec(k) == null || spec(k)?['deleted'] == true)
          .toList();
      _pending.removeAll(missing);
      if (missing.isNotEmpty) unawaited(_save());
      final now = DateTime.now();
      final next = _pending.where((k) {
        if (!_ready(k)) return false;
        final last = _busyBackoff[k];
        return last == null ||
            now.difference(last) > const Duration(seconds: 15);
      }).firstOrNull;
      if (next != null) await check(next);
    });
  }

  Future<ConnectionCheck?> check(ConnectionTarget key, {bool fromQueue = false}) async {
    if (_disposed ||
        !foreground ||
        !_ready(key) ||
        _activeTargets.contains(key) ||
        (!fromQueue && (_queue || busy)) ||
        owner.busy ||
        owner.coreValidationBusy) {
      return null;
    }
    final token = CancellationToken();
    _token ??= token;
    _activeTokens[key] = token;
    _activeTargets.add(key);
    current = _activeTargets.firstOrNull;
    final signature = _signature(key);
    notifyListeners();
    ConnectionCheck outcome(ConnectionCheckStatus status, String code) =>
        ConnectionCheck(status: status, code: code, at: DateTime.now().toUtc());
    var result = outcome(
      ConnectionCheckStatus.notTested,
      'runtime_unavailable',
    );
    bool trafficEntered = false;
    String? lease;
    VpnRemote? connection;
    try {
      if (engine == null) return result;
      var proxy = _existing(key);
      if (proxy == null) {
        if (spec(key)?['internal'] == true) {
          result = outcome(
            ConnectionCheckStatus.notTested,
            'unsupported_route',
          );
          return result;
        }
        if (!await owner.ensureConnected(key.target)) {
          result = outcome(
            ConnectionCheckStatus.notTested,
            'server_unavailable',
          );
          return result;
        }
        token.check();
        connection = owner.remote(key.target);
        if (connection == null || connection.identity != _identity(key)) {
          result = outcome(ConnectionCheckStatus.notTested, 'changed');
          return result;
        }
        lease = newVpnId();
        final response = await connection.transport.request(
          RunnerRequest.fromJson({
            'version': 1,
            'action': 'probe_begin',
            'id': lease,
            'payload': jsonEncode(diagnosticPayload(key)),
          }),
          token,
          sudoPassword: connection.password,
        );
        final access = response.connectionProbe;
        if (response.code != 'ok' || access == null) {
          result = outcome(
            ConnectionCheckStatus.notTested,
            'diagnostic_access',
          );
          return result;
        }
        proxy = compileDiagnostic(key, access);
      }
      if (proxy == null) {
        result = outcome(ConnectionCheckStatus.notTested, 'unsupported');
        return result;
      }
      if (owner.enterConnectionTraffic != null) {
        var entered = await owner.enterConnectionTraffic!();
        for (var attempt = 0; !entered && attempt < 4; attempt++) {
          if (token.isCancelled) break;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (token.isCancelled) break;
          entered = await owner.enterConnectionTraffic!();
        }
        if (!entered) {
          result = outcome(ConnectionCheckStatus.notTested, 'busy');
          return result;
        }
        trafficEntered = true;
      }
      result = await engine!.check(proxy.fields, token);
    } catch (_) {
      result = outcome(
        token.isCancelled
            ? ConnectionCheckStatus.cancelled
            : ConnectionCheckStatus.notTested,
        token.isCancelled ? 'cancelled' : 'diagnostic_access',
      );
    } finally {
      if (lease != null && connection != null) {
        try {
          final cleanup = CancellationToken();
          final deadline = Timer(const Duration(seconds: 15), cleanup.cancel);
          try {
            final response = await connection.transport.request(
              RunnerRequest.fromJson({
                'version': 1,
                'action': 'probe_end',
                'id': lease,
              }),
              cleanup,
              sudoPassword: connection.password,
            );
            if (response.connectionProbe?['closed'] != true) {
              result = outcome(
                ConnectionCheckStatus.notTested,
                'cleanup_pending',
              );
            } else if (response.connectionProbe?['stable'] != true) {
              result = outcome(ConnectionCheckStatus.notTested, 'changed');
            }
          } finally {
            deadline.cancel();
          }
        } catch (_) {
          result = outcome(ConnectionCheckStatus.notTested, 'cleanup_pending');
        }
      }
      if (trafficEntered) await owner.leaveConnectionTraffic?.call();
      if (!_disposed && signature == _signature(key)) {
        _results[key] = _Entry(signature, result);
        if (result.code == 'busy') {
          _busyBackoff[key] = DateTime.now();
        } else {
          _busyBackoff.remove(key);
          if (result.status != ConnectionCheckStatus.cancelled) {
            _pending.remove(key);
          }
        }
        await _save();
      }
      _activeTokens.remove(key);
      _activeTargets.remove(key);
      if (_token == token) {
        _token = _activeTokens.values.firstOrNull;
      }
      current = _activeTargets.firstOrNull;
      if (!_disposed) {
        notifyListeners();
        _changed();
      }
    }
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    cancel(retryOnResume: true);
    owner.removeListener(_changed);
    super.dispose();
  }
}
