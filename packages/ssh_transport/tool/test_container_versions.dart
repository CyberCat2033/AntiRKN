import 'dart:convert';
import 'dart:io';
import 'package:antirkn_ssh_transport/src/inventory_probes.dart';
import 'package:antirkn_ssh_transport/src/server_inventory_reader.dart';

Future<void> main(List<String> args) async {
  final versions = <String, String>{};
  for (final binary in InventoryProbes.containerBinaries) {
    final result = await Process.run('/bin/sh', [
      '-c',
      '${InventoryProbes.prefix}${InventoryProbes.containerVersion(args.single, binary)}',
    ]);
    if (result.exitCode != 0) throw StateError('container_version_failed');
    versions[binary] = parseVersion(result.stdout as String);
  }
  if (versions['amneziawg-go'] != '3.0.0' ||
      versions['awg'] != '3.1.20260812') {
    throw StateError('unexpected_container_versions');
  }
  stdout.writeln(
    jsonEncode({
      'result': 'PASS',
      'source':
          'Actual Docker CLI/daemon exec; public synthetic version-only binaries',
      'versions': versions,
      'vpn_runtime_tested': false,
    }),
  );
}
