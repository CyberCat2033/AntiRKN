import 'dart:io';

import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'runner_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late WorkspaceDatabase db;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('legacy-sync-state-');
    // Written by the build before stage 5 (schema v6, public fixture key) with
    // leftovers of the merge removed on 2026-09-24: an unresolved conflict and
    // a waiting received change. See its header in packages/storage.
    final path = '${directory.path}/workspace.sqlite';
    final raw = sqlite3.open(path);
    try {
      raw.execute(
        File(
          '../../packages/storage/test/fixtures/workspace-v6-legacy.sql',
        ).readAsStringSync(),
      );
    } finally {
      raw.dispose();
    }
    db = WorkspaceDatabase.open(path, key: SecretKeyData(List.filled(32, 19)));
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'runner requests go out without a check of old merge conflicts',
    () async {
      final remote = FakeRunnerTransport(MemoryRunnerJournal())
        ..installed = true;
      final runner = RunnerController(
        serverId: 'one',
        store: db,
        transport: () => remote,
        identity: () => 'runner-identity',
        password: () => null,
        accessFailure: (_) {},
      );
      addTearDown(runner.dispose);
      await runner.refresh();
      await runner.startDiagnostic();
      expect(runner.responseCode, isNot('sync_conflict'));
      expect(remote.submissions, 1);
      expect(await db.readRunnerJournal('one'), isNotNull);
    },
  );
}
