import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

Map<String, Object?> _event(int sequence, String code) => {
  'sequence': sequence,
  'timestamp': 1789340000 + sequence,
  'code': code,
  'progress': 6,
  'total': 6,
};

RunnerJob _upgrade(String id, String status, List<String> codes) => runnerJob(
  id,
  kind: 'component_upgrade_apply',
  status: status,
  progress: 6,
  count: 6,
  interval: 1,
  sequence: codes.length,
  events: [for (var i = 0; i < codes.length; i++) _event(i + 1, codes[i])],
);

PanelAccess _access() => PanelAccess.fromJson({
  'id': 'a' * 32,
  'port': 2053,
  'username': 'antirkn',
  'password': 'A' * 43,
  'panelVersion': '3.7.0',
  'xrayVersion': '26.7.28',
});

void main() {
  final id = 'c' * 32;

  test('a terminal panel update re-verifies the panel only once', () async {
    final store = MemoryRunnerJournal();
    final remote = FakeRunnerTransport(store)..installed = true;
    final c = fixtureRunner(remote, store);
    addTearDown(c.dispose);
    await c.refresh();
    c.panelAccess = _access();
    remote.job = runnerJob(
      id,
      kind: 'panel_update',
      status: 'succeeded',
      count: 6,
      interval: 1,
    );
    c.selected = runnerJob(id, kind: 'panel_update', count: 6, interval: 1);
    await c.selectJob(id);
    expect(remote.panelChecks, 1);
    await c.selectJob(id);
    await c.selectJob(id);
    expect(remote.panelChecks, 1, reason: 'already terminal: no re-verify');
  });

  test(
    'an unconfirmed upgrade stays watched and the confirmation is retried',
    () async {
      final store = MemoryRunnerJournal();
      final remote = ScriptedTransport(store)
        ..installed = true
        ..confirmDisconnects = true;
      final c = fixtureRunner(remote, store);
      addTearDown(c.dispose);
      await c.refresh();
      remote.job = _upgrade(id, 'succeeded', [
        'upgrade_checked',
        'upgrade_awaiting_confirmation',
      ]);
      await c.selectJob(id);
      expect(remote.confirms, 1);
      expect(c.error, RunnerIssue.unavailable);
      expect(c.watchesUpgrade, isTrue);
      expect(c.hasUnfinishedJob, isTrue, reason: 'keeps polling/reconnect');

      // The next poll retries; a lock still held answers upgrade_conflict.
      remote.confirmDisconnects = false;
      remote.confirmCodes.add('upgrade_conflict');
      await c.pollActiveJob();
      expect(remote.confirms, 2);
      expect(c.watchesUpgrade, isTrue);
      expect(c.responseCode, 'ok', reason: 'a retry is not shown as failure');

      remote.job = _upgrade(id, 'succeeded', [
        'upgrade_checked',
        'upgrade_awaiting_confirmation',
        'upgrade_confirmed',
      ]);
      await c.pollActiveJob();
      expect(remote.confirms, 2);
      expect(c.watchesUpgrade, isFalse);
      expect(c.hasUnfinishedJob, isFalse);
      await c.pollActiveJob();
      expect(remote.confirms, 2);
    },
  );

  test(
    'a late rollback refreshes software and re-verifies the panel',
    () async {
      final store = MemoryRunnerJournal();
      final remote = ScriptedTransport(store)..installed = true;
      var refreshes = 0;
      final c = fixtureRunner(
        remote,
        store,
        refreshSoftware: () => refreshes++,
      );
      addTearDown(c.dispose);
      await c.refresh();
      c.panelAccess = _access();
      c.selected = _upgrade(id, 'succeeded', [
        'upgrade_checked',
        'upgrade_awaiting_confirmation',
      ]);
      c.cursor = 2;
      remote.job = c.selected;
      remote.confirmCodes.addAll(['upgrade_failed', 'upgrade_rolled_back']);
      await c.selectJob(id);
      expect(c.watchesUpgrade, isTrue);
      expect(remote.panelChecks, 0);
      expect(refreshes, 0);

      // The confirmation window expired: the server rolled back.
      await c.pollActiveJob();
      expect(remote.confirms, 2);
      remote.job = _upgrade(id, 'failed', [
        'upgrade_checked',
        'upgrade_awaiting_confirmation',
        'upgrade_rolled_back',
      ]);
      await c.pollActiveJob();
      expect(c.selected!.status, 'failed');
      expect(c.watchesUpgrade, isFalse);
      expect(remote.panelChecks, 1);
      expect(refreshes, 1);
      final confirms = remote.confirms;
      await c.pollActiveJob();
      expect(remote.confirms, confirms);
      expect(remote.panelChecks, 1);
    },
  );

  test('the watch ends after its limit', () async {
    final store = MemoryRunnerJournal();
    final remote = ScriptedTransport(store)
      ..installed = true
      ..confirmCodes.add('upgrade_conflict');
    final c = fixtureRunner(remote, store)..upgradeWatchLimit = Duration.zero;
    addTearDown(c.dispose);
    await c.refresh();
    remote.job = _upgrade(id, 'succeeded', [
      'upgrade_checked',
      'upgrade_awaiting_confirmation',
    ]);
    await c.selectJob(id);
    expect(c.watchesUpgrade, isFalse);
    expect(c.hasUnfinishedJob, isFalse);
  });
}
