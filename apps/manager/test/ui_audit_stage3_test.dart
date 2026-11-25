// Regressions for UI audit stage 3: one indicator per process, one button
// per action, one place per piece of information.
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/runner/component_installation_view.dart';
import 'package:antirkn_manager/runner/component_updates_controller.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:antirkn_manager/ssh/ssh_panel.dart';
import 'package:antirkn_manager/vpn/awg_existing_panel.dart';
import 'package:antirkn_manager/vpn/awg_panel.dart';
import 'package:antirkn_manager/vpn/connection_check_view.dart';
import 'package:antirkn_manager/vpn/vpn_plan_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'component_updates_test.dart' as updates;
import 'network_support.dart';
import 'runner_support.dart';
import 'ssh_support.dart' as ssh;
import 'vpn_controller_test.dart' as f;

Widget _app(Widget child, {ComponentUpdatesController? updates}) {
  final body = SingleChildScrollView(child: child);
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      body: updates == null
          ? body
          : ComponentUpdatesScope(controller: updates, child: body),
    ),
  );
}

/// Controllers keep timers; release them before the binding checks for
/// pending timers, which runs ahead of addTearDown.
Future<void> _release(WidgetTester tester, List<ChangeNotifier> xs) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (final x in xs) {
    x.dispose();
  }
  await tester.pump();
}

RunnerController _runner() {
  final store = MemoryRunnerJournal();
  return RunnerController(
    serverId: 'srv1',
    transport: () => FakeRunnerTransport(store),
    identity: () => 'fixture|key',
    password: () => null,
    accessFailure: (_) {},
    store: store,
  );
}

Map<String, Object?> _job(String status) => {
  'id': '2' * 32,
  'kind': 'vless_apply',
  'status': status,
  'count': 3,
  'interval': 1,
  'checkpoint': 1,
  'sequence': 1,
  'cancelRequested': false,
  'events': <Object?>[],
};

