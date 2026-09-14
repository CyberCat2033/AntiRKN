import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as fixtures;

class Export implements ProfileExporter {
  @override
  Future<bool> save(String n, String source) async => true;
}

void main() {
  for (final locale in ['ru', 'en']) {
    for (final width in [390.0, 1400.0]) {
      testWidgets('client and inbound forms $locale width $width text x2', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = fixtures.MemoryVpn();
        final c = fixtures.controller(store, {});
        addTearDown(c.dispose);
        await tester.runAsync(c.load);
        Widget shell(Widget child) => MaterialApp(
          locale: Locale(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.create(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(body: child),
        );
        await tester.pumpWidget(
          shell(
            UsersPage(
              controller: c,
              serverName: (s) => s,
              exporter: Export(),
              motion: MotionPreference.off,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('vpn-user-add')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('vpn-user-login')),
          'client',
        );
        await tester.enterText(
          find.byKey(const ValueKey('vpn-user-name')),
          'Клиент / Client',
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('vpn-user-save')));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(c.workspace.users.single.login, 'client');
        expect(tester.takeException(), isNull);
        final network = NetworkController(
          reader: const SampleInventoryReader(),
        );
        addTearDown(network.dispose);
        await tester.pumpWidget(
          shell(
            InboundForm(
              serverId: 'fixture',
              network: network,
              motion: MotionPreference.off,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('vpn-inbound-name')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('XHTTP').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('security-reality')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
