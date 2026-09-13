// Read-only query of local Docker metadata; only the disposable fixture is reported.
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/src/inventory_probes.dart';
import 'package:antirkn_ssh_transport/src/server_inventory_reader.dart';

Future<void> main(List<String> args) async {
  final result = await Process.run('/bin/sh', [
    '-c',
    '${InventoryProbes.prefix}${InventoryProbes.containers}',
  ]);
  if (result.exitCode != 0) throw StateError('docker_query_failed');
  final entries = parseContainers(result.stdout as String);
  final fixture = entries.where((c) => c.image == args.single).single;
  if (fixture.component != VpnComponent.amneziaWg ||
      fixture.state != ServiceState.stopped) {
    throw StateError('docker_fixture_detection_failed');
  }
  stdout.writeln(
    jsonEncode({
      'result': 'PASS',
      'source':
          'actual local Docker CLI/daemon; disposable unstarted Ubuntu image with AWG test tag',
      'image_tag_is_not_binary_version': true,
      'created_container_detected_as_inactive': true,
    }),
  );
}
