import 'network/ip_address.dart';

/// Last successful inspection, retained offline without implying a live session.
final class ServerInfo {
  const ServerInfo({
    required this.os,
    required this.architecture,
    required this.observedAt,
    this.software,
  });
  final String os;
  final String architecture;
  final DateTime observedAt;
  final ServerSoftwareInventory? software;
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
  uid,
  tools,
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
