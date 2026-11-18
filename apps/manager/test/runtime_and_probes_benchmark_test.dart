import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/backup/backup_controller.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/vpn/connection_checks.dart';
import 'package:antirkn_manager/vpn/profile_share_sheet.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:antirkn_mihomo_runtime/antirkn_mihomo_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vpn_controller_test.dart' as f;
import 'adopt_resource_test.dart' as a;

// ============================================================================
// BENCHMARK TEST DOUBLES (100% ISOLATED IN-MEMORY, ZERO LIVE VPS/DB TRAFFIC)
// ============================================================================

class BenchmarkNet implements IpProbeTransport {
  BenchmarkNet({this.delay = const Duration(milliseconds: 50)});
  final Duration delay;
  int probeCount = 0;

  @override
  Future<ProbeNetwork> network() async => const ProbeNetwork('wifi', 'wifi');

  @override
  Future<void> cancel() async {}

  @override
  Future<IpProbeResult> probe(
    IpProbeTarget target,
    ProbeNetwork network,
    Duration timeout,
    CancellationToken cancellation,
  ) async {
    probeCount++;
    if (delay > Duration.zero) {
      await cancellation.bind(Future<void>.delayed(delay));
    }
    cancellation.check();
    return IpProbeResult(IpProbeStatus.reachable, delay.inMilliseconds);
  }
}

class BenchmarkProbe implements CoreProbeTransport {
  BenchmarkProbe({this.delay = const Duration(milliseconds: 50)});
  final Duration delay;
  int probeCount = 0;

  @override
  Future<CoreTrafficCheck> probe(
    Map<String, Object?>? proxy,
    CancellationToken cancellation, {
    required bool udp,
    String directInterface = '',
  }) async {
    probeCount++;
    if (delay > Duration.zero) {
      await cancellation.bind(Future<void>.delayed(delay));
    }
    cancellation.check();
    return const CoreTrafficCheck(
      status: CoreTrafficStatus.success,
      code: 'connected',
      tcp: true,
      udp: true,
      udpTested: true,
    );
  }
}

class BenchmarkDiagnosticRemote extends f.Remote {
  BenchmarkDiagnosticRemote(
    super.store, {
    this.rtt = const Duration(milliseconds: 50),
  });
  final Duration rtt;
  int probeBeginCount = 0;
  int probeEndCount = 0;

  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    final action = request.json['action'];
    if (action == 'probe_begin') {
      probeBeginCount++;
      if (rtt > Duration.zero) {
        await token.bind(Future<void>.delayed(rtt));
      }
      token.check();
      final payload = jsonDecode(request.json['payload'] as String) as Map;
      return RunnerResponse.fromJson({
        ...response(),
        'connectionProbe': {
          'user': {
            'id': request.json['id'],
            'login': 'probe',
            'name': 'Probe',
            'enabled': true,
          },
          'observation': {
            'id': payload['resource'],
            'workspaceId': payload['workspace'],
            'spec': payload['spec'],
            'confirmed': true,
            'revision': 'fixture',
            'proxy': {
              'type': 'vless',
              'network': 'tcp',
              'tls': false,
              'udp': true,
              'servername': '',
            },
            'clients': [
              {
                'id': request.json['id'],
                'uuid': '22222222-2222-4222-8222-222222222222',
                'enabled': true,
              },
            ],
          },
        },
      });
    }
    if (action == 'probe_end') {
      probeEndCount++;
      return RunnerResponse.fromJson({
        ...response(),
        'connectionProbe': {'closed': true, 'stable': true},
      });
    }
    return super.request(request, token, sudoPassword: sudoPassword);
  }
}

class BenchmarkFileStore implements BackupFileStore {
  Uint8List? pickedBytes;
  Uint8List? savedBytes;
  @override
  Future<Uint8List?> pick() async => pickedBytes;
  @override
  Future<bool> save(Uint8List bytes) async {
    savedBytes = Uint8List.fromList(bytes);
    return true;
  }
}

class MockTransactionalBackupStore implements WorkspaceBackupStore {
  MockTransactionalBackupStore({required this.initialData});
  String initialData;
  String? currentData;
  bool isCorruptingRestore = false;
  int prepareCount = 0;
  int restoreCount = 0;

  @override
  Future<Uint8List> createBackup(String password) async {
    return Uint8List.fromList(utf8.encode(initialData));
  }

