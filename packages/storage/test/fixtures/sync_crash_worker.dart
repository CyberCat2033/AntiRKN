import 'dart:io';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'journal_data.dart';

void main() {
  test('exit immediately after durable packet preparation', () async {
    final path = Platform.environment['ANTIRKN_SYNC_CRASH_DB']!;
    final db = WorkspaceDatabase.open(path, key: fixtureKey());
    await db.writeDraft('public-crash-fixture');
    await db.preparePendingPackets();
    stdout.writeln('sync_fixture_committed_without_close');
    await stdout.flush();
    exit(73);
  });
}
