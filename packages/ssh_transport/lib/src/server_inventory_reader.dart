import 'dart:async';
import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';

import 'inventory_probes.dart';
import 'parallel_reads.dart';

/// All output is reduced to typed observations; stderr/configs/env are never kept.
final class ServerInventoryReader {
  ServerInventoryReader(
    this.execute, {
    DateTime Function()? clock,
    this.elapsed,
  }) : clock = clock ?? DateTime.now;
  final Future<String> Function(String command) execute;
  final DateTime Function() clock;
  final Duration Function()? elapsed;

  Future<ServerSoftwareInventory> read(CancellationToken cancellation) async {
    final started = clock();
    final stopwatch = Stopwatch()..start();
    Future<InventoryValue<T>> probe<T>(
      String command,
      T Function(String) parse,
    ) async {
      cancellation.check();
      if ((elapsed?.call() ?? stopwatch.elapsed) >=
          const Duration(minutes: 5)) {
        return const InventoryValue.failure(InventoryStatus.timeout);
      }
      try {
        final raw = await execute('${InventoryProbes.prefix}$command');
        cancellation.check();
        if (raw.length > 65536) {
          return const InventoryValue.failure(InventoryStatus.outputLimit);
        }
        final marker = raw.trim();
        if (marker == '@unavailable') {
          return const InventoryValue.failure(InventoryStatus.unavailable);
        }
        if (marker == '@denied') {
          return const InventoryValue.failure(InventoryStatus.denied);
        }
        return InventoryValue.ok(parse(raw));
      } on SshFailure catch (e) {
        final status = switch (e.issue) {
          SshIssue.commandFailed => InventoryStatus.failed,
          SshIssue.timeout => InventoryStatus.timeout,
          SshIssue.outputLimit => InventoryStatus.outputLimit,
          SshIssue.invalidInventory => InventoryStatus.invalid,
          SshIssue.sudoDenied ||
          SshIssue.sudoPasswordRequired ||
          SshIssue.sudoAuthenticationFailed ||
          SshIssue.sudoUnavailable ||
          SshIssue.sudoTerminalRequired => InventoryStatus.denied,
          _ => null,
        };
        if (status == null) rethrow;
        return InventoryValue.failure(status);
      } on TimeoutException {
        return const InventoryValue.failure(InventoryStatus.timeout);
      } on FormatException {
        return const InventoryValue.failure(InventoryStatus.invalid);
      }
    }

    final facts = Map.fromEntries(
      await parallelReads(
        InventoryProbes.facts.entries,
        (entry) async => MapEntry(
          entry.key,
          await probe(entry.value, (raw) => parseFact(entry.key, raw)),
        ),
      ),
    );
    final coreProbes = await parallelReads(
      [
        () => probe(InventoryProbes.services, (s) => parseUnits(s, live: true)),
        () => probe(InventoryProbes.serviceFiles, (s) => parseUnits(s, live: false)),
        () => probe(InventoryProbes.containers, parseContainers),
        () => probe(InventoryProbes.module, (s) {
          if (s.trim() == '@missing' || s.trim() == '@present') return s.trim();
          return parseVersion(s);
        }),
      ],
      (runProbe) => runProbe(),
    );
    final units = coreProbes[0] as InventoryValue<Map<String, ServiceState>>;
    final files = coreProbes[1] as InventoryValue<Map<String, ServiceState>>;
    final containers = coreProbes[2] as InventoryValue<List<ContainerObservation>>;
    final module = coreProbes[3] as InventoryValue<String?>;
    final found = {
      for (final c in VpnComponent.values) c: <ComponentInstallation>[],
    };
    final issues = {
      for (final c in VpnComponent.values) c: <InventoryStatus>{},
    };
    bool incomplete(InventoryStatus s) =>
        s != InventoryStatus.ok && s != InventoryStatus.unavailable;
    final uncertain = <VpnComponent>{};
    void recordIssue(
      VpnComponent c,
      InventoryStatus s, {
      bool affectsPresence = true,
    }) {
      issues[c]!.add(s);
      if (affectsPresence) uncertain.add(c);
    }

    for (final c in VpnComponent.values) {
      for (final status in [units.status, files.status, containers.status]) {
        if (incomplete(status)) recordIssue(c, status);
      }
      // A service file can be detected even when this host is not booted under systemd.
      final names = <String>{...?files.value?.keys, ...?units.value?.keys};
      for (final name in names.where((n) => componentForUnit(n) == c)) {
        found[c]!.add(
          ComponentInstallation(
            source: InstallationSource.systemd,
            identity: name,
            state: units.value?[name] ?? ServiceState.unknown,
          ),
        );
      }
      for (final container in containers.value ?? <ContainerObservation>[]) {
        if (container.component != c) continue;
        final identity =
            '${container.image} · ${container.id.substring(0, 12)}';
        found[c]!.add(
          ComponentInstallation(
            source: InstallationSource.docker,
            identity: identity,
            state: container.state,
          ),
        );
        if (c != VpnComponent.amneziaWg ||
            container.state != ServiceState.running) {
          continue;
        }
        for (final binary in InventoryProbes.containerBinaries) {
          final version = await probe(
            InventoryProbes.containerVersion(container.id, binary),
            (s) => s.trim() == '@missing' ? null : parseVersion(s),
          );
          if (version.status == InventoryStatus.ok && version.value == null) {
            continue;
          }
          if (version.status != InventoryStatus.ok) {
            recordIssue(c, version.status, affectsPresence: false);
          }
          found[c]!.add(
            ComponentInstallation(
              source: InstallationSource.docker,
              identity: '$identity · $binary',
              state: container.state,
              version: version.value != null
                  ? InventoryValue.ok(version.value!)
                  : InventoryValue.failure(version.status),
            ),
          );
        }
      }
    }

    final binaryResults = await parallelReads(
      InventoryProbes.binaries.entries,
      (entry) async {
        final presence = await probe(
          InventoryProbes.binaryPresence(entry.key),
          (s) {
            if (!const {'@present', '@missing'}.contains(s.trim())) {
              throw const FormatException('binary_presence');
            }
            return s.trim() == '@present';
          },
        );
        final version = presence.value == true
            ? await probe(InventoryProbes.version(entry.key), parseVersion)
            : null;
        return (entry, presence, version);
      },
    );
    for (final (entry, presence, version) in binaryResults) {
      if (presence.status != InventoryStatus.ok) {
        recordIssue(entry.value, presence.status);
      }
      if (version != null) {
        if (version.status != InventoryStatus.ok) {
          recordIssue(entry.value, version.status, affectsPresence: false);
        }
        found[entry.value]!.add(
          ComponentInstallation(
            source: InstallationSource.binary,
            identity: entry.key,
            version: version,
          ),
        );
      }
    }
    if (incomplete(module.status)) {
      recordIssue(VpnComponent.amneziaWg, module.status);
    }
    if (module.value != null && module.value != '@missing') {
      found[VpnComponent.amneziaWg]!.add(
        ComponentInstallation(
          source: InstallationSource.kernel,
          identity: 'amneziawg',
          version: module.value == '@present'
              ? null
              : InventoryValue.ok(module.value!),
        ),
      );
    }
    final sockets = await parallelReads(
      [
        for (final protocol in SocketProtocol.values)
          for (final family in IpFamily.values) (protocol, family),
      ],
      (pair) async {
        final (protocol, family) = pair;
        return SocketInventory(
          protocol: protocol,
          family: family,
          result: await probe(
            InventoryProbes.sockets(protocol, family),
            (s) => parseSockets(s, protocol, family),
          ),
        );
      },
    );
    cancellation.check();
    return ServerSoftwareInventory(
      observedAt: started.toUtc(),
      facts: facts,
      components: [
        for (final c in VpnComponent.values)
          ComponentObservation(
            component: c,
            presence: found[c]!.isNotEmpty
                ? ComponentPresence.detected
                : uncertain.contains(c)
                ? ComponentPresence.unknown
                : ComponentPresence.absent,
            installations: found[c]!,
            issues: issues[c]!,
          ),
      ],
      sockets: sockets,
    );
  }
}

