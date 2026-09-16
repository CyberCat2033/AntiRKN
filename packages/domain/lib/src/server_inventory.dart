import 'network/ip_address.dart';

/// Last successful inspection, retained offline without implying a live session.
final class ServerInfo {
  const ServerInfo({
    required this.os,
    required this.architecture,
    required this.observedAt,
    this.software,
    this.publicAddresses,
  });
  final String os;
  final String architecture;
  final DateTime observedAt;
  final ServerSoftwareInventory? software;

  /// null means the older cache did not record addresses; [] means none found.
  final List<IpAddress>? publicAddresses;
}

enum InventoryStatus {
  ok,
  unavailable,
  denied,
  failed,
  timeout,
  invalid,
  outputLimit,
}

/// A failed observation is distinct from an empty successful observation.
final class InventoryValue<T> {
  const InventoryValue.ok(T this.value) : status = InventoryStatus.ok;
  const InventoryValue.failure(this.status) : value = null;
  final InventoryStatus status;
  final T? value;
}

enum ServerFact {
  kernel,
  init,
  cpuCount,
  memoryKiB,
  availableMemoryKiB,
  freeDiskKiB,
  totalDiskKiB,
  networkTraffic,
  uid,
  tools,
}

/// One bounded, read-only sample of the server's default-route interfaces.
final class ServerTrafficSnapshot {
  const ServerTrafficSnapshot({required this.bootId, required this.counters});
  final String bootId;
  final Map<String, (int received, int sent)> counters;
  String get interfaces => (counters.keys.toList()..sort()).join(', ');
  int get received => counters.values.fold(0, (sum, v) => sum + v.$1);
  int get sent => counters.values.fold(0, (sum, v) => sum + v.$2);

  factory ServerTrafficSnapshot.parse(String text) {
    final lines = text.trim().split('\n');
    if (lines.length < 2 ||
        lines.length > 65 ||
        !RegExp(r'^[a-f0-9-]{36}$').hasMatch(lines.first)) {
      throw const FormatException('traffic_sample');
    }
    final counters = <String, (int, int)>{};
    for (final line in lines.skip(1)) {
      final match = RegExp(
        r'^([a-zA-Z0-9_.:-]{1,32}) ([0-9]{1,19}) ([0-9]{1,19})$',
      ).firstMatch(line);
      if (match == null || counters.containsKey(match[1])) {
        throw const FormatException('traffic_counter');
      }
      final rx = int.tryParse(match[2]!), tx = int.tryParse(match[3]!);
      if (rx == null || tx == null || rx < 0 || tx < 0) {
        throw const FormatException('traffic_counter');
      }
      counters[match[1]!] = (rx, tx);
    }
    return ServerTrafficSnapshot(
      bootId: lines.first,
      counters: Map.unmodifiable(counters),
    );
  }
}

enum VpnComponent { panel, xray, trustTunnel, amneziaWg }

enum ComponentPresence { detected, absent, unknown }

enum InstallationSource { binary, systemd, docker, kernel }

enum ServiceState { running, stopped, failed, unknown }

final class ComponentInstallation {
  const ComponentInstallation({
    required this.source,
    required this.identity,
    this.state = ServiceState.unknown,
    this.version,
  });
  final InstallationSource source;
  final String identity;
  final ServiceState state;
  // Observed binary/module version only; an image tag is never a binary version.
  final InventoryValue<String>? version;
}

final class ComponentObservation {
  ComponentObservation({
    required this.component,
    required this.presence,
    required Iterable<ComponentInstallation> installations,
    required Iterable<InventoryStatus> issues,
  }) : installations = List.unmodifiable(installations),
       issues = Set.unmodifiable(issues);
  final VpnComponent component;
  final ComponentPresence presence;
  final List<ComponentInstallation> installations;
  final Set<InventoryStatus> issues;
}

enum SocketProtocol { tcp, udp }

final class ServerSocketObservation {
  const ServerSocketObservation({
    required this.protocol,
    required this.family,
    required this.address,
    required this.port,
  });
  final SocketProtocol protocol;
  final IpFamily family;
  // Numeric bind (possibly scoped) or wildcard, never a client endpoint.
  final String address;
  final int port;
}

final class SocketInventory {
  const SocketInventory({
    required this.protocol,
    required this.family,
    required this.result,
  });
  final SocketProtocol protocol;
  final IpFamily family;
  final InventoryValue<List<ServerSocketObservation>> result;
}

final class ServerSoftwareInventory {
  ServerSoftwareInventory({
    required this.observedAt,
    required Map<ServerFact, InventoryValue<String>> facts,
    required Iterable<ComponentObservation> components,
    required Iterable<SocketInventory> sockets,
  }) : facts = Map.unmodifiable(facts),
       components = List.unmodifiable(components),
       sockets = List.unmodifiable(sockets);
  final DateTime observedAt;
  final Map<ServerFact, InventoryValue<String>> facts;
  final List<ComponentObservation> components;
  final List<SocketInventory> sockets;
}
