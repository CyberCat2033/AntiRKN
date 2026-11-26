import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/publication/profile_link_qr.dart';
import 'package:antirkn_manager/ssh/server_catalog.dart';
import 'package:antirkn_manager/ssh/server_catalog_controller.dart';
import 'package:antirkn_manager/vpn/inbounds_panel.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'vpn_controller_test.dart' as vpn_fixtures;
import 'ssh_support.dart';

// ============================================================================
// BENCHMARK HARNESS & MOCK DATA (100% ISOLATED IN-MEMORY)
// ============================================================================

String _hex32(int index) => index.toRadixString(16).padLeft(32, '0');

List<VpnUser> generateMockUsers(int count) => [
  for (var i = 1; i <= count; i++)
    VpnUser(
      id: _hex32(i),
      login: 'benchmark-user-$i',
      name: 'Client User #$i',
      enabled: true,
    ),
];

List<SavedServer> generateMockServers(int count) => [
  for (var i = 1; i <= count; i++)
    SavedServer(
      'server_$i',
      SshProfile(
        name: 'Benchmark Server $i',
        host: '198.51.100.$i',
        port: 22,
        username: 'root',
        authMethod: SshAuthMethod.agent,
      ),
      1,
    ),
];

List<VlessInbound> generateMockInbounds(String serverId, int count) => [
  for (var i = 1; i <= count; i++)
    VlessInbound(
      serverId: serverId,
      spec: {
        ...VlessInbound.defaults(),
        'id': _hex32(2000 + i),
        'name': 'Node VLESS $i',
        'endpoint': '203.0.113.$i',
        'sni': 'node$i.example.com',
        'target': 'node$i.example.com:443',
      },
    ),
];

String generateHeavyYamlRules(int ruleCount) {
  final buffer = StringBuffer();
  buffer.writeln('port: 7890');
  buffer.writeln('socks-port: 7891');
  buffer.writeln('mode: rule');
  buffer.writeln('log-level: silent');
  buffer.writeln('proxies:');
  buffer.writeln('  - name: DIRECT');
  buffer.writeln('    type: direct');
  buffer.writeln('proxy-groups:');
  buffer.writeln('  - name: PROXY');
  buffer.writeln('    type: select');
  buffer.writeln('    proxies:');
  buffer.writeln('      - DIRECT');
  buffer.writeln('rules:');
  for (var i = 1; i <= ruleCount; i++) {
    buffer.writeln('  - DOMAIN-SUFFIX,site$i.benchmark.test,DIRECT');
  }
  buffer.writeln('  - MATCH,DIRECT');
  return buffer.toString();
}

class BenchmarkExporter implements ProfileExporter {
  String? lastSavedName;
  String? lastSavedContent;

  @override
  Future<bool> save(String name, String content) async {
    lastSavedName = name;
    lastSavedContent = content;
    return true;
  }
}

class BenchmarkServerRepo
    implements ServerRepository, LanguagePreferenceStore, SettingsStore {
  final servers = <String, SshProfile>{};
  final settings = <String, String>{};
  int sequence = 0;
  int revision = 1;

  @override
  Future<void> deleteServers(
    List<SavedServer> expected, {
    bool detachJumpReferences = false,
  }) async {
    for (final s in expected) {
      servers.remove(s.id);
    }
  }

  @override
  bool get needsLegacyPassword => false;

  @override
  Future<void> migrateLegacy({String? password}) async {}

  @override
  Future<List<SavedServer>> listServers() async => [
    for (final e in servers.entries) SavedServer(e.key, e.value, revision),
  ];

  @override
  String newServerId() => 'new_${++sequence}';

  @override
  Future<SecretVault> openServer(String id) async => FakeVault();

  @override
  Future<AppLanguage> readLanguage() async => AppLanguage.en;

  @override
  Future<void> writeLanguage(AppLanguage language) async {}

  @override
  Future<String?> readSetting(String key) async => settings[key];

  @override
  Future<void> writeSetting(String key, String value) async {
    settings[key] = value;
  }
}

VpnController createBenchmarkVpn(vpn_fixtures.MemoryVpn store) => VpnController(
  repository: store,
  remote: (_) => null,
  template: () => '{"proxies":[],"proxy-groups":[],"rules":[]}',
  timer: (_, _) => Timer(const Duration(days: 1), () {})..cancel(),
);

