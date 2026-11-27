import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/component_installation_view.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

void main() {
  group('component step labels and progress text', () {
    testWidgets('formats progress text correctly in ru and en', (tester) async {
      late AppLocalizations ru, en;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) {
              ru = AppLocalizations.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) {
              en = AppLocalizations.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // Checkpoint 0: Plan verified / preparation
      expect(componentActiveStepLabel(ru, 0), ru.protocolPrepared);
      expect(componentActiveStepLabel(en, 0), en.protocolPrepared);

      // Checkpoint 1: Downloading
      expect(componentActiveStepLabel(ru, 1), ru.componentsDownloading);
      expect(componentActiveStepLabel(en, 1), en.componentsDownloading);

      // Checkpoint 2: Building executables
      expect(componentActiveStepLabel(ru, 2), ru.componentsBuilding);
      expect(componentActiveStepLabel(en, 2), en.componentsBuilding);

      // Checkpoint 3: Extracting
      expect(componentActiveStepLabel(ru, 3), ru.componentsExtracting);
      expect(componentActiveStepLabel(en, 3), en.componentsExtracting);

      // Checkpoint 4: Version switched
      expect(componentActiveStepLabel(ru, 4), ru.protocolSwitched);
      expect(componentActiveStepLabel(en, 4), en.protocolSwitched);

      // Checkpoint 5: Checking API / health
      expect(componentActiveStepLabel(ru, 5), ru.componentsChecking);
      expect(componentActiveStepLabel(en, 5), en.componentsChecking);
    });
  });

  group('ComponentInstallationView', () {
    testWidgets('renders active progress, indicator, and cancel button', (
      tester,
    ) async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store);
      final c = RunnerController(
        serverId: 'srv1',
        transport: () => remote,
        identity: () => 'fixture|key',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
      await c.prepareInstall();
      await c.applyInstall();

      c.selected = runnerJob(
        'a' * 32,
        kind: 'component_install',
        status: 'running',
        progress: 2,
        count: 6,
        events: [
          {
            'sequence': 1,
            'timestamp': 1789340000,
            'code': 'component_downloaded',
            'progress': 2,
            'total': 6,
          },
        ],
      );
      c.activeComponent = 'trusttunnel';

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: ComponentInstallationView(controller: c)),
        ),
      );

      final l = AppLocalizations.of(
        tester.element(find.byType(ComponentInstallationView)),
      );

      // Drawn like the Xray transaction: the step in words and a ring.
      expect(find.text(l.componentsBuilding), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      final progressFinder = find.byType(CircularProgressIndicator);
      expect(progressFinder, findsOneWidget);
      final progressWidget = tester.widget<CircularProgressIndicator>(
        progressFinder,
      );
      expect(progressWidget.value, closeTo(2 / 6, 0.001));

      final cancelBtn = find.byKey(const ValueKey('component-cancel'));
      expect(cancelBtn, findsOneWidget);

      await tester.tap(cancelBtn);
      await tester.pump();
      expect(remote.cancellations, 1);

      c.dispose();
    });

    testWidgets('displays cancelRequested when cancel is pending', (
      tester,
    ) async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store);
      final c = RunnerController(
        serverId: 'srv1',
        transport: () => remote,
        identity: () => 'fixture|key',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );

      c.selected = RunnerJob.fromJson({
        'id': 'a' * 32,
        'kind': 'component_install',
        'status': 'running',
        'checkpoint': 2,
        'count': 6,
        'interval': 1,
        'sequence': 1,
        'cancelRequested': true,
        'events': [
          {
            'sequence': 1,
            'timestamp': 1789340000,
            'code': 'component_downloaded',
            'progress': 2,
            'total': 6,
          },
        ],
      });

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: ComponentInstallationView(controller: c)),
        ),
      );

      final l = AppLocalizations.of(
        tester.element(find.byType(ComponentInstallationView)),
      );
      expect(find.text(l.runnerCancelRequested), findsOneWidget);

      final cancelBtn = tester.widget<TextButton>(
        find.byKey(const ValueKey('component-cancel')),
      );
      expect(cancelBtn.onPressed, isNull);

      c.dispose();
    });

    testWidgets('displays partial warning and retry button when failed', (
      tester,
    ) async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store);
      final c = RunnerController(
        serverId: 'srv1',
        transport: () => remote,
        identity: () => 'fixture|key',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );

      c.selected = RunnerJob.fromJson({
        'id': 'a' * 32,
        'kind': 'component_install',
        'status': 'partially_applied',
        'checkpoint': 2,
        'count': 6,
        'interval': 1,
        'sequence': 1,
        'cancelRequested': false,
        'events': [
          {
            'sequence': 1,
            'timestamp': 1789340000,
            'code': 'component_download_failed',
            'progress': 2,
            'total': 6,
          },
        ],
      });

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(body: ComponentInstallationView(controller: c)),
        ),
      );

      final l = AppLocalizations.of(
        tester.element(find.byType(ComponentInstallationView)),
      );
      expect(find.text(l.componentsPartial), findsOneWidget);
      expect(find.byKey(const ValueKey('component-retry')), findsOneWidget);

      c.dispose();
    });
  });

  group('RunnerPanel with active component_install', () {
    testWidgets(
      'shows banner step progress and mini progress on component card',
      (tester) async {
        final store = MemoryRunnerJournal();
        final remote = FakeRunnerTransport(store);
        final c = RunnerController(
          serverId: 'srv1',
          transport: () => remote,
          identity: () => 'fixture|key',
          password: () => null,
          accessFailure: (_) {},
          store: store,
        );

        c.selected = runnerJob(
          'a' * 32,
          kind: 'component_install',
          status: 'running',
          progress: 2,
          count: 6,
          events: [
            {
              'sequence': 1,
              'timestamp': 1789340000,
              'code': 'component_downloaded',
              'progress': 2,
              'total': 6,
            },
          ],
        );
        c.activeComponent = 'trusttunnel';

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ru'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
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

        // The card shows the active step in words, like the Xray
        // transaction, without a step counter:
        expect(find.text('Сборка исполняемых файлов на сервере'), findsWidgets);
        expect(find.text('2/6'), findsNothing);
        expect(find.textContaining('Шаг 3 из 6'), findsNothing);

        c.dispose();
      },
    );
  });

  group('apt job card and reboot', () {
    Future<RunnerController> pump(WidgetTester tester, RunnerJob job) async {
      final store = MemoryRunnerJournal();
      final c = RunnerController(
        serverId: 'srv1',
        transport: () => FakeRunnerTransport(store),
        identity: () => 'fixture|key',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
      c.selected = job;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: RunnerPanel(
                controller: c,
                motion: MotionPreference.system,
                reboot: const Text('reboot-action'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return c;
    }

    testWidgets('a running apt job is one card with its step and cancel', (
      tester,
    ) async {
      final c = await pump(
        tester,
        runnerJob(
          'b' * 32,
          kind: 'apt_update',
          status: 'running',
          progress: 0,
          count: 2,
        ),
      );
      expect(find.byType(AppProgressCard), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
      expect(find.byKey(const ValueKey('runner-cancel')), findsOneWidget);
      expect(find.text('reboot-action'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('a finished job that needs a reboot offers it', (tester) async {
      final c = await pump(
        tester,
        runnerJob(
          'c' * 32,
          kind: 'apt_upgrade',
          status: 'succeeded',
          progress: 2,
          count: 2,
          events: [
            {
              'sequence': 1,
              'timestamp': 1789340000,
              'code': 'apt_reboot_required',
              'progress': 2,
              'total': 2,
            },
          ],
        ),
      );
      expect(find.text('reboot-action'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump(const Duration(minutes: 1));
    });
  });
}
