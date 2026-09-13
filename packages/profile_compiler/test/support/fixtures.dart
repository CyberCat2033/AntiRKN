import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';

// Public, non-operational test values. They never describe an administered VPS.
PreparedProxy fixtureNode(
  String id,
  String type, {
  String user = 'user-a',
  bool ru = false,
  bool active = true,
  bool confirmed = true,
}) {
  const testKey = 'KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKio=';
  final name = '${type == 'wireguard' ? 'WG' : type}_${id}_${ru ? 'RU' : 'EU'}';
  return PreparedProxy(
    identity: AccessIdentity(
      id: id,
      userId: user,
      active: active,
      confirmed: confirmed,
    ),
    fields: {
      'name': name,
      'type': type,
      'server': '192.0.2.1',
      'port': 443,
      if (type == 'vless') ...{
        'uuid': '00000000-0000-4000-8000-000000000001',
        'tls': true,
        'network': 'tcp',
        'flow': 'xtls-rprx-vision',
        'servername': 'example.com',
        'client-fingerprint': 'chrome',
        'reality-opts': {
          'public-key': testKey.substring(0, 43),
          'short-id': '0123456789abcdef',
        },
      },
      if (type == 'trusttunnel') ...{
        'username': 'fixture-$user',
        'password': 'fixture-password-$user-not-for-use',
      },
      if (type == 'wireguard') ...{
        'private-key': testKey,
        'public-key': testKey,
        'ip': '10.42.0.2',
        'udp': true,
        'amnezia-wg-option': {
          'jc': 4,
          'jmin': 40,
          'jmax': 70,
          's1': 0,
          's2': 0,
          'h1': 1,
          'h2': 2,
          'h3': 3,
          'h4': 4,
        },
      },
    },
  );
}

Map<String, List<PreparedProxy>> fixtureVariants() => {
  'vless_only': [fixtureNode('a', 'vless')],
  'trusttunnel_only': [fixtureNode('a', 'trusttunnel')],
  'awg_only': [fixtureNode('a', 'wireguard')],
  'mixed_with_ru': [
    fixtureNode('a', 'vless'),
    fixtureNode('b', 'trusttunnel', ru: true),
    fixtureNode('c', 'wireguard'),
  ],
  'mixed_without_ru': [
    fixtureNode('a', 'vless'),
    fixtureNode('b', 'trusttunnel'),
    fixtureNode('c', 'wireguard'),
  ],
  'without_wg': [
    fixtureNode('a', 'vless'),
    fixtureNode('b', 'trusttunnel', ru: true),
  ],
};
