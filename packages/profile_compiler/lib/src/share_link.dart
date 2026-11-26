import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';

/// How a client app imports a [ProxyShareLink].
enum ShareLinkKind {
  /// A `vless://` URI (Xray share link form).
  vless,

  /// An AmneziaWG `.conf` file text.
  awg,

  /// A TrustTunnel `tt://?` deep link.
  trustTunnel,
}

/// The import form of one access, made for manual testing. It carries the
/// access credentials in clear text: show it only on request, never log or
/// store it.
final class ProxyShareLink {
  const ProxyShareLink(this.kind, this.text);
  final ShareLinkKind kind;
  final String text;
  @override
  String toString() => 'ProxyShareLink(${kind.name}, <redacted>)';
}

/// The standard import form of the Mihomo proxy [fields], named [name];
/// null when its type or an option of it has no such form.
ProxyShareLink? proxyShareLink(Map<String, Object?> fields, String name) {
  try {
    return switch (fields['type']) {
      'vless' => _vless(fields, name),
      'wireguard' => _awg(fields, name),
      'trusttunnel' => _trustTunnel(fields, name),
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

String _hostPort(Object? server, Object? port) {
  if (server is! String || server.isEmpty || port is! int) {
    throw const FormatException('share_link_invalid');
  }
  return server.contains(':') && !server.startsWith('[')
      ? '[$server]:$port'
      : '$server:$port';
}

ProxyShareLink? _vless(Map<String, Object?> f, String name) {
  final uuid = f['uuid'];
  if (uuid is! String || uuid.isEmpty) return null;
  final network = f['network'] as String? ?? 'tcp';
  final reality = f['reality-opts'];
  final query = <String, String>{
    'encryption': 'none',
    'type': network,
    'security': reality is Map
        ? 'reality'
        : f['tls'] == true
        ? 'tls'
        : 'none',
    if (f['servername'] case final String sni when sni.isNotEmpty) 'sni': sni,
    if (f['client-fingerprint'] case final String fp when fp.isNotEmpty)
      'fp': fp,
    if (f['flow'] case final String flow when flow.isNotEmpty) 'flow': flow,
    if (reality is Map) ...{
      'pbk': '${reality['public-key'] ?? ''}',
      if (reality['short-id'] case final String sid when sid.isNotEmpty)
        'sid': sid,
    },
  };
  switch (network) {
    case 'tcp':
      break;
    case 'xhttp':
      final opts = f['xhttp-opts'];
      if (opts is! Map) return null;
      for (final key in ['path', 'host', 'mode']) {
        if (opts[key] case final String value when value.isNotEmpty) {
          query[key] = value;
        }
      }
      final extra = _xhttpExtra(opts);
      if (extra == null) return null;
      if (extra.isNotEmpty) query['extra'] = jsonEncode(canonicalValue(extra));
    case 'ws':
      final opts = f['ws-opts'];
      if (opts is Map) {
        if (opts['path'] case final String path when path.isNotEmpty) {
          query['path'] = path;
        }
        final headers = opts['headers'];
        if (headers is Map && headers['Host'] is String) {
          query['host'] = headers['Host'] as String;
        }
      }
    case 'grpc':
      final opts = f['grpc-opts'];
      if (opts is Map && opts['grpc-service-name'] is String) {
        query['serviceName'] = opts['grpc-service-name'] as String;
      }
    default:
      return null;
  }
  final encoded = Uri(queryParameters: query).query;
  return ProxyShareLink(
    ShareLinkKind.vless,
    'vless://${Uri.encodeComponent(uuid)}@${_hostPort(f['server'], f['port'])}'
    '?$encoded#${Uri.encodeComponent(name)}',
  );
}

/// The Xray names of the Mihomo XHTTP options [opts] beyond path, host and
/// mode; null when one has no Xray name.
Map<String, Object?>? _xhttpExtra(Map opts) {
  Map<String, String> names(Map schema) => {
    for (final e in (schema['properties'] as Map).entries)
      if ((e.value as Map)['mihomo'] case final String mihomo)
        mihomo: e.key as String,
  };
  final schema = xhttpOptionsSchema;
  final top = names(schema);
  final mux = names((schema['properties'] as Map)['xmux'] as Map);
  final result = <String, Object?>{};
  for (final e in opts.entries) {
    if (const {'path', 'host', 'mode'}.contains(e.key)) continue;
    final xray = top[e.key];
    if (xray == null) return null;
    if (xray == 'xmux') {
      if (e.value is! Map) return null;
      final inner = <String, Object?>{};
      for (final m in (e.value as Map).entries) {
        final name = mux[m.key];
        if (name == null) return null;
        inner[name] = m.value;
      }
      if (inner.isNotEmpty) result[xray] = inner;
    } else {
      result[xray] = e.value;
    }
  }
  return result;
}

/// AmneziaWG `.conf` key of a Mihomo `amnezia-wg-option` key.
String? _awgKey(String key) {
  for (final e in awgOptionRules.entries) {
    if (e.key == key) return (e.value as Map)['config'] as String?;
  }
  if (RegExp(r'^[hij][1-5]$').hasMatch(key)) return key.toUpperCase();
  return switch (key) {
    'itime' => 'Itime',
    'header-protection-key' => 'HeaderProtectionKey',
    _ => null,
  };
}

ProxyShareLink? _awg(Map<String, Object?> f, String name) {
  final ip = f['ip'], ipv6 = f['ipv6'];
  if (ip is! String || f['private-key'] is! String) return null;
  final lines = <String>[
    '# $name',
    '[Interface]',
    'PrivateKey = ${f['private-key']}',
    'Address = $ip/32${ipv6 is String && ipv6.isNotEmpty ? ', $ipv6/128' : ''}',
    if (f['mtu'] case final int mtu) 'MTU = $mtu',
  ];
  final options = f['amnezia-wg-option'];
  if (options is Map) {
    for (final e in options.entries) {
      if (e.key == 'version' || e.value == null || e.value == '') continue;
      final key = _awgKey(e.key as String);
      if (key == null) return null;
      final value = e.value;
      lines.add('$key = ${value is bool ? (value ? 'on' : 'off') : value}');
    }
  }
  final allowed = f['allowed-ips'];
  final keepalive = f['persistent-keepalive'];
  lines.addAll([
    '',
    '[Peer]',
    'PublicKey = ${f['public-key']}',
    if (f['pre-shared-key'] case final String psk when psk.isNotEmpty)
      'PresharedKey = $psk',
    'Endpoint = ${_hostPort(f['server'], f['port'])}',
    'AllowedIPs = ${allowed is List && allowed.isNotEmpty ? allowed.join(', ') : '0.0.0.0/0'}',
    if (keepalive is int && keepalive > 0) 'PersistentKeepalive = $keepalive',
  ]);
  return ProxyShareLink(ShareLinkKind.awg, '${lines.join('\n')}\n');
}

/// TrustTunnel deep link (DEEP_LINK.md of the TrustTunnel project): TLV
/// entries of varint tag, varint length and value, base64url without
/// padding after `tt://?`.
ProxyShareLink? _trustTunnel(Map<String, Object?> f, String name) {
  final user = f['username'], password = f['password'], sni = f['sni'];
  if (user is! String || password is! String || sni is! String) return null;
  final out = BytesBuilder();
  void varint(int value) {
    if (value < 0x40) {
      out.addByte(value);
    } else if (value < 0x4000) {
      out
        ..addByte(0x40 | (value >> 8))
        ..addByte(value & 0xff);
    } else {
      out
        ..addByte(0x80 | (value >> 24))
        ..addByte((value >> 16) & 0xff)
        ..addByte((value >> 8) & 0xff)
        ..addByte(value & 0xff);
    }
  }

  void entry(int tag, List<int> value) {
    varint(tag);
    varint(value.length);
    out.add(value);
  }

  void text(int tag, String value) => entry(tag, utf8.encode(value));
  entry(0x00, [2]);
  text(0x01, sni);
  text(0x02, _hostPort(f['server'], f['port']));
  text(0x05, user);
  text(0x06, password);
  entry(0x09, [f['quic'] == true ? 0x02 : 0x01]);
  text(0x0C, name);
  final payload = base64Url.encode(out.toBytes()).replaceAll('=', '');
  return ProxyShareLink(ShareLinkKind.trustTunnel, 'tt://?$payload');
}
