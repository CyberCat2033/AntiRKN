import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether the clients page offers checking and publishing now: the
/// publish button in the header.
Future<bool> clientsSyncEnabled(WidgetTester tester) async =>
    tester
        .widget<IconButton>(find.byKey(const ValueKey('vpn-sync-and-publish')))
        .onPressed !=
    null;