String parseFact(ServerFact fact, String raw) {
  final value = raw.trim();
  if (fact == ServerFact.networkTraffic) {
    ServerTrafficSnapshot.parse(value);
    return value;
  }
  if (fact == ServerFact.tools) {
    final lines = const LineSplitter().convert(value);
    if (lines.any(
      (s) => !const {
        'apt-get',
        'dpkg-query',
        'systemctl',
        'docker',
        'sudo',
      }.contains(s),
    )) {
      throw const FormatException('tools');
    }
    return lines.toSet().join(', ');
  }
  if (fact == ServerFact.kernel || fact == ServerFact.init) {
    if (!RegExp(r'^[a-zA-Z0-9_.+()/-]{1,128}$').hasMatch(value)) {
      throw const FormatException('system_fact');
    }
    return value;
  }
  if (!RegExp(r'^[0-9]{1,15}$').hasMatch(value)) {
    throw const FormatException('numeric_fact');
  }
  return value;
}

String parseVersion(String raw) {
  final first = const LineSplitter().convert(raw.trim()).firstOrNull ?? '';
  // Keep just a bounded version token, never a diagnostic line or environment value.
  final match = RegExp(
    r'^(?:(?:Xray|x-ui|3x-ui|amneziawg-tools|amneziawg-go|trusttunnel_endpoint|TrustTunnel)\s+)?v?([0-9]+(?:\.[0-9]+){1,3}(?:[-+][a-zA-Z0-9.-]+)?)(?:\s|$)',
  ).firstMatch(first);
  if (match == null || match[1]!.length > 80) {
    throw const FormatException('version');
  }
  return match[1]!;
}

