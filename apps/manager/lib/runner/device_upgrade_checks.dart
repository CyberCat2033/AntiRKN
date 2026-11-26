import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../vpn/adopt_resource.dart';
import '../vpn/connection_checks.dart';
import '../vpn/external_connection_check.dart';
import '../vpn/vpn_controller.dart';
import 'runner_controller.dart';

/// The device network as the server stores it: a fixed-size digest. The raw
/// identity (all addresses and route tables) is tens of KiB on a desktop and
/// the runner accepts at most 1024 characters.
@visibleForTesting
String networkTag(String identity) =>
    sha256.convert(utf8.encode(identity)).toString();

/// One connection compared around a change of server software (Xray, 3x-ui,
/// TrustTunnel, AmneziaWG): the device's check before, after and, when the
/// server rolled back, once more.
class UpgradeComparison {
  UpgradeComparison(this.id, this.name, this.enabled);
  final Object id;
  final String name;
  final bool enabled;
  ConnectionCheck? before, after, restored;
}

/// The device side of a checked upgrade, shared by the Xray transaction and
/// component upgrades: a diagnostic lease per connection (`probe_begin`),
/// the check through it before the change, the same check from the same
/// network after it, and the leases' end. Every failure is a
/// [FormatException] with the code to show.
class DeviceUpgradeChecks {
  DeviceUpgradeChecks({
    required this.runner,
    required this.vpn,
    required this.host,
    required this.token,
    this.changed,
    this.requireBoth = false,
  });
  final RunnerController runner;
  final VpnController vpn;
  final String host;
  final CancellationToken token;
  final VoidCallback? changed;

  /// Xray: every connection must carry TCP and UDP before the change.
  /// Otherwise a connection must work, and after the change carry at least
  /// what it carried before.
  final bool requireBoth;

  final leases = <String>[];
  final rows = <UpgradeComparison>[];
  final _fields = <Map<String, Object?>>[];
  final _signatures = <ConnectionTarget, String>{};
  late final Object? _identity = runner.identity();
  bool _entered = false;
  String network = '';

  bool get available => vpn.connections.engine != null;

  /// Connection traffic for the checks; the VPN controller stays busy
  /// meanwhile. Pair with [close].
  Future<void> open() async {
    if (vpn.enterConnectionTraffic != null) {
      _entered = await vpn.enterConnectionTraffic!();
      if (!_entered) throw const FormatException('busy');
    }
    vpn.upgradeBusy = true;
  }

  /// The server and the checked connections are as when checking began.
  void same() {
    token.check();
    if (runner.identity() != _identity ||
        _signatures.entries.any(
          (e) => vpn.connections.signature(e.key) != e.value,
        )) {
      throw const FormatException('xray_check_changed');
    }
  }

  Future<void> sameNetwork() async {
    same();
    final now = await token.bind(vpn.connections.engine!.network.network());
    if (!now.measuresDevice || now.identity != network) {
      throw const FormatException('network_changed');
    }
  }

  String get tag => networkTag(network);

  List<Map<String, Object?>> results(String phase) => [
    for (var i = 0; i < leases.length; i++)
      {
        'lease': leases[i],
        'tcp':
            (phase == 'before' ? rows[i].before : rows[i].after)
                ?.traffic
                ?.tcp ==
            true,
        'udp':
            (phase == 'before' ? rows[i].before : rows[i].after)
                ?.traffic
                ?.udp ==
            true,
      },
  ];

  /// A resource the app manages (or adopted) on this server, ready to check.
  ConnectionTarget resource(ConnectionTarget key) {
    final readiness = vpn.connections.evaluateReadiness(key);
    if (readiness.state != InboundReadinessState.ready) {
      throw FormatException(readiness.diagnosticReason ?? 'xray_check_changed');
    }
    return key;
  }

  /// The connection of a 3x-ui inbound row: the app's own resource, or the
  /// row read from the server and checked like an external one.
  Future<ConnectionTarget> panelInbound(Map row, String panelId) async {
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
      return resource((target: runner.serverId, resource: managed.id));
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

  Future<RunnerResponse> request(
    String action,
    String id, [
    Map<String, Object?>? payload,
    CancellationToken? cancel,
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
      cancel ?? token,
      sudoPassword: runner.password(),
    );
  }

  /// Leases [key] and checks it before the change: it must work (with
  /// [requireBoth], over TCP and UDP) from the same network as the others.
  Future<void> before(ConnectionTarget key, UpgradeComparison row) async {
    same();
    _signatures[key] = vpn.connections.signature(key);
    final lease = newVpnId();
    leases.add(lease);
    rows.add(row);
    final access = await request(
      'probe_begin',
      lease,
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
    _fields.add(proxy.fields);
    final check = await vpn.connections.engine!.check(proxy.fields, token);
    row.before = check;
    changed?.call();
    final tcp = check.traffic?.tcp == true, udp = check.traffic?.udp == true;
    if (check.status != ConnectionCheckStatus.working ||
        (requireBoth ? !(tcp && udp) : !(tcp || udp))) {
      throw FormatException(check.code);
    }
    if (network.isEmpty) network = check.networkIdentity;
    if (check.networkIdentity != network) {
      throw const FormatException('network_changed');
    }
  }

  /// The same checks after the change; none may carry less than before.
  Future<List<Map<String, Object?>>> after() async {
    for (var i = 0; i < _fields.length; i++) {
      await sameNetwork();
      final check = await vpn.connections.engine!.check(_fields[i], token);
      final row = rows[i];
      row.after = check;
      changed?.call();
      bool carried(bool? before, bool? now) => before != true || now == true;
      if (check.networkIdentity != network ||
          check.status != ConnectionCheckStatus.working ||
          !carried(row.before?.traffic?.tcp, check.traffic?.tcp) ||
          !carried(row.before?.traffic?.udp, check.traffic?.udp)) {
        throw FormatException(check.code);
      }
    }
    await sameNetwork();
    return results('after');
  }

  /// After a rollback, once more: a restored version alone is not a claim
  /// that traffic has recovered too.
  /// [cancel] replaces [token] when that one was cancelled (a stopped
  /// upgrade is still compared after its rollback).
  Future<void> restore([CancellationToken? cancel]) async {
    final using = cancel ?? token;
    for (var i = 0; i < _fields.length; i++) {
      if (using.isCancelled) return;
      rows[i].restored = await vpn.connections.engine!.check(_fields[i], using);
      changed?.call();
    }
  }

  /// The name the app shows for a TrustTunnel endpoint or AmneziaWG
  /// interface of this server, else its id.
  String nameOf(String component, String id) {
    final spec = component == 'trusttunnel'
        ? vpn.workspace.ttEndpoints.where((e) => e.id == id).firstOrNull?.spec
        : vpn.workspace.awgInterfaces
              .where((i) => i.id == id)
              .firstOrNull
              ?.spec;
    return switch (spec?['name']) {
      final String name when name.isNotEmpty => name,
      _ => id,
    };
  }

  /// Ends the leases (the server refuses while an upgrade still needs them;
  /// their own expiry stays armed) and the connection traffic.
  Future<void> close() async {
    for (final lease in leases) {
      final cleanup = CancellationToken();
      final limit = Timer(const Duration(seconds: 10), cleanup.cancel);
      try {
        await request('probe_end', lease, null, cleanup);
      } catch (_) {
      } finally {
        limit.cancel();
      }
    }
    vpn.upgradeBusy = false;
    if (_entered) await vpn.leaveConnectionTraffic?.call();
    _entered = false;
  }
}