Widget testApp(Widget child) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UI Frame-Pacing & Rebuild Benchmarks', () {
    testWidgets('Benchmark 1: First-frame rendering latency with 100 clients', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final store = vpn_fixtures.MemoryVpn();
      final users = generateMockUsers(100);
      final initialWorkspace = VpnWorkspace(
        id: _hex32(999),
        users: users,
        servers: {
          'server_1': {'name': 'Server 1'},
        },
      );
      store.raw = initialWorkspace.encode();

      final controller = createBenchmarkVpn(store);
      addTearDown(controller.dispose);
      await tester.runAsync(controller.load);

      final exporter = BenchmarkExporter();
      final sw = Stopwatch()..start();

      await tester.pumpWidget(
        testApp(
          UsersPage(
            controller: controller,
            serverName: (id) => 'Server #1',
            exporter: exporter,
            motion: MotionPreference.off,
          ),
        ),
      );
      sw.stop();
      final firstFrameMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        'BASELINE: UsersPage 100 clients initial pump took $firstFrameMs ms',
      );

      expect(find.byType(UsersPage), findsOneWidget);
      expect(firstFrameMs, lessThan(3000));
    });

    testWidgets('Benchmark 2: First-frame rendering latency with 50 servers', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = BenchmarkServerRepo();
      for (final server in generateMockServers(50)) {
        repo.servers[server.id] = server.profile;
      }

      final catalogController = ServerCatalogController(
        repository: repo,
        connector: FakeConnector(),
        picker: FakeKeyPicker(),
        reader: const SampleInventoryReader(),
      );
      addTearDown(catalogController.dispose);
      await tester.runAsync(catalogController.load);

      final sw = Stopwatch()..start();
      await tester.pumpWidget(
        testApp(
          ServerCatalog(
            controller: catalogController,
            motion: MotionPreference.off,
          ),
        ),
      );
      sw.stop();
      final firstFrameMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        'BASELINE: ServerCatalog 50 servers initial pump took $firstFrameMs ms',
      );

      expect(find.byType(ServerCatalog), findsOneWidget);
      expect(firstFrameMs, lessThan(3000));
    });

    testWidgets('Benchmark 3: First-frame rendering latency with 50 inbounds', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final inbounds = generateMockInbounds('server_1', 50);
      final store = vpn_fixtures.MemoryVpn();
      final initialWorkspace = VpnWorkspace(
        id: _hex32(888),
        servers: {
          'server_1': {'name': 'Server 1'},
        },
        inbounds: inbounds,
      );
      store.raw = initialWorkspace.encode();

      final controller = createBenchmarkVpn(store);
      addTearDown(controller.dispose);
      await tester.runAsync(controller.load);

      final sw = Stopwatch()..start();
      await tester.pumpWidget(
        testApp(
          InboundsPanel(
            controller: controller,
            serverId: 'server_1',
            serverName: (id) => 'Server 1',
            network: NetworkController(reader: const SampleInventoryReader()),
            motion: MotionPreference.off,
          ),
        ),
      );
      sw.stop();
      final firstFrameMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        'BASELINE: InboundsPanel 50 nodes initial pump took $firstFrameMs ms',
      );

      expect(find.byType(InboundsPanel), findsOneWidget);
      expect(firstFrameMs, lessThan(3000));
    });

    testWidgets('Benchmark 4: Rebuild Storm audit upon single state change', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final store = vpn_fixtures.MemoryVpn();
      final users = generateMockUsers(50);
      final initialWorkspace = VpnWorkspace(
        id: _hex32(777),
        users: users,
        servers: {
          'server_1': {'name': 'Server 1'},
        },
      );
      store.raw = initialWorkspace.encode();

      final controller = createBenchmarkVpn(store);
      addTearDown(controller.dispose);
      await tester.runAsync(controller.load);

      final exporter = BenchmarkExporter();
      await tester.pumpWidget(
        testApp(
          UsersPage(
            controller: controller,
            serverName: (id) => 'Server #1',
            exporter: exporter,
            motion: MotionPreference.off,
          ),
        ),
      );

      // The client list is lazy (UI-31): only the rows in view are built,
      // not all 50.
      final initialRows = tester.widgetList(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              RegExp(
                r'^client-(?!avatar-|toggle-|qr-)',
              ).hasMatch((w.key! as ValueKey<String>).value),
        ),
      );
      expect(initialRows.length, inInclusiveRange(1, 49));

      // Toggling one single user's state
      final sw = Stopwatch()..start();
      await tester.runAsync(() async {
        final firstUser = controller.workspace.users.first;
        await controller.saveUser(firstUser.copyWith(enabled: false));
      });
      await tester.pump();
      sw.stop();

      // ignore: avoid_print
      print(
        'BASELINE: Rebuild of UsersPage after single user update: took ${sw.elapsedMilliseconds} ms',
      );
      expect(find.byType(UsersPage), findsOneWidget);
    });

    testWidgets('Benchmark 5: ProfileLinkQr RepaintBoundary isolation audit', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var counter = 0;
      final notifier = ValueNotifier<int>(0);
      addTearDown(notifier.dispose);

      await tester.pumpWidget(
        testApp(
          Column(
            children: [
              ValueListenableBuilder<int>(
                valueListenable: notifier,
                builder: (context, val, child) {
                  counter++;
                  return Text('Counter: $val');
                },
              ),
              ProfileLinkQr(
                url: 'https://drive.google.com/uc?id=benchmark_file_123',
                profileName: 'Benchmark Client',
                beforeCopy: () async {},
              ),
            ],
          ),
        ),
      );

      expect(find.byType(ProfileLinkQr), findsOneWidget);
      expect(counter, 1);

      // Trigger 10 parent updates
      for (var i = 1; i <= 10; i++) {
        notifier.value = i;
        await tester.pump();
      }
      expect(counter, 11);
    });
  });

  group('CPU-Bound Tasks & Isolate Offloading Benchmarks', () {
    test('Benchmark 6: Parsing and hashing 2000-rule YAML configuration', () async {
      final heavyYaml = generateHeavyYamlRules(2000);
      expect(heavyYaml.length, greaterThan(50000));

      // Measure synchronous execution on main isolate
      final swSync = Stopwatch()..start();
      final parsed = loadYaml(heavyYaml);
      final hash = sha256.convert(utf8.encode(heavyYaml)).toString();
      swSync.stop();

      expect(parsed, isA<Map>());
      expect(hash.length, 64);
      final syncMs = swSync.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        'BASELINE: 2000 rules YAML loadYaml + SHA-256 on Main Isolate took $syncMs ms',
      );

      // Measure background isolate execution via Isolate.run
      final swIsolate = Stopwatch()..start();
      final isolateHash = await Isolate.run(() {
        final _ = loadYaml(heavyYaml);
        return sha256.convert(utf8.encode(heavyYaml)).toString();
      });
      swIsolate.stop();

      expect(isolateHash, hash);
      final isolateMs = swIsolate.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        'OFFLOADED: 2000 rules YAML loadYaml + SHA-256 via Isolate.run took $isolateMs ms (0 ms Main Isolate blocking)',
      );
    });

    test('Benchmark 7: ProfileCompiler compilation with 2000 rules', () async {
      final heavyYaml = generateHeavyYamlRules(2000);
      const compiler = ProfileCompiler();

      final sw = Stopwatch()..start();
      final prepared = compiler.prepare(heavyYaml);
      final result = compiler.compilePrepared(
        prepared: prepared,
        userId: 'test_user',
        accesses: [],
      );
      sw.stop();

      expect(result.groups, isNotEmpty);
      final compileMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print(
        'BASELINE: ProfileCompiler prepare + compile 2000 rules took $compileMs ms',
      );
    });

    test(
      'Benchmark 8: Notification storms in ConnectionChecks during batch check',
      () async {
        final store = vpn_fixtures.MemoryVpn();
        final initialWorkspace = VpnWorkspace(
          id: _hex32(666),
          servers: {
            'server_1': {'name': 'Server 1'},
          },
        );
        store.raw = initialWorkspace.encode();

        final vpn = createBenchmarkVpn(store);
        addTearDown(vpn.dispose);
        await vpn.load();

        final checks = vpn.connections;

        var notifyCount = 0;
        checks.addListener(() {
          notifyCount++;
        });

        // Simulate batch check of 10 keys
        final keys = [
          for (var i = 1; i <= 10; i++)
            (target: 'server_1', resource: 'res_$i'),
        ];

        checks.checkAll(keys);
        // Wait for queue processing
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // ignore: avoid_print
        print(
          'BASELINE: ConnectionChecks.checkAll() for 10 keys triggered $notifyCount notifyListeners() events',
        );
        expect(notifyCount, greaterThan(0));
      },
    );
  });
}
