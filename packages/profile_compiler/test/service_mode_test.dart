import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workspaceId = 'a1111111111111111111111111111111';
const userId = 'b2222222222222222222222222222222';

final since = DateTime.utc(2026, 11, 26, 10, 15);

Map<String, Object?> modeJson([Map<String, Object?> extra = const {}]) => {
  'version': 1,
  'state': 'active',
  'since': since.toIso8601String(),
  ...extra,
};

Matcher invalid(String code) =>
    throwsA(isA<FormatException>().having((e) => e.message, 'code', code));

VlessInbound inbound(String server, String id, String name) => VlessInbound(
  serverId: server,
  spec: {
    ...VlessInbound.defaults(),
    'id': id,
    'name': name,
    'endpoint': '203.0.113.1',
    'sni': 'example.com',
    'target': 'example.com:443',
  },
);

Map<String, dynamic> confirmed(List<VlessInbound> resources) => {
  'observed': [
    for (final r in resources)
      {
        'id': r.id,
        'workspaceId': workspaceId,
        'spec': r.spec,
        'confirmed': true,
        'publicKey': 'server-public-key',
        'shortId': '0123456789abcdef',
        'clients': [
          {
            'id': userId,
            'enabled': true,
            'uuid': 'aaaaaaaa-aaaa-4aaa-8aaa-${r.id.substring(0, 12)}',
          },
        ],
      },
  ],
};

