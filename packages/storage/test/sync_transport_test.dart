import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import '../../integrations/test/fixtures/drive_fixture.dart';

Matcher issue(SyncTransportIssue expected) =>
    isA<SyncTransportFailure>().having((e) => e.issue, 'issue', expected);
Future<String> digest(Uint8List bytes) async => (await Sha256().hash(
  bytes,
)).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

final class FailAck implements ChangeJournalStore {
  FailAck(this.store);
  final ChangeJournalStore store;
  @override
  Future<void> acknowledgeChanges(List<String> ids) async =>
      throw StateError('simulated_ack_failure');
  @override
  Future<WorkspaceIdentity> readWorkspaceIdentity() =>
      store.readWorkspaceIdentity();
  @override
  Future<List<LocalChange>> readChanges({
    int afterSequence = 0,
    int limit = 100,
  }) => store.readChanges(afterSequence: afterSequence, limit: limit);
  @override
  Future<List<LocalChange>> readPendingChanges({
    int afterSequence = 0,
    int limit = 100,
  }) => store.readPendingChanges(afterSequence: afterSequence, limit: limit);
}

void main() {
  late Directory directory;
  late DriveFixture fixture;
  late GoogleDriveSyncStore remote;
  final workspaces = <WorkspaceDatabase>[];
  final journals = <SyncTransportDatabase>[];
  String path(String name) => '${directory.path}/$name.sqlite';
  WorkspaceDatabase workspace(String name, [int key = 19]) {
    final db = WorkspaceDatabase.open(
      path(name),
      key: SecretKeyData(List.filled(32, key)),
    );
    workspaces.add(db);
    return db;
  }

  Future<SyncTransportDatabase> journal(
    String name,
    WorkspaceDatabase store, {
    String? account,
    int key = 29,
  }) async {
    final identity = await store.readWorkspaceIdentity();
    final db = await SyncTransportDatabase.open(
      path(name),
      key: SecretKeyData(List.filled(32, key)),
      accountKey: account ?? remote.accountKey,
      workspaceId: identity.workspaceId,
      deviceId: identity.deviceId,
    );
    journals.add(db);
    return db;
  }

  SyncTransportEngine engine(
    WorkspaceDatabase db,
    SyncTransportDatabase state, {
    ChangeJournalStore? changes,
  }) => SyncTransportEngine(
    remote: remote,
    journal: state,
    packets: db,
    changes: changes ?? db,
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('drive-transport-');
    fixture = DriveFixture();
    await fixture.start();
    remote = GoogleDriveSyncStore(tokens: FixtureTokens(), http: fixture);
  });
  tearDown(() async {
    await fixture.close();
    for (final j in journals) {
      await j.close();
    }
    journals.clear();
    for (final w in workspaces) {
      await w.close();
    }
    workspaces.clear();
    await directory.delete(recursive: true);
  });

  test(
    'two isolated workspaces deliver encrypted packets; receiver remains unchanged until trusted application',
    () async {
      final first = workspace('a');
      await first.readWorkspaceIdentity();
      var second = workspace('b', 31);
      final backup = await first.createBackup('public-fixture-password');
      await second.restoreBackup(
        await second.prepareRestore(backup, 'public-fixture-password'),
      );
      await second.close();
      second = workspace('b', 31);
      final ja = await journal('ja', first),
          jb = await journal('jb', second, key: 43);
      await first.writeDraft('PRIVATE_TRANSPORT_TEMPLATE_FIXTURE');
      final pending = await first.preparePendingPackets();
      final result = await engine(first, ja).exchange();
      expect(result.uploaded, pending.length);
      expect(await first.readPendingChanges(), isEmpty);
      expect(
        (await engine(second, jb).exchange(uploadLimit: 0)).downloadCaughtUp,
        isTrue,
      );
      final incoming = await jb.readStagedObjects();
      expect(incoming.length, pending.length);
      expect(await second.readDraft(), isNull);
      for (final object in incoming) {
        expect(
          latin1.decode(object.bytes),
          isNot(contains('PRIVATE_TRANSPORT_TEMPLATE_FIXTURE')),
        );
        await second.verifySyncPacket(object.bytes);
      }
      // This explicit fixture-only authorization is separate from the transport.
      await second.receiveSyncPackets(incoming.map((o) => o.bytes).toList());
      expect(await second.readDraft(), 'PRIVATE_TRANSPORT_TEMPLATE_FIXTURE');
      await engine(second, jb).exchange(uploadLimit: 0);
      expect((await jb.readStagedObjects()).length, incoming.length);
      for (final suffix in ['', '-wal']) {
        final file = File('${path('jb')}$suffix');
        if (await file.exists()) {
          final bytes = latin1.decode(await file.readAsBytes());
          for (final value in [
            'PRIVATE_TRANSPORT_TEMPLATE_FIXTURE',
            remote.accountKey,
            '"start"',
            'public-fixture-token',
          ]) {
            expect(bytes, isNot(contains(value)));
          }
        }
      }
    },
  );

  test(
    'lost upload response, restart and exact receipt retain one file per outgoing event',
    () async {
      var db = workspace('a');
      await db.writeDraft('one');
      var state = await journal('ja', db);
      final pending = await db.preparePendingPackets();
      fixture.loseUploadResponse = true;
      await expectLater(
        engine(db, state).exchange(),
        throwsA(issue(SyncTransportIssue.unavailable)),
      );
      expect((await db.readPendingChanges()).length, pending.length);
      expect(fixture.files.length, 1);
      final reserved = (await state.readUpload(pending.first.changeId))!;
      expect(reserved.confirmed, isFalse);
      await state.close();
      await db.close();
      db = workspace('a');
      state = await journal('ja', db);
      await engine(db, state).exchange();
      expect(fixture.files.length, pending.length);
      expect(fixture.puts, pending.length);
      expect(
        (await state.readUpload(pending.first.changeId))!.fileId,
        reserved.fileId,
      );
      expect(await db.readPendingChanges(), isEmpty);
    },
  );

  test(
    'crash gap between durable receipt and workspace ack does not create another upload',
    () async {
      final db = workspace('a');
      await db.writeDraft('one');
      var state = await journal('ja', db);
      await expectLater(
        engine(db, state, changes: FailAck(db)).exchange(),
        throwsStateError,
      );
      final first = (await db.readPendingChanges()).first;
      expect(
        (await state.readUpload(first.header.changeId))!.confirmed,
        isTrue,
      );
      final puts = fixture.puts;
      await state.close();
      state = await journal('ja', db);
      await engine(db, state).exchange(uploadLimit: 1);
      expect(fixture.puts, puts);
      expect(
        (await db.readPendingChanges()).any(
          (c) => c.header.changeId == first.header.changeId,
        ),
        isFalse,
      );
    },
  );

  test(
    'pre-existing file with wrong bytes is not acknowledged or overwritten',
    () async {
      final db = workspace('a');
      await db.writeDraft('one');
      final state = await journal('ja', db);
      final packet = (await db.preparePendingPackets()).first;
      final hash = await digest(packet.bytes);
      await state.reserveUpload(
        SyncUploadReceipt(
          changeId: packet.changeId,
          fileId: 'collision',
          digest: hash,
          size: packet.bytes.length,
        ),
      );
      fixture.insert(
        'collision',
        '$syncTransportNamePrefix$hash',
        Uint8List(packet.bytes.length),
      );
      await expectLater(
        engine(db, state).exchange(),
        throwsA(issue(SyncTransportIssue.conflict)),
      );
      expect(fixture.puts, 0);
      expect((await state.readUpload(packet.changeId))!.confirmed, isFalse);
      expect(await db.readPendingChanges(), isNotEmpty);
    },
  );

  test(
    'initial scan captures files created during enumeration and handles empty pages',
    () async {
      final db = workspace('a'),
          state = await journal('ja', workspace('binding'));
      // Use the same workspace binding as the engine.
      final actual = await journal('actual', db);
      final bytes = Uint8List.fromList([1, 2, 3]);
      final hash = await digest(bytes);
      fixture.duringFirstList = () async {
        fixture.insert('late', '$syncTransportNamePrefix$hash', bytes);
      };
      final result = await engine(db, actual).exchange(uploadLimit: 0);
      expect(result.downloadCaughtUp, isTrue);
      expect((await actual.readStagedObjects()).single.fileId, 'late');
      expect((await actual.readCursor()).listing, isFalse);
      expect((await actual.readCursor()).startToken, '1');
      expect((await state.readCursor()).startToken, isNull);
    },
  );

  test(
    'download failure leaves cursor; restart resumes partially stored page without duplicates',
    () async {
      final db = workspace('a');
      var state = await journal('ja', db);
      for (var i = 0; i < 2; i++) {
        final bytes = Uint8List.fromList([i + 1]);
        fixture.insert(
          'f$i',
          '$syncTransportNamePrefix${await digest(bytes)}',
          bytes,
        );
      }
      fixture.beforeDownload = () async {
        fixture.beforeDownload = () async {
          fixture.denyDownload = true;
        };
      };
      await expectLater(
        engine(db, state).exchange(uploadLimit: 0),
        throwsA(issue(SyncTransportIssue.unavailable)),
      );
      expect((await state.readStagedObjects()).length, 1);
      expect((await state.readCursor()).listing, isTrue);
      expect((await state.readCursor()).pageToken, isNull);
      fixture.denyDownload = false;
      await state.close();
      state = await journal('ja', db);
      await engine(db, state).exchange(uploadLimit: 0);
      expect((await state.readStagedObjects()).length, 2);
    },
  );

  test(
    'removed objects are staged as observations; expired cursor restarts full scan',
    () async {
      final db = workspace('a');
      await db.writeDraft('must remain');
      final state = await journal('ja', db);
      final bytes = Uint8List.fromList([1, 2]);
      fixture.insert(
        'foreign',
        '$syncTransportNamePrefix${await digest(bytes)}',
        bytes,
      );
      await engine(db, state).exchange(uploadLimit: 0);
      fixture.remove('foreign');
      await engine(db, state).exchange(uploadLimit: 0);
      expect((await state.readStagedObjects()).last.removed, isTrue);
      expect(await db.readDraft(), 'must remain');
      fixture.expired = true;
      expect(
        (await engine(db, state).exchange(uploadLimit: 0)).downloadCaughtUp,
        isFalse,
      );
      expect((await state.readCursor()).listing, isTrue);
      expect((await state.readStagedObjects()).length, 2);
      expect(
        (await engine(db, state).exchange(uploadLimit: 0)).downloadCaughtUp,
        isTrue,
      );
    },
  );

  test(
    'cancellation after response does not advance cursor and retry remains possible',
    () async {
      final db = workspace('a');
      final state = await journal('ja', db);
      final bytes = Uint8List.fromList([1]);
      fixture.insert(
        'x',
        '$syncTransportNamePrefix${await digest(bytes)}',
        bytes,
      );
      final cancel = SyncCancellation();
      fixture.beforeDownload = () async => cancel.cancel();
      await expectLater(
        engine(db, state).exchange(uploadLimit: 0, cancellation: cancel),
        throwsA(issue(SyncTransportIssue.cancelled)),
      );
      expect((await state.readCursor()).listing, isTrue);
      expect(await state.readStagedObjects(), isEmpty);
      expect(
        (await engine(db, state).exchange(uploadLimit: 0)).downloadCaughtUp,
        isTrue,
      );
    },
  );

  test(
    'concurrent reservations and cursor CAS; wrong binding/key cannot open journal',
    () async {
      final db = workspace('a');
      final a = await journal('ja', db), b = await journal('ja', db);
      final identity = await db.readWorkspaceIdentity();
      final reserved = await Future.wait([
        a.reserveUpload(
          SyncUploadReceipt(
            changeId: 'change',
            fileId: 'one',
            digest: 'a' * 64,
            size: 2,
          ),
        ),
        b.reserveUpload(
          SyncUploadReceipt(
            changeId: 'change',
            fileId: 'two',
            digest: 'a' * 64,
            size: 2,
          ),
        ),
      ]);
      expect(reserved.first.fileId, reserved.last.fileId);
      final cursor = await a.readCursor();
      await a.saveCursor(
        const SyncTransportCursor(startToken: 'first'),
        expectedRevision: cursor.revision,
      );
      await expectLater(
        b.saveCursor(
          const SyncTransportCursor(startToken: 'stale'),
          expectedRevision: cursor.revision,
        ),
        throwsA(issue(SyncTransportIssue.changed)),
      );
      expect((await b.readCursor()).startToken, 'first');
      for (final pair in [('other', 29), (remote.accountKey, 30)]) {
        await expectLater(
          SyncTransportDatabase.open(
            path('ja'),
            key: SecretKeyData(List.filled(32, pair.$2)),
            accountKey: pair.$1,
            workspaceId: identity.workspaceId,
            deviceId: identity.deviceId,
          ),
          throwsA(issue(SyncTransportIssue.storage)),
        );
      }
      final different = await journal('other', db, account: 'other');
      final requests = fixture.paths.length;
      await expectLater(
        engine(db, different).exchange(),
        throwsA(issue(SyncTransportIssue.changed)),
      );
      expect(fixture.paths.length, requests);
    },
  );

  test(
    'SQLite failure rolls back cursor and staged object; corrupted payload is rejected',
    () async {
      final db = workspace('a');
      final state = await journal('ja', db);
      final raw = sqlite3.open(path('ja'));
      addTearDown(raw.dispose);
      raw.execute(
        "CREATE TRIGGER fail_cursor BEFORE UPDATE ON transport_cursor BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      final cursor = await state.readCursor();
      await expectLater(
        state.saveCursor(
          const SyncTransportCursor(startToken: 'next'),
          expectedRevision: cursor.revision,
        ),
        throwsA(issue(SyncTransportIssue.storage)),
      );
      expect((await state.readCursor()).revision, cursor.revision);
      raw.execute(
        "CREATE TRIGGER fail_inbox BEFORE INSERT ON transport_inbox BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      final bytes = Uint8List.fromList([42]);
      final object = StagedSyncObject(
        fileId: 'x',
        version: '1',
        digest: await digest(bytes),
        bytes: bytes,
      );
      await expectLater(
        state.stageObject(object),
        throwsA(issue(SyncTransportIssue.storage)),
      );
      expect(await state.readStagedObjects(), isEmpty);
      raw.execute('DROP TRIGGER fail_inbox');
      await state.stageObject(object);
      raw.execute('UPDATE transport_inbox SET payload=zeroblob(40)');
      await expectLater(
        state.readStagedObjects(),
        throwsA(issue(SyncTransportIssue.storage)),
      );
    },
  );
  test(
    'process exit without close retains receipt, cursor and staged bytes in WAL',
    () async {
      final worker = await Process.run(
        'flutter',
        ['test', '--no-pub', 'test/fixtures/transport_crash_worker.dart'],
        environment: {'ANTIRKN_TRANSPORT_CRASH_DB': path('crash')},
      );
      expect(worker.exitCode, isNot(0));
      expect(worker.stdout, contains('transport_committed_without_close'));
      final state = await SyncTransportDatabase.open(
        path('crash'),
        key: SecretKeyData(List.filled(32, 29)),
        accountKey: 'crash-account',
        workspaceId: 'crash-workspace',
        deviceId: 'crash-device',
      );
      journals.add(state);
      expect((await state.readCursor()).startToken, 'crash-cursor');
      expect((await state.readUpload('crash-change'))!.confirmed, isTrue);
      expect((await state.readStagedObjects()).single.bytes, [41, 42, 43]);
    },
  );

  test(
    'bounded pagination persists progress and an old receipt cannot ack newer edits',
    () async {
      final db = workspace('a');
      await db.writeDraft('first');
      final state = await journal('ja', db);
      final before = (await db.readPendingChanges())
          .map((c) => c.header.changeId)
          .toSet();
      await engine(db, state).exchange(uploadLimit: 1, downloadPageLimit: 1);
      expect((await state.readCursor()).listing, isFalse);
      expect((await state.readCursor()).lastDownloadAt, isNull);
      await db.writeDraft('second');
      final newIds = (await db.readPendingChanges())
          .map((c) => c.header.changeId)
          .toSet()
          .difference(before);
      expect(newIds, isNotEmpty);
      await engine(db, state).exchange(uploadLimit: 0, downloadPageLimit: 1);
      expect(
        (await db.readPendingChanges()).map((c) => c.header.changeId),
        containsAll(newIds),
      );
      expect((await state.readCursor()).lastDownloadAt, isNotNull);
    },
  );
}
