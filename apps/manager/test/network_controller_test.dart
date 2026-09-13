import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'network_support.dart';

void main() {
  test(
    'failed refresh retains the complete snapshot and both selections',
    () async {
      final inventory = testInventory();
      final reader = TestInventoryReader(() async => inventory);
      final controller = NetworkController(reader: reader);
      addTearDown(controller.dispose);
      await controller.load();
      for (final role in AddressRole.values) {
        controller.select(
          role,
          controller.choices(role).firstWhere((c) => c.enabled),
        );
      }
      final endpoint = controller.selected(AddressRole.endpoint);
      final listener = controller.selected(AddressRole.listener);
      reader.callback = () async =>
          throw StateError('raw transport output is not exposed');
      await controller.load();
      expect(controller.inventory, same(inventory));
      expect(controller.selected(AddressRole.endpoint), same(endpoint));
      expect(controller.selected(AddressRole.listener), same(listener));
      expect(controller.failed, isTrue);
      expect(controller.loading, isFalse);
    },
  );

  test(
    'refresh retains removed choice as invalid and never selects another IP',
    () async {
      final data = networkFixture();
      final reader = TestInventoryReader(() async => testInventory(data: data));
      final controller = NetworkController(reader: reader);
      addTearDown(controller.dispose);
      await controller.load();
      final selected = controller
          .choices(AddressRole.endpoint)
          .firstWhere((c) => c.host == '93.184.215.15');
      controller.select(AddressRole.endpoint, selected);
      (data['addresses'][1]['addr_info'] as List).removeWhere(
        (a) => a['local'] == '93.184.215.15',
      );
      await controller.load();
      expect(controller.selected(AddressRole.endpoint)!.id, selected.id);
      expect(
        controller.selectionIssue(AddressRole.endpoint),
        SelectionIssue.unavailable,
      );
      expect(controller.selected(AddressRole.listener), isNull);
      controller.select(AddressRole.endpoint, null);
      expect(controller.selected(AddressRole.endpoint), isNull);
    },
  );

  test(
    'reordered results and interface renumbering preserve a valid choice',
    () async {
      final data = networkFixture();
      final controller = NetworkController(
        reader: TestInventoryReader(() async => testInventory(data: data)),
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.select(
        AddressRole.endpoint,
        controller.choices(AddressRole.endpoint).firstWhere((c) => c.enabled),
      );
      final id = controller.selected(AddressRole.endpoint)!.id;
      data['addresses'] = (data['addresses'] as List).reversed.toList();
      await controller.load();
      expect(controller.selected(AddressRole.endpoint)!.id, id);
      expect(controller.selectionIssue(AddressRole.endpoint), isNull);
    },
  );

  test(
    'concurrent load is single-flight and ignores late completion after disposal',
    () async {
      final pending = Completer<ServerNetworkInventory>();
      final reader = TestInventoryReader(() => pending.future);
      final controller = NetworkController(reader: reader);
      var notifications = 0;
      controller.addListener(() => notifications++);
      final first = controller.load();
      await controller.load();
      expect(reader.calls, 1);
      controller.dispose();
      pending.complete(testInventory());
      await first;
      expect(notifications, 1);
      expect(controller.inventory, isNull);
    },
  );

  test(
    'select rechecks role and lifetime instead of trusting a stale option',
    () async {
      final data = networkFixture();
      final observedAt = DateTime.utc(2026, 9, 13);
      var now = observedAt;
      final record = (data['addresses'][1]['addr_info'] as List).firstWhere(
        (a) => a['local'] == '93.184.215.15',
      );
      record['valid_life_time'] = 1;
      record['preferred_life_time'] = 1;
      final controller = NetworkController(
        reader: TestInventoryReader(
          () async => testInventory(data: data, observedAt: observedAt),
        ),
        clock: () => now,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final stale = controller
          .choices(AddressRole.endpoint)
          .firstWhere((c) => c.host == '93.184.215.15');
      final wildcard = controller.choices(AddressRole.listener).first;
      controller.select(AddressRole.endpoint, wildcard);
      expect(controller.selected(AddressRole.endpoint), isNull);
      now = now.add(const Duration(seconds: 1));
      controller.select(AddressRole.endpoint, stale);
      expect(controller.selected(AddressRole.endpoint), isNull);
    },
  );
}
