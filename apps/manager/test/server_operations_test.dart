import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' as vpn;
import 'runner_support.dart';

class FailableRemote extends vpn.Remote {
  FailableRemote(super.store);
  bool statusUnavailable = false;
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) {
    if (statusUnavailable && request.json['action'] == 'status') {
      throw const SshFailure(SshIssue.disconnected);
    }
    return super.request(request, token, sudoPassword: sudoPassword);
  }
}

class DatabaseRemote implements RunnerTransport {
  DatabaseRemote(this.db, this.delegate);
  final WorkspaceDatabase db;
  final vpn.Remote delegate;
  void Function()? beforeStatus;
  @override
  String get bundledRelease => delegate.bundledRelease;
  @override
  Future<RunnerInstallation> inspect(CancellationToken token) =>
      delegate.inspect(token);
  @override
  Future<RunnerInstallation> install(
    RunnerInstallation plan,
    CancellationToken token, {
    String? sudoPassword,
  }) => delegate.install(plan, token);
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    if (request.json['action'] == 'status') beforeStatus?.call();
    delegate.store.raw = (await db.readVpn()).source;
    return delegate.request(request, token);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late WorkspaceDatabase a, b;
  final stores = <WorkspaceDatabase>[];
  final controllers = <VpnController>[];
  final runners = <RunnerController>[];
  late FailableRemote server;
  late int baseline;
  WorkspaceDatabase open(String name) {
    final db = WorkspaceDatabase.open(
      '${directory.path}/$name.sqlite',
      key: SecretKeyData(List.filled(32, name == 'a' ? 19 : 41)),
    );
    stores.add(db);
    return db;
  }

  Future<void> copyToB() async {
    final backup = await a.createBackup('public-operation-fixture');
    final target = open('b');
    await target.restoreBackup(
      await target.prepareRestore(backup, 'public-operation-fixture'),
    );
    await target.close();
    b = open('b');
    baseline = (await a.readChanges()).last.header.sequence;
  }

  Future<void> sync(WorkspaceDatabase source, WorkspaceDatabase target) async {
    final packets = await source.preparePendingPackets();
    final status = await target.receiveSyncPackets(
      packets.map((p) => p.bytes).toList(),
    );
    expect(status.conflicts, isEmpty);
    expect(status.blockedGroups, 0);
  }

  VpnController control(WorkspaceDatabase db, {bool online = true}) {
    final remote = DatabaseRemote(db, server);
    final c = VpnController(
      repository: db,
      recovery: db,
      template: () => vpn.template,
      serverIds: () => ['one'],
      remote: (id) => !online
          ? null
          : VpnRemote(
              transport: remote,
              panelId: vpn.panel,
              identity: 'identity-$id',
              observationKey: 'connected-$id',
            ),
      timer: (d, f) => Timer(Duration.zero, () {}),
    );
    controllers.add(c);
    return c;
  }

