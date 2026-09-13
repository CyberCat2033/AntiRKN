import 'dart:convert';

import 'ip_address.dart';

enum NetworkSource { iproute2, sample }

enum AddressFlag {
  secondary,
  temporary,
  tentative,
  deprecated,
  dadfailed,
  optimistic,
}

enum AddressHealth {
  ready,
  interfaceDown,
  unknown,
  tentative,
  dadfailed,
  expired,
  deprecated,
  temporary,
}

final class AddressAssignment {
  AddressAssignment({
    required this.interfaceName,
    required this.interfaceIndex,
    required this.prefixLength,
    required this.scope,
    required this.operState,
    required Set<String> interfaceFlags,
    required Set<AddressFlag> flags,
    required this.observedAt,
    this.validLifetimeSeconds,
    this.preferredLifetimeSeconds,
    this.linkKind,
    this.peer,
  }) : interfaceFlags = Set.unmodifiable(interfaceFlags),
       flags = Set.unmodifiable(flags);

  final String interfaceName;
  final int interfaceIndex;
  final int prefixLength;
  final String scope;
  final String operState;
  final Set<String> interfaceFlags;
  final Set<AddressFlag> flags;
  final DateTime observedAt;
  // null = not reported; 0xffffffff = forever (iproute2 numeric JSON form).
  final int? validLifetimeSeconds;
  final int? preferredLifetimeSeconds;
  final String? linkKind;
  final IpAddress? peer;

  String get identity => jsonEncode([interfaceName, prefixLength]);
  bool get isTunnel => const {
    'tun',
    'wireguard',
    'amneziawg',
    'gre',
    'gretap',
    'ipip',
    'sit',
    'ip6tnl',
    'ip6gre',
    'ip6gretap',
    'vti',
    'vti6',
    'vxlan',
    'geneve',
  }.contains(linkKind);

  bool _ended(int? seconds, DateTime at) =>
      seconds != null &&
      seconds != 0xffffffff &&
      !at.isBefore(observedAt.add(Duration(seconds: seconds)));

  AddressHealth healthAt(DateTime at) {
    if (flags.contains(AddressFlag.dadfailed)) return AddressHealth.dadfailed;
    if (flags.contains(AddressFlag.tentative) ||
        flags.contains(AddressFlag.optimistic)) {
      return AddressHealth.tentative;
    }
    if (_ended(validLifetimeSeconds, at)) return AddressHealth.expired;
    if (!interfaceFlags.contains('UP') ||
        const {
          'DOWN',
          'LOWERLAYERDOWN',
          'NOTPRESENT',
          'DORMANT',
          'TESTING',
        }.contains(operState)) {
      return AddressHealth.interfaceDown;
    }
    if (!const {'UP', 'UNKNOWN'}.contains(operState) ||
        validLifetimeSeconds == null ||
        preferredLifetimeSeconds == null) {
      return AddressHealth.unknown;
    }
    if (flags.contains(AddressFlag.deprecated) ||
        _ended(preferredLifetimeSeconds, at)) {
      return AddressHealth.deprecated;
    }
    if (flags.contains(AddressFlag.temporary)) return AddressHealth.temporary;
    return AddressHealth.ready;
  }
}

final class ServerAddress {
  ServerAddress({
    required this.serverId,
    required this.namespace,
    required this.address,
    required Iterable<AddressAssignment> assignments,
  }) : assignments = List.unmodifiable(assignments);

  final String serverId;
  final String namespace;
  final IpAddress address;
  final List<AddressAssignment> assignments;
  AddressClass get addressClass => address.addressClass;
  String get id =>
      jsonEncode([serverId, namespace, address.family.name, address.canonical]);
}

/// Routing observations, not an inferred effective route or proof of reachability.
final class RouteObservation {
  RouteObservation({
    required this.family,
    required Map<String, Object?> attributes,
  }) : attributes = freezeJson(attributes) as Map<String, Object?>;
  final IpFamily family;
  final Map<String, Object?> attributes;
  String get destination => attributes['dst'] as String? ?? 'default';
  String? get interfaceName => attributes['dev'] as String?;
  Object get table => attributes['table'] ?? 'main';
}

final class RuleObservation {
  RuleObservation({
    required this.family,
    required Map<String, Object?> attributes,
  }) : attributes = freezeJson(attributes) as Map<String, Object?>;
  final IpFamily family;
  final Map<String, Object?> attributes;
  int? get priority => attributes['priority'] as int?;
  Object? get table => attributes['table'];
}

Object? freezeJson(Object? value) => switch (value) {
  Map<String, Object?> map => Map<String, Object?>.unmodifiable(
    map.map((key, value) => MapEntry(key, freezeJson(value))),
  ),
  List list => List<Object?>.unmodifiable(list.map(freezeJson)),
  _ => value,
};

final class ServerNetworkInventory {
  ServerNetworkInventory({
    required this.serverId,
    required this.namespace,
    required this.observedAt,
    required this.source,
    required Iterable<ServerAddress> addresses,
    required Iterable<RouteObservation> routes,
    required Iterable<RuleObservation> rules,
    this.sshPeer,
  }) : addresses = List.unmodifiable(addresses),
       routes = List.unmodifiable(routes),
       rules = List.unmodifiable(rules);
  final String serverId;
  final String namespace;
  final DateTime observedAt;
  final NetworkSource source;
  final List<ServerAddress> addresses;
  final List<RouteObservation> routes;
  final List<RuleObservation> rules;
  // Actual numeric SSH transport peer; never automatically used as a bind.
  final IpAddress? sshPeer;
}

abstract interface class NetworkInventoryReader {
  Future<ServerNetworkInventory> read();
}
