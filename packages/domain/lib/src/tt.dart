import 'network/ip_address.dart';
import 'tt_contract.g.dart';
import 'vless_contract.g.dart';
import 'adopted_resource.dart';

String ttTarget(String serverId) => 'tt/$serverId';
bool isTtTarget(String target) => target.startsWith('tt/');

final class TrustTunnelEndpoint {
  TrustTunnelEndpoint({
    required this.serverId,
    required Map<String, Object?> spec,
  }) : spec = Map.unmodifiable({
         ...spec,
         if (spec['adoption'] != null)
           'adoption': Map<String, Object?>.unmodifiable(
             spec['adoption'] as Map,
           ),
       }) {
    try {
      validateVlessSchema(
        spec,
        ttSchema['properties']['resources']['items'] as Map,
      );
      if (spec.containsKey('adoption')) {
        validateAdoptedResource(spec);
        return;
      }
      final listen = IpAddress.parse(spec['listen'] as String);
      if (listen.category == IpCategory.multicast ||
          ['0.0.0.0', '::'].contains(spec['endpoint']) ||
          deleted && enabled) {
        throw const FormatException('tt_invalid');
      }
      final domain = spec['domain'] as String;
      if (!domain.contains('.') ||
          domain.length > 253 ||
          !domain
              .split('.')
              .every(
                (s) => RegExp(
                  r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
                ).hasMatch(s),
              )) {
        throw const FormatException('tt_invalid');
      }
      if (spec['outbound'] == 'socks5') {
        final uri = Uri.tryParse('socks5://${spec['socksAddress']}');
        if (uri == null ||
            uri.host.isEmpty ||
            !uri.hasPort ||
            uri.port < 1 ||
            uri.port > 65535 ||
            uri.userInfo.isNotEmpty ||
            uri.path.isNotEmpty) {
          throw const FormatException('tt_invalid');
        }
      }
    } on FormatException {
      throw const FormatException('tt_invalid');
    }
  }
  factory TrustTunnelEndpoint.fromJson(Map j) => TrustTunnelEndpoint(
    serverId: j['serverId'] as String,
    spec: Map<String, Object?>.from(j['spec'] as Map),
  );
  final String serverId;
  final Map<String, Object?> spec;
  String get id => spec['id'] as String;
  String get name => spec['name'] as String;
  bool get enabled => spec['enabled'] as bool;
  bool get deleted => spec['deleted'] as bool;
  Map<String, Object?> toJson() => {'serverId': serverId, 'spec': spec};
}

void validateTtPayload(Map<String, Object?> payload) =>
    validateVlessSchema(payload, ttSchema);
