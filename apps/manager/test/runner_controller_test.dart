import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations_en.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
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
    'reboot persists before submit and recovers lost reply without resending',
    () async {
      await install();
      remote.loseSubmitResponse = true;
      await c.rebootServer();
      expect(remote.submissions, 1);
      expect(remote.submitWithoutPersistence, isFalse);
      expect(c.pending?.json['kind'], 'server_reboot');
      final id = c.pending!.id;
      c.dispose();
      c = create();
      await c.restoreLocal();
      remote.loseSubmitResponse = false;
      await c.refresh();
      expect(c.selected?.id, id);
      expect(c.pending, isNull);
      expect(remote.submissions, 1);
      await c.rebootServer();
      expect(remote.submissions, 1);
    },
  );

  test(
    'recovery clears a persisted unsent hardening job before reconnect',
    () async {
      final id = 'a' * 32;
      store.value = jsonEncode({
        'version': 1,
        'identity': identity,
        'cursor': 0,
        'pending': RunnerRequest.sshHarden(id, {
          'username': 'fixture',
          'port': 2222,
          'sudoPassword': 'test-only',
        }, 'f' * 64).json,
      });
      expect(c.pending, isNull);
      await c.clearHardenPending(id);
      expect(c.pending, isNull);
      expect((jsonDecode(store.value!) as Map)['pending'], isNull);
      await c.retryPending();
      expect(remote.submissions, 0);
    },
  );

  test(
    'connect prepares runner once and recovers existing panel independently of last job',
    () async {
      remote.job = runnerJob('d' * 32, status: 'succeeded', progress: 10);
      remote.discovery = {
        'failed': false,
        'cliAvailable': true,
        'panels': [
          {
            'source': 'systemd',
            'port': 2053,
            'listen': '127.0.0.1',
            'basePath': '/',
            'tls': false,
            'inbounds': <Object?>[],
          },
        ],
      };
      remote.recoveredAccess = {
        'id': 'e' * 32,
        'port': 2053,
        'username': 'antirkn',
        'password': 'A' * 43,
        'panelVersion': '3.7.0',
        'xrayVersion': '26.7.28',
      };
      await c.refresh(prepare: true);
      expect(c.error, isNull);
      expect(remote.installs, 1);
      expect(c.panelDetected, isTrue);
      expect(c.panelAccess?.id, 'e' * 32);
      expect(c.panelVerifiedAt, isNotNull);
      c.chooseComponents();
      expect(c.choosingPanel, isFalse);
      await c.preparePanel();
      expect(remote.submissions, 0);
      await c.refresh(prepare: true);
      expect(remote.installs, 1);
      c.disconnected();
      expect(c.panelVerifiedAt, isNull);
    },
  );

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
  test('active polling reads only status after initial inspection', () async {
    await install();
    await c.startDiagnostic();
    final inspections = remote.inspections;
    final requests = remote.requests.length;
    await c.pollActiveJob();
    expect(remote.inspections, inspections);
    expect(remote.requests.skip(requests).map((r) => r.json['action']), [
      'status',
    ]);
  });
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

  test('clearManagedClients sends clear_managed_clients action', () async {
    await install();
    final ok = await c.clearManagedClients();
    expect(ok, isTrue);
    expect(
      remote.requests.any((r) => r.json['action'] == 'clear_managed_clients'),
      isTrue,
    );
  });

  test(
    'upgradable predecessor runner is automatically upgraded during prepare refresh and ensureReady',
    () async {
      remote.installed = true;
      remote.customRelease = 'c' * 64;
      remote.upgradable = true;
      await c.refresh();
      expect(c.installed, isFalse);
      expect(c.installation?.upgradable, isTrue);
      expect(remote.installs, 0);

      final ready = await c.ensureReady();
      expect(ready, isTrue);
      expect(remote.installs, 1);
      expect(c.installed, isTrue);
      expect(c.installation?.release, remote.bundledRelease);
      expect(c.installation?.upgradable, isFalse);
    },
  );

  test(
    'resetJobQueue cancels active jobs and clears local queue state',
    () async {
      await install();
      // Simulate a hung / active job
      c.pending = RunnerRequest.diagnostic('d' * 32);
      c.connectionLost = true;
      c.busy = true;

      await c.resetJobQueue();
      expect(c.busy, isFalse);
      expect(c.pending, isNull);
      expect(c.connectionLost, isFalse);
      expect(
        remote.requests.any((r) => r.json['action'] == 'cancel'),
        isFalse, // no server active jobs in initial store
      );
    },
  );

  test(
    'non-terminal apt_update and apt_upgrade do not block canRequestAction',
    () async {
      await install();
      expect(c.canRequestAction, isTrue);

      c.jobs = [runnerJob('1' * 32, kind: 'diagnostic', status: 'running')];
      expect(c.canRequestAction, isFalse);

      c.jobs = [
        runnerJob(
          '2' * 32,
          kind: 'apt_update',
          count: 2,
          interval: 1,
          status: 'running',
        ),
      ];
      expect(c.canRequestAction, isTrue);

      c.jobs = [
        runnerJob(
          '3' * 32,
          kind: 'apt_upgrade',
          count: 2,
          interval: 1,
          status: 'planned',
        ),
      ];
      expect(c.canRequestAction, isTrue);
    },
  );

  test(
    'submit succeeds without invalidResponse when response contains multiple jobs in queue',
    () async {
      await install();
      final candidate = {
        'component': 'panel',
        'version': '3.11.0',
        'architecture': 'x86_64',
        'assetName': 'x-ui-linux-amd64.tar.gz',
        'url': 'https://example.com/x-ui.tar.gz',
        'bytes': 80000000,
        'sha256': '',
      };
      final plan = {
        'component': 'panel',
        'currentVersion': '3.8.0',
        'targetVersion': '3.11.0',
        'fingerprint': 'a' * 64,
      };
      final oldJob = runnerJob(
        'b' * 32,
        kind: 'apt_update',
        count: 2,
        interval: 1,
        status: 'planned',
      );
      remote.customSubmitJobs = [
        runnerJob(
          '1' * 32,
          kind: 'component_upgrade_apply',
          count: 6,
          interval: 1,
          status: 'planned',
        ),
        oldJob,
      ];

      await c.applyComponentUpgrade(plan, candidate);
      expect(c.error, isNull);
      expect(c.pending, isNull);
      expect(c.selected?.kind, equals('component_upgrade_apply'));
    },
  );

  test('test_ui_upgrade_labels_parity resolves all upgrade event codes', () {
    final l = AppLocalizationsEn();
    final codes = [
      'upgrade_preparing',
      'upgrade_downloading',
      'upgrade_backing_up',
      'upgrade_syntax_checking',
      'upgrade_switching',
      'upgrade_verifying',
      'upgrade_rolling_back',
      'upgrade_completed',
      'upgrade_rolled_back',
      'upgrade_syntax_failed',
      'upgrade_healthcheck_failed',
      'upgrade_download_missing',
      'upgrade_download_failed',
      'upgrade_checksum_failed',
      'upgrade_conflict',
    ];
    for (final code in codes) {
      final label = tryResolveUpgradeLabel(l, code);
      expect(label, isNotNull, reason: 'Code $code must be resolved');
      expect(label!.isNotEmpty, isTrue);
      if (!code.endsWith('_failed') && code != 'upgrade_conflict') {
        expect(label, isNot(contains('Failed')));
      }
    }
  });
}
