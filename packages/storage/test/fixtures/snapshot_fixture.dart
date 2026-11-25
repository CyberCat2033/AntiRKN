import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';

/// Synthetic data shaped like a real workspace: several servers, every
/// protocol, 100+ clients with server-derived credentials and compiled YAML.
/// Values are generated placeholders; nothing here comes from a real account.
final class SyntheticWorkspace {
  SyntheticWorkspace(this.workspaceId, this.serverIds, this.userIds);
  final String workspaceId;
  final List<String> serverIds, userIds;
}

/// A namespace kept from an independently created workspace (server 1 VLESS
/// and client 1): writes never replace it, so it is set at creation.
const syntheticForeignNamespace = 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';

String _hex(int seed, [int length = 32]) {
  final buffer = StringBuffer();
  var value = seed * 2654435761 + 97;
  while (buffer.length < length) {
    value = (value * 1103515245 + 12345) & 0x7fffffff;
    buffer.write(value.toRadixString(16));
  }
  return buffer.toString().substring(0, length);
}

String _yaml(String login, int servers) {
  final proxies = [
    for (var s = 0; s < servers; s++) ...[
      '  - name: vless-$s\n    type: vless\n    server: 203.0.113.${s + 1}\n'
          '    port: 443\n    uuid: ${_hex(s * 7 + login.length, 36)}\n'
          '    network: tcp\n    tls: true\n    servername: example.com\n'
          '    reality-opts:\n      public-key: ${_hex(s + 3, 43)}\n'
          '      short-id: ${_hex(s + 5, 8)}\n',
      '  - name: awg-$s\n    type: wireguard\n    server: 203.0.113.${s + 1}\n'
          '    port: 51820\n    private-key: ${_hex(s + 11, 44)}\n'
          '    public-key: ${_hex(s + 13, 44)}\n'
          '    pre-shared-key: ${_hex(s + 17, 44)}\n    ip: 10.10.0.$s/32\n',
      '  - name: tt-$s\n    type: trusttunnel\n    server: vpn$s.example.com\n'
          '    port: 8443\n    username: $login\n    password: ${_hex(s + 19, 24)}\n',
    ],
  ].join();
  return 'mixed-port: 7890\nmode: rule\nproxies:\n$proxies'
      'proxy-groups:\n  - name: auto\n    type: url-test\n'
      'rules:\n  - MATCH,auto\n# client $login\n';
}

