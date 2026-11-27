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
}
