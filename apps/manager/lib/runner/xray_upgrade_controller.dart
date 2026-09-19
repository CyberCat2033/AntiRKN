import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';
import '../vpn/adopt_resource.dart';
import '../vpn/connection_checks.dart';
import '../vpn/external_connection_check.dart';
import '../vpn/vpn_controller.dart';
import 'runner_controller.dart';

class XrayComparison {
  XrayComparison(this.id, this.name, this.enabled);
  final int id;
  final String name;
  final bool enabled;
  ConnectionCheck? before, after, restored;
}

/// Only this explicit device action can submit or commit an upgrade. Reopening
/// the view merely observes the server's durable transaction and watchdog.
class XrayUpgradeController extends ChangeNotifier {
  XrayUpgradeController({
    required this.runner,
    required this.vpn,
    required this.host,
  });
  final RunnerController runner;
  final VpnController vpn;
  final String host;
  Map<String, dynamic>? plan, operation;
  final rows = <XrayComparison>[];
  bool busy = false, running = false, _disposed = false;
  String phase = 'idle', code = '';
  CancellationToken? _token;
  static const terminal = {'committed', 'rolled_back', 'not_changed'};
  static const revision = 'ac017cdd246ce8bd547653d927e7bf77d7ee73d5';
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void cancel() => _token?.cancel();
  bool get available => vpn.connections.engine != null;

  Future<RunnerResponse> request(
    String action,
    String id,
    CancellationToken token, [
    Map<String, Object?>? payload,
  ]) async {
    final transport = runner.transport();
    if (transport == null) throw const FormatException('server_unavailable');
    return transport.request(
      RunnerRequest.fromJson({
        'version': 1,
        'action': action,
        'id': id,
        if (payload != null) 'payload': jsonEncode(payload),
      }),
      token,
      sudoPassword: runner.password(),
    );
  }

  Future<Map<String, dynamic>> rpc(
    String action,
    String id,
    CancellationToken token, [
    Map<String, Object?>? payload,
  ]) async {
    final response = await request(action, id, token, payload);
    if (response.code != 'ok' || response.xrayCheck == null) {
      throw FormatException(response.code);
    }
    return response.xrayCheck!;
  }

  Future<void> inspect() async {
    if (busy || runner.panelAccess == null || !runner.connected) return;
    busy = true;
    changed();
    final token = CancellationToken();
    _token = token;
    final deadline = Timer(const Duration(seconds: 30), token.cancel);
    try {
      // Latest remains readable if the new Xray failed to start.
      final latest = await request(
        'xray_check_latest',
        runner.panelAccess!.id,
        token,
      );
      if (latest.code == 'ok' && latest.xrayCheck != null) {
        operation = latest.xrayCheck;
        phase = operation!['phase'] as String;
        code = operation!['code'] as String;
      }
      plan = await rpc('xray_check_plan', runner.panelAccess!.id, token);
      if (operation == null) phase = 'idle';
    } catch (error) {
      code = error is FormatException ? error.message : 'server_unavailable';
    } finally {
      deadline.cancel();
      if (_token == token) _token = null;
      busy = false;
      changed();
    }
  }

  Future<ConnectionTarget> target(Map row, String panelId) async {
    final id = row['id'] as int;
    final managed = vpn.workspace.inbounds
        .where(
          (r) =>
              r.serverId == runner.serverId &&
              ((r.spec['adoption'] as Map?)?['sourceId'] == '$id' &&
                      (r.spec['adoption'] as Map?)?['panelId'] == panelId ||
                  row['name'] ==
                      'AntiRKN:${vpn.workspace.resourceWorkspaceId(r.serverId)}:${r.id}'),
        )
        .firstOrNull;
    if (managed != null) {
      final key = (target: runner.serverId, resource: managed.id);
      if (!vpn.connections.available(key)) {
        throw const FormatException('xray_check_changed');
      }
      return key;
    }
    final observed = await runner.readInbound(id);
    if (observed == null) throw const FormatException('diagnostic_access');
    final key = externalConnectionTarget(
      runner.serverId,
      'vless',
      id,
      runner.panelAccess!.port,
    );
    final spec = adoptionSpec('vless', observed, host)..['id'] = key.resource;
    spec['adoption'] = {
      ...Map<String, Object?>.from(spec['adoption'] as Map),
      'panelId': panelId,
      'panelPort': runner.panelAccess!.port,
    };
    final identity = vpn.remote(key.target)?.identity;
    if (identity == null) throw const FormatException('server_unavailable');
    return vpn.connections.registerExternal(key.target, spec, identity);
  }

