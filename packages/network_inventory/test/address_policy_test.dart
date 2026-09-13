import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  const policy = AddressSelectionPolicy();
  test(
    'wildcards only appear for listener; local addresses are role-specific',
    () {
      final inventory = parseFixture(fixture());
      final listeners = policy.choices(
        inventory,
        AddressRole.listener,
        now: observedAt,
      );
      final endpoints = policy.choices(
        inventory,
        AddressRole.endpoint,
        now: observedAt,
      );
      expect(
        listeners
            .where((c) => c.source == AddressChoiceSource.wildcard)
            .map((c) => c.host),
        ['0.0.0.0', '::'],
      );
      expect(
        endpoints.every((c) => c.source == AddressChoiceSource.assigned),
        isTrue,
      );
      expect(
        listeners.singleWhere((c) => c.host == '10.10.0.2').enabled,
        isTrue,
      );
      expect(
        endpoints.singleWhere((c) => c.host == '10.10.0.2').issue,
        SelectionIssue.notPublic,
      );
      expect(endpoints.where((c) => c.enabled).map((c) => c.host), [
        '93.184.215.14',
        '93.184.215.14',
        '93.184.215.15',
        '2a01:4f8:1:2::10',
      ]);
      expect(
        endpoints.any((c) => c.host == inventory.sshPeer!.canonical),
        isFalse,
      );
    },
  );

  test(
    'invalid, temporary, deprecated, down and unscoped addresses explain rejection',
    () {
      final inventory = parseFixture(fixture());
      final options = policy.choices(
        inventory,
        AddressRole.listener,
        now: observedAt,
      );
      for (final entry in {
        '93.184.215.16': SelectionIssue.interfaceDown,
        '2a01:4f8:1:2::11': SelectionIssue.temporary,
        '2a01:4f8:1:2::12': SelectionIssue.tentative,
        '2a01:4f8:1:2::13': SelectionIssue.deprecated,
        '2a01:4f8:1:2::14': SelectionIssue.dadfailed,
        '203.0.113.5': SelectionIssue.unsupportedAddress,
        'fe80::10': SelectionIssue.scopeRequired,
      }.entries) {
        expect(
          options.singleWhere((c) => c.host == entry.key).issue,
          entry.value,
        );
      }
      expect(options.singleWhere((c) => c.host == '10.66.0.1').enabled, isTrue);
    },
  );

  test(
    'known tunnel addresses are not automatically offered as public endpoints',
    () {
      final data = fixture();
      sampleAddress(data, '10.66.0.1')['local'] = '93.184.215.99';
      final options = policy.choices(
        parseFixture(data),
        AddressRole.endpoint,
        now: observedAt,
      );
      expect(
        options.singleWhere((c) => c.host == '93.184.215.99').issue,
        SelectionIssue.tunnel,
      );
    },
  );

  test(
    'lifetimes expire at the boundary; missing lifetimes remain unknown',
    () {
      final data = fixture();
      final record = sampleAddress(data, '2a01:4f8:1:2::10');
      record['valid_life_time'] = 60;
      record['preferred_life_time'] = 30;
      AddressHealth stateAt(int seconds) => addressEntry(
        parseFixture(data),
        record['local'] as String,
      ).assignments.single.healthAt(observedAt.add(Duration(seconds: seconds)));
      expect(stateAt(29), AddressHealth.ready);
      expect(stateAt(30), AddressHealth.deprecated);
      expect(stateAt(60), AddressHealth.expired);
      record.remove('valid_life_time');
      expect(stateAt(0), AddressHealth.unknown);
      record['valid_life_time'] = 'forever';
      record['preferred_life_time'] = 'forever';
      expect(stateAt(1000000000), AddressHealth.ready);
    },
  );

  test(
    'previous choice is rejected after removal or expiry; no replacement chosen',
    () {
      final data = fixture();
      final record = sampleAddress(data, '2a01:4f8:1:2::10');
      record['valid_life_time'] = 10;
      record['preferred_life_time'] = 10;
      final before = parseFixture(data);
      final selected = policy
          .choices(before, AddressRole.endpoint, now: observedAt)
          .singleWhere((c) => c.host == record['local']);
      expect(
        policy.validateSelection(
          selected,
          before,
          AddressRole.endpoint,
          now: observedAt.add(const Duration(seconds: 10)),
        ),
        SelectionIssue.expired,
      );
      (data['addresses'][1]['addr_info'] as List).remove(record);
      expect(
        policy.validateSelection(
          selected,
          parseFixture(data),
          AddressRole.endpoint,
          now: observedAt,
        ),
        SelectionIssue.unavailable,
      );
      expect(
        policy.validateSelection(
          selected,
          parseFixture(fixture(), namespace: 'other'),
          AddressRole.endpoint,
          now: observedAt,
        ),
        SelectionIssue.unavailable,
      );
    },
  );

  test('future observation and protocol capabilities are respected', () {
    final inventory = parseFixture(fixture());
    const restricted = AddressSelectionPolicy(
      families: {IpFamily.ipv4},
      allowWildcard: false,
    );
    final choices = restricted.choices(
      inventory,
      AddressRole.listener,
      now: observedAt.subtract(const Duration(seconds: 1)),
    );
    expect(
      choices.every(
        (c) =>
            c.source == AddressChoiceSource.assigned &&
            c.address.family == IpFamily.ipv4 &&
            c.issue == SelectionIssue.stale,
      ),
      isTrue,
    );
  });
}