  @override
  Future<WorkspaceRestorePlan> prepareRestore(
    Uint8List bytes,
    String password,
  ) async {
    prepareCount++;
    // Check fixed binary magic header 'AntiRKNB'
    if (bytes.length < 8 ||
        bytes[0] != 65 ||
        bytes[1] != 110 ||
        bytes[2] != 116 ||
        bytes[3] != 105 ||
        bytes[4] != 82 ||
        bytes[5] != 75 ||
        bytes[6] != 78 ||
        bytes[7] != 66) {
      throw const BackupFailure(BackupIssue.invalid);
    }
    return _MockRestorePlan(
      summary: BackupSummary(
        createdAt: DateTime.utc(2026, 11, 14),
        workspaceId: '0' * 32,
        servers: 1,
        users: 1,
      ),
      payload: bytes,
    );
  }

  @override
  Future<void> restoreBackup(WorkspaceRestorePlan plan) async {
    restoreCount++;
    if (isCorruptingRestore) {
      // Simulate mid-restore SQLite failure: simulate transaction rollback
      throw const BackupFailure(BackupIssue.storage);
    }
    currentData = 'restored_data';
  }
}

class _MockRestorePlan implements WorkspaceRestorePlan {
  _MockRestorePlan({required this.summary, required this.payload});
  @override
  final BackupSummary summary;
  final Uint8List payload;
  bool disposed = false;
  @override
  void dispose() {
    disposed = true;
  }
}

