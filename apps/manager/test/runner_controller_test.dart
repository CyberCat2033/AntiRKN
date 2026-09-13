import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

void main() {
  late MemoryRunnerJournal store;
  late FakeRunnerTransport remote;
  late RunnerController c;
  var connected = true;
  var identity = 'fixture|key';
  RunnerController create() => RunnerController(
    serverId: 'fixture',
    transport: () => connected ? remote : null,
    identity: () => identity,
    password: () => null,
    accessFailure: (_) {},
    store: store,
  );
  setUp(() {
    store = MemoryRunnerJournal();
    remote = FakeRunnerTransport(store);
    connected = true;
    identity = 'fixture|key';
    c = create();
  });
  tearDown(() => c.dispose());
  Future<void> install() async {
    await c.prepareInstall();
    await c.applyInstall();
  }

  test(
    'inspection, plan preview and dismissal have no server effect',
    () async {
      await c.refresh();
      await c.prepareInstall();
      c.dismissPlan();
      expect(remote.installs, 0);
      expect(remote.requests, isEmpty);
      await c.applyInstall();
      expect(remote.installs, 0);
      await install();
      expect(remote.installs, 1);
      expect(remote.submissions, 0);
    },
  );
  test('persist before submit; double click sends one request', () async {
    await install();
    remote.submitGate = Completer<void>();
    final first = c.startDiagnostic();
    await Future<void>.delayed(Duration.zero);
    await c.startDiagnostic();
    expect(remote.submissions, 1);
    expect(remote.submitWithoutPersistence, isFalse);
    remote.submitGate!.complete();
    await first;
    expect(c.selected!.status, 'running');
    expect(c.pending, isNull);
  });
  test('storage failure prevents first submission', () async {
    await install();
    store.failWrite = true;
    await c.startDiagnostic();
    expect(remote.submissions, 0);
    expect(c.error, RunnerIssue.storage);
    store.failWrite = false;
    await c.retryPending();
    expect(remote.submissions, 1);
    expect(remote.submitWithoutPersistence, isFalse);
  });
  test(
    'lost response and app restart recover result without resubmission',
    () async {
      await install();
      remote.loseSubmitResponse = true;
      await c.startDiagnostic();
      expect(c.pending, isNotNull);
      expect(c.connectionLost, isTrue);
      final id = c.pending!.id;
      c.dispose();
      c = create();
      await c.refresh();
      expect(c.selected!.id, id);
      expect(c.pending, isNull);
      expect(remote.submissions, 1);
      expect(remote.requests.last.json['action'], 'status');
    },
  );
  test(
    'cursor and received events persist together, then merge incrementally',
    () async {
      await install();
      await c.startDiagnostic();
      final id = c.selected!.id;
      final cursor = c.cursor;
      remote.job = runnerJob(id, progress: 2, sequence: 3);
      await c.refresh();
      expect(remote.requests.last.json['cursor'], cursor);
      expect(c.selected!.events.map((e) => e.sequence), [2, 3]);
      final saved = jsonDecode(store.value!) as Map;
      expect(saved['cursor'], 3);
      expect((saved['selected']['events'] as List).length, 2);
    },
  );
  test(
    'disconnect does not cancel the server job; late response is ignored',
    () async {
      await install();
      remote.submitGate = Completer<void>();
      final work = c.startDiagnostic();
      await Future<void>.delayed(Duration.zero);
      connected = false;
      c.disconnected();
      remote.submitGate!.complete();
      await work;
      expect(c.selected, isNull);
      expect(c.pending, isNotNull);
      expect(remote.cancellations, 0);
      expect(c.busy, isFalse);
      connected = true;
      await c.refresh();
      expect(c.selected, isNotNull);
      expect(remote.submissions, 1);
    },
  );
  test(
    'explicit cancellation is a request, observed terminal result is displayed',
    () async {
      await install();
      await c.startDiagnostic();
      await c.cancelJob();
      expect(remote.cancellations, 1);
      expect(c.selected!.status, 'cancelled');
      await c.cancelJob();
      expect(remote.cancellations, 1);
    },
  );
  test(
    'changed server identity cannot resubmit an old pending request',
    () async {
      await install();
      remote.loseSubmitResponse = true;
      await c.startDiagnostic();
      identity = 'replacement|new-key';
      remote.job = null;
      remote.loseSubmitResponse = false;
      await c.refresh();
      expect(c.pending, isNull);
      expect(c.selected, isNull);
      expect(remote.submissions, 1);
    },
  );
  test('failed history read keeps the current result', () async {
    await install();
    await c.startDiagnostic();
    final previous = c.selected;
    remote.failStatus = true;
    await c.selectJob('b' * 32);
    expect(c.selected, same(previous));
    expect(c.error, RunnerIssue.invalidResponse);
  });

  test('request validation blocks injected commands and out-of-range work', () {
    expect(
      () => RunnerRequest.diagnostic('../../etc/shadow'),
      throwsFormatException,
    );
    expect(
      () => RunnerRequest.diagnostic('a' * 32, count: 61),
      throwsFormatException,
    );
    expect(
      () => RunnerRequest.fromJson({
        'version': 1,
        'action': 'list',
        'shell': 'id',
      }),
      throwsFormatException,
    );
  });
}
