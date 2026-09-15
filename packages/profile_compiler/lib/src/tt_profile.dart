import 'package:antirkn_domain/antirkn_domain.dart';
import 'prepared_proxy.dart';

List<PreparedProxy> ttUserAccesses(VpnWorkspace workspace, String userId) {
  final user = workspace.users
      .where((u) => u.id == userId && u.enabled)
      .firstOrNull;
  if (user == null) return [];
  final result = <PreparedProxy>[];
  for (final r in workspace.ttEndpoints.where((r) => r.enabled && !r.deleted)) {
    final server = workspace.servers[ttTarget(r.serverId)];
    if (server?['pending'] != null || server?['error'] != null) {
      throw const FormatException('vpn_pending');
    }
    final observed = (server?['observed'] as List? ?? [])
        .whereType<Map>()
        .where(
          (o) =>
              o['id'] == r.id &&
              o['workspaceId'] == workspace.id &&
              o['confirmed'] == true &&
              canonicalJson(o['spec']) == canonicalJson(r.spec),
        )
        .firstOrNull;
    final client = (observed?['clients'] as List? ?? [])
        .whereType<Map>()
        .where(
          (c) =>
              c['id'] == userId &&
              c['enabled'] == true &&
              c['username'] == user.login,
        )
        .firstOrNull;
    if (client == null) throw const FormatException('vpn_pending');
    final proxy = PreparedProxy(
      identity: AccessIdentity(
        id: r.id,
        userId: userId,
        active: true,
        confirmed: true,
      ),
      fields: {
        'name': '${r.name}_TT_${r.id}',
        'type': 'trusttunnel',
        'server': r.spec['endpoint'],
        'port': r.spec['externalPort'],
        'username': client['username'],
        'password': client['password'],
        'sni': r.spec['domain'],
        'udp': true,
        'quic': r.spec['quic'],
      },
    );
    proxy.validate();
    result.add(proxy);
  }
  return result;
}
