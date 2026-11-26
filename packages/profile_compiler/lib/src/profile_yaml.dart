import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

// Presentation order follows the protocol examples, independently of canonical
// JSON used for operation fingerprints and sync. Unknown fields keep their order.
const _common = ['name', 'type', 'server', 'port', 'ip-version', 'udp'];
const _tls = [
  'tls',
  'servername',
  'sni',
  'alpn',
  'fingerprint',
  'client-fingerprint',
  'skip-cert-verify',
  'name-cert-verify',
  'reality-opts',
  'encryption',
];
const _transport = [
  'network',
  'ws-opts',
  'http-opts',
  'h2-opts',
  'grpc-opts',
  'xhttp-opts',
  'smux',
  'tfo',
  'mptcp',
  'interface-name',
  'routing-mark',
  'dialer-proxy',
];
const _orders = <String, List<String>>{
  'vless': [
    ..._common,
    'uuid',
    'flow',
    'packet-encoding',
    ..._tls,
    ..._transport,
  ],
  'wireguard': [
    'name',
    'type',
    'private-key',
    'server',
    'port',
    'ip',
    'ipv6',
    'public-key',
    'allowed-ips',
    'pre-shared-key',
    'reserved',
    'persistent-keepalive',
    'peers',
    'ip-stack',
    'udp',
    'mtu',
    'dialer-proxy',
    'remote-dns-resolve',
    'dns',
    'amnezia-wg-option',
  ],
  'trusttunnel': [
    'name',
    'type',
    'server',
    'port',
    'username',
    'password',
    'client-fingerprint',
    'health-check',
    'udp',
    'sni',
    'alpn',
    'skip-cert-verify',
    'name-cert-verify',
    'quic',
    'congestion-controller',
    'bbr-profile',
    'max-connections',
    'min-streams',
    'max-streams',
  ],
  'reality-opts': ['public-key', 'short-id'],
  'ws-opts': ['path', 'headers', 'max-early-data', 'early-data-header-name'],
  'grpc-opts': ['grpc-service-name'],
  'xhttp-opts': ['path', 'mode', 'host', 'headers', 'extra'],
  'amnezia-wg-option': [
    'version',
    'jc',
    'jmin',
    'jmax',
    's1',
    's2',
    's3',
    's4',
    'h1',
    'h2',
    'h3',
    'h4',
    'i1',
    'i2',
    'i3',
    'i4',
    'i5',
  ],
};

Object? _ordered(Object? value, [String context = '']) {
  if (value is Map) {
    final order =
        _orders[context] ??
        (value.containsKey('type')
            ? _orders[value['type']] ?? _common
            : const []);
    return <String, Object?>{
      for (final key in [
        ...order.where(value.containsKey),
        ...value.keys.where((k) => !order.contains(k)),
      ])
        key as String: _ordered(value[key], key),
    };
  }
  if (value is List) return value.map((v) => _ordered(v, context)).toList();
  return value;
}

typedef _Position = ({String path, YamlNode node});
List<_Position> _positions(YamlNode node, String path) {
  final result = <_Position>[(path: path, node: node)];
  if (node is YamlMap) {
    for (final e in node.nodes.entries) {
      final key = e.key as YamlScalar;
      final next = '$path/${jsonEncode(key.value)}';
      result.add((path: next, node: key));
      result.addAll(_positions(e.value, next));
    }
  } else if (node is YamlList) {
    for (var i = 0; i < node.nodes.length; i++) {
      result.addAll(_positions(node.nodes[i], '$path/$i'));
    }
  }
  return result;
}

/// Preserve comments attached to static proxy fields. Inline comments become
/// preceding comments when fields move; '#' inside scalars is never a comment.
Map<String, List<String>> _comments(
  String source,
  YamlNode proxies, {
  bool whole = false,
}) {
  final positions = _positions(proxies, whole ? '' : 'proxies');
  final scalars = positions.where((p) => p.node is YamlScalar).toList()
    ..sort(
      (a, b) => a.node.span.start.offset.compareTo(b.node.span.start.offset),
    );
  final comments = <String, List<String>>{};
  var start = whole
      ? 0
      : source.lastIndexOf('\n', proxies.span.start.offset) + 1;
  // Include indented comments before the first sequence item.
  while (start > 0) {
    final previous = source.lastIndexOf('\n', start - 2) + 1;
    final line = source.substring(previous, start);
    if (!RegExp(r'^\s+#').hasMatch(line)) break;
    start = previous;
  }
  final end = whole ? source.length : proxies.span.end.offset;
  final text = source.substring(start, end);
  var commentEnd = -1;
  for (final match in RegExp(r'#').allMatches(text)) {
    final offset = start + match.start;
    if (offset < commentEnd) continue;
    if (scalars.any(
      (p) =>
          offset >= p.node.span.start.offset && offset < p.node.span.end.offset,
    )) {
      continue;
    }
    final line = source.lastIndexOf('\n', offset) + 1;
    final before = source.substring(line, offset);
    // Ignore unindented section headings belonging to the next root key.
    if (before.isEmpty && !whole) continue;
    final inline = before.trim().isNotEmpty;
    final candidates = scalars
        .where(
          (p) => inline
              ? p.node.span.start.offset < offset &&
                    p.node.span.start.offset >= line
              : p.node.span.start.offset > offset,
        )
        .toList();
    final target = candidates.isEmpty
        ? null
        : inline
        ? candidates.last
        : candidates.first;
    commentEnd = source.indexOf('\n', offset);
    if (commentEnd < 0) commentEnd = source.length;
    if (target != null) {
      comments
          .putIfAbsent(target.path, () => [])
          .add(source.substring(offset, commentEnd).trimRight());
    }
  }
  return comments;
}

