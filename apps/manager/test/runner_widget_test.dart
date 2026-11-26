import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

void main() {
  for (final locale in ['ru', 'en']) {
    for (final width in [390.0, 1400.0]) {
      testWidgets(
        'automatic runner setup, progress and events $locale $width text x2',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1000);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final store = MemoryRunnerJournal();
          final remote = FakeRunnerTransport(store);
          final c = RunnerController(
            serverId: 'fixture',
            transport: () => remote,
            identity: () => 'fixture|key',
            password: () => null,
            accessFailure: (_) {},
            store: store,
          );
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(locale),
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
                  key: const PageStorageKey('network-workbench'),
                  child: RunnerPanel(
                    controller: c,
                    motion: MotionPreference.system,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('runner-prepare')), findsNothing);
          expect(find.byKey(const ValueKey('runner-start')), findsNothing);
          c.connectionReady();
          await tester.pumpAndSettle();
          expect(remote.installs, 1);
          expect(remote.submissions, 0);
          // An existing job still has progress, events and cancellation.
          await c.startDiagnostic();
          await tester.pumpAndSettle();
          expect(remote.submissions, 1);
          final cancel = find.byKey(const ValueKey('runner-cancel'));
          await tester.ensureVisible(cancel);
          await tester.pumpAndSettle();
          await tester.tap(cancel);
          await tester.pumpAndSettle();
          expect(remote.cancellations, 1);
          expect(c.selected!.terminal, isTrue);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
        },
      );
    }
  }

  testWidgets(
    'Reset job queue action is available during active jobs and failures',
    (tester) async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store)..installed = true;
      final c = RunnerController(
        serverId: 'fixture',
        transport: () => remote,
        identity: () => 'fixture|key',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
      await c.refresh();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: RunnerPanel(
                controller: c,
                motion: MotionPreference.system,
              ),
            ),
          ),
        ),
      );

      // 1. Running job: Reset job queue should be available
      c.selected = runnerJob(
        '1' * 32,
        kind: 'component_install',
        count: 6,
        status: 'running',
      );
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('runner-reset-queue')), findsOneWidget);

      // 2. Planned job: Reset job queue should be available
      c.selected = runnerJob(
        '2' * 32,
        kind: 'panel_update',
        count: 6,
        status: 'planned',
      );
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('runner-reset-queue')), findsOneWidget);

      // 3. cancelRequested: Reset job queue should be available
      final cancelJob = RunnerJob.fromJson({
        'id': '3' * 32,
        'kind': 'diagnostic',
        'status': 'running',
        'checkpoint': 1,
        'count': 10,
        'interval': 2,
        'sequence': 1,
        'cancelRequested': true,
        'events': [
          {
            'sequence': 1,
            'timestamp': 1789340000,
            'code': 'cancel_requested',
            'progress': 1,
            'total': 10,
          },
        ],
      });
      c.selected = cancelJob;
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('runner-reset-queue')), findsOneWidget);

      c.dispose();
    },
  );

  testWidgets('a closed failure stays closed after refresh and restart', (
    tester,
  ) async {
    final store = MemoryRunnerJournal();
    final remote = FakeRunnerTransport(store)
      ..installed = true
      ..job = runnerJob(
        '4' * 32,
        kind: 'apt_update',
        status: 'failed',
        events: [
          {
            'sequence': 2,
            'timestamp': 1789340000,
            'code': 'apt_failed',
            'progress': 1,
            'total': 10,
          },
        ],
      );
    RunnerController controller() => RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture|key',
      password: () => null,
      accessFailure: (_) {},
      store: store,
    );
    final c = controller();
    await c.refresh();
    expect(c.failedJob?.id, '4' * 32);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: RunnerPanel(controller: c, motion: MotionPreference.system),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    final result = find.byKey(const ValueKey('runner-job-result'));
    expect(result, findsOneWidget);
    expect(
      find.descendant(of: result, matching: find.text(l.runnerFailed)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: result, matching: find.text(l.aptFailed)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('runner-job-close')));
    await tester.pumpAndSettle();
    expect(result, findsNothing);
    expect(c.failedJob, isNull);

    await c.refresh();
    await tester.pumpAndSettle();
    expect(c.selected?.id, '4' * 32);
    expect(c.failedJob, isNull);
    expect(result, findsNothing);

    final restarted = controller();
    await restarted.refresh();
    expect(restarted.selected?.id, '4' * 32);
    expect(restarted.failedJob, isNull);

    // The same job resumed and failed again: its new events show again.
    remote.job = runnerJob(
      '4' * 32,
      kind: 'apt_update',
      status: 'failed',
      sequence: 5,
    );
    await c.refresh();
    await tester.pumpAndSettle();
    expect(c.failedJob?.id, '4' * 32);
    expect(result, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('runner-job-close')));
    await tester.pumpAndSettle();
    expect(result, findsNothing);

    // A newer job's failure is not hidden behind the closed one.
    remote.job = runnerJob('5' * 32, kind: 'apt_upgrade', status: 'failed');
    await c.refresh();
    await tester.pumpAndSettle();
    expect(c.failedJob?.id, '5' * 32);
    expect(result, findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    restarted.dispose();
  });
}
