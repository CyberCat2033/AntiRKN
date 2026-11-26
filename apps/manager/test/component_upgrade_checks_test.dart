import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/runner/device_upgrade_checks.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/component_upgrade_checks_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'connection_checks_test.dart' as n;
import 'runner_support.dart';
import 'vpn_controller_test.dart' as f;
import 'xray_upgrade_test.dart' as x;

/// The runner side of a checked 3x-ui upgrade (upgrade_checks.py): the
/// plan names the enabled inbounds, the job keeps the leases and its window
/// waits for the commit; abort or a refusal rolls it back.
class ComponentRemote extends x.UpgradeRemote {
  ComponentRemote(super.store);
  Map? submitted, committed;
  bool aborted = false, cancelled = false;
  String? job;
  String status = 'running';
  final events = <String>[];
  String? commitRefusal;

  Map<String, dynamic> jobJson() => runnerJob(
    job!,
    kind: 'component_upgrade_apply',
    count: 6,
    interval: 1,
    status: status,
    sequence: events.length,
    events: [
      for (var i = 0; i < events.length; i++)
        {
          'sequence': i + 1,
          'timestamp': 1789340000,
          'code': events[i],
          'progress': 6,
          'total': 6,
        },
    ],
  ).toJson();

  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    final r = request.json, a = r['action'] as String;
    RunnerResponse reply([String code = 'ok', bool withJob = true]) =>
        RunnerResponse.fromJson({
          ...response(jobs: withJob && job != null ? [jobJson()] : const []),
          'code': code,
        });
    if (a == 'component_upgrade_check') {
      calls.add(a);
      return RunnerResponse.fromJson({
        ...response(),
        'componentUpgrade': {
          'component': 'panel',
          'upgradable': true,
          'fingerprint': 'a' * 64,
          'currentVersion': '3.8.0',
          'candidateVersion': '3.11.0',
          'deviceChecks': {
            'panelId': f.panel,
            'inbounds': [
              for (var i = 0; i < state.length; i++)
                {
                  'id': i + 1,
                  'enabled': true,
                  'protocol': 'vless',
                  'name':
                      'AntiRKN:${state[i]['workspaceId']}:${state[i]['id']}',
                },
            ],
          },
        },
      });
    }
    if (a == 'submit' && r['kind'] == 'component_upgrade_apply') {
      calls.add(a);
      submitted = jsonDecode(r['payload'] as String) as Map;
      job = r['id'] as String;
      status = 'succeeded';
      events.addAll(['upgrade_checked', 'upgrade_awaiting_checks']);
      phase = 'awaiting_checks'; // The core fixture fails UDP after this.
      return reply();
    }
    if (a == 'status' && r['id'] == job) return reply();
    if (a == 'component_upgrade_commit') {
      calls.add(a);
      committed = jsonDecode(r['payload'] as String) as Map;
      if (commitRefusal != null) return reply(commitRefusal!, false);
      events.add('upgrade_confirmed');
      return reply('ok', false);
    }
    if (a == 'component_upgrade_abort') {
      calls.add(a);
      aborted = true;
      status = 'failed';
      phase = 'rolled_back';
      events.add('upgrade_rolled_back');
      return reply('ok', false);
    }
    if (a == 'cancel') {
      cancelled = true;
      status = 'failed';
      events.add('upgrade_rolled_back');
      return reply();
    }
    return super.request(request, token, sudoPassword: sudoPassword);
  }

  @override
  Future<RunnerInstallation> install(
    RunnerInstallation p,
    CancellationToken t, {
    String? sudoPassword,
  }) => inspect(t);

  @override
  Future<RunnerInstallation> inspect(CancellationToken t) async =>
      RunnerInstallation.fromJson({
        'supported': true,
        'state': 'installed',
        'release': bundledRelease,
        'fingerprint': 'b' * 64,
        'active': true,
        'upgradable': false,
      });
}

/// A runner with a journal: a job is persisted before it is submitted.
class JournalRunner extends RunnerController {
  JournalRunner(ComponentRemote remote)
    : super(
        serverId: 'one',
        transport: () => remote,
        identity: () => 'identity-one',
        password: () => null,
        accessFailure: (_) {},
        store: MemoryRunnerJournal(),
      );
  @override
  Future<void> requestAction(
    Future<void> Function() action, {
    bool ownProgress = false,
  }) async => action();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ComponentRemote remote;
  late x.UpgradeCore core;
  late JournalRunner runner;
  late VpnController vpn;

