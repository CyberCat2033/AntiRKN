import 'dart:convert';
import 'dart:io';

import 'package:antirkn_network_inventory/antirkn_network_inventory.dart';

/// Read-only developer smoke check. Runs locally, never against a VPS, and
/// outputs only counts/version. Address and routing JSON stays in memory.
Future<void> main() async {
  final captured = <InventoryDocument, String>{};
  for (final entry in IpCommandOutputs.commands.entries) {
    final result = await Process.run(
      entry.value.first,
      entry.value.skip(1).toList(),
    );
    if (result.exitCode != 0) {
      stderr.writeln('local_inventory_command_failed:${entry.key.name}');
      exitCode = 1;
      return;
    }
    captured[entry.key] = result.stdout as String;
  }
  final inventory = const IpInventoryParser().parse(
    outputs: IpCommandOutputs(
      addresses: captured[InventoryDocument.addresses]!,
      routesV4: captured[InventoryDocument.routesV4]!,
      routesV6: captured[InventoryDocument.routesV6]!,
      rulesV4: captured[InventoryDocument.rulesV4]!,
      rulesV6: captured[InventoryDocument.rulesV6]!,
    ),
    serverId: 'local-smoke-only',
    observedAt: DateTime.now().toUtc(),
  );
  final version = await Process.run('ip', ['-Version']);
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'status': 'passed',
      'scope': 'local Linux host only; not Ubuntu VPS acceptance',
      'iproute2': (version.stdout as String).trim(),
      'addresses': inventory.addresses.length,
      'assignments': inventory.addresses.expand((a) => a.assignments).length,
      'routes': inventory.routes.length,
      'rules': inventory.rules.length,
      'capturedAt': inventory.observedAt.toIso8601String(),
      'rawNetworkDataPersisted': false,
    }),
  );
}
