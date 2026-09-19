import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:crypto/crypto.dart';
import 'prepared_proxy.dart';
import 'proxy_name.dart';
import 'adopted_proxy.dart';
import 'access_diagnostic.dart';

String vlessRevision(Map<String, Object?> payload) =>
    sha256.convert(utf8.encode(canonicalJson(payload))).toString();

/// Uses observed per-client credentials, never an administrator's panel access.
List<PreparedProxy> vlessUserAccesses(
  VpnWorkspace workspace,
  String userId, {
  Map<String, String> serverNames = const {},
  void Function(ProfileAccessException)? onPending,
}) {
  final user = workspace.users.where((u) => u.id == userId).firstOrNull;
  if (user == null || !user.enabled) return [];
  final proxies = <PreparedProxy>[];
  for (final inbound in workspace.inbounds.where(
    (i) => i.enabled && !i.deleted && !i.internal,
  )) {
    final subject = accessDiagnosticSubject(
      'VLESS',
      inbound.serverId,
      inbound.name,
      serverNames,
    );
    final server = workspace.servers[inbound.serverId];
    if (server?['error'] == 'vpn_identity') {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_identity', subject),
        onPending,
      );
      continue;
    }
    if (server?['error'] == 'vless_conflict' ||
        (server?['error'] as String?)?.startsWith('vpn_adoption_') == true) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_review', subject),
        onPending,
      );
      continue;
    }
    final observations = server?['observed'] as List? ?? [];
    final candidates = observations
        .whereType<Map>()
        .where(
          (o) =>
              o['id'] == inbound.id &&
              o['workspaceId'] ==
                  workspace.resourceWorkspaceId(inbound.serverId),
        )
        .toList();
    final observation = candidates
        .where((o) => o['confirmed'] == true)
        .firstOrNull;
    if (observation == null) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_readback', subject),
        onPending,
      );
      continue;
    }
    if (canonicalJson(observation['spec']) != canonicalJson(inbound.spec)) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_settings', subject),
        onPending,
      );
      continue;
    }
    final binding = (observation['clients'] as List)
        .whereType<Map>()
        .where((u) => u['id'] == userId && u['enabled'] == true)
        .firstOrNull;
    if (binding == null) {
      reportPendingAccess(
        ProfileAccessException('vpn_pending_client', subject),
        onPending,
      );
      continue;
    }
    final s = inbound.spec;
    if (s.containsKey('adoption')) {
      proxies.add(
        adoptedProxy(workspace, userId, s, observation, binding, serverNames),
      );
      continue;
    }
    final fields = <String, Object?>{
      'name': clientProxyName(workspace, userId, inbound.id, serverNames),
      'type': 'vless',
      'server': s['endpoint'],
      'port': s['externalPort'],
      'uuid': binding['uuid'],
      'udp': true,
      'tls': true,
      'servername': s['sni'],
      'client-fingerprint': s['fingerprint'] ?? 'chrome',
      'packet-encoding': 'xudp',
      'network': inbound.transport == 'raw' ? 'tcp' : 'xhttp',
      if (inbound.transport == 'raw') 'flow': 'xtls-rprx-vision',
      if (inbound.security == 'reality')
        'reality-opts': <String, Object?>{
          'public-key': observation['publicKey'],
          'short-id': observation['shortId'],
          'support-x25519mlkem768': true,
        },
      if (inbound.transport == 'xhttp')
        'xhttp-opts': <String, Object?>{
          'path': s['path'],
          'host': s['host'],
          'mode': s['mode'],
          ...xhttpMihomoOptions(s['xhttp'] as Map? ?? {}),
        },
    };
    final proxy = PreparedProxy(
      identity: AccessIdentity(
        id: inbound.id,
        userId: userId,
        active: true,
        confirmed: true,
      ),
      fields: fields,
    );
    proxy.validate();
    proxies.add(proxy);
  }
  return proxies;
}
