import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

import 'prepared_proxy.dart';
import 'safe_yaml.dart';
import 'profile_yaml.dart';

final class ProxyDescriptor {
  const ProxyDescriptor(this.name, this.type);
  final String name;

  /// Mihomo runtime spelling, used by exclude-type.
  final String type;
}

final class GroupPreview {
  GroupPreview({
    required this.name,
    required List<String> members,
    required this.fallback,
    required this.complete,
  }) : members = List.unmodifiable(members);
  final String name;
  final List<String> members;
  final String? fallback;
  final bool complete;
}

final class ProfileResult {
  ProfileResult({
    required List<GroupPreview> groups,
    required List<ProfileDiagnostic> diagnostics,
    this.yaml,
    this.sha256Hash,
  }) : groups = List.unmodifiable(groups),
       diagnostics = List.unmodifiable(diagnostics);
  final String? yaml;
  final String? sha256Hash;
  final List<GroupPreview> groups;
  final List<ProfileDiagnostic> diagnostics;
  bool get hasBlockingErrors =>
      diagnostics.any((d) => d.severity == DiagnosticSeverity.error);
  VerificationStatus get coreValidation => VerificationStatus.notRun;
  VerificationStatus get connectionValidation => VerificationStatus.notRun;

  @override
  String toString() =>
      'ProfileResult(<redacted>, ${diagnostics.length} diagnostics)';
}

/// Stateless, shared by the GUI and command-line/integration probes.
final class ProfileCompiler {
  const ProfileCompiler();
  static const version = '0.3.0';
  static const targetCore = 'mihomo-v1.19.30';

  ProfileResult preview({
    required String template,
    required List<ProxyDescriptor> proxies,
  }) => _run(template, proxies, null);

  ProfileResult compile({
    required String template,
    required String userId,
    required List<PreparedProxy> accesses,
  }) {
    try {
      final selected = accesses
          .where(
            (a) =>
                a.identity.userId == userId &&
                a.identity.active &&
                a.identity.confirmed,
          )
          .toList();
      final ids = <String>{};
      for (final node in selected) {
        node.validate();
        if (!ids.add(node.identity.id)) {
          throw const FormatException('duplicate_access_id');
        }
      }
      selected.sort((a, b) => a.identity.id.compareTo(b.identity.id));
      return _run(template, [
        for (final node in selected) ProxyDescriptor(node.name, node.typeLabel),
      ], selected);
    } on FormatException catch (e) {
      return _failure(e.message);
    }
  }

  ProfileResult _run(
    String template,
    List<ProxyDescriptor> proxies,
    List<PreparedProxy>? selected,
  ) {
    try {
      final root = parseTemplate(template);
      final existing = root['proxies'] ?? <Object?>[];
      if (existing is! List) return _failure('invalid_proxies');
      if (proxies.length + existing.length > 5000) {
        return _failure('template_node_limit');
      }
      String? yaml;
      if (selected != null) {
        yaml = writeProfileYaml(template, [
          ...existing,
          for (final node in selected) node.fields,
        ]);
      }
      final diagnostics = <ProfileDiagnostic>[];
      void warn(String code, [String? subject]) => diagnostics.add(
        ProfileDiagnostic(code, DiagnosticSeverity.warning, subject: subject),
      );
      final descriptors = [...proxies];
      if (existing.isNotEmpty) {
        warn('base_contains_proxies');
        for (final value in existing) {
          if (value is Map && value['name'] is String) {
            descriptors.add(
              ProxyDescriptor(value['name'] as String, switch (value['type']) {
                'vless' => 'VLESS',
                'trusttunnel' => 'TrustTunnel',
                'wireguard' => 'WireGuard',
                _ => value['type'] is String ? value['type'] as String : '',
              }),
            );
          } else {
            warn('invalid_proxies');
          }
        }
      }
      var previews = <GroupPreview>[];
      try {
        previews = _inspect(root, descriptors, warn);
      } on FormatException catch (e) {
        // Preview limitations never prevent issuing a parseable base profile.
        warn(e.message);
      }
      return ProfileResult(
        groups: previews,
        diagnostics: diagnostics,
        yaml: yaml,
        sha256Hash: yaml == null
            ? null
            : sha256.convert(utf8.encode(yaml)).toString(),
      );
    } on YamlException {
      // Parser exceptions include source excerpts. Never forward them to UI/logs.
      return _failure('invalid_yaml');
    } on FormatException catch (e) {
      return _failure(e.message);
    }
  }