class MockProfileExporter implements ProfileExporter {
  String? yaml;
  @override
  Future<bool> save(String name, String source) async {
    yaml = source;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Subsystem 1 Benchmarks: Connection Checks & Probe Concurrency', () {
    test('measures baseline latency for 20 nodes with 50ms simulated RTT', () async {
      final store = f.MemoryVpn();
      final probe = BenchmarkProbe(delay: const Duration(milliseconds: 50));
      final remote = BenchmarkDiagnosticRemote(store);
      final c = VpnController(
        repository: store,
        remote: (id) => VpnRemote(
          transport: remote,
          panelId: f.panel,
          identity: 'identity-$id',
        ),
        template: () => f.template,
        connectionProbe: ConnectionProbeEngine(
          core: probe,
          network: BenchmarkNet(delay: const Duration(milliseconds: 50)),
          controls: [
            for (var i = 1; i <= 10; i++)
              IpControl('c$i', 'p$i', IpProbeTarget('192.0.2.$i', 443)),
          ],
        ),
        timer: (d, f) => Timer(Duration.zero, () {}),
      );
      addTearDown(c.dispose);
      await c.load();

      // Register 20 external targets
      final targets = <ConnectionTarget>[];
      for (var i = 0; i < 20; i++) {
        final idHex = '${i.toRadixString(16).padLeft(2, '0')}${'0' * 30}';
        final nodeSpec = Map<String, Object?>.from(a.spec('vless'))
          ..['id'] = idHex;
        final key = c.connections.registerExternal(
          'server-$i',
          nodeSpec,
          'identity-server-$i',
        );
        targets.add(key);
      }

      final sw = Stopwatch()..start();
      await c.connections.checkAll(targets);
      sw.stop();

      print(
        'BASELINE/MEASUREMENT: checkAll 20 targets took ${sw.elapsedMilliseconds} ms (completed: ${c.connections.completed}/20)',
      );
      expect(c.connections.completed, 20);
      // In sequential implementation with 20 * (50ms probe + 50ms net), this takes >2000 ms.
      // After bounded concurrency optimization, it will run dramatically faster.
    });

    test(
      'demonstrates graceful queue waiting when owner is busy during checkAll',
      () async {
        final store = f.MemoryVpn();
        final probe = BenchmarkProbe(delay: const Duration(milliseconds: 10));
        final remote = BenchmarkDiagnosticRemote(store);
        final c = VpnController(
          repository: store,
          remote: (id) => VpnRemote(
            transport: remote,
            panelId: f.panel,
            identity: 'identity-$id',
          ),
          template: () => f.template,
          connectionProbe: ConnectionProbeEngine(
            core: probe,
            network: BenchmarkNet(delay: const Duration(milliseconds: 10)),
            controls: [],
          ),
          timer: (d, f) => Timer(Duration.zero, () {}),
        );
        addTearDown(c.dispose);
        await c.load();

        final key = c.connections.registerExternal(
          'server-0',
          Map<String, Object?>.from(a.spec('vless'))..['id'] = '0' * 32,
          'identity-server-0',
        );

        // Artificially mark owner as busy (e.g. running reconciliation or sync)
        c.busy = true;

        // Unbusy owner after 50ms to demonstrate graceful queue release!
        Timer(const Duration(milliseconds: 50), () {
          c.busy = false;
          c.notifyListeners();
        });

        final sw = Stopwatch()..start();
        await c.connections.checkAll([key]);
        sw.stop();

        print(
          'OPTIMIZED: checkAll with owner.busy graceful queue wait completed=${c.connections.completed}, total=${c.connections.total}, queueRunning=${c.connections.queueRunning} in ${sw.elapsedMilliseconds} ms',
        );
        expect(c.connections.completed, 1);
      },
    );
  });

  group('Subsystem 2 Benchmarks: MihomoConfigValidator & Concurrency', () {
    test(
      'measures concurrency barrier and false busy rejections on 10 parallel requests',
      () async {
        // Create validator pointing to non-existent or mock worker
        final validator = MihomoConfigValidator();
        const yaml = 'port: 7890\nmode: rule\n';

        var busyCount = 0;
        var completedCount = 0;

        // Launch 10 validation requests concurrently
        final futures = List.generate(10, (index) async {
          final token = CancellationToken();
          final check = await validator.validate(yaml, token);
          if (check.code == 'busy') {
            busyCount++;
          } else {
            completedCount++;
          }
          return check;
        });

        final results = await Future.wait(futures);
        print(
          'BASELINE: MihomoConfigValidator with 10 concurrent requests: busy=$busyCount, nonBusy=$completedCount',
        );
        expect(results.length, 10);
        // In baseline, single-threaded _busy flag rejects all concurrent requests with 'busy'.
      },
    );
  });

  group('Subsystem 3 Benchmarks: SQLite Rollback & Memory Zeroing', () {
    test(
      'simulates corrupt backup restore and verifies zero memory retention',
      () async {
        final initialData = 'precious_user_database';
        final store = MockTransactionalBackupStore(initialData: initialData);
        final files = BenchmarkFileStore();
        final controller = BackupController(store: store, files: files);
        addTearDown(controller.dispose);

        // Scenario 1: Malformed bytes without valid magic header
        final corruptBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
        files.pickedBytes = corruptBytes;

        await controller.prepare('secret-password-123');
        expect(controller.error, BackupIssue.invalid);
        // Verify crypto bytes were cleared via fillRange(0)
        expect(
          corruptBytes.every((b) => b == 0),
          isTrue,
          reason: 'Bytes must be securely zeroed in memory',
        );
        expect(
          store.restoreCount,
          0,
          reason:
              'Destructive restore must never be initiated for invalid backup',
        );

        // Scenario 2: Failure mid-restore rolls back transaction
        final validHeaderBytes = Uint8List.fromList([
          65,
          110,
          116,
          105,
          82,
          75,
          78,
          66,
          1,
          2,
          3,
        ]);
        files.pickedBytes = Uint8List.fromList(validHeaderBytes);
        store.isCorruptingRestore = true;

        await controller.prepare('secret-password-123');
        expect(controller.summary, isNotNull);

        await controller.restore();
        expect(controller.error, BackupIssue.storage);
        expect(
          store.currentData,
          isNull,
          reason: 'Failed restore must not corrupt or partially apply state',
        );
      },
    );
  });

  group('Subsystem 4 Benchmarks: ProfileShareSheet UI Frame-Pacing', () {
    testWidgets(
      'measures UI build time for ProfileShareSheet with large profile',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 1200);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final store = f.MemoryVpn();
        final c = f.controller(store, {});
        addTearDown(c.dispose);
        await tester.runAsync(c.load);

        final user = VpnUser(
          id: 'a' * 32,
          login: 'bench-user',
          name: 'Benchmark User',
          enabled: true,
        );
        await tester.runAsync(() => c.saveUser(user));

        final exporter = MockProfileExporter();

        final sw = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ProfileShareSheet(
                controller: c,
                user: user,
                exporter: exporter,
              ),
            ),
          ),
        );
        sw.stop();

        print(
          'BASELINE: ProfileShareSheet initial pump took ${sw.elapsedMilliseconds} ms',
        );
        expect(find.byType(ProfileShareSheet), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
      },
    );
  });
}
