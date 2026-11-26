// The three protocol editors share one form structure; protocol pages share
// one action row; TLS certificates are compact rows. Set ANTIRKN_UI_EVIDENCE
// to a directory to save screenshots with real fonts.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/l10n/app_localizations_en.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/vpn/awg_panel.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:antirkn_manager/vpn/tt_certificates.dart';
import 'package:antirkn_manager/vpn/tt_panel.dart';
import 'package:antirkn_manager/vpn/xhttp_options_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'awg_test.dart' as awg;
import 'runner_support.dart';
import 'ssh_support.dart';
import 'tt_endpoint_editor_test.dart' show CertificateTransport;
import 'tt_test.dart' as tt;
import 'vpn_controller_test.dart' as f;

final _evidence = Platform.environment['ANTIRKN_UI_EVIDENCE'];
final _boundary = GlobalKey();
final _l = AppLocalizationsEn();

Future<void> _fonts(WidgetTester tester) async {
  if (_evidence == null) return;
  await tester.runAsync(() async {
    for (final font in [
      ('Roboto', '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf'),
      (
        'MaterialIcons',
        '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
    ]) {
      await (FontLoader(font.$1)
            ..addFont(File(font.$2).readAsBytes().then(ByteData.sublistView)))
          .load();
    }
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  final evidence = _evidence;
  if (evidence == null) return;
  await tester.runAsync(() async {
    final image =
        await (_boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(evidence).create(recursive: true);
    await File('$evidence/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void _size(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app(Widget child, {double scale = 1, bool scroll = false}) =>
    MaterialApp(
      locale: const Locale('en'),
      theme: AppTheme.create(Brightness.dark),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: RepaintBoundary(key: _boundary, child: child!),
      ),
      home: Scaffold(
        body: scroll
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: child,
              )
            : Center(child: child),
      ),
    );

RunnerController _runner(FakeRunnerTransport Function(MemoryRunnerJournal) t) {
  final store = MemoryRunnerJournal();
  final remote = t(store);
  return RunnerController(
    serverId: 'fixture',
    transport: () => remote,
    identity: () => 'fixture|key',
    password: () => null,
    accessFailure: (_) {},
    store: store,
  );
}

double get _now => DateTime.now().millisecondsSinceEpoch / 1000;

final _certificates = [
  {
    'id': 'a' * 32,
    'domain': 'vpn.example.com',
    'mode': 'acme',
    'expiresAt': _now + 90 * 86400,
    'lastSuccess': _now - 600,
    'nextCheck': _now + 600,
  },
  {
    'id': 'b' * 32,
    'domain': 'files.example.com',
    'mode': 'files',
    'expiresAt': _now + 5 * 86400,
    'error': 'tt_certificate_invalid',
  },
];

/// No two vertical neighbours of a form overlap or touch.
void _expectGaps(WidgetTester tester, Finder upper, Finder lower) {
  final a = tester.getRect(upper), b = tester.getRect(lower);
  expect(b.top - a.bottom, greaterThanOrEqualTo(AppFormFields.hintGap));
}

void main() {
  for (final width in [390.0, 1000.0]) {
    testWidgets('VLESS editor: one form structure at $width', (tester) async {
      _size(tester, width, 1900);
      await _fonts(tester);
      final network = NetworkController(reader: const SampleInventoryReader());
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _app(
          InboundForm(
            serverId: 'one',
            network: network,
            motion: MotionPreference.off,
            scanReality: (_, _) async => null,
            inbound: VlessInbound(
              serverId: 'one',
              spec: {
                ...VlessInbound.defaults(),
                'name': 'VLESS',
                'transport': 'xhttp',
                'listen': '203.0.113.5',
                'endpoint': '203.0.113.5',
                'target': 'example.com:443',
                'sni': 'example.com',
                'path': '/path',
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppFormSection), findsNWidgets(5));
      expect(find.text(_l.realityScanHelp), findsNothing);
      expect(find.byTooltip(_l.realityScanHelp), findsOneWidget);
      // Secondary actions share one style.
      expect(
        tester.widget(find.byKey(const ValueKey('vpn-reality-scan'))),
        isA<FilledButton>(),
      );
      await tester.tap(find.byKey(const ValueKey('vpn-reality-scan')));
      await tester.pumpAndSettle();
      expect(find.text(_l.realityScanFailed), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vpn-reality-regenerate')));
      await tester.pumpAndSettle();
      expect(find.text(_l.vpnRealityRegenerated), findsOneWidget);
      _expectGaps(
        tester,
        find.byKey(const ValueKey('vpn-reality-scan')),
        find.text(_l.realityScanFailed),
      );
      _expectGaps(
        tester,
        find.text(_l.realityScanFailed),
        find.byKey(const ValueKey('vpn-inbound-sni')),
      );
      _expectGaps(
        tester,
        find.byKey(const ValueKey('vpn-reality-regenerate')),
        find.text(_l.vpnRealityRegenerated),
      );
      _expectGaps(
        tester,
        find.text(_l.vpnRealityRegenerated),
        find.byType(XhttpOptionsEditor),
      );
      await _capture(tester, 'vless-${width.toInt()}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('AmneziaWG editor: one form structure at $width', (
      tester,
    ) async {
      _size(tester, width, 1200);
      await _fonts(tester);
      final network = NetworkController(reader: const SampleInventoryReader());
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _app(
          AwgForm(
            serverId: 'one',
            spec: awg.spec(),
            network: network,
            motion: MotionPreference.off,
            existing: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppFormSection), findsNWidgets(3));
      expect(find.byType(AppFormSwitch), findsOneWidget);
      await _capture(tester, 'awg-${width.toInt()}');
      await tester.tap(find.text(_l.awgAdvanced));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('awg-externalPort')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('TrustTunnel editor: one form structure at $width', (
      tester,
    ) async {
      _size(tester, width, 1400);
      await _fonts(tester);
      final runner = _runner(CertificateTransport.new);
      final network = NetworkController(reader: const SampleInventoryReader());
      addTearDown(network.dispose);
      await runner.refresh(prepare: true);
      runner.ttCertificates = {'certificates': _certificates};
      await tester.pumpWidget(
        _app(
          ManagedTtDialog(
            serverId: 'fixture',
            spec: tt.spec(),
            runner: runner,
            picker: FakeKeyPicker(),
            network: network,
            motion: MotionPreference.off,
            existing: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppFormSection), findsNWidgets(4));
      expect(
        tester.widget(find.byKey(const ValueKey('tt-issue-certificate'))),
        isA<FilledButton>(),
      );
      expect(
        tester.widget(find.byKey(const ValueKey('tt-regenerate-passwords'))),
        isA<FilledButton>(),
      );
      await _capture(tester, 'tt-${width.toInt()}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      runner.dispose();
    });

    testWidgets('protocol page actions share one spaced row at $width', (
      tester,
    ) async {
      _size(tester, width, 500);
      await _fonts(tester);
      final vpn = f.controller(f.MemoryVpn(), {});
      await tester.runAsync(vpn.load);
      final network = NetworkController(reader: const SampleInventoryReader());
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _app(
          AwgPanel(
            controller: vpn,
            serverId: 'one',
            network: network,
            motion: MotionPreference.off,
          ),
          scroll: true,
        ),
      );
      await tester.pumpAndSettle();
      final add = tester.getRect(find.byKey(const ValueKey('awg-add')));
      final check = tester.getRect(
        find.ancestor(
          of: find.text(_l.connectionCheckAll),
          matching: find.byType(OutlinedButton),
        ),
      );
      // Buttons are as wide as their labels and never touch: side by side
      // when they fit, wrapped under each other otherwise.
      expect(add.width, lessThan(width - 32));
      if ((add.center.dy - check.center.dy).abs() < 1) {
        expect(
          check.left - add.right,
          greaterThanOrEqualTo(AppLayout.smallGap),
        );
      } else {
        expect(
          check.top - add.bottom,
          greaterThanOrEqualTo(AppLayout.smallGap),
        );
      }
      if (width >= AppLayout.compact) {
        expect(add.center.dy, closeTo(check.center.dy, 1));
      }
      await _capture(tester, 'awg-page-${width.toInt()}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      vpn.dispose();
      await tester.pump();
    });

    testWidgets('TLS certificates are compact rows at $width', (tester) async {
      _size(tester, width, 700);
      await _fonts(tester);
      final runner = _runner(FakeRunnerTransport.new);
      runner.ttCertificates = {'certificates': _certificates};
      final network = NetworkController(reader: const SampleInventoryReader());
      addTearDown(network.dispose);
      await tester.pumpWidget(
        _app(
          TtCertificates(
            runner: runner,
            picker: FakeKeyPicker(),
            network: network,
            motion: MotionPreference.off,
          ),
          scroll: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(3));
      expect(find.textContaining(_l.ttLastSuccess), findsNothing);
      expect(find.textContaining(_l.ttRenewAcme), findsNothing);
      expect(find.byTooltip(_l.awgRefresh), findsOneWidget);
      await _capture(tester, 'certificates-${width.toInt()}');
      await tester.tap(find.text('vpn.example.com'));
      await tester.pumpAndSettle();
      expect(find.text(_l.ttLastSuccess), findsOneWidget);
      expect(find.text(_l.ttRenewAcme), findsOneWidget);
      await _capture(tester, 'certificate-details-${width.toInt()}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      runner.dispose();
    });
  }

  testWidgets('VLESS editor fits at text scale 2', (tester) async {
    _size(tester, 390, 3600);
    await _fonts(tester);
    final network = NetworkController(reader: const SampleInventoryReader());
    addTearDown(network.dispose);
    await tester.pumpWidget(
      _app(
        InboundForm(
          serverId: 'one',
          network: network,
          motion: MotionPreference.off,
          scanReality: (_, _) async => null,
        ),
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();
    await _capture(tester, 'vless-390-x2');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
