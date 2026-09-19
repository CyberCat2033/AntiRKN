import 'package:antirkn_domain/antirkn_domain.dart';
import 'access_diagnostic.dart';

/// Human-readable Protocol-ClientName_ServerName names.
///
/// When a client has multiple VLESS inbounds, their inbound names are appended
/// after the server name. Exact duplicates receive a stable numeric suffix
/// because Mihomo requires every proxy name to be unique.
String clientProxyName(
  VpnWorkspace workspace,
  String userId,
  String resourceId,
  Map<String, String> serverNames,
) {
  final user = workspace.users.singleWhere((u) => u.id == userId);
  final nodes =
      <({String id, String serverId, String resourceName, String protocol})>[
        for (final r in workspace.inbounds.where(
          (r) => r.enabled && !r.deleted && !r.internal,
        ))
          (
            id: r.id,
            serverId: r.serverId,
            resourceName: r.name,
            protocol: 'VLESS',
          ),
        for (final r in workspace.awgInterfaces.where(
          (r) => r.enabled && !r.deleted,
        ))
          (
            id: r.id,
            serverId: r.serverId,
            resourceName: r.name,
            protocol: 'AmneziaWG',
          ),
        for (final r in workspace.ttEndpoints.where(
          (r) => r.enabled && !r.deleted,
        ))
          (
            id: r.id,
            serverId: r.serverId,
            resourceName: r.name,
            protocol: 'TrustTunnel',
          ),
      ]..sort((a, b) => a.id.compareTo(b.id));
  final multipleVless =
      nodes.where((node) => node.protocol == 'VLESS').length > 1;

  String baseName(
    ({String id, String serverId, String resourceName, String protocol}) node,
  ) {
    final serverName = serverNames[node.serverId]?.trim();
    final server = serverName?.isNotEmpty == true ? serverName! : node.serverId;
    final inbound = multipleVless && node.protocol == 'VLESS'
        ? '-${node.resourceName}'
        : '';
    return '${node.protocol}-${user.name}_$server$inbound';
  }

  final natural = {for (final node in nodes) baseName(node)};
  final used = <String>{};
  for (final node in nodes) {
    final base = baseName(node);
    var name = base, suffix = 2;
    while (used.contains(name)) {
      do {
        name = '${base}_${suffix++}';
      } while (natural.contains(name));
    }
    used.add(name);
    if (node.id == resourceId) return name;
  }
  throw ProfileAccessException('vpn_pending_resource', null);
}
