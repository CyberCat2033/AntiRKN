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
  expect(InventoryProbes.allowedCommands, contains(command));
  final key = command.substring(InventoryProbes.prefix.length);
  if (failures.contains(key)) throw const SshFailure(SshIssue.commandFailed);
  return responses[key] ?? (throw StateError('Missing fixture command'));
}).read(CancellationToken());

void main() {
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
      expect(() => parseUnits('not output', live: true), throwsFormatException);
      expect(() => parseContainers('private data'), throwsFormatException);
      expect(
        () => InventoryProbes.version('/tmp/evil;shutdown'),
        throwsArgumentError,
      );
    },
  );
}
