import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runner_support.dart';
import 'vpn_controller_test.dart' as v;

/// A saved server that was reinstalled (new host key, empty machine) must
/// heal by itself: the app's resources go back to the new machine without a
/// hidden identity error, and a failed attempt is shown instead of looping.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late v.MemoryVpn store;
  late Map<String, v.Remote> remotes;
  late Map<String, String> identities;
  late VpnController c;

  setUp(() async {
    store = v.MemoryVpn();
    remotes = {'one': v.Remote(store)};
    identities = {'one': 'host|old-key'};
    c = VpnController(
      repository: store,
      template: () => v.template,
      serverIds: () => remotes.keys.toList(),
      remote: (id) => remotes[id] == null
          ? null
          : VpnRemote(
              transport: remotes[id]!,
              panelId: v.panel,
              identity: identities[id]!,
              observationKey: identities[id],
            ),
      timer: (d, f) => Timer(Duration.zero, () {}),
    );
    await c.load();
    await c.saveUser(VpnUser(id: v.alice, login: 'alice', name: 'Alice'));
    await c.saveInbound(v.inbound('one', '1' * 32));
    await c.prepareAndApply(serverIds: {'one'});
    expect(c.error, isNull);
    expect(remotes['one']!.submissions, hasLength(1));
    expect(c.workspace.servers['one']!['identity'], 'host|old-key');
    expect(c.missingOnServer('one'), 0);
  });

  tearDown(() => c.dispose());

  void reinstall() {
    remotes['one'] = v.Remote(store);
    identities['one'] = 'host|new-key';
  }

  test('a reinstalled server gets the app resources back by itself', () async {
    reinstall();
    await c.reconcile();
    final record = c.workspace.servers['one']!;
    expect(record['identity'], 'host|new-key');
    expect(record['error'], isNull);
    expect(c.error, isNull);
    expect(remotes['one']!.submissions, hasLength(1));
    final sent = remotes['one']!.submissions.values.single;
    expect((sent['resources'] as List).map((r) => (r as Map)['id']), [
      '1' * 32,
    ]);
    expect(c.missingOnServer('one'), 0);
  });

  test('a failed automatic send stays visible and is not repeated', () async {
    reinstall();
    remotes['one']!.failPlan = true;
    await c.reconcile();
    expect(c.workspace.servers['one']!['identity'], 'host|new-key');
    expect(c.missingOnServer('one'), 1);
    expect(c.serverSyncIssue, isNotNull);
    expect(c.sendIssue('one'), isNotNull);
    final plans = remotes['one']!.actions.where((a) => a == 'vless_plan');
    expect(plans, hasLength(1));
    await c.reconcile();
    expect(
      remotes['one']!.actions.where((a) => a == 'vless_plan'),
      hasLength(1),
      reason: 'one automatic attempt per change',
    );
    remotes['one']!.failPlan = false;
    await c.prepareAndApply(serverIds: {'one'});
    expect(remotes['one']!.submissions, hasLength(1));
    expect(c.missingOnServer('one'), 0);
  });

  test('a deletion that never reached the server is sent by itself', () async {
    final saved = c.workspace.inbounds.single;
    await c.deleteInbounds([saved]);
    expect(remotes['one']!.submissions, hasLength(1));
    await c.reconcile();
    expect(remotes['one']!.submissions, hasLength(2));
    final sent = remotes['one']!.submissions.values.last;
    expect(((sent['resources'] as List).single as Map)['deleted'], isTrue);
  });

  test('a refusal on one target does not block or mislabel another', () async {
    remotes['two'] = v.Remote(store);
    identities['two'] = 'host2|old-key';
    await c.saveInbound(v.inbound('two', '2' * 32));
    await c.prepareAndApply(serverIds: {'two'});
    expect(remotes['two']!.submissions, hasLength(1));
    reinstall();
    remotes['two'] = v.Remote(store)..failPlan = true;
    identities['two'] = 'host2|new-key';
    for (var i = 0; i < 4; i++) {
      await c.reconcile();
    }
    expect(remotes['one']!.submissions, hasLength(1));
    expect(c.missingOnServer('one'), 0);
    expect(c.sendIssue('one'), isNull);
    expect(c.sendIssue('two'), isNotNull);
    expect(c.missingOnServer('two'), 1);
  });

  test('an explicit replacement rebinds without waiting for a plan', () async {
    reinstall();
    await c.rebindServer('one', 'host|new-key');
    final record = c.workspace.servers['one']!;
    expect(record.keys, ['identity']);
    expect(record['identity'], 'host|new-key');
  });

  test('install confirmed while the server is busy waits its turn', () async {
    final journal = MemoryRunnerJournal();
    final remote = FakeRunnerTransport(journal);
    final runner = RunnerController(
      serverId: 'fixture',
      store: journal,
      identity: () => 'fixture',
      password: () => null,
      accessFailure: (_) {},
      transport: () => remote,
    );
    addTearDown(runner.dispose);
    runner.jobs = [runnerJob('a' * 32, status: 'running')];
    expect(runner.canRequestAction, isFalse);
    final install = runner.installOrUpdate('trusttunnel');
    await Future<void>.delayed(Duration.zero);
    expect(runner.queuedInstalls, ['trusttunnel']);
    expect(remote.submissions, 0);
    // A second confirmation of the same install is not queued twice.
    await runner.installOrUpdate('trusttunnel');
    expect(runner.queuedInstalls, ['trusttunnel']);
    runner.jobs = [runnerJob('a' * 32, status: 'succeeded')];
    await install.timeout(const Duration(seconds: 10));
    expect(runner.queuedInstalls, isEmpty);
    expect(remote.submissions, 1);
  });

  test(
    'an install the server refuses as busy is retried, not dropped',
    () async {
      final journal = MemoryRunnerJournal();
      final remote = _BusyOnce(journal);
      final runner = RunnerController(
        serverId: 'fixture',
        store: journal,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
        transport: () => remote,
      )..busyRetryDelay = const Duration(milliseconds: 10);
      addTearDown(runner.dispose);
      // The app's own VPN sync holds the server: this controller does not see
      // that job, only the "busy" answer to its submission.
      await runner
          .installOrUpdate('trusttunnel')
          .timeout(const Duration(seconds: 10));
      expect(remote.refusals, 1);
      expect(remote.submissions, 2);
      expect(runner.queuedInstalls, isEmpty);
      expect(runner.responseCode, 'ok');
    },
  );
}

class _BusyOnce extends FakeRunnerTransport {
  _BusyOnce(super.store);
  int refusals = 0;
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    if (request.json['action'] == 'submit' && refusals == 0) {
      refusals++;
      submissions++;
      return RunnerResponse.fromJson({
        'version': 1,
        'code': 'busy',
        'alive': true,
        'jobs': <Object?>[],
      });
    }
    return super.request(request, cancellation, sudoPassword: sudoPassword);
  }
}