  List<GroupPreview> _inspect(
    Map<String, Object?> root,
    List<ProxyDescriptor> proxies,
    void Function(String, [String?]) warn,
  ) {
    final names = <String>{..._builtins};
    final types = <String, String>{
      for (final n in _builtins)
        n: n == 'DIRECT' || n == 'COMPATIBLE' ? 'Direct' : 'Reject',
    };
    for (final proxy in proxies) {
      if (proxy.name.isEmpty || !names.add(proxy.name)) {
        warn('duplicate_proxy_name', proxy.name);
      }
      if (!{'VLESS', 'TrustTunnel', 'WireGuard'}.contains(proxy.type)) {
        warn('unsupported_proxy_type', proxy.name);
      }
      types[proxy.name] = proxy.type;
    }
    final rawGroups = root['proxy-groups'] ?? <Object?>[];
    if (rawGroups is! List) throw const FormatException('invalid_proxy_groups');
    if (rawGroups.length > 512 || proxies.length > 5000) {
      throw const FormatException('template_node_limit');
    }
    final groups = <String, Map<String, Object?>>{};
    final providers = _mapping(root['proxy-providers'] ?? <String, Object?>{});
    for (final value in rawGroups) {
      final group = _mapping(value);
      final name = group['name'];
      if (name is! String || name.isEmpty) {
        throw const FormatException('invalid_group_name');
      }
      if (!names.add(name)) warn('duplicate_group_name', name);
      if (providers.containsKey(name)) {
        warn('group_provider_name_conflict', name);
      }
      if (!{
        'select',
        'fallback',
        'url-test',
        'load-balance',
      }.contains(group['type'])) {
        warn('unsupported_group_type', name);
      }
      groups[name] = group;
      types[name] = switch (group['type']) {
        'fallback' => 'Fallback',
        'url-test' => 'URLTest',
        'load-balance' => 'LoadBalance',
        _ => 'Selector',
      };
    }
    final previews = <GroupPreview>[];
    final orderedProxies = proxies.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final entry in groups.entries) {
      final name = entry.key;
      final group = entry.value;
      var complete = true;
      final explicit = _strings(group['proxies']);
      final use = _strings(group['use']);
      for (final reference in explicit) {
        if (!names.contains(reference)) {
          warn('unknown_proxy_reference', name);
        }
      }
      for (final reference in use) {
        if (!providers.containsKey(reference)) {
          warn('unknown_provider_reference', name);
        }
      }
      if (use.isNotEmpty ||
          group['include-all-providers'] == true ||
          group['include-all'] == true) {
        complete = false;
        warn('provider_snapshot_required', name);
      }
      for (final key in [
        'include-all',
        'include-all-proxies',
        'include-all-providers',
      ]) {
        if (group[key] != null && group[key] is! bool) {
          warn('invalid_group_option', name);
        }
      }
      var members = [...explicit];
      try {
        final include = _filter(group['filter']);
        final exclude = _filter(group['exclude-filter']);
        if (group['include-all-proxies'] == true ||
            group['include-all'] == true) {
          members.addAll(
            orderedProxies
                .where((p) => include == null || include.hasMatch(p.name))
                .map((p) => p.name),
          );
        }
        final excludedTypes = group['exclude-type'];
        if (excludedTypes != null && excludedTypes is! String) {
          throw const FormatException('invalid_group_option');
        }
        final excluded = (excludedTypes as String? ?? '').toLowerCase().split(
          '|',
        );
        members = members
            .where(
              (n) =>
                  !(exclude?.hasMatch(n) ?? false) &&
                  !excluded.contains(types[n]?.toLowerCase()),
            )
            .toList();
      } on FormatException catch (e) {
        complete = false;
        warn(e.message, name);
      }
      final fallback = group['empty-fallback'] ?? 'COMPATIBLE';
      if (fallback is! String ||
          !names.contains(fallback) ||
          groups.containsKey(fallback)) {
        warn('invalid_empty_fallback', name);
      }
      final empty = complete && members.isEmpty;
      if (empty) warn('empty_group_requires_policy', name);
      previews.add(
        GroupPreview(
          name: name,
          members: members,
          fallback: empty && fallback is String ? fallback : null,
          complete: complete,
        ),
      );
    }
    _checkCycles(groups, warn);
    _checkRules(root, names, warn);
    final remote = previews
        .where((g) => g.name == 'RemoteBalancer')
        .firstOrNull;
    final chain = previews.where((g) => g.name == 'Proxy_Chain').firstOrNull;
    if (remote != null &&
        chain != null &&
        chain.members.any(
          (n) => !groups.containsKey(n) && !remote.members.contains(n),
        )) {
      warn('chain_has_extra_nodes', 'Proxy_Chain');
    }
    if (groups.containsKey('WG_Auto') &&
        !groups.values.any((g) => _strings(g['proxies']).contains('WG_Auto')) &&
        !_strings(root['rules']).any((r) => r.split(',').contains('WG_Auto'))) {
      warn('unreferenced_group', 'WG_Auto');
    }
    return previews;
  }
}

