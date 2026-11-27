import 'dart:io';
import 'dart:ui' as ui;
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/server_address_picker.dart';
import 'package:antirkn_manager/ssh/server_about_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'network_support.dart';
import 'ssh_support.dart' as ssh;

void main() {
  Widget app(Widget child, {GlobalKey? boundary}) => MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    theme: AppTheme.create(Brightness.dark),
    builder: (context, child) => RepaintBoundary(key: boundary, child: child!),
    home: Scaffold(body: child),
  );

  testWidgets(
    'offline About displays cached IPs, traffic and disk under egress heading',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final info = ServerInfo(
        os: 'Ubuntu',
        architecture: 'x86_64',
        observedAt: DateTime.utc(2026, 9, 16),
        publicAddresses: [IpAddress.parse('93.184.215.15')],
        software: ServerSoftwareInventory(
          observedAt: DateTime.utc(2026, 9, 16),
          components: [],
          sockets: [],
          facts: const {
            ServerFact.freeDiskKiB: InventoryValue.ok('1048576'),
            ServerFact.totalDiskKiB: InventoryValue.ok('2097152'),
            ServerFact.networkTraffic: InventoryValue.ok(
              '11111111-1111-1111-1111-111111111111\neth0 1024 2048',
            ),
          },
        ),
      );
      final saved = ssh.FakeVault()
        ..mode = VaultMode.system
        ..saved = SshProfile(
          host: 'fixture.example',
          port: 22,
          username: 'root',
          authMethod: SshAuthMethod.password,
          secrets: const {ServerSecret.sshPassword: 'fixture-password'},
          lastInfo: info,
        );
      final offline = ssh.controller(saved, ssh.FakeConnector());
      await offline.initialise();
      await tester.pumpWidget(
        app(SingleChildScrollView(child: ServerAboutView(controller: offline))),
      );
      await tester.pumpAndSettle();
      final l = AppLocalizations.of(
        tester.element(find.byType(ServerAboutView)),
      );
      expect(find.text('93.184.215.15'), findsOneWidget);
      expect(find.text('1.0 KiB'), findsOneWidget);
      expect(find.text('2.0 KiB'), findsOneWidget);
      expect(find.text('1.0 GiB'), findsOneWidget);
      expect(find.text(l.egressTitle), findsNWidgets(2));
      expect(find.textContaining('Previous observation'), findsNothing);
      expect(find.textContaining('9/16/2026'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      offline.dispose();
      offline.network.dispose();
    },
  );

  testWidgets(
    'selected address paint stays below fixed sheet header while scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final choices = const AddressSelectionPolicy().choices(
        testInventory(),
        AddressRole.listener,
        now: DateTime.utc(2026),
      );
      final selected = choices.firstWhere(
        (c) => c.address.addressClass == AddressClass.external,
      );
      if (Platform.environment['ANTIRKN_UI_EVIDENCE'] != null) {
        await tester.runAsync(() async {
          for (final entry in {
            'Roboto': '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf',
            'MaterialIcons':
                '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          }.entries) {
            await (FontLoader(entry.key)..addFont(
                  File(
                    entry.value,
                  ).readAsBytes().then((b) => ByteData.sublistView(b)),
                ))
                .load();
          }
        });
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showServerAddressChoice(
                context,
                title: 'Service listening address',
                role: AddressRole.listener,
                choices: choices,
                selected: selected,
                motion: MotionPreference.off,
              ),
              child: const Text('Open'),
            ),
          ),
          boundary: boundary,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('address-options-listener'));
      final y = tester.getTopLeft(list).dy.floor() - 4;
      Future<List<int>> pixel() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final value = bytes.buffer.asUint8List().sublist(
          (y * image.width + 4) * 4,
          (y * image.width + 4) * 4 + 4,
        );
        image.dispose();
        return value;
      }

      final before = await tester.runAsync(pixel);
      final option = find.byKey(ValueKey('option-${selected.id}'));
      final rect = tester.getRect(option);
      final scroll = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      tester
          .state<ScrollableState>(scroll)
          .position
          .jumpTo(rect.center.dy - tester.getTopLeft(list).dy);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(pixel), before);
      expect(find.text('Service listening address'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final evidence = Platform.environment['ANTIRKN_UI_EVIDENCE'];
      if (evidence != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File(
            '$evidence/address-sheet-scroll.png',
          ).writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );
}
