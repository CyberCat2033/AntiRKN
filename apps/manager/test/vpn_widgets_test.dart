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
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('vpn-user-name')))
              .controller!
              .text,
          'client',
        );
        await tester.enterText(
          find.byKey(const ValueKey('vpn-user-login')),
          'client2',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('vpn-user-name')))
              .controller!
              .text,
          'client2',
        );
        await tester.enterText(
          find.byKey(const ValueKey('vpn-user-name')),
          'Клиент / Client',
        );
        await tester.enterText(
          find.byKey(const ValueKey('vpn-user-login')),
          'client',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('vpn-user-name')))
              .controller!
              .text,
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
        String? scannedTarget, scannedSni;
        await tester.pumpWidget(
          shell(
            InboundForm(
              scanReality: (target, sni) async {
                scannedTarget = target;
                scannedSni = sni;
                return {
                  'feasible': true,
                  'tls13': true,
                  'h2': true,
                  'x25519': true,
                  'certValid': true,
                  'host': sni,
                  'tlsVersion': '1.3',
                  'alpn': 'h2',
                  'curveID': 'X25519',
                  'latencyMs': 17,
                  'serverNames': ['www.example.com'],
                };
              },
              serverId: 'fixture',
              network: network,
              motion: MotionPreference.off,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('vpn-inbound-name')), findsOneWidget);
        expect(tester.takeException(), isNull);
        final targetField = find.byKey(const ValueKey('vpn-inbound-target'));
        final sniField = find.byKey(const ValueKey('vpn-inbound-sni'));
        await tester.ensureVisible(targetField);
        await tester.enterText(targetField, 'example.com');
        expect(
          tester.widget<TextField>(sniField).controller!.text,
          'example.com',
        );
        await tester.ensureVisible(sniField);
        await tester.enterText(sniField, 'custom.example.com');
        await tester.ensureVisible(targetField);
        await tester.enterText(targetField, 'other.example.com:443');
        expect(
          tester.widget<TextField>(sniField).controller!.text,
          'custom.example.com',
        );
        final scan = find.byKey(const ValueKey('vpn-reality-scan'));
        await tester.ensureVisible(scan);
        await tester.tap(scan);
        await tester.pumpAndSettle();
        expect(scannedTarget, 'other.example.com:443');
        expect(scannedSni, 'custom.example.com');
        final certificateName = find.widgetWithText(
          ActionChip,
          'www.example.com',
        );
        await tester.ensureVisible(certificateName);
        await tester.tap(certificateName);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(sniField).controller!.text,
          'www.example.com',
        );
        await tester.ensureVisible(
          find.byType(DropdownButtonFormField<String>).first,
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('XHTTP').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('security-reality')), findsOneWidget);
        expect(find.byKey(const ValueKey('vpn-inbound-utls')), findsOneWidget);
        final xmux = find.text('XMUX');
        await tester.ensureVisible(xmux);
        await tester.tap(xmux);
        await tester.pumpAndSettle();
        final connections = find.byKey(
          const ValueKey('xhttp-xmux-maxConnections'),
        );
        await tester.ensureVisible(connections);
        await tester.enterText(connections, '2-3');
        expect(tester.takeException(), isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
