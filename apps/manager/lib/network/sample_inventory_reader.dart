import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_network_inventory/antirkn_network_inventory.dart';
import 'package:flutter/services.dart';

/// Packaged sample only. No processes, sockets, VPS or credentials.
final class SampleInventoryReader implements NetworkInventoryReader {
  const SampleInventoryReader();
  @override
  Future<ServerNetworkInventory> read() async {
    final source = await rootBundle.loadString(
      'packages/antirkn_network_inventory/fixtures/one_vps.json',
    );
    final data = jsonDecode(source) as Map<String, Object?>;
    return const IpInventoryParser().parse(
      outputs: IpCommandOutputs(
        addresses: jsonEncode(data['addresses']),
        routesV4: jsonEncode(data['routesV4']),
        routesV6: jsonEncode(data['routesV6']),
        rulesV4: jsonEncode(data['rulesV4']),
        rulesV6: jsonEncode(data['rulesV6']),
      ),
      serverId: 'sample-vps',
      observedAt: DateTime.now().toUtc(),
      source: NetworkSource.sample,
      sshPeer: IpAddress.parse('203.0.113.20'),
    );
  }
}