VpnComponent? componentForUnit(String name) {
  if (!RegExp(r'^[a-zA-Z0-9_.@:\\-]{1,256}\.service$').hasMatch(name)) {
    return null;
  }
  if (RegExp(r'^x-ui(?:[.@-])').hasMatch(name)) return VpnComponent.panel;
  if (RegExp(r'^xray(?:[.@-])').hasMatch(name)) return VpnComponent.xray;
  if (name == 'antirkn-trusttunnel.service' ||
      RegExp(r'^trusttunnel(?:[.@-])').hasMatch(name)) {
    return VpnComponent.trustTunnel;
  }
  if (name.startsWith('antirkn-awg@') ||
      name.startsWith('awg-quick@') ||
      RegExp(r'^amneziawg(?:[.@-])').hasMatch(name)) {
    return VpnComponent.amneziaWg;
  }
  return null;
}

Map<String, ServiceState> parseUnits(String raw, {required bool live}) {
  final result = <String, ServiceState>{};
  for (final line in const LineSplitter().convert(raw)) {
    if (line.trim().isEmpty) continue;
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < (live ? 4 : 2)) throw const FormatException('units');
    final name = fields.first;
    if (componentForUnit(name) == null) {
      if (!RegExp(r'^[a-zA-Z0-9_.@:\\-]{1,256}\.service$').hasMatch(name)) {
        throw const FormatException('unit_name');
      }
      continue;
    }
    // A template alone is evidence of installation, not an active interface.
    result[name] = !live
        ? ServiceState.unknown
        : switch (fields[2]) {
            'failed' => ServiceState.failed,
            'inactive' => ServiceState.stopped,
            'active' => ServiceState.running,
            _ => ServiceState.unknown,
          };
  }
  return Map.unmodifiable(result);
}

final class ContainerObservation {
  const ContainerObservation(this.component, this.id, this.image, this.state);
  final VpnComponent component;
  final String id;
  final String image;
  final ServiceState state;
}