Future<SyntheticWorkspace> fillSyntheticWorkspace(
  WorkspaceDatabase db, {
  int clients = 120,
  int servers = 3,
}) async {
  final workspaceId = (await db.readWorkspaceIdentity()).workspaceId;
  final serverIds = <String>[];
  for (var s = 0; s < servers; s++) {
    final id = db.newServerId();
    serverIds.add(id);
    await (await db.openServer(id)).saveProfile(
      SshProfile(
        id: id,
        name: 'Server $s',
        host: 'server$s.example',
        port: 22,
        username: 'admin',
        authMethod: SshAuthMethod.password,
        hostKey: TrustedHostKey('ssh-ed25519', 'SHA256:${_hex(s, 43)}'),
        secrets: {ServerSecret.sshPassword: _hex(s + 101, 24)},
        lastInfo: ServerInfo(
          os: 'Ubuntu 24.04 LTS',
          architecture: 'x86_64',
          observedAt: DateTime.utc(2026, 11, 1),
        ),
      ),
    );
  }
  await db.writeDraft(
    'mixed-port: 7890\nmode: rule\nrules:\n  - MATCH,DIRECT\n${'# shared\n' * 40}',
  );
  final userIds = [for (var u = 0; u < clients; u++) _hex(u + 1000)];
  final users = [
    for (var u = 0; u < clients; u++)
      VpnUser(id: userIds[u], login: 'client$u', name: 'Client $u'),
  ];
  final inbounds = <VlessInbound>[];
  final awg = <AwgInterface>[];
  final tt = <TrustTunnelEndpoint>[];
  final records = <String, Map<String, dynamic>>{};
  for (var s = 0; s < servers; s++) {
    final serverId = serverIds[s];
    final vlessId = _hex(s + 200), awgId = _hex(s + 300), ttId = _hex(s + 400);
    inbounds.add(
      VlessInbound(
        serverId: serverId,
        spec: {
          ...VlessInbound.defaults(),
          'id': vlessId,
          'endpoint': '203.0.113.${s + 1}',
          'sni': 'example.com',
          'target': 'example.com:443',
        },
      ),
    );
    awg.add(
      AwgInterface(
        serverId: serverId,
        spec: {
          'id': awgId,
          'name': 'AWG',
          'enabled': true,
          'deleted': false,
          'endpoint': '203.0.113.${s + 1}',
          'port': 51820,
          'externalPort': 51820,
          'pool': '10.10.0.0/20',
          'pool6': '',
          'mtu': 1280,
          'keepalive': 25,
          'options': {
            for (final e in awgOptionRules.entries)
              e.key as String: e.value['default'],
          },
        },
      ),
    );
    tt.add(
      TrustTunnelEndpoint(
        serverId: serverId,
        spec: {
          'id': ttId,
          'name': 'TT',
          'enabled': true,
          'deleted': false,
          'listen': '0.0.0.0',
          'port': 8443,
          'endpoint': '203.0.113.${s + 1}',
          'externalPort': 8443,
          'domain': 'vpn$s.example.com',
          'certificateId': _hex(s + 500),
          'quic': false,
          'ipv6': false,
          'allowPrivate': false,
          'outbound': 'direct',
          'socksAddress': '127.0.0.1:1080',
          'rotation': 0,
        },
      ),
    );
    // Runner journals and VPN records name a server by host and pinned key.
    final identity = 'server$s.example|SHA256:${_hex(s, 43)}';
    Map<String, dynamic> record(String resource, List<Object?> clients) {
      final payload = jsonEncode({'resources': resource, 'users': userIds});
      return {
        'identity': identity,
        'panelId': _hex(s + 600),
        'resourceWorkspaceId': s == 1 && resource == vlessId
            ? syntheticForeignNamespace
            : workspaceId,
        'observed': [
          {
            'id': resource,
            'workspaceId': workspaceId,
            'confirmed': true,
            'revision': _hex(s + 700, 64),
            'clients': clients,
          },
        ],
        'verifiedAt': '2026-11-20T10:00:00.000Z',
        'authorizedPayload': payload,
        'appliedPayload': payload,
        'job': {'id': _hex(s + 800), 'status': 'succeeded'},
        'paused': false,
        'error': null,
      };
    }

    records[serverId] = record(vlessId, [
      for (var u = 0; u < clients; u++)
        {'id': userIds[u], 'enabled': true, 'uuid': _hex(u * 31 + s, 36)},
    ]);
    records[awgTarget(serverId)] = record(awgId, [
      for (var u = 0; u < clients; u++)
        {
          'id': userIds[u],
          'enabled': true,
          'privateKey': _hex(u * 37 + s, 44),
          'publicKey': _hex(u * 41 + s, 44),
          'presharedKey': _hex(u * 43 + s, 44),
          'address': '10.10.${u ~/ 250}.${u % 250 + 2}/32',
        },
    ]);
    records[ttTarget(serverId)] = record(ttId, [
      for (var u = 0; u < clients; u++)
        {
          'id': userIds[u],
          'enabled': true,
          'login': 'client$u',
          'password': _hex(u * 47 + s, 24),
        },
    ]);
    await db.writeRunnerJournal(
      serverId,
      jsonEncode({
        'version': 1,
        'identity': identity,
        'pending': null,
        'selected': {
          'id': _hex(s + 900),
          'kind': 'vless_apply',
          'status': 'succeeded',
          'sequence': 12,
          'events': <Object>[],
        },
        'cursor': 12,
        'egress': {
          'mode': 'direct',
          'addresses': List.filled(4, '203.0.113.9'),
        },
        'panelDiscovery': {
          'panels': [
            {'port': 2053, 'path': '/${_hex(s + 950, 12)}'},
          ],
        },
        'panelAccess': {
          'id': _hex(s + 600),
          'port': 2053,
          'username': 'panel',
          'password': _hex(s + 990, 24),
        },
        'panelVerifiedAt': '2026-11-20T10:00:00.000Z',
      }),
    );
  }
  final vpn = VpnWorkspace(
    id: workspaceId,
    users: users,
    inbounds: inbounds,
    awgInterfaces: awg,
    ttEndpoints: tt,
    servers: records,
    profiles: {
      for (var u = 0; u < clients; u++)
        userIds[u]: {
          'hash': _hex(u + 5000, 64),
          'yaml': _yaml('client$u', servers),
          'at': '2026-11-20T10:00:00.000Z',
          'publicationWorkspaceId': u == 1
              ? syntheticForeignNamespace
              : workspaceId,
        },
    },
  );
  await db.writeVpn(vpn.encode(), expectedRevision: 0);
  await db.writePublicationDocument(
    'settings',
    jsonEncode(
      PublicationSettings(
        accountKey: 'synthetic-account',
        folderId: 'synthetic-folder',
        folderName: 'Profiles',
        enabled: true,
        access: PublicationAccess.link,
      ).toJson(),
    ),
    expectedSource: null,
  );
  for (var u = 0; u < clients; u++) {
    final id = userIds[u];
    if (u % 10 == 0) {
      await db.writePublicationDocument(
        'binding/$id',
        jsonEncode({
          'version': 1,
          'id': _hex(u + 7000),
          'workspaceId': workspaceId,
          'userId': id,
          'accountKey': 'synthetic-account',
          'fileId': 'file${_hex(u + 8000, 28)}',
          'etag': '"etag$u"',
          'hash': _hex(u + 9000, 64),
          'access': 'link',
        }),
        expectedSource: null,
      );
    }
    await db.writePublicationDocument(
      'result/$id',
      jsonEncode({
        'version': 1,
        'fileId': 'file${_hex(u + 8000, 28)}',
        'registryId': 'registry${_hex(1, 24)}',
        'head': _hex(u + 6000),
        'hash': _hex(u + 5000, 64),
        'executor': _hex(1),
        'access': 'link',
        'url': 'https://drive.google.com/uc?id=file${_hex(u + 8000, 28)}',
        'permissionId': 'anyoneWithLink',
        'etag': '"etag$u"',
      }),
      expectedSource: null,
    );
  }
  return SyntheticWorkspace(workspaceId, serverIds, userIds);
}
