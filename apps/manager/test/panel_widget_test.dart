import 'package:antirkn_design_system/antirkn_design_system.dart';
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
        'panel chooses port automatically and requires explicit apply $locale $width text x2',
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
          final l = AppLocalizations.of(
            tester.element(find.byType(RunnerPanel)),
          );
          expect(find.text(l.runnerHelp), findsNothing);
          final choose = find.byKey(const ValueKey('components-choose'));
          await tester.ensureVisible(choose);
          await tester.tap(choose);
          await tester.pumpAndSettle();
          expect(remote.installs, 0);
          expect(remote.installs, 0);
          expect(remote.submissions, 0);
          expect(find.byKey(const ValueKey('components-port')), findsNothing);
          expect(find.text(l.componentsPlanSummary), findsOneWidget);
          expect(find.text(l.panelAutomaticAddress), findsOneWidget);
          expect(c.panelPlan!.port, 43127);
          expect(find.text(l.componentsPlanBody), findsNothing);
          expect(find.text('d' * 64), findsNothing);
          final details = find.text(l.componentsDetails);
          await tester.ensureVisible(details);
          await tester.pumpAndSettle();
          await tester.tap(details);
          await tester.pumpAndSettle();
          expect(find.text(l.componentsPlanBody), findsOneWidget);
          expect(find.text('d' * 64), findsOneWidget);
          expect(remote.installs, 0);
          expect(remote.submissions, 0);
          await tester.ensureVisible(details);
          await tester.pumpAndSettle();
          await tester.tap(details);
          await tester.pumpAndSettle();
          final apply = find.byKey(const ValueKey('components-apply'));
          await tester.ensureVisible(apply);
          await tester.pumpAndSettle();
          await tester.tap(apply);
          await tester.pumpAndSettle();
          expect(remote.installs, 1);
          expect(remote.submissions, 1);
          expect(c.selected!.kind, 'panel_install');
          expect(find.byKey(const ValueKey('runner-start')), findsNothing);
          expect(find.byKey(const ValueKey('components-choose')), findsNothing);
          expect(find.text(l.componentsPlanBody), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
        },
      );
    }
  }
}
