import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'support/fixtures.dart';

void main() {
  final templateFile = File('../../base.yml');
  final template = templateFile.readAsStringSync();
  const compiler = ProfileCompiler();
  ProfileResult preview(String source) =>
      compiler.preview(template: source, proxies: const []);
  Set<String> codes(ProfileResult result) =>
      result.diagnostics.map((d) => d.code).toSet();

  for (final entry in fixtureVariants().entries) {
    test(
      '${entry.key}: preserves template policy and deterministic output',
      () {
        final result = compiler.compile(
          template: template,
          userId: 'user-a',
          accesses: entry.value,
        );
        expect(result.yaml, isNotNull);
        final original = (loadYaml(template) as YamlMap)
            .cast<String, Object?>();
        final output = (loadYaml(result.yaml!) as YamlMap)
            .cast<String, Object?>();
        for (final key in original.keys.where((key) => key != 'proxies')) {
          expect(output[key], equals(original[key]), reason: key);
        }
        final repeated = compiler.compile(
          template: template,
          userId: 'user-a',
          accesses: entry.value.reversed.toList(),
        );
        expect(result.yaml, repeated.yaml);
        expect(result.sha256Hash, repeated.sha256Hash);
        expect(templateFile.readAsStringSync(), template);
        expect(result.coreValidation, VerificationStatus.notRun);
      },
    );
  }

  test('group preview preserves the actual base.yml filters and order', () {
    final nodes = fixtureVariants()['mixed_with_ru']!;
    final result = compiler.compile(
      template: template,
      userId: 'user-a',
      accesses: nodes,
    );
    final groups = {for (final g in result.groups) g.name: g};
    expect(groups['RemoteBalancer']!.members, [nodes[0].name]);
    expect(groups['WG_Auto']!.members, [nodes[2].name]);
    expect(groups['RuZone']!.members, [nodes[1].name]);
    expect(groups['Proxy_Chain']!.members, [
      'RemoteBalancer',
      ...nodes.map((n) => n.name).toList()..sort(),
    ]);
    expect(groups['SmartSelector']!.members, ['Proxy_Chain', 'RuZone']);
    expect(
      codes(result),
      containsAll(['chain_has_extra_nodes', 'unreferenced_group']),
    );
    expect(result.hasBlockingErrors, isFalse);
  });

  test('empty RU/WG groups warn without blocking profile issuance', () {
    final result = compiler.compile(
      template: template,
      userId: 'user-a',
      accesses: [fixtureNode('a', 'vless')],
    );
    expect(result.hasBlockingErrors, isFalse);
    expect(result.yaml, isNotNull);
    expect(codes(result), contains('empty_group_requires_policy'));
    expect(
      result.groups.singleWhere((g) => g.name == 'RuZone').fallback,
      'COMPATIBLE',
    );
    expect(
      result.groups.singleWhere((g) => g.name == 'WG_Auto').members,
      isEmpty,
    );
  });

  test('only active confirmed accesses of selected user are materialized', () {
    final result = compiler.compile(
      template: template,
      userId: 'user-a',
      accesses: [
        fixtureNode('own', 'trusttunnel'),
        fixtureNode('other', 'trusttunnel', user: 'user-b'),
        fixtureNode('disabled', 'vless', active: false),
        fixtureNode('pending', 'vless', confirmed: false),
      ],
    );
    expect((loadYaml(result.yaml!) as Map)['proxies'], hasLength(1));
    expect(result.yaml, contains('fixture-user-a'));
    expect(result.yaml, isNot(contains('user-b')));
    expect(result.yaml, isNot(contains('pending')));
    expect(result.toString(), isNot(contains('fixture-password')));
  });

  test('an existing proxy collection is preserved with a warning', () {
    final result = compiler.compile(
      template:
          'proxies: [{name: old, type: socks5, server: example.com, port: 1080}]',
      userId: 'user-a',
      accesses: [fixtureNode('a', 'vless')],
    );
    expect(codes(result), contains('base_contains_proxies'));
    expect(result.hasBlockingErrors, isFalse);
    final proxies = (loadYaml(result.yaml!) as Map)['proxies'] as List;
    expect(proxies, hasLength(2));
    expect(proxies.first['name'], 'old');
    expect(proxies.first['type'], 'socks5');
    expect(proxies.last['type'], 'vless');
  });

  for (final input in [
    'a: 1\na: 2',
    'proxies: [',
    'a: !!str test',
    'a: &a [*a]',
    '---\na: 1\n---\nb: 2',
  ]) {
    test(
      'rejects unsafe or ambiguous YAML without leaking excerpts: ${input.length}',
      () {
        final result = preview(input);
        expect(result.hasBlockingErrors, isTrue);
        expect(result.yaml, isNull);
        expect(result.diagnostics.first.code, isNot(contains(input)));
      },
    );
  }

  test('enforces byte and depth limits before materialization', () {
    expect(
      codes(preview('a: ${'x' * 262144}')),
      contains('template_size_limit'),
    );
    expect(
      codes(preview('a: ${'[' * 34}0${']' * 34}')),
      contains('template_depth_limit'),
    );
  });

  test('detects cycles, unknown rule destinations and provider references', () {
    final result = preview('''
proxy-groups:
 - {name: A, type: select, proxies: [B]}
 - {name: B, type: select, proxies: [A]}
rules: ["MATCH,missing", "RULE-SET,missing,A"]
''');
    expect(result.hasBlockingErrors, isFalse);
    expect(
      codes(result),
      containsAll([
        'group_cycle',
        'unknown_rule_target',
        'unknown_rule_provider',
      ]),
    );
  });

  test(
    'complex filters and unresolved providers never claim an exact preview',
    () {
      final result = preview('''
proxy-groups:
 - {name: A, type: select, include-all-proxies: true, filter: "(a+)+"}
 - {name: B, type: select, use: [remote]}
proxy-providers:
 remote: {type: http, url: "https://example.com/nodes.yml"}
''');
      expect(result.groups.every((g) => !g.complete), isTrue);
      expect(result.hasBlockingErrors, isFalse);
      expect(
        codes(result),
        containsAll([
          'unsupported_filter_preview',
          'provider_snapshot_required',
        ]),
      );
    },
  );

  test(
    'include filter does not remove explicit group references; exclusions do',
    () {
      final result = preview('''
proxy-groups:
 - {name: A, type: select, proxies: [DIRECT], include-all-proxies: true, filter: "WG"}
 - {name: B, type: select, proxies: [DIRECT], exclude-type: Direct}
''');
      expect(result.groups.first.members, ['DIRECT']);
      expect(result.groups.last.members, isEmpty);
    },
  );

  test('unsupported base options are retained and never gate generation', () {
    for (final source in [
      'proxy-groups: [{name: G, type: relay, proxies: [DIRECT]}]',
      'proxy-groups: [{name: G, type: select, filter: "(a+)+", include-all-proxies: true}]',
      'proxy-groups: [{name: G, type: select, use: [remote]}]',
      'rules: ["AND,((NETWORK,UDP),(DST-PORT,443)),REJECT"]',
      'proxy-groups: {}',
      'dns: {nameserver-policy: [unknown]}',
    ]) {
      final result = compiler.compile(
        template: source,
        userId: 'user-a',
        accesses: [fixtureNode('a', 'vless')],
      );
      expect(result.hasBlockingErrors, isFalse, reason: source);
      expect(result.diagnostics, isNotEmpty, reason: source);
      final output = loadYaml(result.yaml!) as Map;
      for (final entry in (loadYaml(source) as Map).entries) {
        expect(output[entry.key], entry.value, reason: source);
      }
    }
  });

  test('unsupported protocols and invalid VLESS combinations are rejected', () {
    final base = fixtureNode('a', 'vless');
    for (final changes in [
      {'type': 'vmess'},
      {'network': 'xhttp'},
      {'server': '::'},
      {'port': 0},
      {'skip-cert-verify': true},
    ]) {
      final node = PreparedProxy(
        identity: base.identity,
        fields: {...base.fields, ...changes},
      );
      expect(
        compiler
            .compile(template: template, userId: 'user-a', accesses: [node])
            .yaml,
        isNull,
      );
    }
  });
}
