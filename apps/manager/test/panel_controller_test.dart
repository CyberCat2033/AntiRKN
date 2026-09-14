import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

void main() {
  late MemoryRunnerJournal store;
  late FakeRunnerTransport remote;
  RunnerController create() => RunnerController(
    serverId: 'fixture',
    transport: () => remote,
    identity: () => 'fixture|hostkey',
    password: () => null,
    accessFailure: (_) {},
    store: store,
  );
  setUp(() {
    store = MemoryRunnerJournal();
    remote = FakeRunnerTransport(store);
  });

  test('preview, no selection and dismissal have no mutation', () async {
    final c = create();
    addTearDown(c.dispose);
    c.chooseComponents();
    await c.preparePanel();
    expect(remote.requests, isEmpty);
    c.selectPanel(true);
    await c.preparePanel();
    expect(c.panelPlan!.canApply, isTrue);
    expect(remote.installs, 0);
    expect(remote.submissions, 0);
    c.dismissComponents();
    await c.applyPanel();
    expect(remote.installs, 0);
  });

  for (final condition in ['existing', 'port', 'prerequisites', 'stale']) {
    test('$condition blocks install before runner mutation', () async {
      final c = create();
      addTearDown(c.dispose);
      if (condition == 'existing') remote.panelState = 'existing';
      if (condition == 'port') remote.panelPortAvailable = false;
      if (condition == 'prerequisites') remote.panelSupported = false;
      c.chooseComponents();
      c.selectPanel(true);
      await c.preparePanel();
      if (condition == 'stale') remote.panelFingerprint = 'e' * 64;
      await c.applyPanel();
      expect(remote.installs, 0);
      expect(remote.submissions, 0);
    });
  }

  test(
    'uncertain installation survives controller restart with same ID',
    () async {
      final first = create();
      first.chooseComponents();
      first.selectPanel(true);
      await first.preparePanel();
      remote.loseSubmitResponse = true;
      await first.applyPanel();
      expect(remote.submitWithoutPersistence, isFalse);
      final id = first.pending!.id;
      first.dispose();
      final next = create();
      addTearDown(next.dispose);
      await next.restoreLocal();
      expect(next.pending!.id, id);
      remote.loseSubmitResponse = false;
      await next.retryPending();
      expect(remote.submissions, 1);
      expect(next.selected!.id, id);
      expect(next.selected!.kind, 'panel_install');
    },
  );

  test(
    'successful job requires SSH API verification and persists access',
    () async {
      final first = create();
      first.chooseComponents();
      first.selectPanel(true);
      await first.preparePanel();
      await first.applyPanel();
      remote.job = runnerJob(
        first.selected!.id,
        kind: 'panel_install',
        count: 6,
        interval: 1,
        progress: 6,
        status: 'succeeded',
        sequence: 9,
      );
      await first.refresh();
      expect(remote.panelChecks, 1);
      expect(first.panelAccess!.password, 'A' * 43);
      expect((jsonDecode(store.value!) as Map)['pending'], isNull);
      first.dispose();
      final next = create();
      addTearDown(next.dispose);
      await next.restoreLocal();
      expect(next.panelAccess!.id, remote.job!.id);
      expect(next.panelVerifiedAt, isNotNull);
    },
  );

  test('request contract rejects wrong step counts and unknown commands', () {
    final valid = {
      'version': 1,
      'action': 'submit',
      'kind': 'panel_install',
      'id': '1' * 32,
      'count': 6,
      'interval': 1,
      'port': 2053,
      'fingerprint': 'a' * 64,
    };
    expect(() => RunnerRequest.fromJson(valid), returnsNormally);
    for (final patch in [
      {'count': 10},
      {'port': 0},
      {'fingerprint': '../../etc'},
      {'shell': 'id'},
    ]) {
      expect(
        () => RunnerRequest.fromJson({...valid, ...patch}),
        throwsFormatException,
      );
    }
  });
}
