import 'dart:io';
import 'dart:convert';
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
      expect(drive.contents.length, count + 1);
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
        expect(otherDrive.contents.length, history.length + 1);
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
    'independent conflicting workspaces retain local version; tampering and cloud deletion do not overwrite it',
    () async {
      final first = db('a', 61), foreign = db('foreign', 62);
      await first.writeDraft('keep me');
      await foreign.writeDraft('foreign secret');
      final a = await open(first), f = await open(foreign);
      await drain(f);
      final corrupt = Uint8List.fromList(
        drive.contents[drive.files.values.firstWhere(
          (f) => (f['name'] as String).startsWith(syncTransportNamePrefix),
        )['id']]!,
      );
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

  Future<void> seed(WorkspaceDatabase store, String digit) async {
    final id = digit * 32;
    final vault = await store.openServer('server-$digit');
    await vault.saveProfile(
      SshProfile(
        id: 'server-$digit',
        host: 'server-$digit.example',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.password,
        secrets: {ServerSecret.sshPassword: 'fixture-secret-$digit'},
      ),
    );
    final before = await store.readVpn();
    final yaml = 'mode: rule\n# fixture-$digit';
    final hash = (await Sha256().hash(
      utf8.encode(yaml),
    )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    await store.writeVpn(
      VpnWorkspace(
        id: before.workspaceId!,
        users: [VpnUser(id: id, login: 'client-$digit', name: 'Client $digit')],
        servers: {
          'server-$digit': {'panelId': '3' * 32},
          awgTarget('server-$digit'): {},
          ttTarget('server-$digit'): {},
        },
        profiles: {
          id: {'yaml': yaml, 'hash': hash},
        },
      ).encode(),
      expectedRevision: before.revision,
    );
  }

  test(
    'Google sign-in joins a fresh device without backup, preserving credentials and publication namespace',
    () async {
      final first = db('a', 81), second = db('b', 82);
      await seed(first, '1');
      final origin = (await first.readWorkspaceIdentity()).workspaceId;
      final a = await open(first), b = await open(second);
      await drain(a);
      await drain(b);
      expect(
        (await second.listServers()).single.profile.secrets[ServerSecret
            .sshPassword],
        'fixture-secret-1',
      );
      final vpn = VpnWorkspace.decode((await second.readVpn()).source!);
      expect(vpn.users.single.id, '1' * 32);
      for (final target in [
        'server-1',
        awgTarget('server-1'),
        ttTarget('server-1'),
      ]) {
        expect(vpn.desired(target, '3' * 32)['workspaceId'], origin);
        if (target != 'server-1') {
          expect(vpn.desired(target, '3' * 32)['panelId'], origin);
        }
      }
      final draft = (await second.readPublicationDraft('1' * 32))!;
      expect(draft.workspaceId, origin);
      await second.checkPublicationDraft(draft);
      expect((await second.readWorkspaceIdentity()).workspaceId, isNot(origin));
      final before = await second.readVpn();
      await second.writeVpn(
        vpn
            .copy(
              users: [
                VpnUser(id: '1' * 32, login: 'client-1', name: 'Renamed'),
              ],
            )
            .encode(),
        expectedRevision: before.revision,
      );
      await drain(b);
      await drain(a);
      expect(
        VpnWorkspace.decode((await first.readVpn()).source!).users.single.name,
        'Renamed',
      );
      expect((await first.readSyncMergeStatus()).conflicts, isEmpty);
      // Translated history is a normal, valid portable backup.
      final restored = await pair(second, 'c', 83);
      expect(
        (await restored.readPublicationDraft('1' * 32))!.workspaceId,
        origin,
      );
    },
  );

  test(
    'two populated devices merge automatically, restart and tombstones converge',
    () async {
      final first = db('a', 91);
      var second = db('b', 92);
      await seed(first, '1');
      await seed(second, '2');
      final a = await open(first);
      var b = await open(second);
      await Future.wait([drain(a), drain(b)]);
      await drain(a);
      await drain(b);
      for (final store in [first, second]) {
        expect((await store.listServers()).map((s) => s.id).toSet(), {
          'server-1',
          'server-2',
        });
        expect(
          VpnWorkspace.decode(
            (await store.readVpn()).source!,
          ).users.map((u) => u.id).toSet(),
          {'1' * 32, '2' * 32},
        );
        expect((await store.readSyncMergeStatus()).conflicts, isEmpty);
      }
      await b.close();
      await second.close();
      second = db('b', 92);
      b = await open(second);
      await (await first.openServer('server-1')).saveProfile(null);
      await drain(a);
      await drain(b);
      expect((await second.listServers()).map((s) => s.id), ['server-2']);
      final size = drive.contents.length;
      await drain(a);
      await drain(b);
      expect(drive.contents.length, size);
    },
  );

  test(
    'legacy packets skipped without a key are imported once the old device upgrades',
    () async {
      final first = db('a', 101), second = db('b', 102);
      await seed(first, '1');
      final tokens = FixtureTokens();
      final remote = GoogleDriveSyncStore(tokens: tokens, http: drive);
      for (final packet in await first.preparePendingPackets()) {
        final digest = (await Sha256().hash(
          packet.bytes,
        )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
        await remote.createPacket(
          await remote.generateFileId(),
          '$syncTransportNamePrefix$digest',
          packet.bytes,
        );
      }
      final b = await open(second);
      expect((await drain(b)).otherWorkspaces, greaterThan(0));
      expect(await second.listServers(), isEmpty);
      final a = await open(first);
      await drain(a);
      expect((await drain(b)).otherWorkspaces, 0);
      expect((await second.listServers()).single.id, 'server-1');
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
