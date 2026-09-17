import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:flutter/foundation.dart';
import 'vpn_controller.dart';

typedef ConnectionTarget = ({String target, String resource});

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
  CancellationToken? _token;
  ConnectionTarget? current;
  bool _disposed = false, _scheduled = false, foreground = true;
  bool get busy => _token != null;
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

  bool _ready(ConnectionTarget key) {
    if (_external[key] case final row?) {
      return row.spec['enabled'] == true &&
          row.spec['deleted'] != true &&
          owner.remote(key.target)?.identity == row.identity;
    }

    final wanted = spec(key),
        record = owner.workspace.servers[key.target],
        observed = _observed(key);
    return wanted != null &&
        wanted['enabled'] == true &&
        wanted['deleted'] != true &&
        record?['pending'] == null &&
        record?['error'] == null &&
        observed?['confirmed'] == true &&
        observed?['workspaceId'] ==
            owner.workspace.resourceWorkspaceId(key.target) &&
        canonicalJson(observed?['spec']) == canonicalJson(wanted);
  }

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
        ? awgUserAccesses(workspace, userId)
        : isTtTarget(key.target)
        ? ttUserAccesses(workspace, userId)
        : vlessUserAccesses(workspace, userId);
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
            const Duration(minutes: 5)) {
      return null;
    }
    return entry.check;
  }

  final skipped = <ConnectionTarget>{};
  int completed = 0, total = 0;
  bool available(ConnectionTarget key) => _ready(key);
  bool _queue = false;
  bool get queueRunning => _queue;
  Future<void> checkAll(Iterable<ConnectionTarget> keys) async {
    if (_queue || busy || owner.busy) return;
    _queue = true;
    skipped.clear();
    completed = 0;
    final queue = keys.toSet().toList();
    total = queue.length;
    final deadline = Timer(const Duration(minutes: 10), cancel);
    notifyListeners();
    try {
      for (final key in queue.take(64)) {
        if (!_queue || !foreground || _disposed) break;
        if (!_ready(key)) {
          skipped.add(key);
        } else {
          await check(key);
        }
        completed++;
        notifyListeners();
      }
      skipped.addAll(queue.skip(completed));
    } finally {
      deadline.cancel();
      _queue = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> mark(ConnectionTarget key) async {
    _results.remove(key);
    final value = spec(key);
    if (value?['enabled'] == true && value?['deleted'] != true) {
      _pending.add(key);
    } else {
      _pending.remove(key);
    }
    await _save();
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
    _token?.cancel();
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
      final next = _pending.where(_ready).firstOrNull;
      if (next != null) await check(next);
    });
  }

  Future<ConnectionCheck?> check(ConnectionTarget key) async {
    if (_disposed ||
        busy ||
        owner.busy ||
        owner.coreValidationBusy ||
        !foreground ||
        !_ready(key)) {
      return null;
    }
    final token = CancellationToken();
    _token = token;
    current = key;
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
            'payload': jsonEncode({
              'protocol': isAwgTarget(key.target)
                  ? 'awg'
                  : isTtTarget(key.target)
                  ? 'tt'
                  : 'vless',
              'resource': key.resource,
              if (_external.containsKey(key)) 'external': true,
              'workspace': owner.workspace.resourceWorkspaceId(key.target),
              'spec': spec(key),
            }),
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
        proxy = _proxy(temporary, user.id, key);
      }
      if (proxy == null) {
        result = outcome(ConnectionCheckStatus.notTested, 'unsupported');
        return result;
      }
      if (owner.enterConnectionTraffic != null) {
        if (!await owner.enterConnectionTraffic!()) {
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
            if (response.connectionProbe?['closed'] != true ||
                response.connectionProbe?['stable'] != true) {
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
        if (result.status != ConnectionCheckStatus.cancelled) {
          _pending.remove(key);
        }
        await _save();
      }
      _token = null;
      current = null;
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
