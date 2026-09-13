import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_network_inventory/antirkn_network_inventory.dart';

final observedAt = DateTime.utc(2026, 9, 13, 12);

Map<String, dynamic> fixture() =>
    jsonDecode(File('lib/fixtures/one_vps.json').readAsStringSync())
        as Map<String, dynamic>;

ServerNetworkInventory parseFixture(
  Map<String, dynamic> data, {
  String serverId = 'one-vps',
  String namespace = 'default',
}) => const IpInventoryParser().parse(
  outputs: outputs(data),
  serverId: serverId,
  namespace: namespace,
  observedAt: observedAt,
  sshPeer: IpAddress.parse('203.0.113.20'),
);

IpCommandOutputs outputs(Map<String, dynamic> data) => IpCommandOutputs(
  addresses: jsonEncode(data['addresses']),
  routesV4: jsonEncode(data['routesV4']),
  routesV6: jsonEncode(data['routesV6']),
  rulesV4: jsonEncode(data['rulesV4']),
  rulesV6: jsonEncode(data['rulesV6']),
);

Map<String, dynamic> sampleAddress(Map<String, dynamic> data, String ip) {
  for (final interface in data['addresses'] as List) {
    for (final address in interface['addr_info'] as List) {
      if (address['local'] == ip) return address as Map<String, dynamic>;
    }
  }
  throw StateError('test address missing');
}

ServerAddress addressEntry(ServerNetworkInventory inventory, String ip) =>
    inventory.addresses.singleWhere(
      (entry) => entry.address == IpAddress.parse(ip),
    );