List<ContainerObservation> parseContainers(String raw) {
  final result = <ContainerObservation>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (line.isEmpty) continue;
    final fields = line.split('\t');
    if (fields.length != 3 && fields.length != 4) {
      throw const FormatException('container');
    }
    final decoded = fields.map(jsonDecode).toList();
    if (decoded.any((v) => v is! String)) {
      throw const FormatException('container_fields');
    }
    final id = decoded[0] as String,
        image = decoded[1] as String,
        state = decoded[2] as String;
    final name = decoded.length == 4 ? decoded[3] as String : '';
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        image.length > 256 ||
        !RegExp(r'^[a-zA-Z0-9_./:@-]+$').hasMatch(image) ||
        (name.isNotEmpty &&
            !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,255}$').hasMatch(name))) {
      throw const FormatException('container_identity');
    }
    // Image family is an observation only: do not claim API/runtime compatibility.
    final repository = image
        .split('@')
        .first
        .split('/')
        .last
        .split(':')
        .first
        .toLowerCase();
    // Official AmneziaWG 3.x still uses amnezia-awg2. A numeric
    // suffix identifies the family only, never the protocol version.
    final awgName = RegExp(r'^amnezia-awg(?:[1-9][0-9]*)?$');
    final component =
        awgName.hasMatch(repository) ||
            awgName.hasMatch(name) ||
            repository == 'amneziawg-go'
        ? VpnComponent.amneziaWg
        : switch (repository) {
            '3x-ui' => VpnComponent.panel,
            'xray' || 'xray-core' => VpnComponent.xray,
            'trusttunnel' ||
            'trusttunnel_endpoint' ||
            'trusttunnel-endpoint' => VpnComponent.trustTunnel,
            'amnezia-awg' ||
            'amnezia-awg2' ||
            'amneziawg' ||
            'amnezia-wg' => VpnComponent.amneziaWg,
            _ => null,
          };
    if (component != null) {
      result.add(
        ContainerObservation(component, id, image, switch (state) {
          'running' => ServiceState.running,
          'exited' || 'created' || 'paused' => ServiceState.stopped,
          'dead' => ServiceState.failed,
          _ => ServiceState.unknown,
        }),
      );
    }
  }
  return List.unmodifiable(result);
}

List<ServerSocketObservation> parseSockets(
  String raw,
  SocketProtocol protocol,
  IpFamily family,
) {
  final result = <String, ServerSocketObservation>{};
  for (final line in const LineSplitter().convert(raw)) {
    if (line.trim().isEmpty) continue;
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 5) throw const FormatException('sockets');
    final endpoint = fields[3];
    final split = endpoint.lastIndexOf(':');
    if (split < 1) throw const FormatException('socket_endpoint');
    var address = endpoint.substring(0, split);
    if (address.startsWith('[') && address.endsWith(']')) {
      address = address.substring(1, address.length - 1);
    }
    final port = int.tryParse(endpoint.substring(split + 1));
    if (port == null || port < 0 || port > 65535) {
      throw const FormatException('socket_port');
    }
    if (port == 0) continue;
    final scope = address.split('%');
    if (scope.length > 2 ||
        (scope.length == 2 &&
            !RegExp(r'^[a-zA-Z0-9_.:-]{1,64}$').hasMatch(scope.last))) {
      throw const FormatException('socket_scope');
    }
    if (address != '*' && IpAddress.tryParse(scope.first)?.family != family) {
      throw const FormatException('socket_address');
    }
    result['$address:$port'] = ServerSocketObservation(
      protocol: protocol,
      family: family,
      address: address,
      port: port,
    );
  }
  final sorted = result.values.toList()
    ..sort((a, b) {
      final portOrder = a.port.compareTo(b.port);
      return portOrder == 0 ? a.address.compareTo(b.address) : portOrder;
    });
  return List.unmodifiable(sorted);
}
