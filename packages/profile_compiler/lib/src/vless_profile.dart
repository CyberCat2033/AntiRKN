import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:crypto/crypto.dart';
import 'prepared_proxy.dart';

String vlessRevision(Map<String, Object?> payload) =>
    sha256.convert(utf8.encode(canonicalJson(payload))).toString();

/// Uses observed per-client credentials, never an administrator's panel access.
List<PreparedProxy> vlessUserAccesses(VpnWorkspace workspace, String userId) {
  final user = workspace.users.where((u) => u.id == userId).firstOrNull;
  if (user == null || !user.enabled) return [];
  final proxies = <PreparedProxy>[];
  for (final inbound in workspace.inbounds.where(
    (i) => i.enabled && !i.deleted,
  )) {
    final server = workspace.servers[inbound.serverId];
    if (server?['pending'] != null ||
        server?['error'] == 'vpn_identity' ||
        server?['error'] == 'vless_conflict') {
      throw const FormatException('vpn_pending');
    }
    final observations = server?['observed'] as List? ?? [];
    final observation = observations
        .whereType<Map>()
        .where(
          (o) =>
              o['id'] == inbound.id &&
              o['workspaceId'] == workspace.id &&
              o['confirmed'] == true,
        )
        .firstOrNull;
    if (observation == null ||
        canonicalJson(observation['spec']) != canonicalJson(inbound.spec)) {
      throw const FormatException('vpn_pending');
    }
    final binding = (observation['clients'] as List)
        .whereType<Map>()
        .where((u) => u['id'] == userId && u['enabled'] == true)
        .firstOrNull;
    if (binding == null) throw const FormatException('vpn_pending');
    final s = inbound.spec;
    final fields = <String, Object?>{
      'name':
          '${inbound.name}_${inbound.id}${s['region'] == 'RU' ? '_RU' : ''}',
      'type': 'vless',
      'server': s['endpoint'],
      'port': s['externalPort'],
      'uuid': binding['uuid'],
      'udp': true,
      'tls': true,
      'servername': s['sni'],
      'client-fingerprint': 'chrome',
      'packet-encoding': 'xudp',
      'network': inbound.transport == 'raw' ? 'tcp' : 'xhttp',
      if (inbound.transport == 'raw') 'flow': 'xtls-rprx-vision',
      if (inbound.security == 'reality')
        'reality-opts': <String, Object?>{
          'public-key': observation['publicKey'],
          'short-id': observation['shortId'],
        },
      if (inbound.transport == 'xhttp')
        'xhttp-opts': <String, Object?>{
          'path': s['path'],
          'host': s['host'],
          'mode': s['mode'],
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
