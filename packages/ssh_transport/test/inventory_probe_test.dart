import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/src/inventory_probes.dart';
import 'package:antirkn_ssh_transport/src/server_inventory_reader.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Docker permission fallback is a noninteractive metadata read; denial stays explicit',
    () async {
      final directory = await Directory.systemTemp.createTemp('antirkn-probe-');
      final socketPath = '${directory.path}/docker.sock';
      final socket = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(() async {
        await socket.close();
        await directory.delete(recursive: true);
      });
      final docker = File('${directory.path}/docker');
      await docker.writeAsString(r'''#!/bin/sh
[ "$1" = --host ] && [ "$3" = ps ] && [ "$4" = --all ] && [ "$5" = --no-trunc ] && [ "$6" = --format ] || exit 99
printf '"%064d"\t"amnezia-awg2:latest"\t"running"\t"amnezia-awg2"\n' 0
''');
      final sudo = File('${directory.path}/sudo');
      await sudo.writeAsString(r'''#!/bin/sh
[ "$1" = -n ] && [ "$2" = -- ] && [ "$3" = docker ] || exit 99
[ "$ALLOW_TEST_SUDO" = yes ] || exit 1
shift 2
exec "$@"
''');
      expect(
        (await Process.run('chmod', ['700', docker.path, sudo.path])).exitCode,
        0,
      );
      expect((await Process.run('chmod', ['000', socketPath])).exitCode, 0);
      final command = InventoryProbes.containers.replaceAll(
        '/var/run/docker.sock',
        socketPath,
      );
      Future<ProcessResult> run(String allowed) => Process.run(
        '/bin/sh',
        ['-c', command],
        environment: {
          'PATH': '${directory.path}:/usr/bin:/bin',
          'ALLOW_TEST_SUDO': allowed,
        },
      );
      final denied = await run('no');
      expect(denied.exitCode, 0);
      expect(denied.stdout, '@denied\n');
      final permitted = await run('yes');
      expect(permitted.exitCode, 0);
      expect(
        parseContainers(permitted.stdout as String).single.component,
        VpnComponent.amneziaWg,
      );
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root',
  );
}
