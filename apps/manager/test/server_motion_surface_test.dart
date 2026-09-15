import 'dart:io';
import 'dart:ui' as ui;
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'ssh_support.dart' as ssh;

void main() {
  for (final width in [390.0, 1200.0]) {
    testWidgets('server surfaces and nested Back at $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ssh.controller(ssh.FakeVault(), ssh.FakeConnector());
      final draft = TextEditingController();
      addTearDown(draft.dispose);
      await tester.runAsync(() async {
        await ssh.prepare(c);
        c.serverName.text = 'Нидерланды';
        await c.save();
      });
      final screenshots = Platform.environment['ANTIRKN_UI_EVIDENCE'];
      if (screenshots != null) {
        await tester.runAsync(() async {
          for (final font in [
            ('Roboto', '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf'),
            (
              'MaterialIcons',
              '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ),
          ]) {
            final loader = FontLoader(font.$1)
              ..addFont(
                File(
                  font.$2,
                ).readAsBytes().then((b) => ByteData.sublistView(b)),
              );
            await loader.load();
          }
        });
      }
      final base = ColorScheme.fromSeed(
        seedColor: const Color(0xffa85b65),
        brightness: Brightness.dark,
      );
      final legacy = base.copyWith(
        surfaceContainerLowest: base.surface,
        surfaceContainerLow: base.surface,
        surfaceContainer: base.surface,
        surfaceContainerHigh: base.surface,
        surfaceContainerHighest: base.surface,
      );
      final baseTheme = AppTheme.create(Brightness.dark, dynamicScheme: legacy);
      // Widget tests substitute Ahem for unspecified fonts. Use the loaded
      // typeface explicitly in component styles for readable visual evidence.
      final theme = screenshots == null
          ? baseTheme
          : baseTheme.copyWith(
              textTheme: baseTheme.textTheme.apply(fontFamily: 'Roboto'),
              filledButtonTheme: FilledButtonThemeData(
                style: baseTheme.filledButtonTheme.style!.copyWith(
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
      final boundary = GlobalKey();
      var rootBack = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: theme,
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: ServerDetailView(
                session: c,
                motion: MotionPreference.system,
                onBack: () => rootBack++,
                clientCount: 12,
                sections: [
                  ServerProtocolSection(
                    name: 'VLESS',
                    count: 3,
                    mark: 'V',
                    detected: true,
                    child: TextField(
                      key: const ValueKey('protocol-draft'),
                      controller: draft,
                    ),
                  ),
                  const ServerProtocolSection(
                    name: 'AmneziaWG',
                    count: 1,
                    mark: 'W',
                    detected: true,
                    child: Text('interface'),
                  ),
                  const ServerProtocolSection(
                    name: 'TrustTunnel',
                    count: 0,
                    mark: 'T',
                    child: Text('endpoint'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (screenshots != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(screenshots).create(recursive: true);
          await File(
            '$screenshots/motion-surfaces-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('VLESS'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('protocol-draft')),
        'draft',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(rootBack, 0);
      expect(find.byKey(const ValueKey('protocol-draft')), findsNothing);
      await tester.tap(find.text('VLESS'));
      await tester.pumpAndSettle();
      expect(find.text('draft'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      c.network.dispose();
    });
  }
}
