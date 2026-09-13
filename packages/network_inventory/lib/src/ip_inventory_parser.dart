import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';

enum InventoryDocument { addresses, routesV4, routesV6, rulesV4, rulesV6 }

enum InventoryDecodeIssue {
  invalidJson,
  invalidShape,
  limitExceeded,
  conflictingAssignment,
}

/// Safe codes only: no command output, credentials or offending input in errors.
final class InventoryDecodeException implements Exception {
  const InventoryDecodeException(this.issue, this.document);
  final InventoryDecodeIssue issue;
  final InventoryDocument document;
  @override
  String toString() =>
      'InventoryDecodeException(${issue.name}, ${document.name})';
}

final class IpCommandOutputs {
  const IpCommandOutputs({
    required this.addresses,
    required this.routesV4,
    required this.routesV6,
    required this.rulesV4,
    required this.rulesV6,
  });
  final String addresses;
  final String routesV4;
  final String routesV6;
  final String rulesV4;
  final String rulesV6;

  /// Fixed argv for a future SSH collector. No execution is performed here.
  /// -details includes link kinds; namespaces other than the SSH shell's current
  /// network namespace need a separate explicit observation.
  static const commands = <InventoryDocument, List<String>>{
    InventoryDocument.addresses: ['ip', '-j', '-details', 'address', 'show'],
    InventoryDocument.routesV4: [
      'ip',
      '-j',
      '-4',
      'route',
      'show',
      'table',
      'all',
    ],
    InventoryDocument.routesV6: [
      'ip',
      '-j',
      '-6',
      'route',
      'show',
      'table',
      'all',
    ],
    InventoryDocument.rulesV4: ['ip', '-j', '-4', 'rule', 'show'],
    InventoryDocument.rulesV6: ['ip', '-j', '-6', 'rule', 'show'],
  };
}

final class IpInventoryParser {
  const IpInventoryParser();
  static const maxDocumentBytes = 1024 * 1024;
  static const maxRecords = 8192;
  static const maxDepth = 24;

  ServerNetworkInventory parse({
    required IpCommandOutputs outputs,
    required String serverId,
    required DateTime observedAt,
    String namespace = 'default',
    NetworkSource source = NetworkSource.iproute2,
    IpAddress? sshPeer,
  }) {
    if (serverId.isEmpty || namespace.isEmpty) {
      throw ArgumentError('inventory_identity_required');
    }
    final timestamp = observedAt.toUtc();
    const document = InventoryDocument.addresses;
    final decoder = _Decoder(document);
    final interfaces = decoder.array(outputs.addresses);
    final assigned = <IpAddress, Map<String, AddressAssignment>>{};
    final fingerprints = <String, String>{};
    var count = interfaces.length;
    for (final value in interfaces) {
      final interface = decoder.object(value);
      final name = decoder.text(interface['ifname']);
      final index = decoder.integer(interface['ifindex'], min: 1);
      final interfaceFlags = decoder.strings(interface['flags']).toSet();
      final state =
          decoder.optionalText(interface['operstate']) ?? 'UNREPORTED';
      final kind = interface['linkinfo'] == null
          ? null
          : decoder.optionalText(
              decoder.object(interface['linkinfo'])['info_kind'],
            );
      final addresses = interface['addr_info'] == null
          ? <Object?>[]
          : decoder.list(interface['addr_info']);
      count += addresses.length;
      if (count > maxRecords) decoder.fail(InventoryDecodeIssue.limitExceeded);
      for (final value in addresses) {
        final record = decoder.object(value);
        final family = switch (record['family']) {
          'inet' => IpFamily.ipv4,
          'inet6' => IpFamily.ipv6,
          _ => decoder.fail(),
        };
        final address = decoder.ip(record['local'], family);
        final prefix = decoder.integer(
          record['prefixlen'],
          max: family == IpFamily.ipv4 ? 32 : 128,
        );
        final scope = decoder.text(record['scope']);
        final rawFlags = record['flags'] == null
            ? <String>{}
            : decoder.strings(record['flags']).toSet();
        final flags = <AddressFlag>{};
        for (final flag in AddressFlag.values) {
          final boolean = record[flag.name];
          if (boolean != null && boolean is! bool) decoder.fail();
          if (boolean == true || rawFlags.contains(flag.name)) flags.add(flag);
        }
        // iproute2 uses the same kernel bit for secondary IPv4/temporary IPv6.
        if (family == IpFamily.ipv6 && flags.remove(AddressFlag.secondary)) {
          flags.add(AddressFlag.temporary);
        }
        if (family == IpFamily.ipv4 && flags.remove(AddressFlag.temporary)) {
          flags.add(AddressFlag.secondary);
        }
        final valid = decoder.lifetime(record['valid_life_time']);
        final preferred = decoder.lifetime(record['preferred_life_time']);
        if (valid != null && preferred != null && preferred > valid) {
          decoder.fail();
        }
        final assignment = AddressAssignment(
          interfaceName: name,
          interfaceIndex: index,
          prefixLength: prefix,
          scope: scope,
          operState: state,
          interfaceFlags: interfaceFlags,
          flags: flags,
          observedAt: timestamp,
          validLifetimeSeconds: valid,
          preferredLifetimeSeconds: preferred,
          linkKind: kind,
          peer: record['peer'] == null
              ? null
              : decoder.ip(record['peer'], family),
        );
        final identity = jsonEncode([address.canonical, assignment.identity]);
        final fingerprint = jsonEncode([
          index,
          scope,
          state,
          interfaceFlags.toList()..sort(),
          flags.map((f) => f.name).toList()..sort(),
          valid,
          preferred,
          kind,
          assignment.peer?.canonical,
        ]);
        if (fingerprints.containsKey(identity) &&
            fingerprints[identity] != fingerprint) {
          decoder.fail(InventoryDecodeIssue.conflictingAssignment);
        }
        fingerprints[identity] = fingerprint;
        assigned.putIfAbsent(address, () => {})[assignment.identity] =
            assignment;
      }
    }
    final addresses =
        assigned.entries
            .map(
              (entry) => ServerAddress(
                serverId: serverId,
                namespace: namespace,
                address: entry.key,
                assignments: entry.value.values.toList()
                  ..sort((a, b) => a.identity.compareTo(b.identity)),
              ),
            )
            .toList()
          ..sort((a, b) => a.address.compareTo(b.address));

    final routes = <RouteObservation>[];
    final rules = <RuleObservation>[];
    for (final part in [
      (InventoryDocument.routesV4, outputs.routesV4, IpFamily.ipv4, true),
      (InventoryDocument.routesV6, outputs.routesV6, IpFamily.ipv6, true),
      (InventoryDocument.rulesV4, outputs.rulesV4, IpFamily.ipv4, false),
      (InventoryDocument.rulesV6, outputs.rulesV6, IpFamily.ipv6, false),
    ]) {
      final decoder = _Decoder(part.$1);
      final records = decoder.array(part.$2);
      count += records.length;
      if (count > maxRecords) decoder.fail(InventoryDecodeIssue.limitExceeded);
      for (final value in records) {
        final record = decoder.object(value);
        // Preserve every routing attribute (including multipath and selectors).
        // Validate the fields exposed through typed getters. No RPDB evaluator.
        for (final key in ['dst', 'src', 'dev', 'iif', 'oif', 'type']) {
          if (record.containsKey(key)) decoder.text(record[key]);
        }
        for (final key in ['dst', 'src']) {
          if (record.containsKey(key)) decoder.prefix(record[key], part.$3);
        }
        for (final key in ['gateway', 'prefsrc']) {
          if (record.containsKey(key)) decoder.ip(record[key], part.$3);
        }
        if (record.containsKey('priority')) decoder.integer(record['priority']);
        if (record.containsKey('table')) {
          if (record['table'] is int) {
            decoder.integer(record['table']);
          } else {
            decoder.text(record['table']);
          }
        }
        if (part.$4) {
          routes.add(RouteObservation(family: part.$3, attributes: record));
        } else {
          rules.add(RuleObservation(family: part.$3, attributes: record));
        }
      }
    }
    return ServerNetworkInventory(
      serverId: serverId,
      namespace: namespace,
      observedAt: timestamp,
      source: source,
      addresses: addresses,
      routes: routes,
      rules: rules,
      sshPeer: sshPeer,
    );
  }
}