const _builtins = {'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE'};

ProfileResult _failure(String code) => ProfileResult(
  groups: [],
  diagnostics: [ProfileDiagnostic(code, DiagnosticSeverity.error)],
);

Map<String, Object?> _mapping(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('yaml_mapping_required');
  }
  return value;
}

List<String> _strings(Object? value) {
  if (value == null) return [];
  if (value is! List || value.any((Object? x) => x is! String)) {
    throw const FormatException('string_list_required');
  }
  return value.cast<String>();
}

/// Deliberately bounded subset shared by this P0 preview. Reject complex .NET
/// regexes with a warning; they remain unchanged in the exported YAML.
RegExp? _filter(Object? input) {
  if (input == null || input == '') return null;
  if (input is! String || input.length > 256) {
    throw const FormatException('unsupported_filter_preview');
  }
  final insensitive = input.startsWith('(?i)');
  final expression = insensitive ? input.substring(4) : input;
  if (!RegExp(r'^[\p{L}\p{N}_ |()^$-]+$', unicode: true).hasMatch(expression)) {
    throw const FormatException('unsupported_filter_preview');
  }
  try {
    return RegExp(expression, caseSensitive: !insensitive, unicode: true);
  } on FormatException {
    throw const FormatException('unsupported_filter_preview');
  }
}

void _checkCycles(
  Map<String, Map<String, Object?>> groups,
  void Function(String, [String?]) error,
) {
  final done = <String>{};
  final visiting = <String>{};
  void visit(String name) {
    if (done.contains(name)) return;
    if (!visiting.add(name)) {
      error('group_cycle', name);
      return;
    }
    for (final child in _strings(groups[name]!['proxies'])) {
      if (groups.containsKey(child)) visit(child);
    }
    visiting.remove(name);
    done.add(name);
  }

  for (final name in groups.keys) {
    visit(name);
  }
}

void _checkRules(
  Map<String, Object?> root,
  Set<String> names,
  void Function(String, [String?]) error,
) {
  final providers = _mapping(root['rule-providers'] ?? <String, Object?>{});
  const supported = {
    'MATCH',
    'DOMAIN',
    'DOMAIN-SUFFIX',
    'DOMAIN-KEYWORD',
    'IP-CIDR',
    'IP-CIDR6',
    'RULE-SET',
    'GEOIP',
    'GEOSITE',
    'DST-PORT',
    'SRC-PORT',
    'NETWORK',
  };
  for (final rule in _strings(root['rules'])) {
    final parts = rule.split(',').map((p) => p.trim()).toList();
    if (parts.isEmpty || !supported.contains(parts.first)) {
      error('unsupported_rule_preview');
      continue;
    }
    final targetIndex = parts.first == 'MATCH' ? 1 : 2;
    if (parts.length <= targetIndex || !names.contains(parts[targetIndex])) {
      error('unknown_rule_target');
    }
    if (parts.first == 'RULE-SET' &&
        parts.length > 1 &&
        !providers.containsKey(parts[1])) {
      error('unknown_rule_provider');
    }
  }
  final dns = _mapping(root['dns'] ?? <String, Object?>{});
  final policies = _mapping(dns['nameserver-policy'] ?? <String, Object?>{});
  for (final key in policies.keys.where((k) => k.startsWith('rule-set:'))) {
    for (final name in key.substring(9).split(',')) {
      if (!providers.containsKey(name.trim())) {
        error('unknown_dns_rule_provider');
      }
    }
  }
}
