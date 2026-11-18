import 'dart:io';
import 'dart:ui' as ui;
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'ssh_support.dart' as ssh;
import 'vpn_controller_test.dart' as f;

void main() {
  for (final width in [390.0, 1000.0]) {
    testWidgets('server hierarchy, completed status and layout at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = ssh.controller(ssh.FakeVault(), ssh.FakeConnector());
      final vpn = f.controller(f.MemoryVpn(), {});
      addTearDown(vpn.dispose);
      final spec = {
        ...VlessInbound.defaults(),
        'id': '1' * 32,
        'name': 'Main node',
        'endpoint': 'vpn.example',
        'target': 'example.com:443',
        'sni': 'example.com',
      };
      await tester.runAsync(() async {
        await ssh.prepare(c);
        c.serverName.text = 'TEST';
        await c.save();
        await vpn.load();
        await vpn.saveInbound(VlessInbound(serverId: 'one', spec: spec));
        vpn.workspace = vpn.workspace.copy(
          servers: {
            'one': {
              'verifiedAt': '2026-09-15T00:00:00Z',
              'job': {
                'id': '2' * 32,
                'kind': 'vless_apply',
                'status': 'succeeded',
                'count': 3,
                'interval': 1,
                'checkpoint': 3,
                'sequence': 1,
                'cancelRequested': false,
                'events': <Object?>[],
              },
            },
          },
        );
      });
      final screenshot = Platform.environment['ANTIRKN_UI_EVIDENCE'];
      if (screenshot != null) {
        await tester.runAsync(() async {
          final loader = FontLoader('Roboto')
            ..addFont(
              File(
                '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf',
              ).readAsBytes().then((b) => ByteData.sublistView(b)),
            );
          await loader.load();
          final icons = FontLoader('MaterialIcons')
            ..addFont(
              File(
                '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then((b) => ByteData.sublistView(b)),
            );
          await icons.load();
        });
      }
      final boundary = GlobalKey();
      Widget app(double scale) => MaterialApp(
        locale: Locale(width < 600 ? 'ru' : 'en'),
        theme: AppTheme.create(Brightness.dark),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            appBar: AppBar(title: const Text('AntiRKN')),
            body: ServerDetailView(
              session: c,
              motion: MotionPreference.off,
              onBack: () {},
              protocols: InboundsPanel(
                controller: vpn,
                serverId: 'one',
                serverName: (id) => id,
                network: c.network,
                motion: MotionPreference.off,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(1));
      await tester.pumpAndSettle();
      expect(find.text('Completed'), findsNothing);
      expect(find.text('3 / 3'), findsNothing);
      expect(find.text('SNI: example.com'), findsNothing);
      expect(find.text('Main node'), findsOneWidget);
      // Connect and SSH access share one row across the card (since the
      // SSH access action moved next to Connect).
      final connect = tester.getRect(find.byKey(const ValueKey('ssh-connect')));
      final access = tester.getRect(
        find.byKey(const ValueKey('server-ssh-access')),
      );
      final row = tester.getRect(find.byType(AppActionRow).first);
      expect(connect.left, closeTo(row.left, 1));
      expect(access.right, closeTo(row.right, 1));
      expect(row.width, greaterThan(width * 0.5));
      expect(connect.right, lessThan(access.left));
      expect(connect.center.dy, closeTo(access.center.dy, 1));
      if (screenshot != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(screenshot).create(recursive: true);
          await File(
            '$screenshot/server-${width.toInt()}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      // Managed inbound tiles carry no details (since 90b9d28): the REALITY
      // target stays in the editor, not on the summary.
      expect(
        find.byKey(ValueKey('resource-details-${'1' * 32}')),
        findsNothing,
      );
      expect(find.textContaining('example.com:443'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(app(2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('ssh-connect')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      c.network.dispose();
    });
  }
}