  RunnerController runner(WorkspaceDatabase db, FakeRunnerTransport remote) {
    final c = RunnerController(
      serverId: 'one',
      store: db,
      transport: () => remote,
      identity: () => 'runner-identity',
      password: () => null,
      accessFailure: (_) {},
    );
    runners.add(c);
    return c;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('server-operation-test-');
    a = open('a');
    await (await a.openServer('one')).saveProfile(
      SshProfile(
        host: 'fixture.example',
        port: 22,
        username: 'fixture',
        authMethod: SshAuthMethod.password,
        secrets: const {ServerSecret.sshPassword: 'fixture-password'},
      ),
    );
    server = FailableRemote(vpn.MemoryVpn());
    final c = control(a);
    await c.load();
    await c.saveUser(VpnUser(id: vpn.alice, login: 'alice', name: 'Alice'));
    await c.saveInbound(vpn.inbound('one', '1' * 32));
    expect(c.error, isNull);
  });
  tearDown(() async {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    for (final c in runners) {
      c.dispose();
    }
    runners.clear();
    for (final db in stores) {
      await db.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  test(
    'received running operation is observed after restart without submit or outbox echo',
    () async {
      await copyToB();
      final owner = control(a);
      await owner.load();
      server.running = true;
      await owner.prepare();
      await owner.apply();
      final id = owner.operation('one')!.operationId;
      expect(owner.operation('one')!.expectedRevision, 'e' * 64);
      await sync(a, b);
      final receiver = control(b);
      await receiver.load();
      final before = (await b.readChanges()).length;
      server.actions.clear();
      await receiver.reconcile();
      expect(receiver.error, isNull);
      expect(receiver.observesOperation('one'), isTrue);
      expect(
        receiver.hasRunning,
        isFalse,
        reason: 'Observation must not starve incoming completion sync',
      );
      expect(receiver.currentJob('one')!.id, id);
      expect(receiver.currentJob('one')!.status, 'running');
      expect(server.actions, ['status']);
      expect((await b.readChanges()).length, before);
      final next = control(b);
      await next.load();
      server.actions.clear();
      await next.reconcile();
      expect(next.currentJob('one')!.id, id);
      expect(server.actions, ['status']);
      await next.takeOver('one');
      expect(
        next.observesOperation('one'),
        isTrue,
        reason: 'Running work needs no resubmission or ownership change',
      );
      expect(server.actions, ['status', 'status']);
    },
  );

  test(
    'missing job needs explicit takeover and keeps ID, fingerprint and personal keys',
    () async {
      await copyToB();
      final owner = control(a);
      await owner.load();
      await owner.prepare();
      server.failBeforeSubmit = true;
      await owner.apply();
      final id = owner.operation('one')!.operationId;
      expect(server.submissions, isEmpty);
      await sync(a, b);
      final receiver = control(b);
      await receiver.load();
      server.actions.clear();
      await receiver.reconcile();
      expect(server.actions, ['status']);
      expect(receiver.currentJob('one'), isNull);
      await receiver.takeOver('one');
      expect(receiver.error, isNull);
      expect(server.submissions.keys, [id]);
      expect(
        receiver.operation('one')!.executorDeviceId,
        (await b.readWorkspaceIdentity()).deviceId,
      );
      expect(receiver.workspace.servers['one']!['pending'], isNull);
      expect(
        server.actions.indexOf('status'),
        lessThan(server.actions.indexOf('submit')),
      );
      // Deliver the handoff and result to the original device. Its still-open
      // controller cannot write or submit from the stale local snapshot.
      await sync(b, a);
      server.actions.clear();
      await owner.reconcile();
      expect(owner.error, anyOf('sync_conflict', 'vpn_storage_conflict'));
      expect(server.actions, isNot(contains('submit')));
      final reloaded = control(a);
      await reloaded.load();
      expect(
        reloaded.operation('one')!.executorDeviceId,
        (await b.readWorkspaceIdentity()).deviceId,
      );
    },
  );

  test(
    'unsynced edits fence an old controller before submit, preserving the new revision',
    () async {
      final owner = control(a);
      await owner.load();
      await owner.prepare();
      server.failBeforeSubmit = true;
      await owner.apply();
      final newer = control(a);
      await newer.load();
      await newer.saveUser(
        VpnUser(id: vpn.alice, login: 'alice', name: 'Renamed', enabled: false),
      );
      server.actions.clear();
      await owner.reconcile();
      expect(owner.error, anyOf('sync_conflict', 'vpn_storage_conflict'));
      expect(server.actions, isNot(contains('submit')));
      expect(
        VpnWorkspace.decode((await a.readVpn()).source!).users.single.enabled,
        isFalse,
      );
    },
  );

  test(
    'two offline approvals retain their conflict and block execution after delivery',
    () async {
      // Persist the panel binding before branching to allow offline approval.
      final initial = control(a);
      await initial.load();
      await initial.prepare();
      await initial.apply();
      await copyToB();
      final left = control(a, online: false), right = control(b, online: false);
      await left.load();
      await right.load();
      await left.saveUser(
        VpnUser(id: vpn.alice, login: 'alice', name: 'Left', enabled: false),
      );
      await right.saveUser(
        VpnUser(id: vpn.alice, login: 'alice', name: 'Right', enabled: false),
      );
      await left.prepare();
      await right.prepare();
      await left.apply();
      await right.apply();
      expect(left.error, isNull);
      expect(right.error, isNull);
      expect(
        left.operation('one')!.operationId,
        isNot(right.operation('one')!.operationId),
      );
      final status = await a.receiveSyncPackets(
        (await b.preparePendingPackets(
          afterSequence: baseline,
        )).map((p) => p.bytes).toList(),
      );
      expect(status.conflicts, isNotEmpty);
      server.actions.clear();
      final stale = control(a);
      await stale.load();
      await stale.reconcile();
      expect(stale.error, 'sync_conflict');
      expect(server.actions, isNot(contains('submit')));
    },
  );

  test(
    'unknown server fate prevents takeover and leaves executor unchanged',
    () async {
      await copyToB();
      final owner = control(a);
      await owner.load();
      await owner.prepare();
      server.failBeforeSubmit = true;
      await owner.apply();
      await sync(a, b);
      final receiver = control(b);
      await receiver.load();
      final before = (await b.readVpn()).source;
      server.statusUnavailable = true;
      await receiver.takeOver('one');
      expect(receiver.error, 'vpn_connection');
      expect(receiver.observesOperation('one'), isTrue);
      expect((await b.readVpn()).source, before);
      expect(server.submissions, isEmpty);
    },
  );

  test(
    'stale runner controller cannot replace a newer pending ID or submit',
    () async {
      final remote = FakeRunnerTransport(MemoryRunnerJournal())
        ..installed = true;
      final owner = runner(a, remote), stale = runner(a, remote);
      await owner.refresh();
      await stale.refresh();
      await owner.startDiagnostic();
      final before = await a.readRunnerJournal('one');
      await stale.startDiagnostic();
      expect(stale.responseCode, 'sync_conflict');
      expect(remote.submissions, 1);
      expect(await a.readRunnerJournal('one'), before);
    },
  );

  test(
    'runner journal CAS rejects a second local writer and survives reopen',
    () async {
      final old = await a.readRunnerJournal('one');
      final source = jsonEncode({
        'version': 1,
        'identity': 'runner-identity',
        'pending': null,
        'selected': null,
        'cursor': 0,
      });
      await a.writeRunnerJournalIfUnchanged('one', source, expectedSource: old);
      final another = open('a');
      await expectLater(
        another.writeRunnerJournalIfUnchanged(
          'one',
          '$source ',
          expectedSource: old,
        ),
        throwsA(isA<SyncMergeFailure>()),
      );
      expect(await another.readRunnerJournal('one'), source);
    },
  );

  test(
    'received generic runner request reads status, explicit retry transfers the same ID',
    () async {
      await copyToB();
      final mirror = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(mirror)..installed = true;
      final owner = runner(a, remote);
      await owner.refresh();
      // Use public diagnostic action to record a complete durable intent.
      remote.loseSubmitResponse = true;
      await owner.startDiagnostic();
      expect(owner.pending, isNotNull);
      final id = owner.pending!.id;
      expect(
        owner.operation!.executorDeviceId,
        (await a.readWorkspaceIdentity()).deviceId,
      );
      await sync(a, b);
      final received = runner(b, remote);
      final before = await b.readRunnerJournal('one');
      await received.refresh();
      expect(received.observesOperation, isTrue);
      expect(received.selected!.id, id);
      expect(remote.submissions, 1);
      expect(await b.readRunnerJournal('one'), before);
      // Simulate a request that never reached the runner after owner persisted it.
      remote.job = null;
      remote.loseSubmitResponse = false;
      final retry = runner(b, remote);
      await retry.restoreLocal();
      await retry.retryPending();
      expect(retry.error, isNull);
      expect(remote.job!.id, id);
      expect(
        retry.operation!.executorDeviceId,
        (await b.readWorkspaceIdentity()).deviceId,
      );
    },
  );
}
