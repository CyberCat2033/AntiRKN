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
        'component preview and explicit apply $locale $width text x2',
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
                  child: RunnerPanel(
                    controller: c,
                    motion: MotionPreference.system,
                  ),
                ),
              ),
            ),
          );
          final prepare = find.byKey(const ValueKey('component-trusttunnel'));
          await tester.ensureVisible(prepare);
          await tester.tap(prepare);
          await tester.pumpAndSettle();
          expect(c.componentPlan, isNotNull);
          expect(remote.installs, 0);
          expect(remote.submissions, 0);
          final apply = find.byKey(const ValueKey('component-apply'));
          await tester.ensureVisible(apply);
          await tester.pumpAndSettle();
          await tester.tap(apply);
          await tester.pumpAndSettle();
          expect(remote.installs, 1);
          expect(remote.submissions, 1);
          expect(remote.submitWithoutPersistence, isFalse);
          expect(c.selected!.kind, 'component_install');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
        },
      );
    }
  }
}
