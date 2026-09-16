import 'dart:io';
import 'dart:ui' as ui;
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [390.0, 1200.0]) {
    testWidgets('inbound choices preserve manual IP and draft at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final network = NetworkController(reader: const SampleInventoryReader());
      addTearDown(network.dispose);
      final evidence = Platform.environment['ANTIRKN_UI_EVIDENCE'];
      if (evidence != null) {
        await tester.runAsync(() async {
          for (final font in [
            ('Roboto', '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf'),
            (
              'MaterialIcons',
              '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ),
          ]) {
            await (FontLoader(font.$1)..addFont(
                  File(font.$2).readAsBytes().then(ByteData.sublistView),
                ))
                .load();
          }
        });
      }
      final boundary = GlobalKey();
      Future<void> capture(String name) async {
        if (evidence == null) return;
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(evidence).create(recursive: true);
          await File(
            '$evidence/inbound-$name-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      final baseTheme = AppTheme.create(Brightness.dark);
      final theme = evidence == null
          ? baseTheme
          : baseTheme.copyWith(
              textTheme: baseTheme.textTheme.apply(fontFamily: 'Roboto'),
              inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
                labelStyle: baseTheme.inputDecorationTheme.labelStyle?.copyWith(
                  fontFamily: 'Roboto',
                ),
              ),
              filledButtonTheme: FilledButtonThemeData(
                style: baseTheme.filledButtonTheme.style!.copyWith(
                  textStyle: WidgetStatePropertyAll(
                    baseTheme.textTheme.labelLarge!.copyWith(
                      fontFamily: 'Roboto',
                    ),
                  ),
                ),
              ),
              textButtonTheme: TextButtonThemeData(
                style: baseTheme.textButtonTheme.style!.copyWith(
                  textStyle: WidgetStatePropertyAll(
                    baseTheme.textTheme.labelLarge!.copyWith(
                      fontFamily: 'Roboto',
                    ),
                  ),
                ),
              ),
              outlinedButtonTheme: OutlinedButtonThemeData(
                style: baseTheme.outlinedButtonTheme.style!.copyWith(
                  textStyle: WidgetStatePropertyAll(
                    baseTheme.textTheme.labelLarge!.copyWith(
                      fontFamily: 'Roboto',
                    ),
                  ),
                ),
              ),
              listTileTheme: baseTheme.listTileTheme.copyWith(
                titleTextStyle: baseTheme.listTileTheme.titleTextStyle!
                    .copyWith(fontFamily: 'Roboto'),
                subtitleTextStyle: baseTheme.listTileTheme.subtitleTextStyle!
                    .copyWith(fontFamily: 'Roboto'),
              ),
            );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              RepaintBoundary(key: boundary, child: child!),
          home: Scaffold(
            body: InboundForm(
              serverId: 'fixture',
              network: network,
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('vpn-inbound-name'));
      final listen = find.byKey(const ValueKey('vpn-inbound-listen'));
      await tester.enterText(name, 'Personal connection');
      await tester.enterText(listen, '2001:db8::99');
      // Inventory arriving after the form opens must not replace manual input.
      await tester.runAsync(network.load);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(listen).controller!.text, '2001:db8::99');
      expect(find.text('Clear selection'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('transport-raw')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await capture('transport');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('transport-raw')), findsOneWidget);
      expect(tester.widget<TextField>(listen).controller!.text, '2001:db8::99');
      await tester.tap(find.byKey(const ValueKey('transport-raw')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('XHTTP').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('security-reality')), findsOneWidget);
      expect(
        tester.widget<TextField>(name).controller!.text,
        'Personal connection',
      );
      expect(tester.widget<TextField>(listen).controller!.text, '2001:db8::99');
      await capture('form');
      await tester.tap(find.byKey(const ValueKey('pick-listener')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('address-options-listener')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(listen).controller!.text, '2001:db8::99');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
