import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../integrations/test/fixtures/drive_fixture.dart';

void main() {
  late Directory directory;
  late DriveFixture drive;
  final databases = <WorkspaceDatabase>[];
  final sessions = <AutoSyncSession>[];
  WorkspaceDatabase db(String name, int key) {
    final value = WorkspaceDatabase.open(
      '${directory.path}/$name.sqlite',
      key: SecretKeyData(List.filled(32, key)),
    );
    databases.add(value);
    return value;
  }

  Future<WorkspaceDatabase> pair(
    WorkspaceDatabase first,
    String name,
    int key,
  ) async {
    final second = db(name, key);
    final backup = await first.createBackup('public-test-pairing-password');
    await second.restoreBackup(
      await second.prepareRestore(backup, 'public-test-pairing-password'),
    );
    await second.close();
    return db(name, key);
  }

  Future<AutoSyncSession> open(
    WorkspaceDatabase db, {
    String? account,
    DriveFixture? remote,
  }) async {
    final tokens = FixtureTokens();
    if (account != null) tokens.accountKey = account;
    final value = await db.openAutoSync(
      tokens,
      remote: GoogleDriveSyncStore(tokens: tokens, http: remote ?? drive),
    );
    sessions.add(value);
    return value;
  }

  Future<AutoSyncResult> cycle(
    AutoSyncSession session, {
    bool editing = false,
  }) => session.exchange(
    cancellation: SyncCancellation(),
    apply: (receive) async {
      if (editing) return false;
      await receive();
      return true;
    },
  );
  Future<AutoSyncResult> drain(
    AutoSyncSession session, {
    bool editing = false,
  }) async {
    for (var i = 0; i < 30; i++) {
      final result = await cycle(session, editing: editing);
      if (!result.more) return result;
    }
    throw StateError('sync_did_not_drain');
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('auto-sync-test-');
    drive = DriveFixture();
    await drive.start();
  });
  tearDown(() async {
    for (final session in sessions) {
      await session.close();
    }
    sessions.clear();
    for (final value in databases) {
      await value.close();
    }
    databases.clear();
    await drive.close();
    await directory.delete(recursive: true);
  });

  test(
    'paired installations converge automatically; durable editor queue survives restart',
    () async {
      final first = db('a', 11);
      await first.readWorkspaceIdentity();
      var second = await pair(first, 'b', 22);
      final a = await open(first);
      var b = await open(second);
      await first.writeDraft('automatic private fixture');
      await drain(a);
      final waiting = await drain(b, editing: true);
      expect(waiting.waitingForEditor, isTrue);
      expect(await second.readDraft(), isNull);
      await b.close();
      await second.close();
      second = db('b', 22);
      b = await open(second);
      expect((await drain(b)).waitingForEditor, isFalse);
      expect(await second.readDraft(), 'automatic private fixture');
      final count = drive.contents.length;
      await drain(a);
      await drain(b);
      expect(drive.contents.length, count);
      await second.writeDraft('reply from second');
      await drain(b);
      await drain(a);
      expect(await first.readDraft(), 'reply from second');
      expect(await first.readPendingChanges(), isEmpty);
      expect(await second.readPendingChanges(), isEmpty);
    },
  );

  test(
    'lost upload response and restart reuse immutable packet and reserved file ID',
    () async {
      var first = db('a', 33);
      await first.writeDraft('offline queue');
      var session = await open(first);
      drive.loseUploadResponse = true;
      await expectLater(cycle(session), throwsA(isA<SyncTransportFailure>()));
      expect(await first.readPendingChanges(), isNotEmpty);
      final firstId = drive.contents.keys.single;
      final count = (await first.readChanges()).length;
      await session.close();
      await first.close();
      first = db('a', 33);
      session = await open(first);
      await drain(session);
      expect(drive.contents.length, count);
      expect(drive.contents.containsKey(firstId), isTrue);
      expect(await first.readPendingChanges(), isEmpty);
    },
  );

  test(
    'offline edits conflict persistently and explicit resolution converges',
    () async {
      final first = db('a', 41);
      await first.writeDraft('base');
      final second = await pair(first, 'b', 42);
      await first.writeDraft('first offline edit');
      await second.writeDraft('second offline edit');
      final a = await open(first), b = await open(second);
      await drain(a);
      await drain(b);
      final result = await drain(a);
      expect(result.conflicts, 1);
      final conflict = (await first.readSyncMergeStatus()).conflicts.single;
      final chosen = conflict.variants.firstWhere(
        (e) => e.source == 'second offline edit',
      );
      await first.resolveSyncConflict(conflict, chosen.header.changeId);
      await drain(a);
      await drain(b);
      expect((await second.readSyncMergeStatus()).conflicts, isEmpty);
      expect(await second.readDraft(), 'second offline edit');
    },
  );

  test(
    'new Google account exports already acknowledged local and received history',
    () async {
      final first = db('a', 51);
      await first.writeDraft('initial');
      final second = await pair(first, 'b', 52);
      final a = await open(first), b = await open(second);
      await drain(a);
      await drain(b);
      await first.writeDraft('from another device');
      await drain(a);
      await drain(b);
      final otherDrive = DriveFixture();
      await otherDrive.start();
      try {
        final migrated = await open(
          second,
          account: 'other-account',
          remote: otherDrive,
        );
        await drain(migrated);
        final history = {
          ...(await first.readChanges()).map((e) => e.header.changeId),
          ...(await second.readChanges()).map((e) => e.header.changeId),
        };
        expect(otherDrive.contents.length, history.length);
        final third = await pair(first, 'c', 53);
        await second.writeDraft('on new account');
        await drain(migrated);
        final c = await open(
          third,
          account: 'other-account',
          remote: otherDrive,
        );
        await drain(c);
        expect(await third.readDraft(), 'on new account');
        await c.close();
        await migrated.close();
      } finally {
        await otherDrive.close();
      }
    },
  );

  test(
    'foreign workspace, tampering and cloud deletion never mutate local data',
    () async {
      final first = db('a', 61), foreign = db('foreign', 62);
      await first.writeDraft('keep me');
      await foreign.writeDraft('foreign secret');
      final a = await open(first), f = await open(foreign);
      await drain(f);
      final corrupt = Uint8List.fromList(drive.contents.values.first);
      corrupt[corrupt.length - 1] ^= 1;
      final hash = (await Sha256().hash(
        corrupt,
      )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      drive.insert('corrupt', '$syncTransportNamePrefix$hash', corrupt);
      await drain(a);
      expect(await first.readDraft(), 'keep me');
      for (final id in drive.files.keys.toList()) {
        drive.remove(id);
      }
      await drain(a);
      expect(await first.readDraft(), 'keep me');
    },
  );

  test(
    'change signal only follows durable local edits, not packet export or receipts',
    () async {
      final first = db('a', 71);
      await first.readWorkspaceIdentity();
      var notifications = 0;
      final listener = first.localChanges.listen((_) => notifications++);
      await first.writeDraft('one change');
      final session = await open(first);
      await drain(session);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
      await listener.cancel();
    },
  );
}
