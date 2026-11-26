import 'package:antirkn_design_system/antirkn_design_system.dart';
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

  group('a resource card opens like its edit button', () {
    Future<List<String>> pumpTile(
      WidgetTester tester, {
      bool enabled = true,
      bool selecting = false,
    }) async {
      final taps = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ResourceTile(
              storageId: 'tile',
              title: 'VLESS',
              subtitle: 'XHTTP · REALITY',
              badge: 'Enabled',
              switchValue: true,
              note: 'Note',
              selecting: selecting,
              onTap: enabled ? () => taps.add('card') : null,
              tapHint: 'Edit',
              onBadgeTap: () => taps.add('switch'),
              actions: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('enabled-action'),
                    tooltip: 'Clients',
                    onPressed: () => taps.add('action'),
                    icon: const Icon(Icons.people_outline),
                  ),
                  const IconButton(
                    key: ValueKey('disabled-action'),
                    tooltip: 'Relay',
                    onPressed: null,
                    icon: Icon(Icons.fork_right),
                  ),
                ],
              ),
              footer: const TextButton(
                key: ValueKey('disabled-footer'),
                onPressed: null,
                child: Text('Check connection'),
              ),
            ),
          ),
        ),
      );
      return taps;
    }

    testWidgets('the body opens; controls keep their own taps', (tester) async {
      final taps = await pumpTile(tester);
      await tester.tap(find.text('VLESS'));
      await tester.tap(find.text('Note'));
      expect(taps, ['card', 'card']);
      taps.clear();
      await tester.tap(find.byKey(const ValueKey('resource-switch-tile')));
      await tester.tap(find.byKey(const ValueKey('enabled-action')));
      expect(taps, ['switch', 'action']);
      taps.clear();
      // A disabled control has no tap; it must not fall through.
      await tester.tap(find.byKey(const ValueKey('disabled-action')));
      await tester.tap(find.byKey(const ValueKey('disabled-footer')));
      expect(taps, isEmpty);
    });

    testWidgets('no tap when the edit is unavailable', (tester) async {
      final taps = await pumpTile(tester, enabled: false);
      await tester.tap(find.text('VLESS'));
      await tester.tap(find.byKey(const ValueKey('resource-switch-tile')));
      expect(taps, ['switch']);
    });

    testWidgets('the card action is announced with its hint', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTile(tester);
      expect(
        tester.getSemantics(find.byType(InkWell).first),
        matchesSemantics(
          hasTapAction: true,
          onTapHint: 'Edit',
          hasFocusAction: true,
          isFocusable: true,
          label: 'VLESS\nXHTTP · REALITY\nNote\nEnabled',
        ),
      );
      handle.dispose();
    });
  });

  for (final locale in ['ru', 'en']) {
    testWidgets('a VLESS card opens its editor; the switch does not: $locale', (
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
      final l = AppLocalizations.of(tester.element(find.byType(InboundsPanel)));
      final [r, other] = c.workspace.inbounds
          .where((r) => r.serverId == 'one')
          .toList();
      final card = find.byKey(ValueKey('inbound-summary-${r.id}'));
      // Client access is the default state and is no longer captioned.
      expect(
        find.descendant(of: card, matching: find.text(l.vpnClientAccess)),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.text(r.spec['name'] as String),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InboundForm), findsOneWidget);
      Navigator.of(tester.element(find.byType(InboundForm))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(InboundForm), findsNothing);

      // The switch is ignored while the inbound is saving, but its tap
      // still must not reach the card.
      await tester.tap(find.byKey(ValueKey('resource-switch-${r.id}')));
      await tester.pump();
      expect(find.byType(InboundForm), findsNothing);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InboundForm), findsNothing);

      // In selection mode the card toggles instead of opening.
      selection
        ..start()
        ..toggle(r.id);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('inbound-summary-${other.id}')),
          matching: find.text(other.spec['name'] as String),
        ),
        // The body absorbs pointers; the card itself takes the tap.
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byType(InboundForm), findsNothing);
      expect(selection.ids, {r.id, other.id});
      expect(tester.takeException(), isNull);
    });
  }
}
