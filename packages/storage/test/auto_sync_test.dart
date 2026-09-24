import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/journal_data.dart';

final class _Tokens implements SyncAccessTokenProvider {
  @override
  String get accountKey => 'snapshot-test-account';
  @override
  Future<String> accessToken() async => 'fixture';
}

final class _Remote implements SyncRemoteStore, SyncSnapshotStore {
  @override
  String get accountKey => 'snapshot-test-account';
  Uint8List? snapshot, key;
  int version = 0, writes = 0;
  bool unavailable = false, loseResponse = false;

  @override
  Future<SyncRemoteFile?> findSnapshot() async => snapshot == null
      ? null
      : SyncRemoteFile(
          id: 'snapshot-id',
          name: syncSnapshotName,
          size: snapshot!.length,
          version: '$version',
          packet: false,
        );

  @override
  Future<Uint8List> readSnapshot(String fileId) async =>
      Uint8List.fromList(snapshot!);

  @override
  Future<void> writeSnapshot(String? fileId, Uint8List bytes) async {
    if (unavailable) {
      throw const SyncTransportFailure(SyncTransportIssue.network);
    }
    snapshot = Uint8List.fromList(bytes);
    version++;
    writes++;
    if (loseResponse) {
      loseResponse = false;
      throw const SyncTransportFailure(SyncTransportIssue.network);
    }
  }

  @override
  Future<Uint8List?> readSnapshotKey() async =>
      key == null ? null : Uint8List.fromList(key!);