final class _Decoder {
  const _Decoder(this.document);
  final InventoryDocument document;
  Never fail([
    InventoryDecodeIssue issue = InventoryDecodeIssue.invalidShape,
  ]) => throw InventoryDecodeException(issue, document);

  List<Object?> array(String input) {
    if (input.length > IpInventoryParser.maxDocumentBytes ||
        utf8.encode(input).length > IpInventoryParser.maxDocumentBytes) {
      fail(InventoryDecodeIssue.limitExceeded);
    }
    // Bound nesting before allocating the decoded tree. Ignore string contents.
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (final unit in input.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (unit == 92) {
          escaped = true;
        } else if (unit == 34) {
          quoted = false;
        }
      } else if (unit == 34) {
        quoted = true;
      } else if (unit == 91 || unit == 123) {
        if (++depth > IpInventoryParser.maxDepth) {
          fail(InventoryDecodeIssue.limitExceeded);
        }
      } else if (unit == 93 || unit == 125) {
        depth--;
      }
    }
    try {
      return list(jsonDecode(input));
    } on FormatException {
      fail(InventoryDecodeIssue.invalidJson);
    }
  }

  List<Object?> list(Object? value) {
    if (value is! List<Object?>) fail();
    if (value.length > IpInventoryParser.maxRecords) {
      fail(InventoryDecodeIssue.limitExceeded);
    }
    return value;
  }

  Map<String, Object?> object(Object? value) {
    if (value is! Map<String, Object?>) fail();
    return value;
  }

  String text(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 255 ||
        value.runes.any((r) => r < 32 || r == 127)) {
      fail();
    }
    return value;
  }

  String? optionalText(Object? value) => value == null ? null : text(value);
  List<String> strings(Object? value) => list(value).map(text).toList();
  int integer(Object? value, {int min = 0, int max = 0xffffffff}) {
    if (value is! int || value < min || value > max) fail();
    return value;
  }

  int? lifetime(Object? value) => value == null
      ? null
      : value == 'forever'
      ? 0xffffffff
      : integer(value);
  IpAddress ip(Object? value, IpFamily family) {
    final ip = IpAddress.tryParse(text(value));
    if (ip == null || ip.family != family) fail();
    return ip;
  }

  void prefix(Object? value, IpFamily family) {
    final string = text(value);
    if (string == 'default' || string == 'all') return;
    final parts = string.split('/');
    if (parts.length > 2) fail();
    ip(parts.first, family);
    if (parts.length == 2) {
      if (!RegExp(r'^[0-9]{1,3}$').hasMatch(parts.last)) fail();
      integer(int.parse(parts.last), max: family == IpFamily.ipv4 ? 32 : 128);
    }
  }
}
