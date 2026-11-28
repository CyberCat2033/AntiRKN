import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

void main() {
  for (final outcome in ['succeeded', 'failed', 'cancelled']) {
    test(
      'system update refreshes indexes and applies packages automatically on $outcome',
      () async {
        final store = MemoryRunnerJournal();
        final remote = FakeRunnerTransport(store)..installed = true;
        final c = RunnerController(
          serverId: 'fixture',
          transport: () => remote,
          identity: () => 'fixture',
          password: () => null,
          accessFailure: (_) {},
          store: store,
        );
        addTearDown(c.dispose);
        await c.refresh();
        expect(
          remote.requests.where((r) => r.json['action'] == 'apt_plan'),
          isEmpty,
        );
        await c.updateSystem();
        expect(c.error, isNull);
        expect(remote.submissions, 1);
        expect(remote.submitWithoutPersistence, isFalse);
        expect(c.selected!.kind, 'apt_update');
        expect(c.aptPlan, isNull);
        await c.updateSystem();
        expect(remote.submissions, 1);
        final id = remote.job!.id;
        remote.job = runnerJob(
          id,
          kind: 'apt_update',
          status: outcome,
          count: 2,
          progress: 2,
          interval: 1,
          sequence: 3,
        );
        await c.refresh();
        expect(c.error, isNull);
        expect(remote.submissions, outcome == 'succeeded' ? 2 : 1);
        expect(
          remote.requests.where((r) => r.json['action'] == 'apt_plan').length,
          outcome == 'succeeded' ? 1 : 0,
        );
        if (outcome == 'succeeded') {
          expect(c.aptPlan, isNull);
          await c.refresh();
          expect(
            remote.requests.where((r) => r.json['action'] == 'apt_plan'),
            hasLength(1),
          );
          expect(remote.submissions, 2);
          final submit = remote.requests.lastWhere(
            (r) => r.json['action'] == 'submit',
          );
          expect(submit.json['kind'], 'apt_upgrade');
          expect(submit.json['fingerprint'], 'f' * 64);
        } else {
          expect(c.aptPlan, isNull);
        }
      },
    );
  }

  test('Check refreshes the indexes and stops at the plan', () async {
    final store = MemoryRunnerJournal();
    final remote = FakeRunnerTransport(store)..installed = true;
    final c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture',
      password: () => null,
      accessFailure: (_) {},
      store: store,
    );
    addTearDown(c.dispose);
    await c.refresh();
    await c.updateSystem(upgrade: false);
    expect(c.selected!.kind, 'apt_update');
    remote.job = runnerJob(
      remote.job!.id,
      kind: 'apt_update',
      status: 'succeeded',
      count: 2,
      progress: 2,
      interval: 1,
      sequence: 3,
    );
    await c.refresh();
    await c.refresh();
    expect(c.aptPlan, isNotNull);
    expect(remote.submissions, 1);
  });

  test(
    'index request survives a lost reply and does not submit an upgrade on restore',
    () async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store)
        ..installed = true
        ..loseSubmitResponse = true;
      RunnerController create() => RunnerController(
        serverId: 'fixture',
        transport: () => remote,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
      final first = create();
      await first.refresh();
      await first.updateSystem();
      expect(first.pending, isNotNull);
      final id = first.pending!.id!;
      first.dispose();
      remote.loseSubmitResponse = false;
      remote.job = runnerJob(
        id,
        kind: 'apt_update',
        status: 'succeeded',
        count: 2,
        progress: 2,
        interval: 1,
        sequence: 3,
      );
      final second = create();
      addTearDown(second.dispose);
      await second.refresh();
      expect(second.selected!.status, 'succeeded');
      expect(second.pending, isNull);
      expect(remote.submissions, 1);
      expect(second.aptPlan, isNull);
    },
  );

  RunnerController controller(
    MemoryRunnerJournal store,
    FakeRunnerTransport remote,
  ) => RunnerController(
    serverId: 'fixture',
    transport: () => remote,
    identity: () => 'fixture',
    password: () => null,
    accessFailure: (_) {},
    store: store,
  );

  /// A connection, its refresh and the automatic check after it.
  Future<void> connect(RunnerController c) async {
    c.connectionReady();
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
      await c.waitUntilIdle();
    }
  }

  int plans(FakeRunnerTransport remote) =>
      remote.requests.where((r) => r.json['action'] == 'apt_plan').length;

  test(
    'a connection checks Ubuntu read-only, at most every few hours, silently',
    () async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store)..installed = true;
      final c = controller(store, remote);
      addTearDown(c.dispose);
      var now = DateTime.utc(2026, 11, 28, 12);
      c.clock = () => now;
      await connect(c);
      expect(plans(remote), 1);
      // No index refresh, no job card.
      expect(remote.submissions, 0);
      expect(c.selected, isNull);
      expect(c.aptPlan!['packages'], hasLength(1));
      expect(c.aptCheckedAt, now);
      now = now.add(const Duration(hours: 1));
      await connect(c);
      expect(plans(remote), 1);
      // An old result is read again; a refusal keeps it without an error.
      now = now.add(RunnerController.aptSchedule.interval);
      remote.aptPlanCode = 'apt_conflict';
      await connect(c);
      expect(plans(remote), 2);
      expect(c.error, isNull);
      expect(c.responseCode, isNull);
      expect(c.aptPlan!['packages'], hasLength(1));
      // A failed attempt is not repeated at every connection.
      remote.aptPlanCode = null;
      await connect(c);
      expect(plans(remote), 2);
      now = now.add(RunnerController.aptSchedule.retry);
      remote.aptPlanData = {
        'packages': <Object?>[],
        'fingerprint': 'e' * 64,
        'rebootRequired': false,
      };
      await connect(c);
      expect(plans(remote), 3);
      expect(c.aptPlan!['packages'], isEmpty);
    },
  );

  test(
    'the Ubuntu status survives a restart, a disconnect and other plans',
    () async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store)..installed = true;
      final checked = DateTime.utc(2026, 11, 28, 12);
      final first = controller(store, remote)..clock = () => checked;
      await connect(first);
      first.dispose();
      final second = controller(store, remote)
        ..clock = () => checked.add(const Duration(hours: 1));
      addTearDown(second.dispose);
      await second.restoreLocal();
      expect(second.aptPlan!['packages'], hasLength(1));
      expect(second.aptPlan!['fingerprint'], 'f' * 64);
      expect(second.aptCheckedAt, checked);
      second.disconnected();
      expect(second.aptPlan, isNotNull);
      await second.refresh();
      await second.prepareComponent('trusttunnel');
      expect(second.aptPlan!['packages'], hasLength(1));
      // Still fresh: the next connection does not ask again.
      await connect(second);
      expect(plans(remote), 1);
    },
  );

  test(
    'Update with a stored plan reads it again: the same packages go with the new fingerprint, others wait',
    () async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store)..installed = true;
      var now = DateTime.utc(2026, 11, 28, 12);
      final first = controller(store, remote)..clock = () => now;
      await connect(first);
      first.dispose();
      now = now.add(const Duration(hours: 1));
      final c = controller(store, remote)..clock = () => now;
      addTearDown(c.dispose);
      await c.restoreLocal();
      await c.refresh();
      // The package lists moved on: another set is shown, nothing submitted.
      remote.aptPlanData = {
        'packages': [
          {'name': 'fixture', 'installed': '1', 'version': '3'},
        ],
        'fingerprint': 'd' * 64,
        'rebootRequired': false,
      };
      await c.applyApt();
      expect(plans(remote), 2);
      expect(remote.submissions, 0);
      expect(c.error, isNull);
      expect(c.aptPlan!['fingerprint'], 'd' * 64);
      expect(store.value, contains('d' * 64));
      // Fresh now: Update submits it without another read.
      await c.applyApt();
      expect(plans(remote), 2);
      expect(remote.submissions, 1);
      var submit = remote.requests.lastWhere(
        (r) => r.json['action'] == 'submit',
      );
      expect(submit.json['fingerprint'], 'd' * 64);
      // The plan went with the request.
      expect(c.aptPlan, isNull);
      expect(store.value, isNot(contains('"apt"')));
      remote.job = runnerJob(
        remote.job!.id,
        kind: 'apt_upgrade',
        status: 'failed',
        count: 2,
        progress: 2,
        interval: 1,
        sequence: 3,
      );
      await c.refresh();
      await c.dismissJob();
      remote.job = null;
      // Same packages, a new fingerprint: submitted with the new one.
      remote.aptPlanData = null;
      await c.prepareApt(upgrade: true);
      expect(plans(remote), 3);
      now = now.add(RunnerController.aptPlanFresh);
      remote.aptPlanData = {
        'packages': [
          {'name': 'fixture', 'installed': '1', 'version': '2'},
        ],
        'fingerprint': 'c' * 64,
        'rebootRequired': false,
      };
      await c.applyApt();
      expect(plans(remote), 4);
      expect(remote.submissions, 2);
      submit = remote.requests.lastWhere((r) => r.json['action'] == 'submit');
      expect(submit.json['fingerprint'], 'c' * 64);
    },
  );
}
