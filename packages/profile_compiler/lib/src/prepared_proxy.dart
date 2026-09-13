import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';

/// Ephemeral adapter output after credentials have been resolved from a vault.
/// Never store these fields in logs or an unencrypted database.
final class PreparedProxy {
  PreparedProxy({required this.identity, required Map<String, Object?> fields})
    : fields = _freezeMap(fields);

  final AccessIdentity identity;
  final Map<String, Object?> fields;
  String get name => fields['name'] as String;

  String get typeLabel => switch (fields['type']) {
    'vless' => 'VLESS',
    'trusttunnel' => 'TrustTunnel',
    'wireguard' => 'WireGuard',
    _ => throw const FormatException('unsupported_proxy_type'),
  };

  void validate() {
    for (final key in ['name', 'server', 'type']) {
      final value = fields[key];
      if (value is! String ||
          value.isEmpty ||
          value.contains(RegExp(r'[\x00-\x1f]'))) {
        throw const FormatException('invalid_proxy_field');
      }
    }
    final port = fields['port'];
    if (port is! int || port < 1 || port > 65535) {
      throw const FormatException('invalid_port');
    }
    if (['0.0.0.0', '::', '[::]', '*'].contains(fields['server'])) {
      throw const FormatException('wildcard_endpoint');
    }
    switch (fields['type']) {
      case 'vless':
        final network = fields['network'] ?? 'tcp';
        final reality = fields['reality-opts'];
        final vision = fields['flow'] == 'xtls-rprx-vision';
        if (fields['tls'] != true ||
            !((network == 'tcp' && reality is Map && vision) ||
                (network == 'xhttp' &&
                    !fields.containsKey('flow') &&
                    fields['xhttp-opts'] is Map))) {
          throw const FormatException('unsupported_vless_preset');
        }
        if (fields['uuid'] is! String || fields['servername'] is! String) {
          throw const FormatException('missing_vless_credentials');
        }
      case 'trusttunnel':
        if (fields['username'] is! String || fields['password'] is! String) {
          throw const FormatException('missing_trusttunnel_credentials');
        }
      case 'wireguard':
        if (fields['private-key'] is! String ||
            fields['public-key'] is! String ||
            fields['ip'] is! String ||
            fields['amnezia-wg-option'] is! Map) {
          throw const FormatException('missing_awg_parameters');
        }
      default:
        throw const FormatException('unsupported_proxy_type');
    }
    if (fields['skip-cert-verify'] == true) {
      throw const FormatException('insecure_certificate_policy');
    }
  }

  @override
  String toString() => 'PreparedProxy(<redacted>)';
}

Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
    Map.unmodifiable(value.map((key, value) => MapEntry(key, _freeze(value))));

Object? _freeze(Object? value) => switch (value) {
  Map<String, Object?>() => _freezeMap(value),
  List() => List<Object?>.unmodifiable(value.map(_freeze)),
  null || String() || bool() || int() || double() => value,
  _ => throw const FormatException('non_serializable_proxy'),
};

/// A canonical ordering for nested mappings; list order remains semantic.
Object? canonicalValue(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: canonicalValue(value[key])};
  }
  if (value is List) return value.map(canonicalValue).toList();
  return value;
}

String canonicalJson(Object? value) => jsonEncode(canonicalValue(value));
