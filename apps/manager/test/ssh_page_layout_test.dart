import 'dart:io';
import 'dart:ui' as ui;

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ssh_support.dart' as ssh;

/// The SSH access page of a new and of a connected server: compact state,
/// technical values on demand, the reconnect warning only when it applies.
/// With ANTIRKN_UI_EVIDENCE set to a folder, the pages are also saved as PNG.
void main() {
  final evidence = Platform.environment['ANTIRKN_UI_EVIDENCE'];

  Future<void> loadFonts(WidgetTester tester) async {
    if (evidence == null) return;
    await tester.runAsync(() async {
      final text = FontLoader('Roboto')
        ..addFont(
          File(
            '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf',
          ).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      await text.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      await icons.load();
    });
  }

  Future<void> shot(
    WidgetTester tester,
    GlobalKey boundary,
    String name,
  ) async {
    if (evidence == null) return;
    await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(evidence).create(recursive: true);
      await File(
        '$evidence/$name.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('the opened server card shows the connection stage', (
    tester,
  ) async {
    final c = ssh.controller(ssh.FakeVault(), ssh.FakeConnector());
    await tester.runAsync(() async {
      await c.initialise();
      c.serverName.text = 'NL';
      c.host.text = '203.0.113.10';
      c.username.text = 'admin';
      c.password.text = 'fixture-password-only';
      await c.connect();
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        theme: AppTheme.create(Brightness.dark),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ServerDetailView(
            session: c,
            motion: MotionPreference.off,
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    expect(find.text(l.sshConnected), findsOneWidget);
    // Not a bare "Connecting": what the connection is doing right now.
    for (final (stage, label) in [
      (SshStage.reading, l.sshReading),
      (SshStage.checkingPrivileges, l.privilegesChecking),
      (SshStage.connecting, l.sshConnecting),
      (SshStage.idle, l.uiOffline),
    ]) {
      c.stage = stage;
      c.notifyListeners();
      await tester.pump();
      expect(find.text(label), findsOneWidget, reason: '$stage');
    }
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  for (final width in [390.0, 1000.0]) {
    for (final connected in [false, true]) {
      final state = connected ? 'connected' : 'new';
      testWidgets('SSH access page, $state server, $width, text x2', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final vault = ssh.FakeVault();
        final connector = ssh.FakeConnector();
        final c = ssh.controller(vault, connector);
        await tester.runAsync(() async {
          await c.initialise();
          if (connected) {
            c.serverName.text = 'NL';
            c.host.text = '203.0.113.10';
            c.port.text = '2222';
            c.username.text = 'admin';
            c.password.text = 'fixture-password-only';
            await c.connect();
          }
        });
        if (connected) {
          expect(c.stage, SshStage.connected);
          expect(vault.saved!.hostKey!.fingerprint, 'SHA256:fixture');
        }
        await loadFonts(tester);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            theme: AppTheme.create(Brightness.dark),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              // Around the navigator: the details sheet is in the picture.
              child: RepaintBoundary(key: boundary, child: child),
            ),
            home: Scaffold(
              body: ServerDetailView(
                session: c,
                motion: MotionPreference.off,
                onBack: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (connected) {
          await tester.tap(find.byKey(const ValueKey('server-ssh-access')));
          await tester.pumpAndSettle();
        }
        final l = AppLocalizations.of(tester.element(find.byType(Scaffold)));
        expect(tester.takeException(), isNull);
        // One title: the page's, no card title repeating it.
        expect(find.text(l.uiSshAccess), findsOneWidget);
        expect(find.text(l.sshEditHelp), findsNothing);
        expect(find.textContaining('SHA256:'), findsNothing);
        expect(find.byKey(const ValueKey('ssh-host')), findsOneWidget);
        // Segments while they fit, radio rows when they do not (r2).
        expect(
          find.byType(SegmentedButton<SshAuthMethod>),
          width < 600 ? findsNothing : findsOneWidget,
        );
        expect(
          find.byType(RadioListTile<SshAuthMethod>),
          width < 600 ? findsNWidgets(2) : findsNothing,
        );
        if (connected) {
          expect(find.text(l.sshConnected), findsOneWidget);
          expect(find.text('Ubuntu 24.04 · x86_64'), findsOneWidget);
          // Nothing to save yet; Save is still the form's main action.
          final save = find.byKey(const ValueKey('ssh-save'));
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          expect(find.byKey(const ValueKey('ssh-connect')), findsNothing);
        } else {
          expect(find.byKey(const ValueKey('ssh-status')), findsNothing);
          expect(find.byKey(const ValueKey('ssh-connect')), findsOneWidget);
        }
        await shot(tester, boundary, 'ssh-$state-${width.toInt()}-x2');

        if (connected) {
          await tester.tap(find.byKey(const ValueKey('ssh-details')));
          await tester.pumpAndSettle();
          expect(find.textContaining('SHA256:fixture'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await shot(tester, boundary, 'ssh-details-${width.toInt()}-x2');
          await tester.tapAt(const Offset(10, 10));
          await tester.pumpAndSettle();

          // A new name keeps the session: no warning.
          await tester.enterText(find.byKey(const ValueKey('ssh-name')), 'DE');
          await tester.pumpAndSettle();
          expect(find.text(l.sshEditHelp), findsNothing);
          // A changed port closes it on save: said right then.
          await tester.enterText(
            find.byKey(const ValueKey('ssh-port')),
            '2223',
          );
          await tester.pumpAndSettle();
          expect(find.text(l.sshEditHelp), findsOneWidget);
          expect(tester.takeException(), isNull);
          await shot(tester, boundary, 'ssh-changed-${width.toInt()}-x2');
        }
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        c.network.dispose();
      });
    }
  }
}
