import 'dart:io';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'journal_data.dart';

void main() {
  test('abrupt exit after durable write without closing SQLite', () async {
    final path = Platform.environment['ANTIRKN_JOURNAL_CRASH_DB']!;
    final db = WorkspaceDatabase.open(path, key: fixtureKey());
    await db.writeDraft('private-crash-fixture');
    // Deliberately skips tearDown, database.close and SQLite checkpoint.
    stdout.writeln('journal_fixture_committed_without_close');
    await stdout.flush();
    exit(73);
  });
}
