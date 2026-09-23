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
  late WorkspaceDatabase a;
  final stores = <WorkspaceDatabase>[];
  final controllers = <VpnController>[];
  final runners = <RunnerController>[];
  late FailableRemote server;
  WorkspaceDatabase open(String name) {
    final db = WorkspaceDatabase.open(
      '${directory.path}/$name.sqlite',
      key: SecretKeyData(List.filled(32, name == 'a' ? 19 : 41)),
    );
    stores.add(db);
    return db;
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

}
