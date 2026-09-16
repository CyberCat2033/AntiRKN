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
        'panel action chooses port and submits once $locale $width text x2',
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
          expect(find.text(l.runnerApply), findsNothing);
          expect(remote.installs, greaterThanOrEqualTo(1));
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
