import 'dart:async';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/android_ip_probe_transport.dart';
import 'package:antirkn_manager/network/ip_diagnostics_controller.dart';
import 'package:antirkn_manager/ssh/server_about_view.dart';
import 'ssh_support.dart' as ssh;
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
  final targets = <IpProbeTarget>[];
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
    targets.add(target);
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

  SshProfile profile({
    String id = 'one',
    int port = 2222,
    String fingerprint = 'fixture',
  }) => SshProfile(
    id: id,
    host: 'server.example',
    port: port,
    username: 'test',
    authMethod: SshAuthMethod.password,
    hostKey: TrustedHostKey('ssh-ed25519', fingerprint),
    lastInfo: ServerInfo(
      os: 'Ubuntu',
      architecture: 'x86_64',
      observedAt: DateTime.utc(2026, 9, 17),
      publicAddresses: [
        IpAddress.parse('93.184.215.15'),
        IpAddress.parse('93.184.215.16'),
        IpAddress.parse('2606:4700::1111'),
      ],
    ),
  );
  ServerIpDiagnostics server({
    String id = 'one',
    int port = 2222,
    String fingerprint = 'fixture',
  }) {
    final p = profile(id: id, port: port, fingerprint: fingerprint);
    return ServerIpDiagnostics(p, p.lastInfo!.publicAddresses!);
  }

  test('server targets use only public IPv4, TCP 443 and saved SSH port', () {
    final p = profile();
    final request = ServerIpDiagnostics(p, [
      ...p.lastInfo!.publicAddresses!,
      IpAddress.parse('93.184.215.15'),
      IpAddress.parse('10.0.0.1'),
      IpAddress.parse('127.0.0.1'),
    ]);
    expect(request.targets(IpProbeKind.tcp).map((t) => t.port), [443, 443]);
    expect(request.targets(IpProbeKind.ssh).map((t) => t.port), [2222, 2222]);
    expect(request.addresses, ['93.184.215.15', '93.184.215.16']);
    expect(
      () => ServerIpDiagnostics(p, []).targets(IpProbeKind.tcp),
      throwsFormatException,
    );
  });
  test(
    'results survive controller restart and retain only five runs',
    () async {
      await c.ready;
      for (var i = 0; i < 6; i++) {
        await c.start(server(), IpProbeKind.tcp);
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
      expect(
        restored.resultFor(server(), '93.184.215.15')?.status,
        IpProbeStatus.reachable,
      );
      expect(restored.resultFor(server(id: 'other'), '93.184.215.15'), isNull);
      expect(restored.resultFor(server(port: 2223), '93.184.215.15'), isNull);
      expect(
        restored.resultFor(server(fingerprint: 'changed'), '93.184.215.15'),
        isNull,
      );
      expect(restored.resultFor(server(), '2606:4700::1111'), isNull);
      expect(
        probes.targets.every((t) => t.address.family == IpFamily.ipv4),
        isTrue,
      );
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
    await locked.start(server(), IpProbeKind.tcp);
    expect(probes.calls, 0);
    expect(locked.issue, 'busy');
    expect(left, 0);
    locked.dispose();
  });
  test(
    'connection loss belongs to the triggering IPv4; remaining IPs are untested',
    () async {
      await c.ready;
      final request = server();
      final run = IpDiagnosticRun(
        DateTime.utc(2026, 9, 17),
        request.targets(IpProbeKind.tcp),
      );
      run.currentIp = request.addresses.first;
      run.stage = IpDiagnosticStage.degraded;
      run.suspectedStrong = true;
      run.lossAt = run.startedAt;
      run.add(
        IpProbeSample(
          run.targets.first,
          const IpProbeResult(IpProbeStatus.timeout, 3000),
          'target',
          run.startedAt,
        ),
      );
      c.history = [
        {...run.toJson(), 'serverKey': request.key, 'currentIp': run.currentIp},
      ];
      expect(c.resultFor(request, request.addresses.first)?.strong, isTrue);
      expect(
        c.resultFor(request, request.addresses.first)?.connectionLost,
        isTrue,
      );
      expect(c.resultFor(request, request.addresses.last)?.strong, isFalse);
      expect(c.resultFor(request, request.addresses.last)?.status, isNull);
      // A persisted in-flight run must not show as running after reopening.
      c.history.first['stage'] = 'target';
      expect(
        c.resultFor(request, request.addresses.last)?.stage,
        IpDiagnosticStage.cancelled,
      );
      expect(c.resultFor(request, request.addresses.last)?.running, isFalse);
      // Older unscoped reports cannot be safely attributed to this server.
      c.history.first.remove('serverKey');
      expect(c.resultFor(request, request.addresses.first), isNull);
    },
  );
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
      final work = guarded.start(server(), IpProbeKind.tcp);
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
    for (final width in [390.0, 1000.0]) {
      testWidgets(
        '$locale About at $width: one button, method dialog, inline IPv4 results',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
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
          final vault = ssh.FakeVault()
            ..mode = VaultMode.system
            ..saved = profile();
          final session = ssh.controller(vault, ssh.FakeConnector());
          await session.initialise();
          // Unsaved SSH editor text must not change diagnostic parameters.
          session.port.text = '9999';
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.create(Brightness.dark),
              locale: Locale(locale),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: Scaffold(
                appBar: AppBar(
                  title: Text(locale == 'ru' ? 'О сервере' : 'About server'),
                ),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: ServerAboutView(controller: session, diagnostics: c),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final l = AppLocalizations.of(
            tester.element(find.byType(ServerAboutView)),
          );
          expect(find.text(l.diagTitle), findsOneWidget);
          expect(probes.calls, 0);
          final button = find.byKey(const ValueKey('server-ip-diagnostics'));
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(find.byType(TextField), findsNothing);
          expect(find.text('${l.diagPort} 443'), findsOneWidget);
          expect(find.text('${l.diagPort} 2222'), findsOneWidget);
          await tester.tap(find.text(l.sshCancel));
          await tester.pumpAndSettle();
          expect(probes.calls, 0);
          await tester.tap(button);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('diagnostics-method-ssh')),
          );
          await tester.tap(find.byKey(const ValueKey('diagnostics-start')));
          await tester.pumpAndSettle();
          expect(c.current!.stage, IpDiagnosticStage.complete);
          expect(find.text('SSH :2222 · ${l.diagReachable}'), findsNWidgets(2));
          expect(
            find.byKey(const ValueKey('diagnostic-result-2606:4700::1111')),
            findsNothing,
          );
          expect(find.text(l.diagTitle), findsOneWidget);
          expect(find.text(l.diagControlList), findsNothing);
          expect(find.text(l.diagHistory), findsNothing);
          await tester.tap(button);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('diagnostics-start')));
          await tester.pumpAndSettle();
          expect(find.text('TCP :443 · ${l.diagReachable}'), findsNWidgets(2));
          expect(
            probes.targets.every((t) => t.address.family == IpFamily.ipv4),
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          session.dispose();
          session.network.dispose();
        },
      );
    }
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
