import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:test/test.dart';

VlessInbound resource({bool internal = false, Map<String, Object?>? xhttp}) =>
    VlessInbound(
      serverId: 'server',
      spec: {
        ...VlessInbound.defaults(),
        'id': 'a' * 32,
        'name': 'XHTTP',
        'internal': internal,
        'endpoint': '203.0.113.1',
        'sni': 'example.com',
        'target': 'example.com:443',
        'transport': 'xhttp',
        'fingerprint': 'firefox',
        'xhttp': ?xhttp,
      },
    );
VpnWorkspace workspace(VlessInbound r) => VpnWorkspace(
  id: 'b' * 32,
  users: [VpnUser(id: 'c' * 32, login: 'alice', name: 'alice')],
  inbounds: [r],
  servers: {
    'server': {
      'observed': [
        {
          'id': r.id,
          'workspaceId': 'b' * 32,
          'spec': r.spec,
          'confirmed': true,
          'publicKey': 'A' * 43,
          'shortId': '0123456789abcdef',
          'clients': [
            {
              'id': 'c' * 32,
              'enabled': true,
              'uuid': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            },
          ],
        },
      ],
    },
  },
);

void main() {
  test('XMUX and shared XHTTP fields export using Mihomo names', () {
    final r = resource(
      xhttp: {
        'xmux': {
          'maxConnections': '2-3',
          'hKeepAlivePeriod': 30,
          'hMaxRequestTimes': '600-900',
        },
        'xPaddingBytes': '200-400',
        'sessionIDPlacement': 'header',
        'sessionIDKey': 'X-Session',
        'headers': {'X-Test': 'yes'},
        'noSSEHeader': true,
        'scMaxBufferedPosts': 30,
      },
    );
    final restored = VpnWorkspace.decode(workspace(r).encode());
    final access = vlessUserAccesses(restored, 'c' * 32).single;
    expect(access.fields['client-fingerprint'], 'firefox');
    final options = access.fields['xhttp-opts'] as Map;
    expect(options['reuse-settings'], {
      'max-connections': '2-3',
      'h-keep-alive-period': 30,
      'h-max-request-times': '600-900',
    });
    expect(options['x-padding-bytes'], '200-400');
    expect(options['session-placement'], 'header');
    expect(options['headers'], {'X-Test': 'yes'});
    expect(options.containsKey('noSSEHeader'), isFalse);
    expect(options.containsKey('sc-max-buffered-posts'), isFalse);
  });
  test(
    'internal inbounds never enter client YAML even with an old observed binding',
    () {
      final r = resource(internal: true);
      final w = workspace(r);
      expect(r.enabled, isTrue);
      expect(vlessUserAccesses(w, 'c' * 32), isEmpty);
      expect(VpnWorkspace.decode(w.encode()).inbounds.single.internal, isTrue);
      expect(
        (w.desired('server', 'd' * 32)['resources'] as List).single['internal'],
        isTrue,
      );
    },
  );
  test(
    'legacy documents and invalid XHTTP settings are handled explicitly',
    () {
      final base = resource();
      final legacy = {...base.spec}..remove('internal');
      expect(VlessInbound(serverId: 'server', spec: legacy).internal, isFalse);
      for (final extra in <Map<String, Object?>>[
        {
          'xmux': {'maxConnections': '2', 'maxConcurrency': '4'},
        },
        {
          'xmux': {'hMaxReusableSecs': '30-10'},
        },
        {
          'headers': {'Host': 'example.com'},
        },
        {
          'headers': {'X-Test': 'bad\r\nInjected: yes'},
        },
        {'uplinkHTTPMethod': 'GET'},
        {'arbitrary': true},
      ]) {
        expect(() => resource(xhttp: extra), throwsFormatException);
      }
    },
  );
}
