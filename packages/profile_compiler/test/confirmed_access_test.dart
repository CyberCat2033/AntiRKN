import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:test/test.dart';

const workspaceId = 'a1111111111111111111111111111111';
const userId = 'b2222222222222222222222222222222';
const serverId = 'server';

VpnUser get user => VpnUser(id: userId, login: 'alice', name: 'Alice');

Map<String, dynamic> serverRecord(
  String resourceId,
  Map<String, Object?> spec,
  Map<String, Object?> client,
) => {
  'pending': {'id': 'c3333333333333333333333333333333'},
  'error': 'vpn_connection',
  'observed': [
    {
      'id': resourceId,
      'workspaceId': workspaceId,
      'spec': spec,
      'confirmed': true,
      'publicKey': 'server-public-key',
      'shortId': '0123456789abcdef',
      'headerProtectionKey': 'header-protection-key',
      'clients': [client],
    },
  ],
};

void main() {
  test(
    'confirmed VLESS remains issuable while another server job is pending',
    () {
      final resource = VlessInbound(
        serverId: serverId,
        spec: {
          ...VlessInbound.defaults(),
          'id': 'd4444444444444444444444444444444',
          'name': 'VLESS',
          'endpoint': '203.0.113.1',
          'sni': 'example.com',
          'target': 'example.com:443',
        },
      );
      final workspace = VpnWorkspace(
        id: workspaceId,
        users: [user],
        inbounds: [resource],
        servers: {
          serverId: serverRecord(resource.id, resource.spec, {
            'id': userId,
            'enabled': true,
            'uuid': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          }),
        },
      );

      expect(vlessUserAccesses(workspace, userId), hasLength(1));
    },
  );

  test(
    'confirmed AWG remains issuable while another server job is pending',
    () {
      final resource = AwgInterface(
        serverId: serverId,
        spec: {
          'id': 'e5555555555555555555555555555555',
          'name': 'AWG',
          'enabled': true,
          'deleted': false,
          'endpoint': '203.0.113.1',
          'port': 51820,
          'externalPort': 51820,
          'pool': '10.10.0.0/20',
          'pool6': '',
          'mtu': 1280,
          'keepalive': 25,
          'options': {
            for (final entry in awgOptionRules.entries)
              entry.key as String: entry.value['default'],
          },
        },
      );
      final workspace = VpnWorkspace(
        id: workspaceId,
        users: [user],
        awgInterfaces: [resource],
        servers: {
          awgTarget(serverId): serverRecord(resource.id, resource.spec, {
            'id': userId,
            'enabled': true,
            'address': '10.10.0.2',
            'privateKey': 'client-private-key',
            'presharedKey': 'client-preshared-key',
          }),
        },
      );

      expect(awgUserAccesses(workspace, userId), hasLength(1));
    },
  );

  test('confirmed TT remains issuable while another server job is pending', () {
    final resource = TrustTunnelEndpoint(
      serverId: serverId,
      spec: {
        'id': 'f6666666666666666666666666666666',
        'name': 'TT',
        'enabled': true,
        'deleted': false,
        'listen': '0.0.0.0',
        'port': 443,
        'endpoint': '203.0.113.1',
        'externalPort': 443,
        'domain': 'vpn.example.com',
        'certificateId': '07777777777777777777777777777777',
        'quic': false,
        'ipv6': false,
        'allowPrivate': false,
        'outbound': 'direct',
        'socksAddress': '127.0.0.1:1080',
        'rotation': 0,
      },
    );
    final workspace = VpnWorkspace(
      id: workspaceId,
      users: [user],
      ttEndpoints: [resource],
      servers: {
        ttTarget(serverId): serverRecord(resource.id, resource.spec, {
          'id': userId,
          'enabled': true,
          'username': 'alice',
          'password': 'client-password',
        }),
      },
    );

    expect(ttUserAccesses(workspace, userId), hasLength(1));
  });

  test('a pending resource without exact readback still blocks issuance', () {
    final resource = VlessInbound(
      serverId: serverId,
      spec: {
        ...VlessInbound.defaults(),
        'id': '18888888888888888888888888888888',
        'name': 'VLESS',
        'endpoint': '203.0.113.1',
        'sni': 'example.com',
        'target': 'example.com:443',
      },
    );
    final changed = {...resource.spec, 'externalPort': 8443};
    final workspace = VpnWorkspace(
      id: workspaceId,
      users: [user],
      inbounds: [resource],
      servers: {
        serverId: serverRecord(resource.id, changed, {
          'id': userId,
          'enabled': true,
          'uuid': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        }),
      },
    );

    expect(
      () => vlessUserAccesses(workspace, userId),
      throwsA(
        isA<ProfileAccessException>()
            .having((error) => error.code, 'code', 'vpn_pending_settings')
            .having(
              (error) => error.subject,
              'subject',
              'VLESS · server · VLESS',
            ),
      ),
    );
  });

  test('pending callback reports every affected VLESS resource', () {
    final first = VlessInbound(
      serverId: serverId,
      spec: {
        ...VlessInbound.defaults(),
        'id': '18888888888888888888888888888888',
        'name': 'First',
        'endpoint': '203.0.113.1',
        'sni': 'example.com',
        'target': 'example.com:443',
      },
    );
    final second = VlessInbound(
      serverId: serverId,
      spec: {
        ...VlessInbound.defaults(),
        'id': '28888888888888888888888888888888',
        'name': 'Second',
        'endpoint': '203.0.113.2',
        'sni': 'example.com',
        'target': 'example.com:443',
      },
    );
    final issues = <ProfileAccessException>[];
    final accesses = vlessUserAccesses(
      VpnWorkspace(id: workspaceId, users: [user], inbounds: [first, second]),
      userId,
      serverNames: {serverId: 'NL'},
      onPending: issues.add,
    );

    expect(accesses, isEmpty);
    expect(issues.map((issue) => issue.code), [
      'vpn_pending_readback',
      'vpn_pending_readback',
    ]);
    expect(issues.map((issue) => issue.subject), [
      'VLESS · NL · First',
      'VLESS · NL · Second',
    ]);
  });
}
