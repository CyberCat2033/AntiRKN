import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/xray_upgrade_controller.dart';
import 'package:antirkn_manager/runner/xray_upgrade_view.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'connection_checks_test.dart' as n;
import 'vpn_controller_test.dart' as f;

class UpgradeRemote extends f.Remote {
  UpgradeRemote(super.store);
  String phase = 'idle';
  int? missing;
  bool loseCommit = false;
  bool supported = true;
  bool available = true;
  String currentVersion = '26.7.28';
  String candidateVersion = '26.9.9';
  String? operationId;
  final calls = <String>[];
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    final r = request.json, a = r['action'] as String;
    if (!a.startsWith('xray_check_') && !a.startsWith('probe_')) {
      return super.request(request, token, sudoPassword: sudoPassword);
    }
    calls.add(a);
    token.check();
    final id = r['id'] as String;
    Map<String, Object?> value = {};
    if (a == 'xray_check_plan') {
      value = {
        'supported': supported,
        'available': available,
        'maxInbounds': 8,
        'current': currentVersion,
        'candidate': candidateVersion,
        'fingerprint': 'e' * 64,
        'inbounds': [
          for (var i = 0; i < state.length; i++)
            {
              'id': i + 1,
              'enabled': true,
              'protocol': 'vless',
              'name': 'AntiRKN:${state[i]['workspaceId']}:${state[i]['id']}',
            },
        ],
      };
      if (missing != null) {
        (value['inbounds'] as List).add({
          'id': 9,
          'enabled': true,
          'protocol': 'unknown',
          'name': 'unsupported',
        });
      }
    } else if (a == 'probe_begin') {
      final payload = jsonDecode(r['payload'] as String) as Map;
      final observed = state.firstWhere((s) => s['id'] == payload['resource']);
      return RunnerResponse.fromJson({
        ...response(),
        'connectionProbe': {
          'user': {
            'id': id,
            'login': 'probe',
            'name': 'Probe',
            'enabled': true,
          },
          'observation': {
            ...observed,
            'clients': [
              {
                ...Map<String, dynamic>.from(
                  (observed['clients'] as List).first as Map,
                ),
                'id': id,
              },
            ],
          },
        },
      });
    } else if (a == 'probe_end') {
      return RunnerResponse.fromJson({
        ...response(),
        'connectionProbe': {'closed': true, 'stable': true},
      });
    } else if (a == 'xray_check_begin') {
      operationId = id;
      phase = 'awaiting_checks';
      value = {
        'id': id,
        'phase': phase,
        'nonce': 'nonce',
        'manifest': 'manifest',
        'code': phase,
      };
    } else if (a == 'xray_check_abort') {
      phase = 'rolled_back';
      value = {'id': id, 'phase': phase, 'code': 'restored'};
    } else if (a == 'xray_check_commit') {
      phase = 'committed';
      if (loseCommit) throw const SshFailure(SshIssue.disconnected);
      value = {'id': id, 'phase': phase, 'code': phase};
    } else if (a == 'xray_check_status' || a == 'xray_check_latest') {
      value = {'id': operationId ?? id, 'phase': phase, 'code': phase};
    }
    return RunnerResponse.fromJson({...response(), 'xrayCheck': value});
  }
}

class ReadyRunner extends RunnerController {
  ReadyRunner(UpgradeRemote remote)
    : super(
        serverId: 'one',
        transport: () => remote,
        identity: () => 'identity-one',
        password: () => null,
        accessFailure: (_) {},
      );
  @override
  Future<void> requestAction(Future<void> Function() action) async => action();
}

