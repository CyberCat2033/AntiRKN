import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/component_updates_controller.dart';
import 'package:antirkn_manager/runner/component_versions_view.dart';
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
  bool choosable = true;
  Map<String, Object?>? latest;
  Map? begun;

  /// The server rolled back on its own after the restart (e.g. 3x-ui API).
  String? serverFailure;
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
        'choosable': choosable,
        'latest': latest,
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
      begun = jsonDecode(r['payload'] as String) as Map;
      phase = serverFailure == null ? 'awaiting_checks' : 'rolled_back';
      value = {
        'id': id,
        'phase': phase,
        'nonce': 'nonce',
        'manifest': 'manifest',
        'code': serverFailure ?? phase,
      };
    } else if (a == 'xray_check_abort') {
      phase = 'rolled_back';
      value = {'id': id, 'phase': phase, 'code': 'restored'};
    } else if (a == 'xray_check_commit') {
      phase = 'committed';
      if (loseCommit) throw const SshFailure(SshIssue.disconnected);
      value = {'id': id, 'phase': phase, 'code': phase};
    } else if (a == 'xray_check_status' || a == 'xray_check_latest') {
      value = {
        'id': operationId ?? id,
        'phase': phase,
        'code': serverFailure ?? phase,
      };
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
  Future<void> requestAction(
    Future<void> Function() action, {
    bool ownProgress = false,
  }) async => action();

  /// The runner is installed and the panel signed in, as for a user who
  /// reaches the software page.
  bool signedIn = false;
  @override
  Future<bool> ensureReady() async => signedIn || await super.ensureReady();
}

class VersionsRunner extends ReadyRunner {
  VersionsRunner(super.remote);
  final generic = <Map<String, Object?>>[];
  @override
  Future<Map<String, Map<String, dynamic>>> componentVersionPlans(
    List<String> components,
  ) async => {
    for (final c in components) c: {'arch': 'x86_64'},
  };
  @override
  Future<void> installComponentVersion(Map<String, Object?> candidate) async =>
      generic.add(candidate);
}

class XraySource implements ComponentReleaseSource {
  final resolved = <String>[];
  @override
  Future<Map<String, String>> check() async => {'xray': '26.11.9'};
  @override
  Future<List<ComponentRelease>> releases(String component) async => [
    const ComponentRelease('26.11.9'),
  ];
  @override
  Future<Map<String, Object?>?> resolveInstallerRelease({
    required String component,
    required String version,
  }) async => null;
  @override
  Future<Map<String, Object?>?> resolveAsset({
    required String component,
    required String version,
    String? architecture,
  }) async {
    resolved.add(version);
    return asset(version);
  }
}

