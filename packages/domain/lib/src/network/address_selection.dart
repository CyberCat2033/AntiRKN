import 'dart:convert';

import 'ip_address.dart';
import 'network_inventory.dart';

enum AddressRole { listener, endpoint }

enum AddressChoiceSource { assigned, wildcard }

enum SelectionIssue {
  interfaceDown,
  unknown,
  tentative,
  dadfailed,
  expired,
  deprecated,
  temporary,
  notPublic,
  unsupportedAddress,
  tunnel,
  scopeRequired,
  unavailable,
  stale,
}

final class AddressChoice {
  const AddressChoice({
    required this.id,
    required this.address,
    required this.source,
    this.assignment,
    this.issue,
  });
  final String id;
  final IpAddress address;
  final AddressChoiceSource source;
  final AddressAssignment? assignment;
  final SelectionIssue? issue;
  bool get enabled => issue == null;
  String get host => address.canonical;
}

/// Shared policy for future protocol forms. No port or reachability claims.
final class AddressSelectionPolicy {
  const AddressSelectionPolicy({
    this.families = const {IpFamily.ipv4, IpFamily.ipv6},
    this.allowWildcard = true,
  });
  final Set<IpFamily> families;
  final bool allowWildcard;

  List<AddressChoice> choices(
    ServerNetworkInventory inventory,
    AddressRole role, {
    required DateTime now,
  }) {
    final choices = <AddressChoice>[];
    if (role == AddressRole.listener && allowWildcard) {
      for (final text in ['0.0.0.0', '::']) {
        final address = IpAddress.parse(text);
        if (!families.contains(address.family)) continue;
        choices.add(
          AddressChoice(
            id: jsonEncode([
              inventory.serverId,
              inventory.namespace,
              'wildcard',
              text,
            ]),
            address: address,
            source: AddressChoiceSource.wildcard,
          ),
        );
      }
    }
    for (final entry in inventory.addresses) {
      if (!families.contains(entry.address.family)) continue;
      for (final assignment in entry.assignments) {
        choices.add(
          AddressChoice(
            id: jsonEncode([entry.id, assignment.identity]),
            address: entry.address,
            source: AddressChoiceSource.assigned,
            assignment: assignment,
            issue: _issue(entry.address, assignment, role, now),
          ),
        );
      }
    }
    return List.unmodifiable(choices);
  }

  SelectionIssue? validateSelection(
    AddressChoice selected,
    ServerNetworkInventory inventory,
    AddressRole role, {
    required DateTime now,
  }) {
    for (final current in choices(inventory, role, now: now)) {
      if (current.id == selected.id) return current.issue;
    }
    return SelectionIssue.unavailable;
  }

  SelectionIssue? _issue(
    IpAddress ip,
    AddressAssignment assignment,
    AddressRole role,
    DateTime now,
  ) {
    if (now.isBefore(assignment.observedAt)) return SelectionIssue.stale;
    final health = assignment.healthAt(now);
    if (health != AddressHealth.ready) {
      return switch (health) {
        AddressHealth.interfaceDown => SelectionIssue.interfaceDown,
        AddressHealth.unknown => SelectionIssue.unknown,
        AddressHealth.tentative => SelectionIssue.tentative,
        AddressHealth.dadfailed => SelectionIssue.dadfailed,
        AddressHealth.expired => SelectionIssue.expired,
        AddressHealth.deprecated => SelectionIssue.deprecated,
        AddressHealth.temporary => SelectionIssue.temporary,
        AddressHealth.ready => null,
      };
    }
    if (role == AddressRole.endpoint) {
      if (ip.category != IpCategory.publicUnicast) {
        return SelectionIssue.notPublic;
      }
      if (assignment.isTunnel) return SelectionIssue.tunnel;
    } else {
      if (const {
        IpCategory.unspecified,
        IpCategory.multicast,
        IpCategory.special,
        IpCategory.documentation,
      }.contains(ip.category)) {
        return SelectionIssue.unsupportedAddress;
      }
      if (ip.family == IpFamily.ipv6 && ip.category == IpCategory.linkLocal) {
        // Protocol adapters must explicitly implement zone/interface binding.
        return SelectionIssue.scopeRequired;
      }
    }
    return null;
  }
}
