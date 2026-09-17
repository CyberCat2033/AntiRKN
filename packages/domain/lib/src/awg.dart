import 'awg_contract.g.dart';
import 'network/ip_address.dart';
import 'vless_contract.g.dart';
import 'adopted_resource.dart';

/// Protocol targets share the durable workspace coordinator while retaining
/// independent observations and operation IDs for each backend.
String awgTarget(String serverId) => 'awg/$serverId';
bool isAwgTarget(String target) => target.startsWith('awg/');
String vpnServerId(String target) => isAwgTarget(target)
    ? target.substring(4)
    : target.startsWith('tt/')
    ? target.substring(3)
    : target;

Map get awgResourceSchema =>
    (awgSchema['properties'] as Map)['resources']['items'] as Map;
Map get awgOptionRules =>
    (awgResourceSchema['properties'] as Map)['options']['properties'] as Map;

final class AwgInterface {
  AwgInterface({required this.serverId, required Map<String, Object?> spec})
    : spec = Map.unmodifiable({
        ...spec,
        if (spec['adoption'] != null)
          'adoption': Map<String, Object?>.unmodifiable(
            spec['adoption'] as Map,
          ),
        if (spec['options'] != null)
          'options': Map<String, Object?>.unmodifiable(spec['options'] as Map),
      }) {
    validateVlessSchema(spec, awgResourceSchema);
    if (spec.containsKey('adoption')) {
      validateAdoptedResource(spec);
      return;
    }
    final pool = (spec['pool'] as String).split('/');
    if (pool.length != 2) throw const FormatException('awg_invalid');
    final address = IpAddress.parse(pool.first);
    final prefix = int.parse(pool.last);
    if (address.family != IpFamily.ipv4 ||
        prefix < 16 ||
        prefix > 24 ||
        address.category != IpCategory.private) {
      throw const FormatException('awg_invalid');
    }
    final numeric = address.bytes.fold<int>(0, (v, b) => (v << 8) | b);
    if (numeric & ((1 << (32 - prefix)) - 1) != 0) {
      throw const FormatException('awg_invalid');
    }
    if (spec['pool6'] != '') {
      final v6 = (spec['pool6'] as String).split('/');
      if (v6.length != 2 ||
          v6.last != '64' ||
          IpAddress.parse(v6.first).family != IpFamily.ipv6 ||
          !RegExp(r'^f[cd]', caseSensitive: false).hasMatch(v6.first)) {
        throw const FormatException('awg_invalid');
      }
      if (IpAddress.parse(v6.first).bytes.skip(8).any((b) => b != 0)) {
        throw const FormatException('awg_invalid');
      }
    }
    if (['0.0.0.0', '::'].contains(spec['endpoint']) || deleted && enabled) {
      throw const FormatException('awg_invalid');
    }
    final options = spec['options'] as Map;
    if ((options['jmin'] as int) > (options['jmax'] as int) ||
        options['random-trailers'] == true &&
            {for (var i = 1; i <= 4; i++) options['s$i']}.length != 1) {
      throw const FormatException('awg_invalid');
    }
    for (final entry in awgOptionRules.entries) {
      if ((entry.value as Map)['range'] == true) {
        final values = (options[entry.key] as String).split('-').map(int.parse);
        if (values.first < 1 ||
            values.last > 65535 ||
            values.first > values.last) {
          throw const FormatException('awg_invalid');
        }
      }
    }
    if (int.parse((options['rekey-after-time'] as String).split('-').last) >=
        int.parse((options['reject-after-time'] as String).split('-').first)) {
      throw const FormatException('awg_invalid');
    }
  }
  factory AwgInterface.fromJson(Map j) => AwgInterface(
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

void validateAwgPayload(Map<String, Object?> payload) =>
    validateVlessSchema(payload, awgSchema);
