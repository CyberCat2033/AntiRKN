import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fixtures/fake_snapshot_remote.dart';
import 'fixtures/snapshot_fixture.dart';

// Devices working in turn ("handing over the baton"): a phone back from the
// background, a PC closed or killed. Two isolated databases, one fake Drive.

/// What the shell's gate does: runs the restore unless an editor is open.
final class _Gate {
  bool open = true;
  int calls = 0, applied = 0;
  Future<bool> call(Future<void> Function() receive) async {
    calls++;
    if (!open) return false;
    await receive();
    applied++;
    return true;
  }
}

Future<void> _editVpn(
  WorkspaceDatabase db,
  void Function(Map<String, dynamic>) edit,
) async {
  final stored = await db.readVpn();
  final vpn = jsonDecode(stored.source!) as Map<String, dynamic>;
  edit(vpn);
  await db.writeVpn(jsonEncode(vpn), expectedRevision: stored.revision);
}

void main() {
  late Directory directory;
  final stores = <WorkspaceDatabase>[];
  final sessions = <AutoSyncSession>[];
  final tokens = FakeSnapshotTokens();
  late FakeSnapshotRemote remote;

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

  /// A replaced database is reopened by the app, as after a restore.
  Future<WorkspaceDatabase> reopen(
    WorkspaceDatabase db,
    String name,
    int key,
  ) async {
    await db.close();
    stores.remove(db);
    return open(name, key);
  }

  Future<AutoSyncResult> leave(AutoSyncSession sync, [_Gate? gate]) =>
      sync.exchange(
        apply: (gate ?? _Gate()).call,
        cancellation: SyncCancellation(),
      );

  Future<AutoSyncResult> enter(
    AutoSyncSession sync,
    _Gate gate, {
    bool launch = false,
  }) => sync.exchange(
    apply: gate.call,
    cancellation: SyncCancellation(),
    forceRecovery: launch,
    enter: true,
  );

  /// The PC uploads V1, the phone starts and pulls it.
  Future<(WorkspaceDatabase, WorkspaceDatabase)> pcAndPhone() async {
    final pc = open('pc', 11);
    await pc.writeDraft('version one');
    await leave(await session(pc));
    final phone = open('phone', 22);
    expect(await phone.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    return (pc, await reopen(phone, 'phone', 22));
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('relay-sync-test-');
    remote = FakeSnapshotRemote();
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
    'a phone back from the background receives the PC upload without restarting',
    () async {
      var (pc, phone) = await pcAndPhone();
      final device = (await phone.readWorkspaceIdentity()).deviceId;
      final phoneSync = await session(phone);
      await leave(phoneSync);
      await pc.writeDraft('version two from the PC');
      await leave(await session(pc));
      remote.calls.clear();
      final gate = _Gate();
      final result = await enter(phoneSync, gate);
      expect(result.received, isTrue);
      expect(gate.applied, 1);
      expect(remote.calls, ['findSnapshot', 'readSnapshot']);
      phone = await reopen(phone, 'phone', 22);
      expect(await phone.readDraft(), 'version two from the PC');
      expect((await phone.readWorkspaceIdentity()).deviceId, device);
      // Bound to the received version: the next return costs one request.
      remote.calls.clear();
      await enter(await session(phone), gate);
      expect(remote.calls, ['findSnapshot']);
    },
  );

  test(
    'returning without cloud changes costs one metadata request and no download',
    () async {
      final (_, phone) = await pcAndPhone();
      final sync = await session(phone);
      remote.calls.clear();
      final gate = _Gate();
      for (var index = 0; index < 3; index++) {
        final result = await enter(sync, gate);
        expect(result.received, isFalse);
      }
      expect(remote.calls, ['findSnapshot', 'findSnapshot', 'findSnapshot']);
      expect(gate.calls, 0);
      expect(remote.writes, 1);
    },
  );

  test(
    'applying waits for an open editor and keeps what was downloaded',
    () async {
      var (pc, phone) = await pcAndPhone();
      final phoneSync = await session(phone);
      await pc.writeDraft('version two from the PC');
      await leave(await session(pc));
      remote.calls.clear();
      final gate = _Gate()..open = false;
      final waiting = await enter(phoneSync, gate);
      expect(waiting.waitingForEditor, isTrue);
      expect(waiting.received, isFalse);
      expect(await phone.readDraft(), 'version one');
      expect(remote.calls, ['findSnapshot', 'readSnapshot']);
      // Polled while the editor stays open: nothing is downloaded again.
      remote.calls.clear();
      expect((await leave(phoneSync, gate)).waitingForEditor, isTrue);
      expect(remote.calls, isEmpty);
      gate.open = true;
      final applied = await leave(phoneSync, gate);
      expect(applied.received, isTrue);
      expect(remote.calls, isEmpty);
      phone = await reopen(phone, 'phone', 22);
      expect(await phone.readDraft(), 'version two from the PC');
    },
  );

  test('a startup pull cut by its deadline is finished on entry', () async {
    final pc = open('pc', 11);
    await pc.writeDraft('cloud data');
    await leave(await session(pc));
    var phone = open('phone', 22);
    remote.holdRead = Completer<void>();
    expect(
      await phone.pullCurrentSnapshot(
        tokens,
        remote: remote,
        deadline: const Duration(milliseconds: 100),
      ),
      isFalse,
    );
    remote.holdRead!.complete();
    remote.holdRead = null;
    final gate = _Gate();
    expect(
      (await enter(await session(phone), gate, launch: true)).received,
      isTrue,
    );
    phone = await reopen(phone, 'phone', 22);
    expect(await phone.readDraft(), 'cloud data');
  });

  test(
    'edits left without a local snapshot by a killed process are uploaded at launch',
    () async {
      final (pc, phone) = await pcAndPhone();
      await pc.writeDraft('edited, then the process was killed');
      // SIGTERM or a crash: no exit flush, so no local snapshot of the edit.
      await File('${directory.path}/pc.sqlite.current-snapshot').delete();
      final writes = remote.writes;
      final gate = _Gate();
      await enter(await session(pc), gate, launch: true);
      expect(remote.writes, writes + 1);
      final result = await enter(await session(phone), gate);
      expect(result.received, isTrue);
      final restored = await reopen(phone, 'phone', 22);
      expect(await restored.readDraft(), 'edited, then the process was killed');
    },
  );

  test(
    'cache-only changes upload nothing; an edit of intent uploads once',
    () async {
      final pc = open('pc', 11);
      final fixture = await fillSyntheticWorkspace(pc, clients: 3, servers: 1);
      final sync = await session(pc);
      await leave(sync);
      remote.calls.clear();
      await _editVpn(pc, (vpn) {
        for (final record in (vpn['servers'] as Map).values) {
          record['verifiedAt'] = '2026-11-25T10:00:00.000Z';
        }
        (vpn['profiles'] as Map)[fixture.userIds[0]]['yaml'] = 'rebuilt';
      });
      await leave(sync);
      expect(remote.calls, isEmpty);
      await pc.writeDraft('intent changed');
      await leave(sync);
      expect(remote.calls, ['writeSnapshot']);
    },
  );
}