final class ProfileYamlTemplate {
  const ProfileYamlTemplate(this.original, this.whole, this.comments);
  final YamlMap original;
  final bool whole;
  final Map<String, List<String>> comments;
}

ProfileYamlTemplate prepareProfileYaml(String template) {
  final original = loadYamlNode(template) as YamlMap;
  final oldProxies = original.nodes['proxies'];
  // A flow-style root cannot contain a block-style proxies child. Expand it
  // once, preserving root order and associating comments by YAML node paths.
  final whole = template
      .substring(original.span.start.offset)
      .trimLeft()
      .startsWith('{');
  final comments = whole
      ? _comments(template, original, whole: true)
      : oldProxies is YamlList
      ? _comments(template, oldProxies)
      : <String, List<String>>{};
  return ProfileYamlTemplate(original, whole, comments);
}

String writeProfileYaml(String template, List<Object?> proxies) =>
    writeProfileYamlPrepared(template, proxies, prepareProfileYaml(template));

/// Reuses the source tree and comment locations across a client batch.
/// [groupProxies] replaces the explicit `proxies` of groups, by index in
/// `proxy-groups`; everything else is the template as written.
String writeProfileYamlPrepared(
  String template,
  List<Object?> proxies,
  ProfileYamlTemplate prepared, {
  Map<int, List<String>> groupProxies = const {},
}) {
  final original = prepared.original;
  final whole = prepared.whole;
  final comments = {...prepared.comments}
    // A comment on a dropped member must not move to another one.
    ..removeWhere(
      (path, _) => groupProxies.keys.any(
        (i) => path.startsWith('/${jsonEncode('proxy-groups')}/$i/'),
      ),
    );
  final ordered = proxies.map(_ordered).toList();
  final groups = original['proxy-groups'];
  final expected = <Object?, Object?>{
    ...original,
    'proxies': ordered,
    if (groupProxies.isNotEmpty && groups is List)
      'proxy-groups': [
        for (final (i, group) in groups.indexed)
          if (groupProxies[i] case final members?)
            {...group as Map, 'proxies': members}
          else
            group,
      ],
  };
  final editor = YamlEditor(whole ? '' : template);
  if (whole) {
    editor.update(
      [],
      wrapAsYamlNode(_data(expected), collectionStyle: CollectionStyle.BLOCK),
    );
  } else {
    editor.update([
      'proxies',
    ], wrapAsYamlNode(ordered, collectionStyle: CollectionStyle.BLOCK));
    for (final entry in groupProxies.entries) {
      editor.update(['proxy-groups', entry.key, 'proxies'], entry.value);
    }
  }
  var output = editor.toString();
  final root = loadYamlNode(output) as YamlMap;
  final nodes = root.nodes['proxies'] as YamlList;
  final inserts = <int, List<String>>{};
  final positions = whole ? _positions(root, '') : _positions(nodes, 'proxies');
  for (final entry in comments.entries) {
    final matches = positions.where(
      (p) => p.path == entry.key && p.node is YamlScalar,
    );
    if (matches.isEmpty) continue;
    final pos = matches.first.node.span.start.offset;
    final line = output.lastIndexOf('\n', pos) + 1;
    final prefix = RegExp(r'^\s*').firstMatch(output.substring(line, pos))![0]!;
    inserts
        .putIfAbsent(line, () => [])
        .addAll(entry.value.map((c) => '$prefix$c\n'));
  }
  // Locations come from the YAML tree, not a regex matching arbitrary '-'.
  for (var i = 1; i < nodes.nodes.length; i++) {
    final line = output.lastIndexOf('\n', nodes.nodes[i].span.start.offset) + 1;
    inserts.putIfAbsent(line, () => []).insert(0, '\n');
  }
  for (final offset in inserts.keys.toList()..sort((a, b) => b.compareTo(a))) {
    output = output.replaceRange(offset, offset, inserts[offset]!.join());
  }
  // A presentation change must never alter a block scalar or another section.
  final actual = loadYaml(output) as Map;
  if (jsonEncode(_plain(actual)) != jsonEncode(_plain(expected))) {
    throw const FormatException('yaml_presentation_failed');
  }
  return output;
}

Object? _plain(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _plain(value[key])};
  }
  if (value is List) return value.map(_plain).toList();
  return value;
}

Object? _data(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key as String: _data(entry.value),
    };
  }
  if (value is List) return value.map(_data).toList();
  return value;
}
