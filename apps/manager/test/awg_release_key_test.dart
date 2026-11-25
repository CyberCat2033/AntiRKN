import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/component_installation_view.dart';
import 'package:antirkn_manager/runner/component_updates_controller.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'component_updates_test.dart' show Source;
import 'runner_support.dart';

void main() {
  group('AmneziaWG release keys', () {
    test('Docker and binary programs map to their own release', () {
      const awg = VpnComponent.amneziaWg;
      expect(releaseKey(awg, '/usr/bin/awg'), 'amneziawgTools');
      expect(releaseKey(awg, '/usr/local/bin/amneziawg-go'), 'amneziawg');
      expect(
        releaseKey(awg, 'amneziavpn/amneziawg-go · 0123456789ab · awg'),
        'amneziawgTools',
      );
      expect(
        releaseKey(awg, 'example/awg-tools · 0123456789ab · amneziawg-go'),
        'amneziawg',
      );
      expect(
        installationReleaseKey(
          awg,
          const ComponentInstallation(
            source: InstallationSource.kernel,
            identity: 'amneziawg',
          ),
        ),
        isNull,
      );
    });

    for (final locale in ['en', 'ru']) {
      testWidgets('Docker AmneziaWG offers no update $locale', (tester) async {
        final store = MemoryRunnerJournal();
        final remote = FakeRunnerTransport(store)..installed = true;
        final c = RunnerController(
          serverId: 'fixture',
          transport: () => remote,
          identity: () => 'fixture',
          password: () => null,
          accessFailure: (_) {},
          store: store,
          software: () => ServerSoftwareInventory(
            observedAt: DateTime.now(),
            facts: {},
            sockets: [],
            components: [
              ComponentObservation(
                component: VpnComponent.amneziaWg,
                presence: ComponentPresence.detected,
                issues: [],
                installations: [
                  ComponentInstallation(
                    source: InstallationSource.docker,
                    identity: 'amneziavpn/amnezia-wg · 0123456789ab',
                    state: ServiceState.running,
                  ),
                  ComponentInstallation(
                    source: InstallationSource.docker,
                    identity: 'amneziavpn/amnezia-wg · 0123456789ab · awg',
                    state: ServiceState.running,
                    version: InventoryValue.ok('3.1.20260101'),
                  ),
                  ComponentInstallation(
                    source: InstallationSource.docker,
                    identity:
                        'amneziavpn/amnezia-wg · 0123456789ab · amneziawg-go',
                    state: ServiceState.running,
                    version: InventoryValue.ok('3.1.20260101'),
                  ),
                ],
              ),
            ],
          ),
        );
        await c.refresh();
        final updates = ComponentUpdatesController(source: Source())
          ..latest = {
            'amneziawg': '3.1.20260828',
            'amneziawgTools': '3.1.20260812',
          };
        await tester.pumpWidget(
          ComponentUpdatesScope(
            controller: updates,
            child: MaterialApp(
              locale: Locale(locale),
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
          ),
        );
        await tester.pumpAndSettle();
        final l = lookupAppLocalizations(Locale(locale));
        expect(find.byKey(const ValueKey('component-amneziawg')), findsNothing);
        expect(
          find.byKey(const ValueKey('component-versions-amneziawg')),
          findsNothing,
        );
        expect(find.text(l.softwareAwgDockerUpdate), findsOneWidget);
        // Both programs keep their own versions.
        expect(
          find.textContaining('amneziawg-tools 3.1.20260101'),
          findsWidgets,
        );
        expect(find.textContaining('AmneziaWG Go 3.1.20260101'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        updates.dispose();
      });
    }
  });
}
