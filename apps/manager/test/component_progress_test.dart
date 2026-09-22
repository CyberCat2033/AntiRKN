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
      expect(componentStepProgressText(ru, 0, 6), 'Шаг 1 из 6: План проверен');
      expect(
        componentStepProgressText(en, 0, 6),
        'Step 1 of 6: Plan verified',
      );

      // Checkpoint 1: Downloading
      expect(componentActiveStepLabel(ru, 1), ru.componentsDownloading);
      expect(componentActiveStepLabel(en, 1), en.componentsDownloading);
      expect(componentStepProgressText(ru, 1, 6), 'Шаг 2 из 6: Загрузка архива');
      expect(
        componentStepProgressText(en, 1, 6),
        'Step 2 of 6: Downloading archive',
      );

      // Checkpoint 2: Building executables
      expect(componentActiveStepLabel(ru, 2), ru.componentsBuilding);
      expect(componentActiveStepLabel(en, 2), en.componentsBuilding);
      expect(
        componentStepProgressText(ru, 2, 6),
        'Шаг 3 из 6: Сборка исполняемых файлов на сервере',
      );
      expect(
        componentStepProgressText(en, 2, 6),
        'Step 3 of 6: Building executables on server',
      );

      // Checkpoint 3: Extracting
      expect(componentActiveStepLabel(ru, 3), ru.componentsExtracting);
      expect(componentActiveStepLabel(en, 3), en.componentsExtracting);
      expect(
        componentStepProgressText(ru, 3, 6),
        'Шаг 4 из 6: Распаковка и проверка файлов',
      );
      expect(
        componentStepProgressText(en, 3, 6),
        'Step 4 of 6: Extracting and verifying files',
      );

      // Checkpoint 4: Version switched
      expect(componentActiveStepLabel(ru, 4), ru.protocolSwitched);
      expect(componentActiveStepLabel(en, 4), en.protocolSwitched);
      expect(
        componentStepProgressText(ru, 4, 6),
        'Шаг 5 из 6: Новая версия установлена',
      );
      expect(
        componentStepProgressText(en, 4, 6),
        'Step 5 of 6: New version installed',
      );

      // Checkpoint 5: Checking API / health
      expect(componentActiveStepLabel(ru, 5), ru.componentsChecking);
      expect(componentActiveStepLabel(en, 5), en.componentsChecking);
      expect(
        componentStepProgressText(ru, 5, 6),
        'Шаг 6 из 6: Проверка состояния и API',
      );
      expect(
        componentStepProgressText(en, 5, 6),
        'Step 6 of 6: Checking state and API',
      );
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

      expect(
        find.text(l.componentStepProgress(3, 6, l.componentsBuilding)),
        findsOneWidget,
      );
      final progressFinder = find.byType(LinearProgressIndicator);
      expect(progressFinder, findsOneWidget);
      final progressWidget = tester.widget<LinearProgressIndicator>(
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
    testWidgets('shows banner step progress and mini progress on component card', (
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

      // Top banner shows active step text instead of past event code:
      expect(
        find.text('Шаг 3 из 6: Сборка исполняемых файлов на сервере'),
        findsWidgets,
      );

      // Card action shows mini progress "2/6":
      expect(find.text('2/6'), findsOneWidget);

      c.dispose();
    });
  });
}
