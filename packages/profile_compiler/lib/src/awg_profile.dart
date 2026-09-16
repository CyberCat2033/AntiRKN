import 'package:antirkn_domain/antirkn_domain.dart';
import 'prepared_proxy.dart';
import 'proxy_name.dart';

List<PreparedProxy> awgUserAccesses(VpnWorkspace workspace, String userId) {
  if (!workspace.users.any((u) => u.id == userId && u.enabled)) return [];
  final proxies = <PreparedProxy>[];
  for (final interface in workspace.awgInterfaces.where(
    (r) => r.enabled && !r.deleted,
  )) {
    final server = workspace.servers[awgTarget(interface.serverId)];
    if (server?['pending'] != null || server?['error'] != null) {
      throw const FormatException('vpn_pending');
    }
    final observed = (server?['observed'] as List? ?? [])
        .whereType<Map>()
        .where(
          (r) =>
              r['id'] == interface.id &&
              r['workspaceId'] ==
                  workspace.resourceWorkspaceId(
                    awgTarget(interface.serverId),
                  ) &&
              r['confirmed'] == true &&
              canonicalJson(r['spec']) == canonicalJson(interface.spec),
        )
        .firstOrNull;
    final client = (observed?['clients'] as List? ?? [])
        .whereType<Map>()
        .where((c) => c['id'] == userId && c['enabled'] == true)
        .firstOrNull;
    if (client == null) throw const FormatException('vpn_pending');
    final s = interface.spec;
    final proxy = PreparedProxy(
      identity: AccessIdentity(
        id: interface.id,
        userId: userId,
        active: true,
        confirmed: true,
      ),
      fields: {
        'name': clientProxyName(workspace, userId, interface.id),
        'type': 'wireguard',
        'server': s['endpoint'],
        'port': s['externalPort'],
        'ip': client['address'],
        if (s['pool6'] != '') 'ipv6': client['address6'],
        'private-key': client['privateKey'],
        'public-key': observed!['publicKey'],
        'pre-shared-key': client['presharedKey'],
        'udp': true,
        'mtu': s['mtu'],
        'persistent-keepalive': s['keepalive'],
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
