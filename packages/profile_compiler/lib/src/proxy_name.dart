import 'package:antirkn_domain/antirkn_domain.dart';

/// Human-readable names; duplicate node labels receive a stable numeric suffix.
String clientProxyName(
  VpnWorkspace workspace,
  String userId,
  String resourceId,
) {
  final user = workspace.users.singleWhere((u) => u.id == userId);
  final nodes = <({String id, String name, String protocol})>[
    for (final r in workspace.inbounds.where(
      (r) => r.enabled && !r.deleted && !r.internal,
    ))
      (id: r.id, name: r.name, protocol: 'VLESS'),
    for (final r in workspace.awgInterfaces.where(
      (r) => r.enabled && !r.deleted,
    ))
      (id: r.id, name: r.name, protocol: 'AmneziaWG'),
    for (final r in workspace.ttEndpoints.where((r) => r.enabled && !r.deleted))
      (id: r.id, name: r.name, protocol: 'TrustTunnel'),
  ]..sort((a, b) => a.id.compareTo(b.id));
  final natural = {
    for (final n in nodes) '${n.protocol}-${user.name}_${n.name}',
  };
  final used = <String>{};
  for (final node in nodes) {
    final base = '${node.protocol}-${user.name}_${node.name}';
    var name = base, suffix = 2;
    while (used.contains(name)) {
      do {
        name = '${base}_${suffix++}';
      } while (natural.contains(name));
    }
    used.add(name);
    if (node.id == resourceId) return name;
  }
  throw const FormatException('vpn_pending');
}