class UpgradeCore implements CoreProbeTransport {
  UpgradeCore(this.remote);
  final UpgradeRemote remote;
  bool failUdp = false, failBaseline = false;
  CancellationToken? cancelAfter;
  @override
  Future<CoreTrafficCheck> probe(
    Map<String, Object?>? proxy,
    CancellationToken token, {
    required bool udp,
  }) async {
    cancelAfter?.cancel();
    final bad =
        proxy != null &&
        (failBaseline ||
            failUdp &&
                remote.phase == 'awaiting_checks' &&
                '${proxy['uuid']}'.endsWith('222222222222'));
    return CoreTrafficCheck(
      status: bad ? CoreTrafficStatus.failed : CoreTrafficStatus.success,
      code: bad ? 'connection_failed' : 'connected',
      tcp: true,
      udp: !bad,
      udpTested: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late f.MemoryVpn store;
  late UpgradeRemote remote;
  late UpgradeCore core;
  late ReadyRunner runner;
  late VpnController vpn;
  late XrayUpgradeController upgrade;
  Future<void> setup() async {
    store = f.MemoryVpn();
    remote = UpgradeRemote(store);
    core = UpgradeCore(remote);
    runner = ReadyRunner(remote);
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
    upgrade = XrayUpgradeController(
      runner: runner,
      vpn: vpn,
      host: '192.0.2.1',
    );
    addTearDown(() {
      upgrade.dispose();
      vpn.dispose();
      runner.dispose();
    });
  }

  test(
    'all exact outbound checks are required for commit; workspace unchanged',
    () async {
      await setup();
      final before = store.raw;
      await upgrade.run();
      expect(upgrade.phase, 'committed');
      expect(remote.calls.where((a) => a == 'probe_begin').length, 2);
      expect(remote.calls, contains('xray_check_commit'));
      expect(remote.calls, isNot(contains('xray_check_abort')));
      expect(
        upgrade.rows.every(
          (r) =>
              r.before?.traffic?.udp == true && r.after?.traffic?.udp == true,
        ),
        isTrue,
      );
      expect(store.raw, before);
      expect(vpn.upgradeBusy, isFalse);
    },
  );
  test(
    'one inbound losing only UDP aborts and rechecks restored traffic',
    () async {
      await setup();
      core.failUdp = true;
      await upgrade.run();
      expect(upgrade.phase, 'rolled_back');
      expect(remote.calls, contains('xray_check_abort'));
      expect(remote.calls, isNot(contains('xray_check_commit')));
      expect(upgrade.rows.last.after?.traffic?.tcp, isTrue);
      expect(upgrade.rows.last.after?.traffic?.udp, isFalse);
      expect(
        upgrade.rows.every(
          (r) => r.restored?.status == ConnectionCheckStatus.working,
        ),
        isTrue,
      );
    },
  );
  test('incomplete baseline never submits replacement', () async {
    await setup();
    core.failBaseline = true;
    await upgrade.run();
    expect(upgrade.phase, 'not_changed');
    expect(remote.calls, isNot(contains('xray_check_begin')));
  });
  test('unsupported enabled inbound cannot be skipped', () async {
    await setup();
    remote.missing = 9;
    await upgrade.run();
    expect(upgrade.code, 'xray_check_coverage');
    expect(remote.calls, isNot(contains('probe_begin')));
  });
  test(
    'lost commit reply reads durable committed state without abort',
    () async {
      await setup();
      remote.loseCommit = true;
      await upgrade.run();
      expect(upgrade.phase, 'committed');
      expect(remote.calls, contains('xray_check_status'));
      expect(remote.calls, isNot(contains('xray_check_abort')));
    },
  );
  test('already on candidate version does not throw layout error', () async {
    await setup();
    remote.currentVersion = '26.9.9';
    remote.candidateVersion = '26.9.9';
    remote.available = false;
    remote.supported = true;
    await upgrade.inspect();
    expect(upgrade.code, isNot('xray_check_layout'));
    await upgrade.run();
    expect(upgrade.code, isNot('xray_check_layout'));
    expect(upgrade.phase, 'not_changed');
  });
  test('unsupported layout throws layout error in inspect and run', () async {
    await setup();
    remote.supported = false;
    remote.available = false;
    await upgrade.inspect();
    expect(upgrade.code, 'xray_check_layout');
    await upgrade.run();
    expect(upgrade.code, 'xray_check_layout');
  });
  for (final locale in ['ru', 'en']) {
    testWidgets('upgrade controls fit narrow screen with large text $locale', (
      tester,
    ) async {
      await tester.runAsync(setup);
      runner.panelAccess = null;
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: XrayUpgradeView(
                runner: runner,
                vpn: vpn,
                host: '192.0.2.1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
