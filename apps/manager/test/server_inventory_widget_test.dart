import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/ssh/server_inventory_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ServerSoftwareInventory fixture() => ServerSoftwareInventory(
  observedAt: DateTime.utc(2026, 9, 13),
  facts: {
    ServerFact.kernel: const InventoryValue.ok('6.8.0-99-generic'),
    ServerFact.uid: const InventoryValue.ok('1000'),
    ServerFact.memoryKiB: const InventoryValue.ok('2097152'),
    ServerFact.freeDiskKiB: const InventoryValue.failure(
      InventoryStatus.timeout,
    ),
    ServerFact.tools: const InventoryValue.ok('apt-get, systemctl, sudo'),
  },
  components: [
    ComponentObservation(
      component: VpnComponent.panel,
      presence: ComponentPresence.detected,
      installations: const [
        ComponentInstallation(
          source: InstallationSource.systemd,
          identity: 'x-ui.service',
          state: ServiceState.stopped,
        ),
        ComponentInstallation(
          source: InstallationSource.binary,
          identity: '/usr/local/x-ui/x-ui',
          version: InventoryValue.ok('3.7.0'),
        ),
      ],
      issues: [],
    ),
    ComponentObservation(
      component: VpnComponent.xray,
      presence: ComponentPresence.absent,
      installations: [],
      issues: [],
    ),
    ComponentObservation(
      component: VpnComponent.trustTunnel,
      presence: ComponentPresence.unknown,
      installations: [],
      issues: [InventoryStatus.denied],
    ),
    ComponentObservation(
      component: VpnComponent.amneziaWg,
      presence: ComponentPresence.detected,
      installations: const [
        ComponentInstallation(
          source: InstallationSource.docker,
          identity:
              'ghcr.io/example/amneziawg:long-image-tag-to-check-wrapping · abcdef123456',
          state: ServiceState.running,
        ),
      ],
      issues: [],
    ),
  ],
  sockets: [
    for (final family in IpFamily.values)
      SocketInventory(
        protocol: SocketProtocol.tcp,
        family: family,
        result: InventoryValue.ok([
          ServerSocketObservation(
            protocol: SocketProtocol.tcp,
            family: family,
            address: family == IpFamily.ipv4
                ? '0.0.0.0'
                : 'fe80::1234:1234:1234:1234%ethernet0',
            port: 443,
          ),
        ]),
      ),
    const SocketInventory(
      protocol: SocketProtocol.udp,
      family: IpFamily.ipv4,
      result: InventoryValue.failure(InventoryStatus.failed),
    ),
  ],
);

void main() {
  for (final language in ['ru', 'en']) {
    for (final width in [390.0, 1400.0]) {
      testWidgets(
        'software details ports errors and stale state $language $width text x2',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1000);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(language),
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
                  child: ServerInventoryPanel(
                    inventory: fixture(),
                    current: false,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final l = AppLocalizations.of(
            tester.element(find.byType(ServerInventoryPanel)),
          );
          expect(find.text(l.inventoryStale), findsOneWidget);
          expect(find.text(l.inventoryUnknown), findsOneWidget);
          expect(find.text(l.inventoryAbsent), findsOneWidget);
          for (final name in ['panel', 'trustTunnel', 'amneziaWg']) {
            final tile = find.byKey(PageStorageKey('component-$name'));
            await tester.ensureVisible(tile);
            await tester.pumpAndSettle();
            await tester.tap(
              find.descendant(of: tile, matching: find.byType(ListTile)).first,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          expect(find.text(l.inventoryVersion('3.7.0')), findsOneWidget);
          expect(find.text(l.inventoryStopped), findsOneWidget);
          expect(find.textContaining(l.inventoryDenied), findsOneWidget);
          final ports = find.byKey(const PageStorageKey('inventory-ports'));
          await tester.ensureVisible(ports);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(of: ports, matching: find.byType(ListTile)).first,
          );
          await tester.pumpAndSettle();
          expect(find.text('0.0.0.0:443'), findsOneWidget);
          expect(
            find.textContaining('fe80::1234:1234:1234:1234%ethernet0'),
            findsOneWidget,
          );
          expect(find.text(l.inventoryFailed), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
