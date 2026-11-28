import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether the clients page menu offers checking and publishing now: opens
/// the menu, reads the item and closes the menu again.
Future<bool> clientsSyncEnabled(WidgetTester tester) async {
  final menu = find.byKey(const ValueKey('vpn-clients-menu'));
  await tester.tap(menu);
  await tester.pump(const Duration(milliseconds: 300));
  final item = tester.widget<AppMenuItem>(
    find.byKey(const ValueKey('vpn-sync-and-publish')),
  );
  await tester.tap(menu);
  await tester.pump(const Duration(milliseconds: 300));
  return item.onPressed != null;
}
