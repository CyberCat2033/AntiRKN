import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/src/inventory_probes.dart';
import 'package:antirkn_ssh_transport/src/server_inventory_reader.dart';
import 'package:test/test.dart';

Map<String, String> cleanResponses() => {
  for (final entry in InventoryProbes.facts.entries)
    entry.value: switch (entry.key) {
      ServerFact.kernel => '6.8.0-99-generic',
      ServerFact.init => 'systemd',
      ServerFact.tools => 'apt-get\ndpkg-query\nsystemctl\nsudo\n',
      ServerFact.uid => '1000',
      ServerFact.networkTraffic =>
        '00000000-0000-0000-0000-000000000000\neth0 1024 1024',
      _ => '1024',
    },
  InventoryProbes.services: '',
  InventoryProbes.serviceFiles: '',
  InventoryProbes.containers: '@unavailable',
  InventoryProbes.module: '@missing',
  for (final path in InventoryProbes.binaries.keys)
    InventoryProbes.binaryPresence(path): '@missing',
  for (final protocol in SocketProtocol.values)
    for (final family in IpFamily.values)
      InventoryProbes.sockets(protocol, family): '',
};
Future<ServerSoftwareInventory> read(
  Map<String, String> responses, {
  Set<String> failures = const {},
}) => ServerInventoryReader((command) async {
  expect(InventoryProbes.isAllowedCommand(command), isTrue);
  final key = command.substring(InventoryProbes.prefix.length);
  if (failures.contains(key)) throw const SshFailure(SshIssue.commandFailed);
  return responses[key] ??
      (key.contains(' exec ')
          ? '@missing'
          : throw StateError('Missing fixture command'));
}).read(CancellationToken());

