import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/android_ip_probe_transport.dart';
import 'package:antirkn_manager/network/ip_diagnostics_controller.dart';
import 'package:antirkn_manager/network/ip_diagnostics_page.dart';
import 'package:antirkn_network_inventory/antirkn_network_inventory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class MemorySettings implements SettingsStore {
  final values = <String, String>{};
  @override
  Future<String?> readSetting(String key) async => values[key];
  @override
  Future<void> writeSetting(String key, String value) async {
    values[key] = value;
  }
}

class Probes implements IpProbeTransport {
  int calls = 0, closed = 0;
  Completer<IpProbeResult>? hold;
  @override
  Future<ProbeNetwork> network() async =>
      const ProbeNetwork('wifi-local', 'wifi');
  @override
  Future<IpProbeResult> probe(
    IpProbeTarget target,
    ProbeNetwork network,
    Duration timeout,
    CancellationToken cancellation,
  ) async {
    calls++;
    return hold == null
        ? const IpProbeResult(IpProbeStatus.reachable, 2)
        : cancellation.bind(hold!.future);
  }

  @override
  Future<void> cancel() async {
    closed++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Probes probes;
  late MemorySettings settings;
  late IpDiagnosticsController c;
  setUp(() {
    probes = Probes();
    settings = MemorySettings();
    c = IpDiagnosticsController(
      engine: IpDiagnosticEngine(
        transport: probes,
        controls: defaultIpControls(),
      ),
      store: settings,
    );
  });
  tearDown(() => c.dispose());

  test('numeric public inputs only, bounded queue, and TLS hostname', () {
    for (final input in [
      '',
      'example.com',
      '127.0.0.1',
      '10.1.1.1',
      '1.1.1.1:443',
    ]) {
      c.addresses.text = input;
      expect(c.parse, throwsFormatException);
    }
    c.addresses.text = '1.1.1.1\n8.8.8.8\n1.1.1.1';
    expect(c.parse(), hasLength(2));
    c.kind = IpProbeKind.tls;
    expect(c.parse, throwsFormatException);
    c.host.text = 'example.com';
    expect(c.parse(), hasLength(2));
    c.port.text = '65536';
    expect(c.parse, throwsFormatException);
  });
  test(
    'results survive controller restart and retain only five runs',
    () async {
      await c.ready;
      c.addresses.text = '93.184.216.34';
      for (var i = 0; i < 6; i++) {
        await c.start(c.parse());
      }
      expect(c.history, hasLength(5));
      final restored = IpDiagnosticsController(
        engine: c.engine,
        store: settings,
      );
      await restored.ready;
      expect(restored.history, hasLength(5));
      expect(restored.history.first['stage'], 'complete');
      expect(restored.busy, isFalse);
      final before = probes.calls;
      await restored.clearHistory();
      expect(probes.calls, before);
      expect(settings.values['ipDiagnosticHistory'], '[]');
      restored.dispose();
    },
  );
  test('conflicting server operation prevents all probes', () async {
    var left = 0;
    final locked = IpDiagnosticsController(
      engine: c.engine,
      enter: () async => false,
      leave: () async {
        left++;
      },
    );
    await locked.start([IpProbeTarget('1.1.1.1', 443)]);
    expect(probes.calls, 0);
    expect(locked.issue, 'busy');
    expect(left, 0);
    locked.dispose();
  });
  test(
    'stop releases the background fence after pending probes finish',
    () async {
      probes.hold = Completer<IpProbeResult>();
      var left = 0;
      final guarded = IpDiagnosticsController(
        engine: c.engine,
        enter: () async => true,
        leave: () async {
          left++;
        },
      );
      final work = guarded.start([IpProbeTarget('1.1.1.1', 443)]);
      await Future<void>.delayed(Duration.zero);
      expect(guarded.busy, isTrue);
      guarded.stop();
      await work;
      expect(guarded.current!.stage, IpDiagnosticStage.cancelled);
      expect(left, 1);
      expect(guarded.busy, isFalse);
      expect(probes.closed, greaterThan(0));
      guarded.dispose();
    },
  );
  for (final locale in ['ru', 'en']) {
    testWidgets(
      '$locale form does not scan on opening or on cancelling consent',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        c.dispose();
        probes = Probes();
        c = IpDiagnosticsController(
          engine: IpDiagnosticEngine(
            transport: probes,
            controls: defaultIpControls(),
          ),
          store: settings,
        );
        await c.ready;
        c.addresses.text = '1.1.1.1';
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: IpDiagnosticsPage(controller: c)),
          ),
        );
        await tester.pumpAndSettle();
        expect(probes.calls, 0);
        await tester.ensureVisible(
          find.byKey(const ValueKey('diagnostics-start')),
        );
        await tester.tap(find.byKey(const ValueKey('diagnostics-start')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('diagnostics-confirm')),
          findsOneWidget,
        );
        final l = AppLocalizations.of(
          tester.element(find.byType(IpDiagnosticsPage)),
        );
        await tester.tap(find.text(l.sshCancel));
        await tester.pumpAndSettle();
        expect(probes.calls, 0);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('diagnostics-start')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('diagnostics-confirm')));
        await tester.pumpAndSettle();
        expect(
          c.current,
          isNotNull,
          reason: 'busy=${c.busy} issue=${c.issue} calls=${probes.calls}',
        );
        expect(c.current!.stage, IpDiagnosticStage.complete);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  test(
    'Android channel preserves numeric IP, route identity and timeout',
    () async {
      final messages = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidIpProbeTransport.channel, (
            call,
          ) async {
            messages.add(call);
            return switch (call.method) {
              'network' => {
                'identity': 'wifi-vpn',
                'kind': 'vpn',
                'vpn': true,
                'bound': true,
              },
              'probe' => {'status': 'reachable', 'ms': 12},
              _ => null,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidIpProbeTransport.channel, null),
      );
      final bridge = AndroidIpProbeTransport();
      final network = await bridge.network();
      expect(network.vpn, isTrue);
      expect(network.bound, isTrue);
      await bridge.probe(
        IpProbeTarget(
          '1.1.1.1',
          443,
          kind: IpProbeKind.tls,
          host: 'one.one.one.one',
        ),
        network,
        const Duration(seconds: 3),
        CancellationToken(),
      );
      expect(messages.last.arguments, containsPair('network', 'wifi-vpn'));
      expect(messages.last.arguments, containsPair('timeout', 3000));
      expect(messages.last.arguments, containsPair('ip', '1.1.1.1'));
      await bridge.cancel();
      expect(messages.last.method, 'cancel');
    },
  );
}
