import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

void main() {
  late MemoryRunnerJournal store;
  late FakeRunnerTransport remote;
  late RunnerController c;
  setUp(() async {
    store = MemoryRunnerJournal();
    remote = FakeRunnerTransport(store)..installed = true;
    c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture',
      password: () => null,
      accessFailure: (_) {},
      store: store,
    );
    await c.refresh();
    c.panelAccess = PanelAccess.fromJson({
      'id': 'a' * 32,
      'port': 2053,
      'username': 'antirkn',
      'password': 'A' * 43,
      'panelVersion': '3.7.0',
      'xrayVersion': '26.7.28',
    });
  });
  tearDown(() => c.dispose());
  test('preview and dismissal do not submit an update', () async {
    await c.preparePanelUpdate();
    expect(c.panelUpdatePlan!.canApply, isTrue);
    expect(remote.submissions, 0);
    c.dismissPanelUpdate();
    await c.applyPanelUpdate();
    expect(remote.submissions, 0);
  });
  for (final state in ['current', 'incompatible', 'stale']) {
    test('$state blocks an update', () async {
      if (state != 'stale') remote.panelUpdateState = state;
      await c.preparePanelUpdate();
      if (state == 'stale') remote.panelFingerprint = 'e' * 64;
      await c.applyPanelUpdate();
      expect(remote.submissions, 0);
    });
  }
  test('uncertain update persists and resumes with the same ID', () async {
    await c.preparePanelUpdate();
    remote.loseSubmitResponse = true;
    await c.applyPanelUpdate();
    expect(remote.submitWithoutPersistence, isFalse);
    final id = c.pending!.id;
    c.dispose();
    c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture',
      password: () => null,
      accessFailure: (_) {},
      store: store,
    );
    await c.restoreLocal();
    expect(c.pending!.id, id);
    remote.loseSubmitResponse = false;
    await c.retryPending();
    expect(c.selected!.kind, 'panel_update');
    expect(c.selected!.id, id);
    expect(remote.submissions, 1);
  });
  test('rejected stored credentials request login again', () async {
    remote.panelVerifyCode = 'panel_auth_failed';
    await c.verifyPanel();
    expect(c.panelLoginRequired, isTrue);
    expect(c.panelVerifiedAt, isNull);
    remote.panelVerifyCode = 'ok';
    await c.verifyPanel();
    expect(c.panelLoginRequired, isFalse);
  });
  for (final lang in ['ru', 'en']) {
    testWidgets('pair update preview on narrow screen $lang text x2', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(lang),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              key: const PageStorageKey('network-workbench'),
              children: [
                const SizedBox(height: 300),
                RunnerPanel(controller: c, motion: MotionPreference.off),
                const SizedBox(height: 1000),
              ],
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -250));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('panel-update')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('panel-update')));
      await tester.pumpAndSettle();
      expect(find.text('3x-ui 3.7.0 → 3.8.0'), findsOneWidget);
      expect(find.text('Xray 26.7.28 → 26.7.28'), findsOneWidget);
      expect(find.byKey(const ValueKey('panel-access')), findsNothing);
      expect(remote.submissions, 0);
      await tester.ensureVisible(
        find.byKey(const ValueKey('panel-update-apply')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('panel-update-apply')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('panel-update-apply')));
      await tester.pumpAndSettle();
      expect(remote.submissions, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
