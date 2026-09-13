import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_network_inventory/antirkn_network_inventory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('one VPS: all assignments, both route families and all rule tables', () {
    final inventory = parseFixture(fixture());
    expect(inventory.addresses, hasLength(14));
    expect(inventory.addresses.expand((a) => a.assignments), hasLength(15));
    expect(inventory.routes, hasLength(6));
    expect(inventory.rules, hasLength(6));
    expect(
      inventory.routes.where((r) => r.destination == 'default'),
      hasLength(3),
    );
    expect(
      inventory.routes.map((r) => r.table),
      containsAll(['main', 100, 'local']),
    );
    expect(inventory.rules.map((r) => r.priority), contains(32766));
    expect(inventory.sshPeer!.canonical, '203.0.113.20');
    expect(inventory.observedAt, observedAt);
    expect(
      addressEntry(
        inventory,
        '93.184.215.14',
      ).assignments.map((a) => a.interfaceName),
      ['eth0', 'eth1'],
    );
    expect(
      addressEntry(inventory, '93.184.215.15').assignments.single.flags,
      contains(AddressFlag.secondary),
    );
    expect(
      addressEntry(inventory, '10.66.0.1').assignments.single.isTunnel,
      isTrue,
    );
  });

  test('subnets, gateways, prefsrc and SSH peer never invent assigned IPs', () {
    final data = fixture();
    (data['routesV4'] as List).add({
      'dst': '8.0.0.0/8',
      'gateway': '8.8.8.8',
      'prefsrc': '8.8.4.4',
    });
    final ips = parseFixture(data).addresses.map((a) => a.address.canonical);
    for (final absent in [
      '93.184.215.1',
      '93.184.215.200',
      '203.0.113.20',
      '8.8.8.8',
      '8.8.4.4',
    ]) {
      expect(ips, isNot(contains(absent)));
    }
  });

  test('IDs survive reordering, IPv6 spelling and interface index changes', () {
    final data = fixture();
    final before = parseFixture(data);
    data['addresses'] = (data['addresses'] as List).reversed.toList();
    for (final interface in data['addresses'] as List) {
      interface['addr_info'] = (interface['addr_info'] as List).reversed
          .toList();
      interface['ifindex'] += 10;
    }
    sampleAddress(data, '2a01:4f8:1:2::10')['local'] =
        '2A01:04F8:0001:0002:0000:0000:0000:0010';
    final after = parseFixture(data);
    expect(after.addresses.map((a) => a.id), before.addresses.map((a) => a.id));
    const policy = AddressSelectionPolicy();
    expect(
      policy
          .choices(after, AddressRole.listener, now: observedAt)
          .map((c) => c.id),
      policy
          .choices(before, AddressRole.listener, now: observedAt)
          .map((c) => c.id),
    );
    expect(
      parseFixture(data, namespace: 'separate').addresses.first.id,
      isNot(before.addresses.first.id),
    );
  });

  test(
    'duplicate assignments collapse; contradictory copies reject the snapshot',
    () {
      final data = fixture();
      final copies = data['addresses'] as List;
      copies.add(jsonDecode(jsonEncode(copies[1])));
      expect(
        parseFixture(data).addresses.expand((a) => a.assignments),
        hasLength(15),
      );
      copies.last['operstate'] = 'DOWN';
      expect(
        () => parseFixture(data),
        throwsA(
          isA<InventoryDecodeException>().having(
            (e) => e.issue,
            'issue',
            InventoryDecodeIssue.conflictingAssignment,
          ),
        ),
      );
    },
  );

  test('point-to-point peer is preserved separately from local address', () {
    final data = fixture();
    sampleAddress(data, '10.66.0.1')['peer'] = '10.66.0.2';
    final inventory = parseFixture(data);
    expect(
      addressEntry(inventory, '10.66.0.1').assignments.single.peer!.canonical,
      '10.66.0.2',
    );
    expect(
      inventory.addresses.any((a) => a.address.canonical == '10.66.0.2'),
      isFalse,
    );
  });

  test(
    'iproute2 boolean flags and array flags produce the same IPv6 state',
    () {
      final data = fixture();
      final record = sampleAddress(data, '2a01:4f8:1:2::11');
      record.remove('temporary');
      record['flags'] = ['secondary'];
      expect(
        addressEntry(
          parseFixture(data),
          record['local'] as String,
        ).assignments.single.healthAt(observedAt),
        AddressHealth.temporary,
      );
      record['flags'] = ['optimistic'];
      expect(
        addressEntry(
          parseFixture(data),
          record['local'] as String,
        ).assignments.single.healthAt(observedAt),
        AddressHealth.tentative,
      );
    },
  );

  test('unknown routing selectors and multipath are retained immutably', () {
    final data = fixture();
    final route = {
      'dst': 'default',
      'table': 200,
      'nexthops': [
        {'gateway': '10.0.0.1', 'dev': 'eth0', 'weight': 1},
        {'gateway': '10.0.0.2', 'dev': 'eth1', 'weight': 2},
      ],
    };
    (data['routesV4'] as List).add(route);
    (data['rulesV6'] as List).add({
      'priority': 150,
      'src': 'all',
      'fwmark': '0x1',
      'table': 200,
      'not': null,
    });
    final inventory = parseFixture(data);
    final parsed = inventory.routes
        .singleWhere((r) => r.table == 200)
        .attributes;
    expect(parsed, route);
    expect(() => parsed['table'] = 999, throwsUnsupportedError);
    expect(() => (parsed['nexthops'] as List).clear(), throwsUnsupportedError);
    expect(
      () => ((parsed['nexthops'] as List).first as Map)['weight'] = 4,
      throwsUnsupportedError,
    );
    expect(inventory.rules.last.attributes['fwmark'], '0x1');
  });

  test(
    'empty inventory is valid; missing or partial output is not empty success',
    () {
      final data = {for (final key in fixture().keys) key: <dynamic>[]};
      expect(parseFixture(data).addresses, isEmpty);
      data.remove('routesV6');
      expect(
        () => parseFixture(data),
        throwsA(
          isA<InventoryDecodeException>().having(
            (e) => e.document,
            'document',
            InventoryDocument.routesV6,
          ),
        ),
      );
    },
  );

  test(
    'bad family, prefix, IP, flags and lifetime reject an entire observation',
    () {
      for (final change in <String, Object?>{
        'family': 'unknown',
        'prefixlen': 129,
        'local': '1.2.3.999',
        'scope': null,
        'tentative': 'false',
        'valid_life_time': -1,
        'preferred_life_time': 1.5,
      }.entries) {
        final data = fixture();
        sampleAddress(data, '2a01:4f8:1:2::10')[change.key] = change.value;
        expect(
          () => parseFixture(data),
          throwsA(isA<InventoryDecodeException>()),
          reason: change.key,
        );
      }
    },
  );

  test('malformed input reports safe codes without echoing raw input', () {
    const sensitive = 'raw-input-must-not-appear';
    try {
      const IpInventoryParser().parse(
        outputs: const IpCommandOutputs(
          addresses: sensitive,
          routesV4: '[]',
          routesV6: '[]',
          rulesV4: '[]',
          rulesV6: '[]',
        ),
        serverId: 'one',
        observedAt: observedAt,
      );
      fail('expected decode failure');
    } on InventoryDecodeException catch (error) {
      expect(error.issue, InventoryDecodeIssue.invalidJson);
      expect(error.toString(), isNot(contains(sensitive)));
    }
  });

  test('input size, depth and record count are bounded', () {
    for (final input in [
      ' ' * (IpInventoryParser.maxDocumentBytes + 1),
      '[' * 25 + ']' * 25,
      jsonEncode(
        List.filled(IpInventoryParser.maxRecords + 1, <String, Object?>{}),
      ),
    ]) {
      expect(
        () => const IpInventoryParser().parse(
          outputs: IpCommandOutputs(
            addresses: input,
            routesV4: '[]',
            routesV6: '[]',
            rulesV4: '[]',
            rulesV6: '[]',
          ),
          serverId: 'one',
          observedAt: observedAt,
        ),
        throwsA(
          isA<InventoryDecodeException>().having(
            (e) => e.issue,
            'issue',
            InventoryDecodeIssue.limitExceeded,
          ),
        ),
      );
    }
  });

  test('brackets inside quoted routing metadata do not count as nesting', () {
    final data = fixture();
    data['routesV4'][0]['unknown'] = '[{"escaped":\\' * 30;
    expect(parseFixture(data).routes, hasLength(6));
  });
}