  Future<void> run() async {
    if (busy || vpn.busy || !runner.canRequestAction || !available) return;
    busy = true;
    running = true;
    phase = 'baseline';
    code = '';
    rows.clear();
    changed();
    final token = CancellationToken();
    _token = token;
    final deadline = Timer(const Duration(minutes: 14), token.cancel);
    final leases = <String>[];
    final fields = <Map<String, Object?>>[];
    final signatures = <ConnectionTarget, String>{};
    String? id, nonce, manifest;
    bool entered = false, began = false;
    String network = '';
    try {
      if (vpn.enterConnectionTraffic != null) {
        entered = await vpn.enterConnectionTraffic!();
        if (!entered) throw const FormatException('busy');
      }
      vpn.upgradeBusy = true;
      await runner.requestAction(() async {
        final identity = runner.identity(), panelId = runner.panelAccess?.id;
        if (panelId == null || identity == null) {
          throw const FormatException('server_unavailable');
        }
        void same() {
          token.check();
          if (runner.identity() != identity ||
              signatures.entries.any(
                (e) => vpn.connections.signature(e.key) != e.value,
              )) {
            throw const FormatException('xray_check_changed');
          }
        }

        plan = await rpc('xray_check_plan', panelId, token);
        if (plan!['latest'] case final Map latest) {
          if (!terminal.contains(latest['phase'])) {
            operation = Map<String, dynamic>.from(latest);
            throw const FormatException('xray_check_busy');
          }
        }
        if (plan!['available'] != true) {
          throw const FormatException('xray_check_layout');
        }
        final inventory = (plan!['inbounds'] as List).cast<Map>();
        final enabled = inventory.where((r) => r['enabled'] == true).toList();
        rows.addAll(
          inventory.map(
            (r) => XrayComparison(
              r['id'] as int,
              '${r['name']}',
              r['enabled'] == true,
            ),
          ),
        );
        changed();
        if (enabled.isEmpty ||
            enabled.length > (plan!['maxInbounds'] as int) ||
            enabled.any((r) => r['protocol'] != 'vless')) {
          throw const FormatException('xray_check_coverage');
        }
        for (final row in enabled) {
          same();
          final key = await target(row, panelId);
          signatures[key] = vpn.connections.signature(key);
          final lease = newVpnId();
          leases.add(lease);
          final access = await request(
            'probe_begin',
            lease,
            token,
            vpn.connections.diagnosticPayload(key),
          );
          if (access.code != 'ok' || access.connectionProbe == null) {
            throw const FormatException('diagnostic_access');
          }
          final proxy = vpn.connections.compileDiagnostic(
            key,
            access.connectionProbe!,
          );
          if (proxy == null) throw const FormatException('unsupported_route');
          fields.add(proxy.fields);
          final check = await vpn.connections.engine!.check(
            proxy.fields,
            token,
          );
          rows.firstWhere((r) => r.id == row['id']).before = check;
          changed();
          if (check.status != ConnectionCheckStatus.working ||
              check.traffic?.tcp != true ||
              check.traffic?.udp != true) {
            throw FormatException(check.code);
          }
          if (network.isEmpty) network = check.networkIdentity;
          if (check.networkIdentity != network) {
            throw const FormatException('network_changed');
          }
        }
        same();
        Future<void> sameNetwork() async {
          same();
          final now = await token.bind(
            vpn.connections.engine!.network.network(),
          );
          if (now.vpn || now.identity != network) {
            throw const FormatException('network_changed');
          }
        }

        await sameNetwork();
        id = newVpnId();
        began = true;
        phase = 'preparing';
        changed();
        operation = await rpc('xray_check_begin', id!, token, {
          'panelId': panelId,
          'fingerprint': plan!['fingerprint'],
          'leases': leases,
          'network': network,
          'core': revision,
          'baseline': [
            for (final lease in leases)
              {'lease': lease, 'tcp': true, 'udp': true},
          ],
        });
        nonce = operation!['nonce'] as String;
        manifest = operation!['manifest'] as String;
        while (operation!['phase'] != 'awaiting_checks' &&
            !terminal.contains(operation!['phase'])) {
          same();
          phase = operation!['phase'] as String;
          changed();
          await token.bind(Future<void>.delayed(const Duration(seconds: 1)));
          operation = await rpc('xray_check_status', id!, token);
        }
        if (operation!['phase'] != 'awaiting_checks') {
          throw const FormatException('xray_check_failed');
        }
        phase = 'comparison';
        changed();
        final checks = <Map<String, Object?>>[];
        for (var i = 0; i < fields.length; i++) {
          await sameNetwork();
          final check = await vpn.connections.engine!.check(fields[i], token);
          rows.firstWhere((r) => r.id == enabled[i]['id']).after = check;
          changed();
          if (check.networkIdentity != network ||
              check.status != ConnectionCheckStatus.working ||
              check.traffic?.tcp != true ||
              check.traffic?.udp != true) {
            throw FormatException(check.code);
          }
          checks.add({'lease': leases[i], 'tcp': true, 'udp': true});
        }
        await sameNetwork();
        operation = await rpc('xray_check_commit', id!, token, {
          'nonce': nonce,
          'manifest': manifest,
          'network': network,
          'checks': checks,
        });
        if (operation!['phase'] != 'committed') {
          throw const FormatException('xray_check_failed');
        }
        phase = 'committed';
        code = 'committed';
        runner.refreshSoftware?.call();
      });
      if (!began) throw const FormatException('server_unavailable');
    } catch (error) {
      code = token.isCancelled
          ? 'cancelled'
          : error is FormatException
          ? error.message
          : 'xray_check_failed';
      phase = began ? 'recovery_pending' : 'not_changed';
      changed();
      if (began && id != null) {
        final recovery = CancellationToken();
        final limit = Timer(const Duration(seconds: 45), recovery.cancel);
        try {
          operation = await rpc('xray_check_status', id!, recovery);
          if (!terminal.contains(operation!['phase']) && nonce != null) {
            operation = await rpc('xray_check_abort', id!, recovery, {
              'nonce': nonce,
              'manifest': manifest,
            });
          }
          phase = operation!['phase'] as String;
          if (phase == 'rolled_back' && !token.isCancelled) {
            // Repeat on the original device. A restored binary alone is not a
            // claim that traffic has also recovered.
            for (var i = 0; i < fields.length; i++) {
              final check = await vpn.connections.engine!.check(
                fields[i],
                token,
              );
              rows.where((r) => r.enabled).elementAt(i).restored = check;
              changed();
            }
          }
        } catch (_) {
          phase = 'recovery_pending';
        } finally {
          limit.cancel();
        }
      }
    } finally {
      // The server rejects early lease removal while a transaction needs them.
      // Their independent expiry remains armed if SSH is unavailable.
      for (final lease in leases) {
        final cleanup = CancellationToken();
        final limit = Timer(const Duration(seconds: 10), cleanup.cancel);
        try {
          await request('probe_end', lease, cleanup);
        } catch (_) {
        } finally {
          limit.cancel();
        }
      }
      deadline.cancel();
      _token = null;
      vpn.upgradeBusy = false;
      if (entered) await vpn.leaveConnectionTraffic?.call();
      running = false;
      busy = false;
      changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
