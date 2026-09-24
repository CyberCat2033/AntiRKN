import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/src/profile_yaml.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final nodes = [
    {
      'uuid': 'test-only',
      'network': 'xhttp',
      'port': 443,
      'type': 'vless',
      'name': 'example',
      'server': '192.0.2.1',
      'tls': true,
      'flow': '',
      'xhttp-opts': {'mode': 'auto', 'path': '/test'},
      'future-z': 1,
      'future-a': 2,
    },
    {
      'public-key': 'test-only',
      'type': 'wireguard',
      'private-key': 'test-only',
      'name': 'WG',
      'server': '192.0.2.2',
      'port': 51820,
      'ip': '10.0.0.2',
    },
    {
      'password': 'test-only',
      'username': 'test',
      'port': 443,
      'server': '192.0.2.3',
      'type': 'trusttunnel',
      'name': 'TT',
    },
  ];
  for (final source in [
    'proxies: []\nrules: ["MATCH,DIRECT"]\n',
    '{"proxies":[],"rules":["MATCH,DIRECT"]}',
  ]) {
    test('ordered blocks with one separator; root style: ${source[0]}', () {
      final before = canonicalJson(nodes);
      final output = writeProfileYaml(source, nodes);
      expect(
        writeProfileYamlPrepared(source, nodes, prepareProfileYaml(source)),
        output,
      );
      final root = loadYaml(output) as Map;
      final proxies = root['proxies'] as List;
      expect(proxies, nodes);
      expect(canonicalJson(nodes), before);
      expect((proxies[0] as Map).keys, [
        'name',
        'type',
        'server',
        'port',
        'uuid',
        'flow',
        'tls',
        'network',
        'xhttp-opts',
        'future-z',
        'future-a',
      ]);
      expect((proxies[1] as Map).keys.take(3), ['name', 'type', 'private-key']);
      expect((proxies[2] as Map).keys, [
        'name',
        'type',
        'server',
        'port',
        'username',
        'password',
      ]);
      expect(RegExp(r'\n\n\s*- name:').allMatches(output), hasLength(2));
      expect(output, isNot(contains('\n\n\n')));
      expect(root['rules'], ['MATCH,DIRECT']);
    });
  }
  test(
    'static comments, quoted hash and multiline scalars survive ordering',
    () {
      const source = '''# Root heading
proxies:
  # Saved entry
  - password: "test#not-comment" # Password description
    note: |+
      first
      # scalar text

    name: static
    type: http
    server: example.com
    port: 443
# Rules heading
rules: ["MATCH,DIRECT"]
''';
      final original = loadYaml(source) as Map;
      final output = writeProfileYaml(source, [
        ...(original['proxies'] as List),
        ...nodes,
      ]);
      expect(
        writeProfileYamlPrepared(source, [
          ...(original['proxies'] as List),
          ...nodes,
        ], prepareProfileYaml(source)),
        output,
      );
      expect((loadYaml(output) as Map)['proxies'][0], original['proxies'][0]);
      for (final comment in [
        '# Root heading',
        '# Saved entry',
        '# Password description',
        '# Rules heading',
      ]) {
        expect(comment.allMatches(output), hasLength(1), reason: comment);
      }
      expect(output, contains('test#not-comment'));
    },
  );
}
