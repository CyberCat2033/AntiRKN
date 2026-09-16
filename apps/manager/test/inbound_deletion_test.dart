import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/catalog_selection.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bulk removal persists only selected tombstones and preserves clients; stale consent fails',
    () async {
      final store = f.MemoryVpn();
      final remote = f.Remote(store);
      final c = f.controller(store, {'one': remote});
      addTearDown(c.dispose);
      await f.setup(c);
      final selected = c.workspace.inbounds
          .where((r) => r.serverId == 'one')
          .toList();
      await c.saveInbound(
        VlessInbound(
          serverId: 'one',
          spec: {...selected.first.spec, 'name': 'changed'},
        ),
      );
      await c.deleteInbounds(selected);
      expect(c.error, isNotNull);
      expect(c.workspace.inbounds.any((r) => r.deleted), false);
      final current = c.workspace.inbounds
          .where((r) => r.serverId == 'one')
          .toList();
      await c.deleteInbounds(current);
      expect(c.error, isNull);
      expect(c.workspace.inbounds.where((r) => r.deleted).length, 2);
      expect(
        c.workspace.inbounds
            .where((r) => r.serverId == 'two')
            .every((r) => !r.deleted),
        true,
      );
      expect(c.workspace.users.every((u) => !u.deleted), true);
      await c.prepareAndApply(serverIds: {'one'});
      expect(c.error, isNull);
      expect(
        (remote.submissions.values.single['resources'] as List).every(
          (r) => r['deleted'] == true,
        ),
        true,
      );
      final restored = VpnWorkspace.decode(store.raw!);
      expect(restored.inbounds.where((r) => r.deleted), hasLength(2));
    },
  );

  for (final locale in ['ru', 'en']) {
    testWidgets('inbound selection and cancelled bulk confirmation: $locale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = f.controller(f.MemoryVpn(), {}), selection = CatalogSelection();
      final network = NetworkController(reader: const SampleInventoryReader());
      addTearDown(c.dispose);
      addTearDown(selection.dispose);
      addTearDown(network.dispose);
      await tester.runAsync(() => f.setup(c));
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: SingleChildScrollView(
              child: InboundsPanel(
                controller: c,
                selection: selection,
                serverId: 'one',
                serverName: (id) => id,
                network: network,
                motion: MotionPreference.off,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('inbound-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inbound-select-all')));
      await tester.pumpAndSettle();
      expect(selection.ids.length, 2);
      await tester.tap(find.byKey(const ValueKey('inbound-delete-selected')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('inbound-confirm-delete')),
        findsOneWidget,
      );
      await tester.tap(
        find
            .widgetWithText(TextButton, locale == 'ru' ? 'Отмена' : 'Cancel')
            .last,
      );
      await tester.pumpAndSettle();
      expect(c.workspace.inbounds.any((r) => r.deleted), false);
      expect(tester.takeException(), isNull);
    });
  }
}
