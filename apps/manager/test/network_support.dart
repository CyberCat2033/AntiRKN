import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_network_inventory/antirkn_network_inventory.dart';

Map<String, dynamic> networkFixture() =>
    jsonDecode(
          File(
            '../../packages/network_inventory/lib/fixtures/one_vps.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

ServerNetworkInventory testInventory({
  Map<String, dynamic>? data,
  DateTime? observedAt,
}) {
  final values = data ?? networkFixture();
  return const IpInventoryParser().parse(
    outputs: IpCommandOutputs(
      addresses: jsonEncode(values['addresses']),
      routesV4: jsonEncode(values['routesV4']),
      routesV6: jsonEncode(values['routesV6']),
      rulesV4: jsonEncode(values['rulesV4']),
      rulesV6: jsonEncode(values['rulesV6']),
    ),
    serverId: 'sample-vps',
    observedAt: observedAt ?? DateTime.now().toUtc(),
    source: NetworkSource.sample,
    sshPeer: IpAddress.parse('203.0.113.20'),
  );
}

class TestInventoryReader implements NetworkInventoryReader {
  TestInventoryReader(this.callback);
  Future<ServerNetworkInventory> Function() callback;
  int calls = 0;
  @override
  Future<ServerNetworkInventory> read() {
    calls++;
    return callback();
  }
}
