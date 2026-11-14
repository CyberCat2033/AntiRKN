import 'dart:async';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';
import 'package:antirkn_ssh_transport/src/server_inventory_reader.dart';
import 'package:test/test.dart';

Matcher issue(SshIssue issue) =>
    isA<SshFailure>().having((e) => e.issue, 'issue', issue);

SshProfile profile(int port) => SshProfile(
  host: '127.0.0.1',
  port: port,
  username: 'test',
  authMethod: SshAuthMethod.password,
  secrets: {ServerSecret.sshPassword: 'test-password'},
);

void main() {
  group('SSH Transport Chaos & Stress Suite', () {
    test(
      'stress: 50+ concurrent connection attempts with abrupt socket destruction release resources cleanly',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);

        final acceptedSockets = <Socket>[];
        final serverSub = server.listen((socket) {
          acceptedSockets.add(socket);
          // Abruptly destroy the socket simulating sudden TCP reset
          socket.destroy();
        });
        addTearDown(serverSub.cancel);

        const connector = DartSshConnector(
          connectTimeout: Duration(milliseconds: 600),
        );

        final futures = List.generate(55, (index) async {
          final cancellation = CancellationToken();
          try {
            await connector.connect(
              profile(server.port),
              verifyHostKey: (_) async => true,
              cancellation: cancellation,
            );
            fail('Connection should not succeed on destroyed socket');
          } on SshFailure catch (e) {
            // Must be safely categorized failure
            expect(
              e.issue,
              anyOf(
                equals(SshIssue.network),
                equals(SshIssue.timeout),
                equals(SshIssue.cancelled),
                equals(SshIssue.authentication),
              ),
            );
          }
        });

        await Future.wait(futures);

        // Ensure all accepted sockets were destroyed
        for (final s in acceptedSockets) {
          s.destroy();
        }
      },
    );

    test(
      'chaos injection: half-open black-hole socket cleanly times out without unhandled async errors',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);

        final blackHoleSockets = <Socket>[];
        final serverSub = server.listen((socket) {
          blackHoleSockets.add(socket);
          // Absorb data silently without answering (black hole / half-open)
          socket.listen((_) {});
        });
        addTearDown(() {
          serverSub.cancel();
          for (final s in blackHoleSockets) {
            s.destroy();
          }
        });

        const connector = DartSshConnector(
          connectTimeout: Duration(milliseconds: 400),
        );
        final cancellation = CancellationToken();

        await expectLater(
          connector.connect(
            profile(server.port),
            verifyHostKey: (_) async => true,
            cancellation: cancellation,
          ),
          throwsA(anyOf(issue(SshIssue.timeout), issue(SshIssue.network))),
        );
      },
    );

    test(
      'chaos injection: immediate RST reset mid-handshake returns safe network failure',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);

        final serverSub = server.listen((socket) {
          // Send broken banner then immediately destroy
          socket.add([83, 83, 72, 45, 50, 46, 48, 10]); // SSH-2.0\n
          socket.destroy();
        });
        addTearDown(serverSub.cancel);

        const connector = DartSshConnector(
          connectTimeout: Duration(milliseconds: 800),
        );
        final cancellation = CancellationToken();

        await expectLater(
          connector.connect(
            profile(server.port),
            verifyHostKey: (_) async => true,
            cancellation: cancellation,
          ),
          throwsA(
            anyOf(
              issue(SshIssue.network),
              issue(SshIssue.timeout),
              issue(SshIssue.authentication),
            ),
          ),
        );
      },
    );

    test(
      'inventory static fact and binary caching cuts repeat probe command count by >50%',
      () async {
        final executedCommands = <String>[];
        Future<String> mockExecute(String cmd) async {
          executedCommands.add(cmd);
          if (cmd.contains('uname -r')) return '6.8.0-45-generic';
          if (cmd.contains('cat /proc/1/comm')) return 'systemd';
          if (cmd.contains('_NPROCESSORS_ONLN')) return '4';
          if (cmd.contains('MemTotal:')) return '8192000';
          if (cmd.contains('MemAvailable:')) return '4096000';
          if (cmd.contains("NR==2 {print \$4}")) return '20480000';
          if (cmd.contains("NR==2 {print \$2}")) return '50000000';
          if (cmd.contains('boot_id')) {
            return '11111111-2222-3333-4444-555555555555\neth0 1000 2000';
          }
          if (cmd.contains('id -u')) return '0';
          if (cmd.contains('apt-get')) return 'systemctl\napt-get\ndpkg-query';
          if (cmd.contains('list-units')) return '';
          if (cmd.contains('list-unit-files')) return '';
          if (cmd.contains('docker.sock')) return '@unavailable';
          if (cmd.contains('module')) return '@missing';
          if (cmd.contains('ss -') || cmd.contains('netstat')) return '';
          if (cmd.contains('which') || cmd.contains('--version')) {
            return '@missing';
          }
          return '';
        }

        final cancellation = CancellationToken();

        // 1. Cold observation
        final readerCold = ServerInventoryReader(mockExecute);
        final invCold = await readerCold.read(cancellation);
        final coldCommandCount = executedCommands.length;
        expect(coldCommandCount, greaterThan(15));
        expect(invCold.facts[ServerFact.kernel]?.value, '6.8.0-45-generic');

        // Extract cached static facts and cached binaries
        final cachedStaticFacts = <ServerFact, InventoryValue<String>>{
          for (final entry in invCold.facts.entries)
            if (entry.key != ServerFact.availableMemoryKiB &&
                entry.key != ServerFact.freeDiskKiB &&
                entry.key != ServerFact.networkTraffic &&
                entry.value.status == InventoryStatus.ok)
              entry.key: entry.value,
        };
        final cachedBinaries = <VpnComponent, List<ComponentInstallation>>{
          for (final comp in invCold.components)
            comp.component: comp.installations
                .where((inst) => inst.source == InstallationSource.binary)
                .toList(),
        };

        // 2. Warm observation with caching
        executedCommands.clear();
        final readerWarm = ServerInventoryReader(
          mockExecute,
          cachedFacts: cachedStaticFacts,
          cachedBinaries: cachedBinaries,
        );
        final invWarm = await readerWarm.read(cancellation);
        final warmCommandCount = executedCommands.length;

        // Static facts retained from cache
        expect(invWarm.facts[ServerFact.kernel]?.value, '6.8.0-45-generic');
        // Dynamic facts still probed
        expect(invWarm.facts[ServerFact.availableMemoryKiB]?.value, '4096000');
        expect(invWarm.facts[ServerFact.freeDiskKiB]?.value, '20480000');

        // Verify >50% reduction in probed commands
        expect(warmCommandCount, lessThan((coldCommandCount * 0.5).round()));
      },
    );
  });
}
