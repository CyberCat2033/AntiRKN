import 'package:antirkn_domain/antirkn_domain.dart';
import 'prepared_proxy.dart';
import 'proxy_name.dart';
import 'adopted_proxy.dart';
import 'access_diagnostic.dart';

/// With [skipServiceMode], resources of servers in service mode are left out
/// before any access check, so their pending state never blocks a profile.
/// Proxy names are still computed over every resource.
List<PreparedProxy> ttUserAccesses(
  VpnWorkspace workspace,
  String userId, {
  Map<String, String> serverNames = const {},
  void Function(ProfileAccessException)? onPending,
  bool skipServiceMode = false,
}) {
  final user = workspace.users
      .where((u) => u.id == userId && u.enabled)
      .firstOrNull;
  if (user == null) return [];
  final result = <PreparedProxy>[];
  for (final r in workspace.ttEndpoints.where(
    (r) =>
        r.enabled &&
        !r.deleted &&
        !(skipServiceMode && workspace.inServiceMode(r.serverId)),
  )) {
    final subject = accessDiagnosticSubject(
      'TrustTunnel',
      r.serverId,
      r.name,
      serverNames,
    );
    final server = workspace.servers[ttTarget(r.serverId)];
    if (server?['error'] == 'vpn_identity') {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_identity', subject),
        onPending,
      );
      continue;
    }
    if (server?['error'] == 'tt_conflict' ||
        (server?['error'] as String?)?.startsWith('vpn_adoption_') == true) {
      throw const FormatException('tt_conflict');
    }
    final candidates = (server?['observed'] as List? ?? [])
        .whereType<Map>()
        .where(
          (o) =>
              o['id'] == r.id &&
              o['workspaceId'] ==
                  workspace.resourceWorkspaceId(ttTarget(r.serverId)),
        )
        .toList();
    final observed = candidates
        .where((o) => o['confirmed'] == true)
        .firstOrNull;
    if (observed == null) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_readback', subject),
        onPending,
      );
      continue;
    }
    if (canonicalJson(observed['spec']) != canonicalJson(r.spec)) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_settings', subject),
        onPending,
      );
      continue;
    }
    final client = (observed['clients'] as List? ?? [])
        .whereType<Map>()
        .where(
          (c) =>
              c['id'] == userId &&
              c['enabled'] == true &&
              (r.spec.containsKey('adoption') || c['username'] == user.login),
        )
        .firstOrNull;
    if (client == null) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_client', subject),
        onPending,
      );
      continue;
    }
    if (r.spec.containsKey('adoption')) {
      result.add(
        adoptedProxy(workspace, userId, r.spec, observed, client, serverNames),
      );
      continue;
    }
    final proxy = PreparedProxy(
      identity: AccessIdentity(
        id: r.id,
        userId: userId,
        active: true,
        confirmed: true,
      ),
      fields: {
        'name': clientProxyName(workspace, userId, r.id, serverNames),
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
