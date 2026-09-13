// Disposable localhost fixture only. Test secrets are read privately, never logged.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';

Future<void> main(List<String> args) async {
  final fixture = Directory(args[0]);
  final installed = args[1] == 'installed';
  final credentials =
      jsonDecode(await File('${fixture.path}/credentials.json').readAsString())
          as Map;
  final fingerprint = (await File(
    '${fixture.path}/host-fingerprint',
  ).readAsString()).trim();
  final port = int.parse(await File('${fixture.path}/port').readAsString());
  final mode = File('${fixture.path}/inventory-mode');
  final results = <String, Object>{};
  void check(bool condition, String code) {
    if (!condition) throw StateError(code);
  }

  for (final username in ['testuser', 'root']) {
    await mode.writeAsString('');
    final token = CancellationToken();
    final connection = await const DartSshConnector().connect(
      SshProfile(
        host: '127.0.0.1',
        port: port,
        username: username,
        authMethod: SshAuthMethod.password,
        secrets: {ServerSecret.sshPassword: credentials['password'] as String},
      ),
      verifyHostKey: (key) async => key.fingerprint == fingerprint,
      cancellation: token,
    );
    unawaited(connection.done.catchError((Object _) {}));
    try {
      var snapshot = await connection.observe(token);
      final software = snapshot.software!;
      check(
        software.facts.values.every((v) => v.status == InventoryStatus.ok),
        'system_facts_failed',
      );
      check(
        (software.facts[ServerFact.uid]!.value == '0') == (username == 'root'),
        'uid_mismatch',
      );
      check(
        software.sockets.every((s) => s.result.status == InventoryStatus.ok),
        'socket_query_failed',
      );
      check(
        software.sockets.any(
          (g) =>
              g.protocol == SocketProtocol.tcp &&
              g.result.value!.any((s) => s.port == 22),
        ),
        'ssh_listener_missing',
      );
      for (final group in software.sockets) {
        check(
          group.result.value!.any(
            (s) =>
                s.port ==
                (group.protocol == SocketProtocol.tcp ? 18443 : 51820),
          ),
          'fixture_socket_missing',
        );
      }
      check(
        software.sockets.any(
          (g) =>
              g.protocol == SocketProtocol.udp &&
              g.result.value!.any((s) => s.port == 51822),
        ),
        'connected_udp_not_observed',
      );
      if (!installed) {
        check(
          software.components
              .take(3)
              .every((c) => c.presence == ComponentPresence.absent),
          'clean_host_false_detection: ${software.components.map((c) => '${c.component.name}/${c.presence.name}/${c.issues.map((s) => s.name).join(',')}').join(';')}',
        );
      } else {
        check(
          software.components[0].presence == ComponentPresence.detected,
          'panel_missing',
        );
        check(
          software.components[0].installations.any(
            (i) => i.source == InstallationSource.systemd,
          ),
          'service_file_missing',
        );
        check(
          software.components[1].installations.any(
            (i) => i.version?.value == '26.3.27',
          ),
          'xray_version_missing',
        );
        check(
          software.components[3].installations.any(
            (i) => i.version?.value == '1.0.20250522',
          ),
          'awg_version_missing',
        );
        check(
          software.components[2].presence ==
              (username == 'root'
                  ? ComponentPresence.detected
                  : ComponentPresence.unknown),
          'denied_directory_looks_absent',
        );
        if (username == 'root') {
          check(
            software.components[2].installations.any(
              (i) => i.version?.value == '1.1.0',
            ),
            'tt_version_missing',
          );
        }
      }
      results[username] = {
        'status': 'PASS',
        'socket_count': software.sockets.fold(
          0,
          (int n, g) => n + g.result.value!.length,
        ),
      };
      if (username == 'root' && installed) {
        for (final failure in [
          'disk-failure',
          'timeout',
          'large',
          'docker-denied',
        ]) {
          await mode.writeAsString(failure);
          snapshot = await connection.observe(CancellationToken());
          final next = snapshot.software!;
          switch (failure) {
            case 'disk-failure':
              check(
                next.facts[ServerFact.freeDiskKiB]!.status ==
                    InventoryStatus.failed,
                'disk_failure_status',
              );
            case 'timeout':
              check(
                next.facts[ServerFact.kernel]!.status ==
                    InventoryStatus.timeout,
                'timeout_status',
              );
            case 'large':
              check(
                next.facts[ServerFact.kernel]!.status ==
                    InventoryStatus.outputLimit,
                'limit_status',
              );
            case 'docker-denied':
              check(
                next.components.every(
                  (c) => c.issues.contains(InventoryStatus.denied),
                ),
                'docker_access_status',
              );
          }
          check(
            next.sockets.every((s) => s.result.status == InventoryStatus.ok),
            'partial_failure_lost_socket_data',
          );
          results[failure] = 'PASS';
        }
        await mode.writeAsString('');
        final recovered = await connection.observe(CancellationToken());
        check(
          recovered.software!.facts.values.every(
            (v) => v.status == InventoryStatus.ok,
          ),
          'refresh_recovery',
        );
        results['refresh_same_ssh_session'] = 'PASS';
        await mode.writeAsString('timeout');
        final cancelled = CancellationToken();
        final timer = Timer(
          const Duration(milliseconds: 300),
          cancelled.cancel,
        );
        try {
          await connection.observe(cancelled);
          throw StateError('cancellation_ignored');
        } on SshFailure catch (e) {
          check(e.issue == SshIssue.cancelled, 'cancellation_status');
          results['cancel_inventory'] = 'PASS';
        } finally {
          timer.cancel();
        }
      }
    } finally {
      connection.close();
    }
  }
  stdout.writeln(jsonEncode(results));
}