void main() {
  test(
    'container daemon and tools versions are read separately; image tag is not a version',
    () async {
      final id = 'c' * 64;
      final responses = cleanResponses()
        ..[InventoryProbes.containers] =
            '${jsonEncode(id)}\t"amnezia-awg2:latest"\t"running"\t"amnezia-awg2"'
        ..[InventoryProbes.containerVersion(id, 'amneziawg-go')] =
            'amneziawg-go v3.0.0\n\nUserspace daemon'
        ..[InventoryProbes.containerVersion(id, 'awg')] =
            'amneziawg-tools v3.1.20260812 - https://amnezia.org';
      final awg = (await read(responses)).components.last;
      expect(awg.installations.map((i) => i.version?.value), [
        null,
        '3.0.0',
        '3.1.20260812',
      ]);
      expect(awg.installations[1].identity, endsWith('amneziawg-go'));
      expect(awg.installations[2].identity, endsWith('awg'));
      responses[InventoryProbes.containerVersion(id, 'amneziawg-go')] =
          '@denied';
      final denied = (await read(responses)).components.last;
      expect(denied.presence, ComponentPresence.detected);
      expect(denied.issues, contains(InventoryStatus.denied));
      expect(denied.installations[2].version!.value, '3.1.20260812');
    },
  );

  test('container probes accept only full IDs and known version binaries', () {
    final id = 'a' * 64;
    final command =
        '${InventoryProbes.prefix}${InventoryProbes.containerVersion(id, 'awg')}';
    expect(InventoryProbes.isAllowedCommand(command), isTrue);
    expect(InventoryProbes.canElevate(command), isTrue);
    expect(
      InventoryProbes.canElevate('${InventoryProbes.prefix}id -u'),
      isFalse,
    );
    expect(
      InventoryProbes.isAllowedCommand('$command; echo injected'),
      isFalse,
    );
    for (final bad in ['abc', '$id; id', '-$id', '$id\n']) {
      expect(
        () => InventoryProbes.containerVersion(bad, 'awg'),
        throwsArgumentError,
      );
    }
    expect(
      () => InventoryProbes.containerVersion(id, 'sh'),
      throwsArgumentError,
    );
  });

  test(
    'stopped containers are detected without starting or executing them',
    () async {
      final responses = cleanResponses()
        ..[InventoryProbes.containers] =
            '${jsonEncode('d' * 64)}\t"amnezia-awg2"\t"exited"';
      final result = await ServerInventoryReader((command) async {
        expect(command, isNot(contains(' exec ')));
        return responses[command.substring(InventoryProbes.prefix.length)]!;
      }).read(CancellationToken());
      expect(result.components.last.installations.single.version, isNull);
    },
  );

  test(
    'slow inspection survives the old deadline and uses at most three concurrent reads',
    () async {
      final responses = cleanResponses();
      var active = 0, peak = 0;
      final result = await ServerInventoryReader((command) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
        return responses[command.substring(InventoryProbes.prefix.length)]!;
      }, elapsed: () => const Duration(minutes: 2)).read(CancellationToken());
      expect(
        result.facts.values.every((v) => v.status == InventoryStatus.ok),
        isTrue,
      );
      expect(
        result.sockets.every((s) => s.result.status == InventoryStatus.ok),
        isTrue,
      );
      expect(peak, 3);
    },
  );
  test(
    'core inventory probes (services, files, containers, module) execute concurrently (Audit #2)',
    () async {
      final responses = cleanResponses();
      var coreActive = 0, corePeak = 0;
      final coreCommands = {
        InventoryProbes.services,
        InventoryProbes.serviceFiles,
        InventoryProbes.containers,
        InventoryProbes.module,
      };
      await ServerInventoryReader((command) async {
        final stripped = command.substring(InventoryProbes.prefix.length);
        if (coreCommands.contains(stripped)) {
          coreActive++;
          if (coreActive > corePeak) corePeak = coreActive;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          coreActive--;
        }
        return responses[stripped]!;
      }).read(CancellationToken());
      expect(corePeak, greaterThan(1));
      expect(corePeak, lessThanOrEqualTo(3));
    },
  );
  test(
    'official AWG 1/2/3 family is detected by image or container name without guessing version',
    () async {
      for (final image in [
        'amnezia-awg:latest',
        'amnezia-awg2:latest',
        'amnezia-awg3:latest',
        'amneziavpn/amneziawg-go:latest',
        'sha256:${'b' * 64}',
      ]) {
        final responses = cleanResponses()
          ..[InventoryProbes.containers] =
              '${jsonEncode('a' * 64)}\t${jsonEncode(image)}\t"running"\t"amnezia-awg2"\n';
        final result = await read(responses);
        final awg = result.components.last;
        expect(awg.presence, ComponentPresence.detected);
        expect(awg.installations.single.version, isNull);
        expect(awg.installations.single.state, ServiceState.running);
      }
      expect(parseVersion('amneziawg-tools v3.1.20260812'), '3.1.20260812');
      expect(
        parseContainers(
          '${jsonEncode('a' * 64)}\t"alpine:latest"\t"running"\t"unrelated"',
        ),
        isEmpty,
      );
    },
  );
  test('clean host absence is successful, not a failed check', () async {
    final result = await read(cleanResponses());
    expect(
      result.components.map((c) => c.presence),
      everyElement(ComponentPresence.absent),
    );
    expect(result.facts[ServerFact.uid]!.value, '1000');
    expect(result.sockets, hasLength(4));
    expect(result.sockets.every((s) => s.result.value!.isEmpty), isTrue);
  });
  test(
    'binary, inactive service, Docker and loaded AWG are separate evidence',
    () async {
      final responses = cleanResponses()
        ..[InventoryProbes.binaryPresence('/usr/local/x-ui/x-ui')] = '@present'
        ..[InventoryProbes.version('/usr/local/x-ui/x-ui')] = 'v3.7.0\n'
        ..[InventoryProbes.services] =
            'x-ui.service loaded inactive dead Panel\n'
        ..[InventoryProbes.serviceFiles] =
            'x-ui.service enabled enabled\nawg-quick@.service disabled enabled\n'
        ..[InventoryProbes.containers] =
            '${jsonEncode('a' * 64)}\t"ghcr.io/trusttunnel/trusttunnel:custom"\t"running"\n'
        ..[InventoryProbes.module] = '1.0.0\n';
      final result = await read(responses);
      final panel = result.components.first;
      expect(panel.presence, ComponentPresence.detected);
      expect(
        panel.installations.map((i) => i.source),
        containsAll([InstallationSource.binary, InstallationSource.systemd]),
      );
      expect(panel.installations.first.state, ServiceState.stopped);
      expect(panel.installations.last.version!.value, '3.7.0');
      final tt = result.components[2].installations.single;
      expect(tt.source, InstallationSource.docker);
      expect(tt.version, isNull);
      expect(tt.state, ServiceState.running);
      expect(
        result.components[3].installations.last.source,
        InstallationSource.kernel,
      );
    },
  );
  test(
    'denied Docker or paths cannot produce absent; other facts survive',
    () async {
      final responses = cleanResponses()
        ..[InventoryProbes.containers] = '@denied';
      final result = await read(responses);
      expect(
        result.components.map((c) => c.presence),
        everyElement(ComponentPresence.unknown),
      );
      expect(result.facts[ServerFact.kernel]!.value, '6.8.0-99-generic');
      responses[InventoryProbes.containers] = '@unavailable';
      responses[InventoryProbes.binaryPresence(
            '/opt/trusttunnel/trusttunnel_endpoint',
          )] =
          '@denied';
      final partial = await read(responses);
      expect(partial.components[2].presence, ComponentPresence.unknown);
      expect(partial.components[0].presence, ComponentPresence.absent);
    },
  );
  test(
    'failed version retains detected component without guessed version',
    () async {
      final responses = cleanResponses()
        ..[InventoryProbes.binaryPresence('/usr/bin/awg')] = '@present'
        ..[InventoryProbes.version('/usr/bin/awg')] =
            'unrecognized output credential=PRIVATE';
      final result = await read(
        responses,
        failures: {InventoryProbes.facts[ServerFact.freeDiskKiB]!},
      );
      expect(result.components.last.presence, ComponentPresence.detected);
      expect(
        result.components.last.installations.single.version!.status,
        InventoryStatus.invalid,
      );
      expect(
        result.components.last.installations.single.version!.value,
        isNull,
      );
      expect(
        result.facts[ServerFact.freeDiskKiB]!.status,
        InventoryStatus.failed,
      );
      expect(result.facts[ServerFact.cpuCount]!.value, '1024');
    },
  );
  test(
    'timeouts are partial; cancellation and connection loss stop scan',
    () async {
      var calls = 0;
      final responses = cleanResponses();
      final result = await ServerInventoryReader((command) async {
        if (calls++ == 0) throw TimeoutException('safe test');
        return responses[command.substring(InventoryProbes.prefix.length)]!;
      }).read(CancellationToken());
      expect(result.facts[ServerFact.kernel]!.status, InventoryStatus.timeout);
      expect(result.facts[ServerFact.init]!.value, 'systemd');
      calls = 0;
      final token = CancellationToken();
      await expectLater(
        ServerInventoryReader((_) async {
          calls++;
          token.cancel();
          return 'systemd';
        }).read(token),
        throwsA(
          isA<SshFailure>().having((e) => e.issue, 'issue', SshIssue.cancelled),
        ),
      );
      expect(calls, 1);
      await expectLater(
        ServerInventoryReader(
          (_) async => throw const SshFailure(SshIssue.network),
        ).read(CancellationToken()),
        throwsA(isA<SshFailure>()),
      );
    },
  );
  test(
    'global deadline and output limit bound optional observations',
    () async {
      var time = DateTime.utc(2026), calls = 0;
      final reader = ServerInventoryReader(
        (_) async {
          calls++;
          time = time.add(const Duration(minutes: 6));
          return 'x' * 65537;
        },
        clock: () => time,
        elapsed: () => time.difference(DateTime.utc(2026)),
      );
      final result = await reader.read(CancellationToken());
      expect(calls, 1);
      expect(
        result.facts[ServerFact.kernel]!.status,
        InventoryStatus.outputLimit,
      );
      expect(
        result.components.map((c) => c.presence),
        everyElement(ComponentPresence.unknown),
      );
    },
  );
  test(
    'version parsing keeps only tokens, rejects errors and control characters',
    () {
      for (final sample in [
        'Xray 26.3.27 (Xray, Penetrates Everything.)\nextra',
        'v3.7.0',
        '1.1.0',
        'amneziawg-tools v1.0.20250522 - https://amnezia.org',
      ]) {
        expect(parseVersion(sample), matches(r'^[0-9.]+$'));
      }
      for (final sample in [
        '',
        'error secret=token',
        'password 1.1.0',
        '\u001b[31m1.1.0',
      ]) {
        expect(() => parseVersion(sample), throwsFormatException);
      }
    },
  );
  test('ports preserve families wildcard scope protocol and numeric order', () {
    final v4 = parseSockets(
      'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\nLISTEN 0 128 127.0.0.1:22 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:443 0.0.0.0:*',
      SocketProtocol.tcp,
      IpFamily.ipv4,
    );
    expect(v4.map((s) => s.port), [22, 443]);
    final v6 = parseSockets(
      'UNCONN 0 0 [fe80::1%eth0]:53 [::]:*\nUNCONN 0 0 *:51820 *:*',
      SocketProtocol.udp,
      IpFamily.ipv6,
    );
    expect(v6.first.address, 'fe80::1%eth0');
    expect(v6.last.address, '*');
    expect(v6.last.protocol, SocketProtocol.udp);
    for (final sample in [
      'garbage',
      'LISTEN 0 0 127.0.0.1:99999 *:*',
      'LISTEN 0 0 [::]:22 *:*',
    ]) {
      expect(
        () => parseSockets(sample, SocketProtocol.tcp, IpFamily.ipv4),
        throwsFormatException,
      );
    }
  });
  test(
    'unknown states/images never imply running component, no injected command',
    () {
      expect(
        parseUnits(
          'awg-quick@awg0.service loaded activating start AWG',
          live: true,
        ).values.single,
        ServiceState.unknown,
      );
      expect(
        parseContainers(
          '${jsonEncode('a' * 64)}\t"unrelated/image:1"\t"running"',
        ),
        isEmpty,
      );
      expect(
        componentForUnit('antirkn-trusttunnel.service'),
        VpnComponent.trustTunnel,
      );
      expect(
        componentForUnit('antirkn-awg@awg0.service'),
        VpnComponent.amneziaWg,
      );
      expect(() => parseUnits('not output', live: true), throwsFormatException);
      expect(() => parseContainers('private data'), throwsFormatException);
      expect(
        () => InventoryProbes.version('/tmp/evil;shutdown'),
        throwsArgumentError,
      );
    },
  );
}
