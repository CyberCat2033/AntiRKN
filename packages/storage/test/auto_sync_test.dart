import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'fixtures/fake_snapshot_remote.dart';
import 'fixtures/journal_data.dart';

typedef _Remote = FakeSnapshotRemote;
typedef _Tokens = FakeSnapshotTokens;

/// What the cloud snapshot v5 carries of a VPN document: no observations or
/// compiled profiles (schemas/cloud-snapshot-v5.json). Compared canonically.
String _vpnIntent(String source) {
  final vpn = jsonDecode(source) as Map<String, dynamic>;
  Map<String, dynamic> record(Object? value) =>
      Map<String, dynamic>.of(value as Map<String, dynamic>)..removeWhere(
        (key, _) =>
            const {'observed', 'verifiedAt', 'appliedPayload'}.contains(key),
      );
  return canonicalJson({
    ...vpn,
    'servers': {
      for (final entry in (vpn['servers'] as Map).entries)
        if (record(entry.value).isNotEmpty)
          entry.key as String: record(entry.value),
    },
    'profiles': <String, Object?>{},
  });
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
    await first.upsertVpnUser(
      VpnUser(
        id: fixtureUserId,
        login: 'fixture',
        name: 'Fixture',
        baseTemplate: 'rules: [MATCH,DIRECT]\n# individual-private-fixture',
        baseTemplateName: 'individual.yaml',
      ),
      expectedRevision: 0,
    );
    await _upload(await session(first));
    expect(
      String.fromCharCodes(remote.snapshot!),
      isNot(contains('individual-private-fixture')),
    );
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
    final user = VpnWorkspace.decode(
      (await reopened.readVpn()).source!,
    ).users.single;
    expect(user.baseTemplate, contains('individual-private-fixture'));
    expect(user.baseTemplateName, 'individual.yaml');
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
          return db.select('SELECT count(*) AS n FROM sync_history').single['n']
              as int;
        } finally {
          db.dispose();
        }
      }

      expect(count(), greaterThan(50));
      await _upload(await session(first));
      expect(count(), lessThan(5));
      await first.writeDraft('draft after compaction');
      expect(await first.readDraft(), 'draft after compaction');
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
      // A new device has the intent; its cache is read from the servers.
      expect(
        canonicalJson(jsonDecode((await restored.readVpn()).source!)),
        _vpnIntent(fixtureCurrentVpnSource()),
      );
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
      // These fixture records name no server identity: nothing proves the
      // cache belongs to the same machine, so only the intent remains.
      expect(
        canonicalJson(jsonDecode((await refreshed.readVpn()).source!)),
        _vpnIntent(fixtureCurrentVpnSource()),
      );
    },
  );

  Future<AutoSyncResult> enter(AutoSyncSession sync) => sync.exchange(
    apply: (receive) async {
      await receive();
      return true;
    },
    cancellation: SyncCancellation(),
    forceRecovery: true,
    enter: true,
  );

  Future<AutoSyncResult> choose(
    AutoSyncSession sync,
    SyncDivergenceChoice choice,
  ) => sync.resolve(
    choice,
    apply: (receive) async {
      await receive();
      return true;
    },
    cancellation: SyncCancellation(),
  );

  /// A restore closes the store: the app reopens it, as the test does.
  Future<WorkspaceDatabase> reopen(
    WorkspaceDatabase store,
    String name,
    int key,
  ) async {
    await store.close();
    return open(name, key);
  }

  /// What the app's first launch writes before anyone signs in.
  Future<void> firstLaunch(WorkspaceDatabase store) async =>
      store.writeVpnWorkspace(
        VpnWorkspace(id: (await store.readWorkspaceIdentity()).workspaceId),
        expectedRevision: 0,
      );

  test(
    'a fresh install signed in after launch takes the cloud workspace',
    () async {
      final first = open('first', 11);
      await first.writeDraft('cloud data');
      await _upload(await session(first));
      final cloudWorkspace = (await first.readWorkspaceIdentity()).workspaceId;
      final second = open('second', 22);
      await firstLaunch(second);
      final result = await enter(await session(second));
      expect(result.received, isTrue);
      expect(result.divergence, isNull);
      final restored = await reopen(second, 'second', 22);
      expect(await restored.readDraft(), 'cloud data');
      expect(
        (await restored.readWorkspaceIdentity()).workspaceId,
        cloudWorkspace,
      );
      expect(remote.writes, 1);
    },
  );

  test(
    'a fresh install left blocked by an earlier version recovers on entry',
    () async {
      final first = open('first', 11);
      await first.writeDraft('cloud data');
      await _upload(await session(first));
      final second = open('second', 22);
      await firstLaunch(second);
      // The earlier version captured the first-launch state as unsent edits
      // and stopped at the other workspace in the cloud.
      final path = '${directory.path}/second.sqlite';
      final db = sqlite3.open(path);
      final int sequence;
      try {
        sequence =
            db.select('SELECT sequence FROM sync_identity').single['sequence']
                as int;
      } finally {
        db.dispose();
      }
      await File('$path.current-snapshot').writeAsBytes([1, 2, 3]);
      await second.writeSetting('syncSnapshotPendingSequence', '$sequence');
      expect((await enter(await session(second))).received, isTrue);
      expect(await File('$path.current-snapshot').exists(), isFalse);
      expect(
        await (await reopen(second, 'second', 22)).readDraft(),
        'cloud data',
      );
      expect(remote.writes, 1);
    },
  );

  test('a fresh install also takes the cloud at the next launch', () async {
    final first = open('first', 11);
    await first.writeDraft('cloud data');
    await _upload(await session(first));
    final second = open('second', 22);
    await firstLaunch(second);
    expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    expect(
      await (await reopen(second, 'second', 22)).readDraft(),
      'cloud data',
    );
  });

  test('an empty device takes a cloud workspace without data once', () async {
    // An earlier version uploaded a fresh install as it was: a workspace
    // without data. A journal tombstone, which no snapshot carries, makes
    // this device send the same.
    final first = open('first', 11);
    await firstLaunch(first);
    final db = sqlite3.open('${directory.path}/first.sqlite');
    try {
      db.execute(
        "INSERT INTO sync_heads VALUES ('template', 'default', 1, 'gone', 1)",
      );
    } finally {
      db.dispose();
    }
    await _upload(await session(first));
    expect(remote.writes, 1);
    var second = open('second', 22);
    await firstLaunch(second);
    expect((await enter(await session(second))).received, isTrue);
    second = await reopen(second, 'second', 22);
    final reads = remote.calls.where((c) => c == 'readSnapshot').length;
    final sync = await session(second);
    final again = await enter(sync);
    expect(again.received, isFalse);
    expect(again.divergence, isNull);
    final leaving = await sync.exchange(
      apply: (_) async => true,
      cancellation: SyncCancellation(),
    );
    expect(leaving.remoteNewer, isFalse);
    expect(remote.calls.where((c) => c == 'readSnapshot').length, reads);
    expect(remote.writes, 1);
  });

  test('an empty device signed in to an empty Drive uploads nothing', () async {
    final first = open('first', 11);
    await firstLaunch(first);
    await enter(await session(first));
    expect(remote.writes, 0);
    expect(remote.snapshot, isNull);
  });

  test('a device whose only server was deleted uploads the deletion', () async {
    final first = open('first', 11);
    await firstLaunch(first);
    final server = await first.openServer('only-server');
    await server.saveProfile(fixtureServer());
    await _upload(await session(first));
    await first.deleteServers(await first.listServers());
    await enter(await session(first));
    expect(remote.writes, 2);
    final second = open('second', 22);
    await firstLaunch(second);
    expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    expect(await (await reopen(second, 'second', 22)).listServers(), isEmpty);
  });

  test(
    'own data and another workspace in the cloud ask which data to keep',
    () async {
      final first = open('first', 11);
      await first.writeDraft('cloud data');
      await _upload(await session(first));
      final second = open('second', 22);
      await second.writeDraft('independent local data');
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isFalse);
      final sync = await session(second);
      final result = await enter(sync);
      expect(result.divergence?.otherWorkspace, isTrue);
      expect(await second.readDraft(), 'independent local data');
      expect(remote.writes, 1);
      // Remembered across sessions until the user chooses.
      final again = await (await session(
        second,
      )).exchange(apply: (_) async => true, cancellation: SyncCancellation());
      expect(again.divergence?.otherWorkspace, isTrue);
      expect(remote.writes, 1);
      final taken = await choose(sync, SyncDivergenceChoice.takeCloud);
      expect(taken.received, isTrue);
      final restored = await reopen(second, 'second', 22);
      expect(await restored.readDraft(), 'cloud data');
      expect(
        (await restored.readWorkspaceIdentity()).workspaceId,
        (await first.readWorkspaceIdentity()).workspaceId,
      );
      expect(remote.writes, 1);
      final settled = await enter(await session(restored));
      expect(settled.divergence, isNull);
      expect(settled.received, isFalse);
      expect(remote.writes, 1);
    },
  );

  test(
    'keeping own data replaces another cloud workspace and asks the others',
    () async {
      final first = open('first', 11);
      await first.writeDraft('cloud data');
      await _upload(await session(first));
      final second = open('second', 22);
      await second.writeDraft('independent local data');
      final sync = await session(second);
      expect((await _upload(sync)).divergence?.otherWorkspace, isTrue);
      expect(remote.writes, 1);
      await choose(sync, SyncDivergenceChoice.keepLocal);
      expect(remote.writes, 2);
      expect(await second.readDraft(), 'independent local data');
      // The first device is clean and bound to its own workspace: it is
      // asked as well instead of being replaced.
      final firstSync = await session(first);
      final asked = await enter(firstSync);
      expect(asked.divergence?.otherWorkspace, isTrue);
      expect(await first.readDraft(), 'cloud data');
      await choose(firstSync, SyncDivergenceChoice.takeCloud);
      expect(
        await (await reopen(first, 'first', 11)).readDraft(),
        'independent local data',
      );
      expect(remote.writes, 2);
    },
  );

  test(
    'clean device after another device upload receives the new version',
    () async {
      final first = open('first', 11);
      await first.writeDraft('version one');
      await _upload(await session(first));
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      final restored = open('second', 22);
      await restored.writeDraft('version two');
      await _upload(await session(restored));
      final writes = remote.writes;
      remote.calls.clear();
      // First device has no edits; leaving the app must not report a conflict
      // and must not overwrite or race the newer cloud state. It has nothing
      // to send, so it does not even ask Drive; the next pull receives.
      final result = await _upload(await session(first));
      expect(result.remoteNewer, isFalse);
      expect(remote.calls, isEmpty);
      expect(remote.writes, writes);
      await _upload(await session(first), retry: true);
      expect(remote.writes, writes);
      expect(await first.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await first.close();
      final refreshed = open('first', 11);
      expect(await refreshed.readDraft(), 'version two');
    },
  );

  test(
    'a new cloud version of the same intent is remembered, not applied',
    () async {
      final first = open('first', 11);
      await first.writeDraft('version one');
      await _upload(await session(first));
      // Drive moved the version on without new content (or a device sent
      // the same data again).
      remote.version++;
      var applied = 0;
      Future<AutoSyncResult> enter(AutoSyncSession sync) => sync.exchange(
        apply: (receive) async {
          applied++;
          await receive();
          return true;
        },
        cancellation: SyncCancellation(),
        enter: true,
      );
      final sync = await session(first);
      final result = await enter(sync);
      expect(result.received, isFalse);
      expect(applied, 0);
      expect(await first.pullCurrentSnapshot(tokens, remote: remote), isFalse);
      // The version is remembered: the next entry costs one metadata read.
      remote.calls.clear();
      expect((await enter(sync)).received, isFalse);
      expect(remote.calls, ['findSnapshot']);
      // The device stays clean and its next edit writes over that version.
      await first.writeDraft('version two');
      final writes = remote.writes;
      await _upload(sync);
      expect(remote.writes, writes + 1);
      // Another intent is still received.
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    },
  );

  test(
    'unconfirmed snapshot of a clean device does not block a later pull',
    () async {
      final first = open('first', 11);
      await first.writeDraft('version one');
      await _upload(await session(first));
      // An older version captured again without edits and never confirmed
      // the upload. Clean devices no longer capture, but such files remain.
      await first.writeSetting('syncSnapshotUploaded', 'never-confirmed');
      final local = File('${directory.path}/first.sqlite.current-snapshot');
      expect(await local.exists(), isTrue);
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      final restored = open('second', 22);
      await restored.writeDraft('version two');
      await _upload(await session(restored));
      final writes = remote.writes;
      // Startup recovery finds nothing to send and does not conflict.
      await _upload(await session(first), retry: true);
      expect(remote.writes, writes);
      expect(await first.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await first.close();
      final refreshed = open('first', 11);
      expect(await refreshed.readDraft(), 'version two');
      expect(await local.exists(), isFalse);
      // The refreshed device is clean and bound to the received version.
      await refreshed.writeDraft('version three');
      await _upload(await session(refreshed));
      expect(remote.writes, writes + 1);
    },
  );

  test(
    'empty unbound device never uploads over an existing cloud snapshot',
    () async {
      final first = open('first', 11);
      await first.writeDraft('cloud data');
      await _upload(await session(first));
      final second = open('second', 22);
      final result = await _upload(await session(second));
      expect(result.remoteNewer, isTrue);
      expect(remote.writes, 1);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      expect(await open('second', 22).readDraft(), 'cloud data');
    },
  );

  test('device id stays stable across cloud pulls of one workspace', () async {
    final first = open('first', 11);
    await first.writeDraft('version one');
    await _upload(await session(first));
    final second = open('second', 22);
    final ownDevice = (await second.readWorkspaceIdentity()).deviceId;
    expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    await second.close();
    var restored = open('second', 22);
    final identity = await restored.readWorkspaceIdentity();
    expect(identity.deviceId, ownDevice);
    final operation = ServerOperation(
      operationId: 'e' * 32,
      executorDeviceId: identity.deviceId,
    );
    final vpn = await restored.readVpn();
    await restored.writeVpn(
      VpnWorkspace(
        id: identity.workspaceId,
        servers: {
          fixtureServerId: {'operation': operation.toJson()},
        },
      ).encode(),
      expectedRevision: vpn.revision,
    );
    await _upload(await session(restored));
    await first.close();
    final firstAgain = open('first', 11);
    expect(
      await firstAgain.pullCurrentSnapshot(tokens, remote: remote),
      isTrue,
    );
    await firstAgain.close();
    final edited = open('first', 11);
    await edited.writeDraft('version two');
    await _upload(await session(edited));
    expect(await restored.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    await restored.close();
    restored = open('second', 22);
    final after = await restored.readWorkspaceIdentity();
    expect(after.deviceId, ownDevice);
    expect(after.workspaceId, identity.workspaceId);
    expect(await restored.readDraft(), 'version two');
    final record = VpnWorkspace.decode(
      (await restored.readVpn()).source!,
    ).servers[fixtureServerId]!;
    expect(
      ServerOperation.fromJson(record['operation'] as Map).executorDeviceId,
      after.deviceId,
    );
  });

  test(
    'a database with legacy merge conflicts uploads and edits after migration',
    () async {
      final path = '${directory.path}/legacy.sqlite';
      createV6Legacy(path);
      final store = open('legacy', 19);
      await _upload(await session(store));
      expect(remote.writes, 1);
      final db = sqlite3.open(path);
      try {
        expect(
          db.select(
            "SELECT name FROM sqlite_master WHERE name IN ('sync_conflicts','sync_incoming','sync_branches')",
          ),
          isEmpty,
        );
      } finally {
        db.dispose();
      }
      await store.writeDraft('edited after cleanup');
      expect(await store.readDraft(), 'edited after cleanup');
      await _upload(await session(store));
      expect(remote.writes, 2);
    },
  );

  test('leaving repeatedly without edits makes no Drive requests', () async {
    final first = open('first', 11);
    await first.writeDraft('version one');
    final sync = await session(first);
    await _upload(sync);
    expect(remote.writes, 1);
    remote.calls.clear();
    for (var index = 0; index < 5; index++) {
      await _upload(sync);
    }
    expect(remote.writes, 1);
    expect(remote.calls, isEmpty);
    // A device that only received the cloud snapshot is just as clean.
    final second = open('second', 22);
    expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    await second.close();
    final restored = open('second', 22);
    final follower = await session(restored);
    remote.calls.clear();
    for (var index = 0; index < 5; index++) {
      await _upload(follower);
    }
    expect(remote.writes, 1);
    expect(remote.calls, isEmpty);
  });

  test(
    'an ordinary exchange after an edit costs at most two requests',
    () async {
      final first = open('first', 11);
      await first.writeDraft('version one');
      final sync = await session(first);
      await _upload(sync);
      for (var index = 0; index < 3; index++) {
        await first.writeDraft('edit $index');
        remote.calls.clear();
        await _upload(sync);
        expect(remote.writes, index + 2);
        expect(
          remote.requests,
          lessThanOrEqualTo(2),
          reason: '${remote.calls}',
        );
      }
    },
  );

  test(
    'a cloud version written meanwhile is never overwritten by a stale device',
    () async {
      final first = open('first', 11);
      await first.writeDraft('version one');
      final sync = await session(first);
      await _upload(sync);
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      final other = open('second', 22);
      await other.writeDraft('newer from second');
      final otherSync = await session(other);
      await first.writeDraft('stale edit from first');
      // The second device uploads between the first device's check and write.
      remote.beforeWrite = () async {
        await _upload(otherSync);
      };
      // Stage 4: the same workspace diverged; the user chooses a version.
      expect((await _upload(sync)).divergence, isNotNull);
      final third = open('third', 33);
      expect(await third.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await third.close();
      expect(await open('third', 33).readDraft(), 'newer from second');
      expect(await first.readDraft(), 'stale edit from first');
    },
  );

  test(
    'a key created by another device at the same time is used by both',
    () async {
      remote.racingKey = Uint8List.fromList(List.filled(32, 9));
      final first = open('first', 11);
      await first.writeDraft('written with the winning key');
      await _upload(await session(first));
      expect(remote.key, remote.racingKey);
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      final restored = open('second', 22);
      expect(await restored.readDraft(), 'written with the winning key');
      await restored.writeDraft('second continues');
      await _upload(await session(restored));
      expect(await first.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await first.close();
      expect(await open('first', 11).readDraft(), 'second continues');
    },
  );

  test(
    'a cached snapshot key that no longer opens the cloud is read again',
    () async {
      final first = open('first', 11);
      await first.writeDraft('version one');
      await _upload(await session(first));
      final second = open('second', 22);
      expect(await second.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      await second.close();
      final other = open('second', 22);
      // The account's app data was reset; the other device starts afresh
      // with a new key, its cached one is not used for a new snapshot.
      remote
        ..snapshot = null
        ..key = null;
      await other.writeDraft('after reset');
      remote.calls.clear();
      await _upload(await session(other));
      expect(remote.calls, contains('createSnapshotKey'));
      remote.calls.clear();
      expect(await first.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      expect(remote.calls, contains('readSnapshotKey'));
      await first.close();
      final refreshed = open('first', 11);
      expect(await refreshed.readDraft(), 'after reset');
      // The refreshed key is cached again: an edit costs one request.
      await refreshed.writeDraft('edited after reset');
      remote.calls.clear();
      await _upload(await session(refreshed));
      expect(remote.calls, ['writeSnapshot']);
    },
  );

  test(
    'startup pull gives up at its deadline and never applies late',
    () async {
      final first = open('first', 11);
      await first.writeDraft('cloud data');
      await _upload(await session(first));
      final second = open('second', 22);
      final workspace = (await second.readWorkspaceIdentity()).workspaceId;
      remote.holdRead = Completer<void>();
      final watch = Stopwatch()..start();
      expect(
        await second.pullCurrentSnapshot(
          tokens,
          remote: remote,
          deadline: const Duration(milliseconds: 200),
        ),
        isFalse,
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      // The app opened local data and is being edited when Drive answers.
      await second.writeDraft('local while offline');
      remote.holdRead!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await second.readDraft(), 'local while offline');
      expect((await second.readWorkspaceIdentity()).workspaceId, workspace);
      remote.holdRead = null;
      final third = open('third', 33);
      expect(
        await third.pullCurrentSnapshot(
          tokens,
          remote: remote,
          deadline: const Duration(seconds: 30),
        ),
        isTrue,
      );
    },
  );
}