  @override
  Future<void> createSnapshotKey(Uint8List bytes) async {
    if (key != null) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
    key = Uint8List.fromList(bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<AutoSyncResult> _upload(AutoSyncSession session, {bool retry = false}) =>
    session.exchange(
      apply: (_) async => true,
      cancellation: SyncCancellation(),
      forceRecovery: retry,
    );

void main() {
  late Directory directory;
  final stores = <WorkspaceDatabase>[];
  final sessions = <AutoSyncSession>[];
  final tokens = _Tokens();
  late _Remote remote;

  WorkspaceDatabase open(String name, int key) {
    final store = WorkspaceDatabase.open(
      '${directory.path}/$name.sqlite',
      key: SecretKeyData(List.filled(32, key)),
      offloadVpnWrites: true,
    );
    stores.add(store);
    return store;
  }

  Future<AutoSyncSession> session(WorkspaceDatabase store) async {
    final value = await store.openAutoSync(tokens, remote: remote);
    sessions.add(value);
    return value;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('single-snapshot-test-');
    remote = _Remote();
  });
  tearDown(() async {
    for (final value in sessions) {
      await value.close();
    }
    sessions.clear();
    for (final value in stores) {
      await value.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  test(
    'one encrypted cloud snapshot replaces the previous current state',
    () async {
      final first = open('first', 11);
      await first.writeDraft('private current draft');
      final sync = await session(first);
      expect(remote.writes, 0);
      await _upload(sync);
      expect(remote.writes, 1);
      expect(
        String.fromCharCodes(remote.snapshot!),
        isNot(contains('private current draft')),
      );
      await first.writeDraft('second current draft');
      await _upload(sync);
      expect(remote.writes, 2);
      expect(await first.readDraft(), 'second current draft');
      expect(
        await File('${directory.path}/first.sqlite.current-snapshot').exists(),
        isTrue,
      );
    },
  );

  test('isolated database uploads and restores a current snapshot', () async {
    final first = await WorkspaceDatabase.openIsolated(
      '${directory.path}/isolated-first.sqlite',
      key: SecretKeyData(List.filled(32, 31)),
    );
    stores.add(first);
    await first.writeDraft('isolated private draft');
    await _upload(await session(first));
    final second = await WorkspaceDatabase.openIsolated(
      '${directory.path}/isolated-second.sqlite',
      key: SecretKeyData(List.filled(32, 32)),
    );
    stores.add(second);
    expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    await second.close();
    final reopened = await WorkspaceDatabase.openIsolated(
      '${directory.path}/isolated-second.sqlite',
      key: SecretKeyData(List.filled(32, 32)),
    );
    stores.add(reopened);
    expect(await reopened.readDraft(), 'isolated private draft');
  });

  test(
    'saved snapshot bounds the local journal and later edits still work',
    () async {
      final first = open('first', 11);
      for (var index = 0; index < 80; index++) {
        await first.writeDraft('draft $index');
      }
      final path = '${directory.path}/first.sqlite';
      int count() {
        final db = sqlite3.open(path);
        try {
          return db.select('SELECT count(*) AS n FROM sync_changes').single['n']
              as int;
        } finally {
          db.dispose();
        }
      }

      expect(count(), greaterThan(50));
      await _upload(await session(first));
      expect(count(), lessThan(5));
      expect((await first.readSyncMergeStatus()).conflicts, isEmpty);
      await first.writeDraft('draft after compaction');
      expect(await first.readDraft(), 'draft after compaction');
      expect((await first.readSyncMergeStatus()).conflicts, isEmpty);
      await _upload(await session(first));
      expect(count(), lessThan(5));
    },
  );

  test(
    'profile publication remains readable after repeated compaction',
    () async {
      final first = open('first', 11);
      final workspaceId = (await first.readWorkspaceIdentity()).workspaceId;
      const userId = '11111111111111111111111111111111';
      Future<void> saveProfile(String yaml) async {
        final before = await first.readVpn();
        final source = before.source == null
            ? VpnWorkspace(
                id: workspaceId,
                users: [VpnUser(id: userId, login: 'fixture', name: 'Fixture')],
              )
            : VpnWorkspace.decode(before.source!);
        final hash = (await Sha256().hash(
          utf8.encode(yaml),
        )).bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
        await first.writeVpn(
          source
              .copy(
                profiles: {
                  userId: {'yaml': yaml, 'hash': hash},
                },
              )
              .encode(),
          expectedRevision: before.revision,
        );
      }

      await saveProfile('first current profile');
      final firstHead = (await first.readPublicationDraft(userId))!.headId;
      await _upload(await session(first));
      await saveProfile('second current profile');
      expect(
        (await first.readPublicationDraft(userId))!.ancestors,
        contains(firstHead),
      );
      await _upload(await session(first));
      await saveProfile('third current profile');
      expect(
        (await first.readPublicationDraft(userId))!.bytes,
        utf8.encode('third current profile'),
      );
      expect((await first.readSyncMergeStatus()).conflicts, isEmpty);
    },
  );

  test(
    'failed upload leaves encrypted local snapshot for startup retry',
    () async {
      final first = open('first', 11);
      await first.writeDraft('keep when offline');
      final sync = await session(first);
      remote.unavailable = true;
      await expectLater(_upload(sync), throwsA(isA<SyncTransportFailure>()));
      final local = File('${directory.path}/first.sqlite.current-snapshot');
      expect(await local.exists(), isTrue);
      expect(
        String.fromCharCodes(await local.readAsBytes()),
        isNot(contains('keep when offline')),
      );
      remote.unavailable = false;
      await _upload(sync, retry: true);
      expect(remote.writes, 1);
      await _upload(sync, retry: true);
      expect(remote.writes, 1);
    },
  );

  test(
    'lost Drive response is acknowledged on retry without another write',
    () async {
      final first = open('first', 11);
      await first.writeDraft('accepted despite lost response');
      final sync = await session(first);
      remote.loseResponse = true;
      await expectLater(_upload(sync), throwsA(isA<SyncTransportFailure>()));
      expect(remote.writes, 1);
      await _upload(sync, retry: true);
      expect(remote.writes, 1);
      expect(await first.readDraft(), 'accepted despite lost response');
    },
  );

  test(
    'empty second device imports servers, clients and secrets; clean first device follows later snapshot',
    () async {
      await createV1('${directory.path}/first.sqlite');
      final first = WorkspaceDatabase.open(
        '${directory.path}/first.sqlite',
        key: fixtureKey(),
      );
      stores.add(first);
      expect(
        (await first.listServers()).single.profile.secrets,
        fixtureServer().secrets,
      );
      expect((await first.readVpn()).source, fixtureVpn().encode());
      await _upload(await session(first));
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      final restored = open('second', 22);
      expect(
        (await restored.listServers()).single.profile.secrets,
        fixtureServer().secrets,
      );
      expect((await restored.readVpn()).source, fixtureCurrentVpnSource());
      await restored.writeDraft('new state from second');
      await _upload(await session(restored));
      expect(await first.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await first.close();
      final refreshed = WorkspaceDatabase.open(
        '${directory.path}/first.sqlite',
        key: fixtureKey(),
      );
      stores.add(refreshed);
      expect(await refreshed.readDraft(), 'new state from second');
      expect(
        (await refreshed.listServers()).single.profile.secrets,
        fixtureServer().secrets,
      );
      expect((await refreshed.readVpn()).source, fixtureCurrentVpnSource());
    },
  );

  test(
    'different nonempty local workspace cannot overwrite cloud state',
    () async {
      final first = open('first', 11);
      await first.writeDraft('cloud data');
      await _upload(await session(first));
      final second = open('second', 22);
      await second.writeDraft('independent local data');
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isFalse);
      await expectLater(
        _upload(await session(second)),
        throwsA(
          isA<SyncTransportFailure>().having(
            (e) => e.issue,
            'issue',
            SyncTransportIssue.conflict,
          ),
        ),
      );
      expect(await second.readDraft(), 'independent local data');
      expect(remote.writes, 1);
    },
  );
}