Map<String, Object?> asset(String version, {String sha = ''}) => {
  'component': 'xray',
  'version': version,
  'architecture': 'x86_64',
  'assetName': 'Xray-linux-64.zip',
  'url': XrayUpgradeController.officialUrl(version),
  'bytes': 1,
  'sha256': sha.isEmpty ? 'a' * 64 : sha,
};

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
    String directInterface = '',
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
  test(
    'terminal operation clears error and phase on inspect when update is available',
    () async {
      await setup();
      remote.phase = 'rolled_back';
      remote.available = true;
      remote.candidateVersion = '26.11.9';
      await upgrade.inspect();
      expect(upgrade.phase, 'idle');
      expect(upgrade.code, isEmpty);
    },
  );
  group('UI-45 explicit Xray version', () {
    test('only the official amd64 archive with a SHA-256 is a candidate', () {
      expect(XrayUpgradeController.releaseCandidate(asset('26.5.1')), {
        'version': '26.5.1',
        'url':
            'https://github.com/XTLS/Xray-core/releases/download/v26.5.1/Xray-linux-64.zip',
        'sha256': 'a' * 64,
      });
      for (final bad in [
        null,
        {...asset('26.5.1'), 'sha256': ''},
        {...asset('26.5.1'), 'sha256': 'sha256:${'a' * 64}'},
        {...asset('26.5.1'), 'sha256': 'A' * 64},
        {...asset('26.5.1'), 'url': XrayUpgradeController.officialUrl('26.5')},
        {
          ...asset('26.5.1'),
          'url':
              'https://github.com/XTLS/Xray-core/releases/download/v26.5.1/Xray-linux-arm64-v8a.zip',
        },
        {...asset('26.5.1-rc1')},
      ]) {
        expect(XrayUpgradeController.releaseCandidate(bad), isNull);
      }
    });
    test(
      'an older version below the pinned target runs the full check',
      () async {
        await setup();
        remote.currentVersion = '27.0.0';
        remote.supported = false;
        remote.available = false;
        await upgrade.install(asset('26.5.1'));
        expect(upgrade.phase, 'committed');
        expect(remote.begun?['candidate'], {
          'version': '26.5.1',
          'url': XrayUpgradeController.officialUrl('26.5.1'),
          'sha256': 'a' * 64,
        });
        expect(remote.calls.where((a) => a == 'probe_begin').length, 2);
        expect(remote.calls, contains('xray_check_commit'));
        expect(upgrade.chosen, isNull);
      },
    );
    test('the pinned flow sends no candidate', () async {
      await setup();
      await upgrade.run();
      expect(upgrade.phase, 'committed');
      expect(remote.begun!.containsKey('candidate'), isFalse);
    });
    test('an automatic update never moves a newer core back', () async {
      await setup();
      // Someone installed a newer core after the update was offered.
      remote.currentVersion = '26.12.1';
      await upgrade.install(asset('26.12.0'), upgradeOnly: true);
      expect(upgrade.phase, 'not_changed');
      expect(remote.calls, isNot(contains('xray_check_begin')));
      // The pinned flow is forward-only as well.
      remote.candidateVersion = '26.9.9';
      await upgrade.run();
      expect(upgrade.phase, 'not_changed');
      expect(remote.calls, isNot(contains('xray_check_begin')));
    });
    test('a version chosen in the sheet may still be older', () async {
      await setup();
      await upgrade.install(asset('26.5.1'));
      expect(upgrade.phase, 'committed');
      expect((remote.begun!['candidate'] as Map)['version'], '26.5.1');
    });
    test('an unsupported panel is not relaxed for a chosen version', () async {
      await setup();
      remote.choosable = false;
      await upgrade.install(asset('26.5.1'));
      expect(upgrade.code, 'xray_check_layout');
      expect(remote.calls, isNot(contains('probe_begin')));
      expect(remote.calls, isNot(contains('xray_check_begin')));
    });
    test('the running version is not changed', () async {
      await setup();
      await upgrade.install(asset('26.7.28'));
      expect(upgrade.phase, 'not_changed');
      expect(remote.calls, isNot(contains('xray_check_begin')));
    });
    test('a release without a digest never reaches the server', () async {
      await setup();
      await upgrade.install({...asset('26.5.1'), 'sha256': ''});
      expect(upgrade.code, 'xray_release_missing');
      expect(remote.calls, isEmpty);
    });
    test('the server reason is shown when 3x-ui stops answering', () async {
      await setup();
      remote.serverFailure = 'xray_check_panel_api';
      await upgrade.install(asset('26.5.1'));
      expect(upgrade.phase, 'rolled_back');
      expect(upgrade.code, 'xray_check_panel_api');
      expect(remote.calls, isNot(contains('xray_check_commit')));
    });
    test('the previous version is the one before the last commit', () async {
      await setup();
      remote.latest = {
        'id': 'f' * 32,
        'phase': 'committed',
        'current': '26.7.1',
        'candidate': '26.7.28',
        'code': 'committed',
      };
      await upgrade.inspect();
      expect(upgrade.previousVersion, '26.7.1');
      remote.latest = {...remote.latest!, 'phase': 'rolled_back'};
      await upgrade.inspect();
      expect(upgrade.previousVersion, isNull);
    });
    test('the generic component path refuses Xray', () async {
      await setup();
      expect(
        () => runner.installComponentVersion(asset('26.11.9')),
        throwsArgumentError,
      );
    });

    Future<void> dialog(
      WidgetTester tester,
      VersionsRunner versions,
      XraySource source, {
      String row = '26.11.9',
    }) async {
      final updates = ComponentUpdatesController(source: source);
      addTearDown(updates.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showComponentVersions(
                  context,
                  controller: versions,
                  updates: updates,
                  title: '3x-ui / Xray',
                  installed: const {'xray': '26.7.28'},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('component-version-xray-$row')),
          matching: find.byType(OutlinedButton),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('choosing an Xray version starts the checked transaction', (
      tester,
    ) async {
      final versions = VersionsRunner(UpgradeRemote(f.MemoryVpn()));
      final installs = <Map<String, Object?>>[];
      versions.xrayVersionChoice = XrayVersionChoice(
        install: (a) async => installs.add(a),
        update: (_) async {},
        ready: () => true,
        previous: () => '26.7.1',
      );
      final source = XraySource();
      await dialog(tester, versions, source);
      expect(
        find.byKey(const ValueKey('component-version-xray-restore')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('component-version-confirm')));
      await tester.pumpAndSettle();
      expect(source.resolved, ['26.11.9']);
      expect(installs.single['version'], '26.11.9');
      expect(versions.generic, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      versions.dispose();
    });

    testWidgets('restoring the previous Xray downloads it again', (
      tester,
    ) async {
      final versions = VersionsRunner(UpgradeRemote(f.MemoryVpn()));
      final installs = <Map<String, Object?>>[];
      versions.xrayVersionChoice = XrayVersionChoice(
        install: (a) async => installs.add(a),
        update: (_) async {},
        ready: () => true,
        previous: () => '26.7.1',
      );
      final source = XraySource();
      await dialog(tester, versions, source, row: 'restore');
      await tester.tap(find.byKey(const ValueKey('component-version-confirm')));
      await tester.pumpAndSettle();
      expect(source.resolved, ['26.7.1']);
      expect(installs.single['version'], '26.7.1');
      expect(versions.generic, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      versions.dispose();
    });

    testWidgets('without the checked transaction Xray is not changed', (
      tester,
    ) async {
      final versions = VersionsRunner(UpgradeRemote(f.MemoryVpn()));
      final source = XraySource();
      await dialog(tester, versions, source);
      expect(
        find.byKey(const ValueKey('component-version-xray-unavailable')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('component-version-confirm')),
        findsNothing,
      );
      expect(source.resolved, isEmpty);
      expect(versions.generic, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      versions.dispose();
    });
  });
  testWidgets('Update installs the shown release, not the pinned one', (
    tester,
  ) async {
    await tester.runAsync(setup);
    // The runner pins 26.9.9; the row shows the newest release.
    remote.candidateVersion = '26.9.9';
    runner.signedIn = true;
    final source = XraySource();
    final updates = ComponentUpdatesController(source: source);
    addTearDown(updates.dispose);
    await tester.pumpWidget(
      ComponentUpdatesScope(
        controller: updates,
        child: MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
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
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => runner.xrayVersionChoice!.update('26.11.9'));
    await tester.pumpAndSettle();
    expect(source.resolved, ['26.11.9']);
    expect((remote.begun!['candidate'] as Map)['version'], '26.11.9');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final locale in ['ru', 'en']) {
    testWidgets('no standalone block; a server-side upgrade fits a narrow '
        'screen with large text $locale', (tester) async {
      await tester.runAsync(setup);
      final access = runner.panelAccess;
      runner.panelAccess = null;
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget app(Key key) => MaterialApp(
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
              key: key,
              runner: runner,
              vpn: vpn,
              host: '192.0.2.1',
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(const ValueKey('idle')));
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(tester.element(find.byType(Scaffold)));
      // Idle: the update starts from the 3x-ui / Xray software row.
      expect(find.text(l.xrayUpgradeTitle), findsNothing);
      expect(runner.xrayVersionChoice, isNotNull);
      // The server still recovers a previous upgrade: its status is shown.
      runner.panelAccess = access;
      remote.phase = 'recovery_pending';
      await tester.pumpWidget(app(const ValueKey('recovering')));
      // The indeterminate bar never settles.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Inline like a component install: the step and one bar, no card.
      expect(find.textContaining(l.xrayUpgradePending), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('xray-upgrade-close')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
