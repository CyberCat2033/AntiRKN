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
/// With [skipServiceMode], resources of servers in service mode are left out
/// before any access check, so their pending state never blocks a profile.
/// Proxy names are still computed over every resource.
List<PreparedProxy> vlessUserAccesses(
  VpnWorkspace workspace,
  String userId, {
  Map<String, String> serverNames = const {},
  void Function(ProfileAccessException)? onPending,
  bool skipServiceMode = false,
}) {
  final user = workspace.users.where((u) => u.id == userId).firstOrNull;
  if (user == null || !user.enabled) return [];
  final proxies = <PreparedProxy>[];
  for (final inbound in workspace.inbounds.where(
    (i) =>
        i.enabled &&
        !i.deleted &&
        !i.internal &&
        !(skipServiceMode && workspace.inServiceMode(i.serverId)),
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
    final fields = vlessProxyFields(
      name: clientProxyName(workspace, userId, inbound.id, serverNames),
      spec: s,
      observation: observation,
      uuid: binding['uuid'] as String,
    );
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

/// Mihomo fields of one VLESS access from the inbound [spec], its observed
/// REALITY keys and the client [uuid]. Profiles and the REALITY target check
/// (FR-SNI) build the same proxy.
Map<String, Object?> vlessProxyFields({
  required String name,
  required Map<String, Object?> spec,
  required Map<dynamic, dynamic> observation,
  required String uuid,
}) {
  final raw = spec['transport'] == 'raw';
  return <String, Object?>{
    'name': name,
    'type': 'vless',
    'server': spec['endpoint'],
    'port': spec['externalPort'],
    'uuid': uuid,
    'udp': true,
    'tls': true,
    'servername': spec['sni'],
    'client-fingerprint': spec['fingerprint'] ?? 'chrome',
    'packet-encoding': 'xudp',
    'network': raw ? 'tcp' : 'xhttp',
    if (raw) 'flow': 'xtls-rprx-vision',
    if (spec['security'] == 'reality')
      'reality-opts': <String, Object?>{
        'public-key': observation['publicKey'],
        'short-id': observation['shortId'],
        'support-x25519mlkem768': true,
      },
    if (!raw)
      'xhttp-opts': <String, Object?>{
        'path': spec['path'],
        'host': spec['host'],
        'mode': spec['mode'],
        ...xhttpMihomoOptions(spec['xhttp'] as Map? ?? {}),
      },
  };
}