void main() {
  group('ServerServiceMode', () {
    test('round-trips its one canonical form', () {
      final mode = ServerServiceMode.fromJson(modeJson());
      expect(mode.state, ServerServiceState.active);
      expect(mode.since, since);
      expect(mode.toJson(), modeJson());
      expect(
        mode.withState(ServerServiceState.returning).toJson()['state'],
        'returning',
      );
      // A local time is stored as UTC.
      expect(
        ServerServiceMode(
          state: ServerServiceState.active,
          since: since.toLocal(),
        ),
        mode,
      );
    });

    test('rejects anything but the strict v1 record', () {
      for (final value in <Object?>[
        null,
        'active',
        modeJson({'version': 2}),
        modeJson({'state': 'paused'}),
        modeJson({'since': '2026-11-26T10:15:00'}),
        modeJson({'since': '2026-11-26T13:15:00+03:00'}),
        modeJson({'since': '2026-11-26T10:15:00Z'}),
        modeJson({'since': 'yesterday'}),
        modeJson({'since': 1}),
        modeJson({'note': 'extra'}),
        {'version': 1, 'state': 'active'},
      ]) {
        expect(
          () => ServerServiceMode.fromJson(value),
          invalid('vpn_service_mode_invalid'),
          reason: '$value',
        );
      }
    });
  });

  group('ServerServiceMode executor', () {
    const device = 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3';

    test('is kept only while returning', () {
      final returning = ServerServiceMode.fromJson(
        modeJson({'state': 'returning', 'executor': device}),
      );
      expect(returning.executor, device);
      expect(
        returning.toJson(),
        modeJson({'state': 'returning', 'executor': device}),
      );
      // Another executor is another record.
      expect(
        returning,
        isNot(returning.withState(ServerServiceState.returning)),
      );
      final active = returning.withState(
        ServerServiceState.active,
        executor: device,
      );
      expect(active.executor, isNull);
      expect(active.toJson(), modeJson());
    });

    test('rejects an executor that is not a device id or not returning', () {
      for (final value in <Object?>[
        modeJson({'executor': device}),
        modeJson({'state': 'returning', 'executor': 'device'}),
        modeJson({'state': 'returning', 'executor': null}),
        modeJson({'state': 'returning', 'executor': 1}),
        modeJson({'state': 'returning', 'executor': device.toUpperCase()}),
      ]) {
        expect(
          () => ServerServiceMode.fromJson(value),
          invalid('vpn_service_mode_invalid'),
          reason: '$value',
        );
      }
      expect(
        () => ServerServiceMode(
          state: ServerServiceState.active,
          since: since,
          executor: device,
        ),
        invalid('vpn_service_mode_invalid'),
      );
    });
  });

  group('VpnWorkspace service mode', () {
    final mode = ServerServiceMode.fromJson(modeJson());

    test('is encoded as version 6 only while a server is in it', () {
      final plain = VpnWorkspace(id: workspaceId);
      final plainJson = jsonDecode(plain.encode()) as Map;
      expect(plainJson['version'], 3);
      expect(plainJson.containsKey('serviceMode'), isFalse);

      final serviced = plain.copy(serviceMode: {'server-a': mode});
      final encoded = jsonDecode(serviced.encode()) as Map;
      expect(encoded['version'], 6);
      expect(encoded['serviceMode'], {'server-a': modeJson()});
      final decoded = VpnWorkspace.decode(serviced.encode());
      expect(decoded.serviceMode, {'server-a': mode});
      // Other copies keep it; an explicit empty map leaves service mode.
      expect(
        decoded
            .copy(
              users: [VpnUser(id: userId, login: 'a', name: 'A')],
            )
            .serviceMode,
        {'server-a': mode},
      );
      expect(decoded.copy(serviceMode: const {}).encode(), plain.encode());
    });

    test('old documents without the key still decode', () {
      for (final version in [1, 2, 3, 4, 5]) {
        final decoded = VpnWorkspace.decode(
          jsonEncode({
            'version': version,
            'id': workspaceId,
            'users': <Object?>[],
            'inbounds': <Object?>[],
            'servers': <String, Object?>{},
          }),
        );
        expect(decoded.serviceMode, isEmpty);
        expect(decoded.inServiceMode('server-a'), isFalse);
      }
      expect(
        () => VpnWorkspace.decode(
          jsonEncode({
            'version': 7,
            'id': workspaceId,
            'users': <Object?>[],
            'inbounds': <Object?>[],
            'servers': <String, Object?>{},
          }),
        ),
        invalid('vpn_version'),
      );
    });

    test('accepts any target form and keys only physical server ids', () {
      final workspace = VpnWorkspace(
        id: workspaceId,
        serviceMode: {'server-a': mode},
      );
      for (final target in ['server-a', 'awg/server-a', 'tt/server-a']) {
        expect(workspace.inServiceMode(target), isTrue, reason: target);
        expect(workspace.serviceModeOf(target), mode);
      }
      expect(workspace.inServiceMode('server-b'), isFalse);
      expect(workspace.serviceModeOf('awg/server-b'), isNull);

      for (final id in ['', 'awg/server-a', 'tt/server-a', 'bad\nid']) {
        expect(
          () => VpnWorkspace(id: workspaceId, serviceMode: {id: mode}),
          invalid('vpn_service_mode_invalid'),
          reason: id,
        );
      }
      for (final value in <Object?>[
        [],
        {'server-a': 'active'},
        {
          'server-a': modeJson({'state': 'gone'}),
        },
      ]) {
        expect(
          () => VpnWorkspace.decode(
            jsonEncode({
              'version': 6,
              'id': workspaceId,
              'users': <Object?>[],
              'inbounds': <Object?>[],
              'servers': <String, Object?>{},
              'serviceMode': value,
            }),
          ),
          invalid('vpn_service_mode_invalid'),
          reason: '$value',
        );
      }
    });
  });

  group('skipServiceMode', () {
    final one = inbound('one', '1' * 32, 'First');
    final two = inbound('two', '2' * 32, 'Second');
    final waiting = inbound('two', '3' * 32, 'Waiting');
    final user = VpnUser(id: userId, login: 'alice', name: 'Alice');
    VpnWorkspace workspace(Map<String, ServerServiceMode> serviceMode) =>
        VpnWorkspace(
          id: workspaceId,
          users: [user],
          inbounds: [one, two, waiting],
          // Server two has a resource its readback never confirmed.
          servers: {
            'one': confirmed([one]),
            'two': confirmed([two]),
          },
          serviceMode: serviceMode,
        );

    test('leaves the serviced server out before its pending state', () {
      final serviced = workspace({
        'two': ServerServiceMode(
          state: ServerServiceState.returning,
          since: since,
        ),
      });
      final pending = <ProfileAccessException>[];
      final accesses = vlessUserAccesses(
        serviced,
        userId,
        onPending: pending.add,
        skipServiceMode: true,
      );
      expect(pending, isEmpty);
      expect(accesses.map((a) => a.name), ['VLESS-Alice_one-First']);
      // Names of the remaining servers are the ones they had before.
      final before = vlessUserAccesses(
        workspace(const {}),
        userId,
        onPending: (_) {},
      );
      expect(before.map((a) => a.name), contains(accesses.single.name));
      expect(awgUserAccesses(serviced, userId, skipServiceMode: true), isEmpty);
      expect(ttUserAccesses(serviced, userId, skipServiceMode: true), isEmpty);
    });

    test('is off by default: connection checks still see every server', () {
      final serviced = workspace({
        'two': ServerServiceMode(
          state: ServerServiceState.active,
          since: since,
        ),
      });
      final pending = <ProfileAccessException>[];
      final accesses = vlessUserAccesses(
        serviced,
        userId,
        onPending: pending.add,
      );
      expect(accesses, hasLength(2));
      expect(pending.single.code, 'vpn_pending_readback');
    });
  });

  group('template groups naming hidden proxies', () {
    final one = inbound('one', '1' * 32, 'First');
    final two = inbound('two', '2' * 32, 'Second');
    final user = VpnUser(id: userId, login: 'alice', name: 'Alice');
    final workspace = VpnWorkspace(
      id: workspaceId,
      users: [user],
      inbounds: [one, two],
      servers: {
        'one': confirmed([one]),
        'two': confirmed([two]),
      },
      serviceMode: {
        'two': ServerServiceMode(
          state: ServerServiceState.active,
          since: since,
        ),
      },
    );
    const visible = 'VLESS-Alice_one-First', hidden = 'VLESS-Alice_two-Second';
    ProfileResult compile(String template) => const ProfileCompiler().compile(
      template: template,
      userId: userId,
      accesses: vlessUserAccesses(workspace, userId, skipServiceMode: true),
      hiddenProxies: serviceModeProxyNames(workspace, userId),
    );
    Map<String, Object?> group(ProfileResult result, String name) =>
        Map<String, Object?>.from(
          ((jsonDecode(jsonEncode(loadYaml(result.yaml!)))
                      as Map)['proxy-groups']
                  as List)
              .cast<Map>()
              .singleWhere((g) => g['name'] == name),
        );

    test('names only the proxies of servers in service mode', () {
      expect(serviceModeProxyNames(workspace, userId), {hidden});
      expect(
        serviceModeProxyNames(workspace.copy(serviceMode: const {}), userId),
        isEmpty,
      );
    });

    test('drop a hidden reference and keep an unknown one', () {
      for (final template in [
        jsonEncode({
          'proxies': <Object?>[],
          'proxy-groups': [
            {
              'name': 'Pick',
              'type': 'select',
              'proxies': [visible, hidden, 'Ghost'],
            },
          ],
          'rules': ['MATCH,Pick'],
        }),
        [
          'proxies: []',
          'proxy-groups:',
          '  - name: Pick',
          '    type: select',
          '    proxies:',
          '      - $visible',
          '      # The serviced server',
          '      - $hidden',
          '      - Ghost',
          'rules:',
          '  - MATCH,Pick',
          '',
        ].join('\n'),
      ]) {
        final result = compile(template);
        expect(result.hasBlockingErrors, isFalse, reason: template);
        expect(group(result, 'Pick')['proxies'], [visible, 'Ghost']);
        expect(result.yaml, isNot(contains(hidden)));
        expect(
          result.diagnostics.where((d) => d.code == 'unknown_proxy_reference'),
          hasLength(1),
        );
      }
    });

    test('a group left empty is a blocking error without YAML', () {
      final result = compile(
        jsonEncode({
          'proxies': <Object?>[],
          'proxy-groups': [
            {
              'name': 'Main',
              'type': 'select',
              'proxies': ['Only'],
            },
            {
              'name': 'Only',
              'type': 'select',
              'proxies': [hidden],
            },
          ],
          'rules': ['MATCH,Main'],
        }),
      );
      expect(result.hasBlockingErrors, isTrue);
      expect(result.yaml, isNull);
      expect(
        result.diagnostics
            .where((d) => d.severity == DiagnosticSeverity.error)
            .map((d) => (d.code, d.subject)),
        [('service_mode_group_empty', 'Only')],
      );
      // A group that still includes other proxies is not empty.
      final included = compile(
        jsonEncode({
          'proxies': <Object?>[],
          'proxy-groups': [
            {
              'name': 'Only',
              'type': 'select',
              'include-all-proxies': true,
              'proxies': [hidden],
            },
          ],
          'rules': ['MATCH,Only'],
        }),
      );
      expect(included.hasBlockingErrors, isFalse);
      expect(group(included, 'Only')['proxies'], isEmpty);
    });

    test('an unknown reference alone keeps its old warning', () {
      final result = compile(
        jsonEncode({
          'proxies': <Object?>[],
          'proxy-groups': [
            {
              'name': 'Only',
              'type': 'select',
              'proxies': ['Ghost'],
            },
          ],
          'rules': ['MATCH,Only'],
        }),
      );
      expect(result.hasBlockingErrors, isFalse);
      expect(group(result, 'Only')['proxies'], ['Ghost']);
    });
  });
}
