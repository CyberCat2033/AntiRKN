import 'package:antirkn_domain/antirkn_domain.dart';
import 'prepared_proxy.dart';
import 'proxy_name.dart';
import 'adopted_proxy.dart';
import 'access_diagnostic.dart';

/// With [skipServiceMode], resources of servers in service mode are left out
/// before any access check, so their pending state never blocks a profile.
/// Proxy names are still computed over every resource.
List<PreparedProxy> awgUserAccesses(
  VpnWorkspace workspace,
  String userId, {
  Map<String, String> serverNames = const {},
  void Function(ProfileAccessException)? onPending,
  bool skipServiceMode = false,
}) {
  if (!workspace.users.any((u) => u.id == userId && u.enabled)) return [];
  final proxies = <PreparedProxy>[];
  for (final interface in workspace.awgInterfaces.where(
    (r) =>
        r.enabled &&
        !r.deleted &&
        !(skipServiceMode && workspace.inServiceMode(r.serverId)),
  )) {
    final subject = accessDiagnosticSubject(
      'AmneziaWG',
      interface.serverId,
      interface.name,
      serverNames,
    );
    final server = workspace.servers[awgTarget(interface.serverId)];
    if (server?['error'] == 'vpn_identity') {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_identity', subject),
        onPending,
      );
      continue;
    }
    if (server?['error'] == 'awg_conflict' ||
        (server?['error'] as String?)?.startsWith('vpn_adoption_') == true) {
      throw const FormatException('awg_conflict');
    }
    final candidates = (server?['observed'] as List? ?? [])
        .whereType<Map>()
        .where(
          (r) =>
              r['id'] == interface.id &&
              r['workspaceId'] ==
                  workspace.resourceWorkspaceId(awgTarget(interface.serverId)),
        )
        .toList();
    final observed = candidates
        .where((r) => r['confirmed'] == true)
        .firstOrNull;
    if (observed == null) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_readback', subject),
        onPending,
      );
      continue;
    }
    if (canonicalJson(observed['spec']) != canonicalJson(interface.spec)) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_settings', subject),
        onPending,
      );
      continue;
    }
    final client = (observed['clients'] as List? ?? [])
        .whereType<Map>()
        .where((c) => c['id'] == userId && c['enabled'] == true)
        .firstOrNull;
    if (client == null) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_client', subject),
        onPending,
      );
      continue;
    }
    final s = interface.spec;
    if (s.containsKey('adoption')) {
      proxies.add(
        adoptedProxy(workspace, userId, s, observed, client, serverNames),
      );
      continue;
    }
    final proxy = PreparedProxy(
      identity: AccessIdentity(
        id: interface.id,
        userId: userId,
        active: true,
        confirmed: true,
      ),
      fields: {
        'name': clientProxyName(workspace, userId, interface.id, serverNames),
        'type': 'wireguard',
        'server': s['endpoint'],
        'port': s['externalPort'],
        'ip': client['address'],
        if (s['pool6'] != '') 'ipv6': client['address6'],
        'private-key': client['privateKey'],
        'public-key': observed['publicKey'],
        'pre-shared-key': client['presharedKey'],
        'udp': true,
        'mtu': s['mtu'],
        'persistent-keepalive': 0,
        'allowed-ips': ['0.0.0.0/0', if (s['pool6'] != '') '::/0'],
        'amnezia-wg-option': {
          'version': 3,
          ...Map<String, Object?>.from(s['options'] as Map),
          'header-protection-key': observed['headerProtectionKey'],
          for (var i = 1; i <= 4; i++) 'h$i': '$i',
        },
      },
    );
    proxy.validate();
    proxies.add(proxy);
  }
  return proxies;
}
