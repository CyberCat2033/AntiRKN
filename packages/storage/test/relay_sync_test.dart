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

Map<String, dynamic> _vpnOf(String source) =>
    jsonDecode(source) as Map<String, dynamic>;

Map<String, Object?> _operation(String id, String device) =>
    ServerOperation(operationId: id, executorDeviceId: device).toJson();

/// An operation this device started on [target]: pending until the runner
/// answers.
void _startOperation(
  Map<String, dynamic> vpn,
  String target,
  String id,
  String device,
) {
  final record = (vpn['servers'] as Map)[target] as Map;
  record['pending'] = {'id': id, 'kind': 'vless_apply', 'payload': '{}'};
  record['operation'] = _operation(id, device);
  record['authorizedPayload'] = '{"next":"$id"}';
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

  Future<AutoSyncResult> choose(
    AutoSyncSession sync,
    SyncDivergenceChoice choice, [
    _Gate? gate,
  ]) => sync.resolve(
    choice,
    apply: (gate ?? _Gate()).call,
    cancellation: SyncCancellation(),
  );

  /// The phone's upload is killed midway; the PC, not knowing its edit,
  /// works on and uploads; the phone comes back.
  Future<(WorkspaceDatabase, WorkspaceDatabase, AutoSyncResult)>
  killedUploadThenPc({
    void Function(Map<String, dynamic> vpn, String phone)? phoneVpn,
    void Function(Map<String, dynamic> vpn, String pc)? pcVpn,
  }) async {
    final pc = open('pc', 11);
    await fillSyntheticWorkspace(pc, clients: 3, servers: 1);
    await pc.writeDraft('version one');
    await leave(await session(pc));
    var phone = open('phone', 22);
    expect(await phone.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    phone = await reopen(phone, 'phone', 22);
    final phoneDevice = (await phone.readWorkspaceIdentity()).deviceId;
    await phone.writeDraft('edit made on the phone');
    if (phoneVpn != null) {
      await _editVpn(phone, (vpn) => phoneVpn(vpn, phoneDevice));
    }
    remote.unavailable = true;
    await expectLater(
      leave(await session(phone)),
      throwsA(isA<SyncTransportFailure>()),
    );
    remote.unavailable = false;
    final pcSync = await session(pc);
    await enter(pcSync, _Gate(), launch: true);
    await pc.writeDraft('edit made on the PC');
    if (pcVpn != null) {
      final pcDevice = (await pc.readWorkspaceIdentity()).deviceId;
      await _editVpn(pc, (vpn) => pcVpn(vpn, pcDevice));
    }
    await leave(pcSync);
    final writes = remote.writes;
    final result = await enter(await session(phone), _Gate(), launch: true);
    expect(remote.writes, writes, reason: 'nothing is overwritten');
    return (pc, phone, result);
  }

  Future<String?> cloudDraft() async {
    final reader = open('reader-${remote.version}', 99);
    expect(await reader.pullCurrentSnapshot(tokens, remote: remote), isTrue);
    return (await reopen(reader, 'reader-${remote.version}', 99)).readDraft();
  }

  test(
    'an upload killed midway, then work on the PC: the phone offers a choice and loses nothing',
    () async {
      final (_, phone, result) = await killedUploadThenPc();
      final divergence = result.divergence!;
      expect(divergence.cloud.savedAt, isNotNull);
      expect(divergence.local.savedAt, isNotNull);
      if (Platform.isLinux) {
        expect(divergence.cloud.deviceName, startsWith('Linux'));
      }
      expect(await phone.readDraft(), 'edit made on the phone');
      expect(await cloudDraft(), 'edit made on the PC');
      // Until the user chooses: no writes, one metadata request on return.
      final sync = await session(phone);
      remote.calls.clear();
      expect((await leave(sync)).divergence, isNotNull);
      expect(remote.calls, isEmpty);
      expect((await enter(sync, _Gate())).divergence, isNotNull);
      expect(remote.calls, ['findSnapshot']);
      await phone.writeDraft('more edits while waiting');
      expect((await leave(sync)).divergence, isNotNull);
      expect(remote.calls, ['findSnapshot']);
    },
  );

  test('a stale conditional write diverges instead of overwriting', () async {
    final (pc, phone) = await pcAndPhone();
    final phoneSync = await session(phone);
    await pc.writeDraft('PC version');
    await leave(await session(pc));
    await phone.writeDraft('phone version');
    remote.calls.clear();
    final result = await leave(phoneSync);
    expect(result.divergence, isNotNull);
    expect(remote.calls.first, 'writeSnapshot');
    expect(remote.writes, 2);
    expect(await cloudDraft(), 'PC version');
    expect(await phone.readDraft(), 'phone version');
  });

  test(
    'keeping this device data replaces the cloud version, confirmed by Drive',
    () async {
      final (pc, phone, _) = await killedUploadThenPc();
      final device = (await phone.readWorkspaceIdentity()).deviceId;
      final sync = await session(phone);
      final result = await choose(sync, SyncDivergenceChoice.keepLocal);
      expect(result.divergence, isNull);
      expect(result.lastSuccess, isNotNull);
      expect(await cloudDraft(), 'edit made on the phone');
      expect((await phone.readWorkspaceIdentity()).deviceId, device);
      // Automatic exchange is back; the PC receives the phone's data.
      remote.calls.clear();
      expect((await enter(sync, _Gate())).divergence, isNull);
      expect(remote.calls, ['findSnapshot']);
      expect((await enter(await session(pc), _Gate())).received, isTrue);
      final refreshed = await reopen(pc, 'pc', 11);
      expect(await refreshed.readDraft(), 'edit made on the phone');
    },
  );

  test(
    'taking the cloud version replaces unsent edits and keeps own operations',
    () async {
      late String target;
      final (_, before, _) = await killedUploadThenPc(
        phoneVpn: (vpn, device) {
          target = (vpn['servers'] as Map).keys.first as String;
          _startOperation(vpn, target, 'a1' * 16, device);
        },
      );
      final device = (await before.readWorkspaceIdentity()).deviceId;
      final gate = _Gate();
      final result = await choose(
        await session(before),
        SyncDivergenceChoice.takeCloud,
        gate,
      );
      expect(result.received, isTrue);
      expect(gate.applied, 1);
      final phone = await reopen(before, 'phone', 22);
      expect(await phone.readDraft(), 'edit made on the PC');
      final identity = await phone.readWorkspaceIdentity();
      expect(identity.deviceId, device);
      final record =
          _vpnOf((await phone.readVpn()).source!)['servers'][target] as Map;
      expect(record['pending']['id'], 'a1' * 16);
      expect(record['operation']['executorDeviceId'], device);
      expect(await phone.readRestoredTargets(), isNot(contains(target)));
      expect(await phone.readSetting('syncSnapshotDivergence'), isEmpty);
      // The cloud learns about the operation with the next upload.
      final sync = await session(phone);
      expect((await enter(sync, _Gate(), launch: true)).divergence, isNull);
      final cloud = await openFakeSnapshot(remote);
      final cloudVpn = _vpnOf(
        (cloud['documents'] as List).singleWhere(
              (row) => row['id'] == 'vpn-workspace-v1',
            )['source']
            as String,
      );
      expect(cloudVpn['servers'][target]['pending']['id'], 'a1' * 16);
    },
  );

  test(
    'keeping this device data keeps the PC operation and deletion',
    () async {
      late String target, deleted;
      final (pc, before, _) = await killedUploadThenPc(
        pcVpn: (vpn, device) {
          target = (vpn['servers'] as Map).keys.first as String;
          _startOperation(vpn, target, 'c3' * 16, device);
          final users = vpn['users'] as List;
          deleted = (users[0] as Map)['id'] as String;
          users[0] = {
            ...users[0] as Map,
            'enabled': false,
            'deleted': true,
            'deletion': {
              'version': 1,
              'id': 'd4' * 16,
              'executor': device,
              'targets': {
                target: {'status': 'waiting'},
              },
            },
          };
        },
      );
      final pcDevice = (await pc.readWorkspaceIdentity()).deviceId;
      final gate = _Gate();
      final result = await choose(
        await session(before),
        SyncDivergenceChoice.keepLocal,
        gate,
      );
      // The PC's operation is merged here first; it uploads at the reopen.
      expect(result.received, isTrue);
      var phone = await reopen(before, 'phone', 22);
      expect(await phone.readDraft(), 'edit made on the phone');
      Future<void> check(WorkspaceDatabase db) async {
        final vpn = _vpnOf((await db.readVpn()).source!);
        expect(
          vpn['servers'][target]['operation']['executorDeviceId'],
          pcDevice,
        );
        final user = (vpn['users'] as List).singleWhere(
          (u) => u['id'] == deleted,
        );
        expect(user['deleted'], isTrue);
        expect(user['deletion']['executor'], pcDevice);
      }

      await check(phone);
      // Foreign work still needs a look on this device.
      expect(await phone.readRestoredTargets(), contains(target));
      await enter(await session(phone), _Gate(), launch: true);
      expect(await cloudDraft(), 'edit made on the phone');
      expect((await enter(await session(pc), _Gate())).received, isTrue);
      phone = await reopen(pc, 'pc', 11);
      await check(phone);
      expect(await phone.readDraft(), 'edit made on the phone');
      expect(await phone.readRestoredTargets(), isNot(contains(target)));
    },
  );

  test(
    'own unfinished operations after a cloud pull need no confirmation',
    () async {
      final pc = open('pc', 11);
      await fillSyntheticWorkspace(pc, clients: 3, servers: 1);
      await leave(await session(pc));
      var phone = open('phone', 22);
      expect(await phone.pullCurrentSnapshot(tokens, remote: remote), isTrue);
      phone = await reopen(phone, 'phone', 22);
      final device = (await phone.readWorkspaceIdentity()).deviceId;
      late String target;
      await _editVpn(phone, (vpn) {
        target = (vpn['servers'] as Map).keys.first as String;
        _startOperation(vpn, target, 'e5' * 16, device);
      });
      await leave(await session(phone));
      // The PC receives a foreign operation: it is to be confirmed there.
      expect((await enter(await session(pc), _Gate())).received, isTrue);
      final pcAgain = await reopen(pc, 'pc', 11);
      expect(await pcAgain.readRestoredTargets(), contains(target));
      await pcAgain.writeDraft('PC edit');
      await leave(await session(pcAgain));
      expect((await enter(await session(phone), _Gate())).received, isTrue);
      phone = await reopen(phone, 'phone', 22);
      expect(await phone.readDraft(), 'PC edit');
      expect(await phone.readRestoredTargets(), isNot(contains(target)));
    },
  );
}