  Future<void> setup() async {
    final store = f.MemoryVpn();
    remote = ComponentRemote(store);
    core = x.UpgradeCore(remote);
    runner = JournalRunner(remote);
    // The journal loads once (and resets what it holds); then the panel.
    await runner.componentVersionPlans(['panel']);
    remote.calls.clear();
    runner.panelAccess = PanelAccess.fromJson({
      'id': f.panel,
      'port': 2053,
      'username': 'fixture',
      'managed': false,
      'password': 'fixture-only-password-for-test',
      'host': '127.0.0.1',
      'panelVersion': '3.8.0',
      'xrayVersion': '26.7.28',
    });
    vpn = VpnController(
      repository: store,
      remote: (id) => VpnRemote(
        transport: remote,
        panelId: f.panel,
        identity: 'identity-$id',
      ),
      template: () => f.template,
      connectionProbe: ConnectionProbeEngine(
        core: core,
        network: n.Net(),
        controls: [
          for (var i = 1; i <= 10; i++)
            IpControl('c$i', 'p$i', IpProbeTarget('192.0.2.$i', 443)),
        ],
      ),
      timer: (d, cb) => Timer(Duration.zero, () {}),
    );
    vpn.connections.setForeground(false);
    await vpn.load();
    await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
    for (final digit in ['1', '2']) {
      await vpn.saveInbound(f.inbound('one', digit * 32));
    }
    await vpn.prepare();
    await vpn.apply();
    runner.deviceChecks = (token, changed) => DeviceUpgradeChecks(
      runner: runner,
      vpn: vpn,
      host: '192.0.2.1',
      token: token,
      changed: changed,
    );
    addTearDown(() {
      vpn.dispose();
      runner.dispose();
    });
  }

  const candidate = {'component': 'panel', 'version': '3.11.0'};

  test('a 3x-ui upgrade keeps the new version only after the same checks '
      'from the same network', () async {
    await setup();
    await runner.installComponentVersion(candidate);
    expect(runner.upgradeCheckPhase, 'committed');
    final check = remote.submitted!['deviceCheck'] as Map;
    expect(check['panelId'], f.panel);
    expect((check['leases'] as List).length, 2);
    expect((check['baseline'] as List).every((r) => r['tcp'] == true), isTrue);
    final committed = remote.committed!;
    expect(
      sha256.convert(utf8.encode(committed['key'] as String)).toString(),
      check['keyHash'],
    );
    expect(committed['network'], check['network']);
    expect(
      (committed['checks'] as List).map((r) => r['lease']).toList(),
      check['leases'],
    );
    expect(remote.aborted, isFalse);
    expect(remote.calls.where((a) => a == 'probe_end').length, 2);
    expect(runner.upgradeChecks.every((r) => r.after != null), isTrue);
    expect(vpn.upgradeBusy, isFalse);
  });

  test('worse results after the switch roll back and check again', () async {
    await setup();
    core.failUdp = true;
    await runner.installComponentVersion(candidate);
    expect(remote.calls, isNot(contains('component_upgrade_commit')));
    expect(remote.aborted, isTrue);
    expect(runner.upgradeCheckPhase, 'rolled_back');
    expect(runner.upgradeCheckCode, 'connection_failed');
    expect(runner.upgradeChecks.every((r) => r.restored != null), isTrue);
    expect(remote.calls.where((a) => a == 'probe_end').length, 2);
  });

  test('a refused commit rolls back too', () async {
    await setup();
    remote.commitRefusal = 'upgrade_checks_changed';
    await runner.installComponentVersion(candidate);
    expect(remote.aborted, isTrue);
    expect(runner.upgradeCheckPhase, 'rolled_back');
    expect(runner.upgradeCheckCode, 'upgrade_checks_changed');
  });

  test('a failed baseline submits nothing', () async {
    await setup();
    core.failBaseline = true;
    await runner.installComponentVersion(candidate);
    expect(remote.submitted, isNull);
    expect(runner.upgradeCheckPhase, 'failed');
    expect(remote.calls.where((a) => a == 'probe_end').length, 1);
  });

  test('without the device side nothing is submitted', () async {
    await setup();
    runner.deviceChecks = null;
    await runner.installComponentVersion(candidate);
    expect(remote.submitted, isNull);
    expect(runner.upgradeCheckCode, 'upgrade_checks_unavailable');
  });

  for (final locale in ['en', 'ru']) {
    for (final width in [390.0, 700.0, 1000.0, 1400.0]) {
      testWidgets('the checks card fits $width with large text, $locale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = JournalRunner(ComponentRemote(f.MemoryVpn()))
          ..activeComponent = 'panel'
          ..upgradeCheckPhase = 'rolled_back'
          ..upgradeCheckCode = 'upgrade_checks_failed';
        c.upgradeChecks.add(UpgradeComparison(1, 'NL', true));
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            theme: AppTheme.create(Brightness.dark),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ComponentUpgradeChecksView(controller: c),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final l = AppLocalizations.of(tester.element(find.byType(Scaffold)));
        expect(tester.takeException(), isNull);
        expect(find.textContaining(l.upgradeChecksRolledBack), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('upgrade-checks-details')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('NL'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      });
    }
  }
}