void main() {
  group('UI-39 component install', () {
    for (final host in ['trusttunnel', null]) {
      testWidgets('one bar, one step text and one cancel (card: $host)', (
        tester,
      ) async {
        final c = _runner();
        c.selected = runnerJob(
          'a' * 32,
          kind: 'component_install',
          progress: 2,
          count: 6,
        );
        c.activeComponent = host;
        await tester.pumpWidget(
          _app(RunnerPanel(controller: c, motion: MotionPreference.system)),
        );
        final l = AppLocalizations.of(tester.element(find.byType(RunnerPanel)));
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.byKey(const ValueKey('component-cancel')), findsOneWidget);
        expect(find.byKey(const ValueKey('runner-cancel')), findsNothing);
        expect(find.text(componentStepProgressText(l, 2, 6)), findsOneWidget);
        if (host != null) {
          // The card keeps a compact step count, without a bar of its own.
          expect(find.text('2/6'), findsOneWidget);
        }
        await _release(tester, [c]);
      });
    }
  });

  testWidgets('UI-41 an action with its own progress adds no runner bar', (
    tester,
  ) async {
    final c = _runner();
    await tester.pumpWidget(
      _app(RunnerPanel(controller: c, motion: MotionPreference.system)),
    );
    c
      ..actionPending = true
      ..actionShowsOwnProgress = true
      ..notifyListeners();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    c
      ..actionShowsOwnProgress = false
      ..notifyListeners();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await _release(tester, [c]);
  });

  testWidgets('UI-45 one update check, without the runner', (tester) async {
    final source = updates.Source();
    final u = ComponentUpdatesController(source: source);
    addTearDown(u.dispose);
    final c = _runner();
    await tester.pumpWidget(
      _app(
        RunnerPanel(controller: c, motion: MotionPreference.system),
        updates: u,
      ),
    );
    final l = AppLocalizations.of(tester.element(find.byType(RunnerPanel)));
    // No per-card "Check" next to the page's button.
    expect(find.text(l.uiCheck), findsNothing);
    expect(find.byKey(const ValueKey('updates-check')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('updates-check')));
    await tester.pump();
    expect(source.calls, 1);
    expect(c.actionPending, isFalse);
    await _release(tester, [c]);
  });

  test('UI-46 the counter and the cards share one update rule', () async {
    final u = ComponentUpdatesController(source: updates.Source());
    addTearDown(u.dispose);
    await u.check();
    final latest = u.latest.entries.first;
    // "v1.8" and "1.8" are one version: not an update.
    expect(availableUpdates(u, {latest.key: 'v${latest.value}'}), isEmpty);
    expect(availableUpdates(u, {latest.key: '0.0.1'}), {
      latest.key: latest.value,
    });
  });

  testWidgets('UI-43 a failed job names its event once; distinct labels', (
    tester,
  ) async {
    final c = _runner();
    c.selected = runnerJob(
      'b' * 32,
      kind: 'protocol_remove',
      status: 'failed',
      events: [
        {
          'sequence': 2,
          'timestamp': 1789340000,
          'code': 'panel_download_failed',
          'progress': 1,
          'total': 10,
        },
      ],
    );
    await tester.pumpWidget(
      _app(RunnerPanel(controller: c, motion: MotionPreference.system)),
    );
    final l = AppLocalizations.of(tester.element(find.byType(RunnerPanel)));
    expect(
      find.text(runnerEventLabel(l, 'panel_download_failed')),
      findsOneWidget,
    );
    expect(l.runnerReconnect, isNot(l.runnerRetry));
    expect(l.runnerResend, isNot(l.runnerRetry));
    await _release(tester, [c]);
  });

  group('UI-40 protocol tab', () {
    for (final running in [true, false]) {
      testWidgets('one bar while busy (job running: $running)', (tester) async {
        final vpn = f.controller(f.MemoryVpn(), {});
        await tester.runAsync(vpn.load);
        vpn.workspace = vpn.workspace.copy(
          servers: {
            'one': {'job': _job(running ? 'running' : 'succeeded')},
          },
        );
        vpn.upgradeBusy = true;
        await tester.pumpWidget(
          _app(
            ListenableBuilder(
              listenable: vpn,
              builder: (_, _) => Column(
                children: [
                  VpnJobView(controller: vpn, serverId: 'one'),
                  VpnPlanView(
                    controller: vpn,
                    serverName: (id) => id,
                    jobServerId: 'one',
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        await _release(tester, [vpn]);
      });
    }
  });

  testWidgets('UI-49 the AmneziaWG section has one check-all and refresh', (
    tester,
  ) async {
    final vpn = f.controller(f.MemoryVpn(), {});
    await tester.runAsync(vpn.load);
    final r = _runner();
    r.awgDiscovery = {
      'resources': [
        {'id': 'awg0', 'name': 'awg0', 'peers': 1, 'active': true},
      ],
    };
    final network = NetworkController(
      reader: TestInventoryReader(() async => testInventory()),
    );
    addTearDown(network.dispose);
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            AwgPanel(
              controller: vpn,
              runner: r,
              serverId: 'one',
              network: network,
              motion: MotionPreference.system,
            ),
            AwgExistingPanel(
              controller: vpn,
              runner: r,
              serverId: 'one',
              serverHost: 'vpn.example',
              motion: MotionPreference.system,
            ),
          ],
        ),
      ),
    );
    final l = AppLocalizations.of(tester.element(find.byType(AwgPanel)));
    expect(find.text('awg0'), findsOneWidget);
    expect(find.byType(ConnectionCheckAll), findsOneWidget);
    expect(find.byTooltip(l.awgRefresh), findsOneWidget);
    expect(find.text(l.awgRefresh), findsNothing);
    await _release(tester, [vpn, r]);
  });

  testWidgets('UI-42 a vault write during a connection shows one bar', (
    tester,
  ) async {
    final c = ssh.controller(ssh.FakeVault(), ssh.FakeConnector());
    await tester.runAsync(() => ssh.prepare(c));
    c
      ..stage = SshStage.connecting
      ..vaultBusy = true;
    await tester.pumpWidget(_app(SshPanel(controller: c)));
    expect(c.unlocked && c.busy && c.vaultSaving, isTrue);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    c.stage = SshStage.idle;
    await _release(tester, [c]);
  });

  testWidgets('UI-50 the only section of a page has no second title', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const AppSettingsSection(child: Text('body'))),
    );
    expect(find.byType(Text), findsOneWidget);
  });
}
