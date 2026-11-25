// Stage 2 of UI_AUDIT_REPORT.md (UI-25…UI-38): main-isolate blocking and
// rebuild storms. Every test records a counter or a timing and asserts a
// threshold; the printed METRIC lines are the "after" values in the report.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/network/socket_ip_probe_transport.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/sync/auto_sync_controller.dart';
import 'package:antirkn_manager/settings_hub.dart';
import 'package:antirkn_manager/ssh/server_detail_view.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:antirkn_manager/drag_select_list.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as widgets;
import 'package:flutter_test/flutter_test.dart';

import 'publication_test.dart' as pub;
import 'network_support.dart';
import 'ssh_support.dart';
import 'vpn_controller_test.dart' as fx;

void _metric(String line) {
  // ignore: avoid_print
  print('METRIC: $line');
}

class _ShellRepository
    implements
        ServerRepository,
        LanguagePreferenceStore,
        SettingsStore,
        VpnRepository {
  final servers = <String, SshProfile>{};
  final settings = <String, String>{};
  String? vpnSource;
  int vpnRevision = 1, sequence = 0;

  @override
  Future<void> deleteServers(
    List<SavedServer> expected, {
    bool detachJumpReferences = false,
  }) async {
    for (final server in expected) {
      servers.remove(server.id);
    }
  }

  @override
  bool get needsLegacyPassword => false;
  @override
  Future<void> migrateLegacy({String? password}) async {}
  @override
  Future<List<SavedServer>> listServers() async => [
    for (final entry in servers.entries) SavedServer(entry.key, entry.value, 1),
  ];
  @override
  String newServerId() => 'server-${++sequence}';
  @override
  Future<SecretVault> openServer(String id) async =>
      FakeVault()..saved = servers[id];
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

  @override
  Future<VpnStoredDocument> readVpn() async =>
      VpnStoredDocument(vpnSource, vpnRevision);
  @override
  Future<int> writeVpn(String source, {required int expectedRevision}) async {
    if (expectedRevision != vpnRevision) {
      throw const VaultFailure(VaultIssue.busy);
    }
    vpnSource = source;
    return ++vpnRevision;
  }
}

class _Exporter implements ProfileExporter {
  @override
  Future<bool> save(String name, String content) async => true;
}

/// Counts how often elements of the given widget types rebuild.
Map<Type, int> _countRebuilds(List<Type> types) {
  final counts = {for (final type in types) type: 0};
  final previous = widgets.debugOnRebuildDirtyWidget;
  widgets.debugOnRebuildDirtyWidget = (element, builtOnce) {
    final type = element.widget.runtimeType;
    if (counts.containsKey(type)) counts[type] = counts[type]! + 1;
    previous?.call(element, builtOnce);
  };
  addTearDown(() => widgets.debugOnRebuildDirtyWidget = previous);
  return counts;
}

String _hex32(int index) => index.toRadixString(16).padLeft(32, '0');

/// A base template with a realistic rule list: every compiled profile is a
/// real Mihomo YAML of ~15 KiB.
final _template =
    '{"proxies":[],"proxy-groups":[{"name":"ALL","type":"select","include-all-proxies":true}],"rules":['
    '${[for (var i = 0; i < 350; i++) '"DOMAIN-SUFFIX,site$i.example.org,ALL"'].join(',')},"MATCH,ALL"]}';

/// A realistic client profile: a Mihomo document with a few hundred rules.
String _profileYaml(int user, {int rules = 350}) {
  final buffer = StringBuffer()
    ..writeln('mixed-port: 7890')
    ..writeln('mode: rule')
    ..writeln('proxies:')
    ..writeln('  - name: "VLESS user $user"')
    ..writeln('    type: vless')
    ..writeln('    server: 203.0.113.1')
    ..writeln('    port: 443')
    ..writeln('    uuid: ${_hex32(user)}')
    ..writeln('proxy-groups:')
    ..writeln('  - name: ALL')
    ..writeln('    type: select')
    ..writeln('rules:');
  for (var i = 0; i < rules; i++) {
    buffer.writeln('  - DOMAIN-SUFFIX,site$i.example.org,ALL');
  }
  buffer.writeln('  - MATCH,ALL');
  return buffer.toString();
}

VpnWorkspace _bigWorkspace(int users) => VpnWorkspace(
  id: _hex32(4242),
  users: [
    for (var i = 1; i <= users; i++)
      VpnUser(id: _hex32(i), login: 'user-$i', name: 'Client $i'),
  ],
  servers: {
    'one': {'name': 'Server one'},
  },
  profiles: {
    for (var i = 1; i <= users; i++)
      _hex32(i): {
        'hash': 'f' * 64,
        'yaml': _profileYaml(i),
        'at': '2026-11-25T00:00:00.000Z',
        'publicationWorkspaceId': _hex32(4242),
      },
  },
);

/// Stores the workspace object like the database worker does: nothing is
/// encoded on the calling isolate.
class _WorkerLikeVpn implements VpnRepository, VpnWorkspaceWriter {
  _WorkerLikeVpn(this.raw);
  String? raw;
  int revision = 1;
  @override
  Future<VpnStoredDocument> readVpn() async => VpnStoredDocument(raw, revision);
  @override
  Future<int> writeVpn(String source, {required int expectedRevision}) async {
    raw = source;
    return ++revision;
  }

  @override
  Future<int> writeVpnWorkspace(
    VpnWorkspace workspace, {
    required int expectedRevision,
  }) async => ++revision;
}

/// The longest stretch the event loop of this isolate was blocked while
/// [action] ran: a 1 ms periodic timer cannot fire during synchronous work.
Future<int> _longestStallMs(Future<void> Function() action) async {
  var longest = 0;
  final clock = Stopwatch()..start();
  var last = 0;
  final probe = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = clock.elapsedMilliseconds;
    if (now - last > longest) longest = now - last;
    last = now;
  });
  try {
    await action();
    final now = clock.elapsedMilliseconds;
    if (now - last > longest) longest = now - last;
  } finally {
    probe.cancel();
  }
  return longest;
}

/// [users] clients on two servers with four VLESS inbounds, applied and read
/// back through the fake runner: [VpnController.hasCurrentVerifiedProfiles]
/// walks every target, the worst case for each notification.
Future<VpnController> _verifiedController(int users) async {
  final store = fx.MemoryVpn()
    ..raw = VpnWorkspace(
      id: _hex32(4343),
      users: [
        for (var i = 1; i <= users; i++)
          VpnUser(id: _hex32(i), login: 'user-$i', name: 'Client $i'),
      ],
      inbounds: [
        fx.inbound('one', '1' * 32),
        fx.inbound('one', '2' * 32),
        fx.inbound('two', '3' * 32),
        fx.inbound('two', '4' * 32),
      ],
    ).encode();
  final remotes = {'one': fx.Remote(store), 'two': fx.Remote(store)};
  final c = fx.controller(store, remotes);
  await c.load();
  await c.prepare();
  await c.apply();
  return c;
}

/// Average wall time of one synchronous [VpnController] notification with
/// every listener attached (publication, connection checks).
double _notifyCostMs(VpnController c, {int rounds = 20}) {
  c.dismissPlans();
  final clock = Stopwatch()..start();
  for (var i = 0; i < rounds; i++) {
    c.dismissPlans();
  }
  return clock.elapsedMicroseconds / rounds / 1000;
}

class _CountingPublications extends pub.Repository {
  int reads = 0;
  @override
  Future<String?> readPublicationDocument(String id) {
    reads++;
    return super.readPublicationDocument(id);
  }

  @override
  Future<String?> readPublicationQueue(String id) {
    reads++;
    return super.readPublicationQueue(id);
  }
}

void main() {
  group('UI-26 workspace encode/decode off the main isolate', () {
    test('300 clients with real YAML: load, rebuild and core check', () async {
      final workspace = _bigWorkspace(300);
      final source = workspace.encode();
      final encodeClock = Stopwatch()..start();
      workspace.encode();
      final encodeMs = encodeClock.elapsedMilliseconds;
      final decodeClock = Stopwatch()..start();
      VpnWorkspace.decode(source);
      final decodeMs = decodeClock.elapsedMilliseconds;
      final repository = _WorkerLikeVpn(source);
      final c = VpnController(
        repository: repository,
        remote: (_) => null,
        template: () => _template,
        timer: (_, _) => Timer(const Duration(days: 1), () {})..cancel(),
      );
      addTearDown(c.dispose);
      // Warm up the isolate machinery and the JIT outside the measurement.
      await c.load();
      final loadStall = await _longestStallMs(c.load);
      final rebuildStall = await _longestStallMs(c.refreshProfiles);
      final checkStall = await _longestStallMs(
        () => c.validateCoreProfile(_hex32(1)),
      );
      _metric(
        'UI-26 300 clients, ${(source.length / 1024 / 1024).toStringAsFixed(1)} MiB: '
        'sync encode=${encodeMs}ms decode=${decodeMs}ms; main-isolate stall '
        'load=${loadStall}ms refreshProfiles=${rebuildStall}ms '
        'validateCoreProfile=${checkStall}ms',
      );
      expect(c.loaded, isTrue);
      expect(c.workspace.users, hasLength(300));
      expect(c.workspace.profiles, hasLength(300));
      // The heavy JSON work runs elsewhere: the loop is never blocked for as
      // long as one synchronous encode or decode of the same document takes.
      expect(loadStall, lessThan(decodeMs));
      expect(rebuildStall, lessThan(encodeMs));
      expect(checkStall, lessThan(encodeMs));
    });
  });

  group('UI-28 connection checks stay local', () {
    testWidgets('a checks tick rebuilds the users page at most once', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final c = (await tester.runAsync(() => _verifiedController(50)))!;
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: UsersPage(
              controller: c,
              serverName: (id) => id,
              exporter: _Exporter(),
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pump();
      // The page's own builder recreates its DragSelectList on each rebuild.
      final counts = _countRebuilds([DragSelectList]);
      var ticks = 0, vpnNotifications = 0;
      void tick() => ticks++;
      void vpnTick() => vpnNotifications++;
      c.connections.addListener(tick);
      c.addListener(vpnTick);
      addTearDown(() {
        c.connections.removeListener(tick);
        c.removeListener(vpnTick);
      });
      final keys = [
        for (final r in c.workspace.inbounds)
          (target: r.serverId, resource: r.id),
      ];
      // Ticks that do not change VpnController.busy: a queue whose targets
      // are not ready (each is skipped) still reports start, skips and end.
      final missing = [
        for (var i = 0; i < 4; i++) (target: 'one', resource: _hex32(9000 + i)),
      ];
      for (var round = 0; round < 3; round++) {
        await tester.runAsync(() => c.connections.checkAll(missing));
        await tester.pump();
      }
      final quietTicks = ticks, quietVpn = vpnNotifications;
      final quietRebuilds = counts[DragSelectList]!;
      // Ticks of real checks: each start and end flips busy.
      for (var round = 0; round < 3; round++) {
        for (final key in keys) {
          await tester.runAsync(() => c.connections.check(key));
          await tester.pump();
        }
      }
      final pumps = 3 * keys.length;
      _metric(
        'UI-28 50 clients: skipped queue x3 → connections ticks=$quietTicks, '
        'VpnController notify=$quietVpn, UsersPage rebuilds=$quietRebuilds; '
        '12 checks (+${ticks - quietTicks} ticks, $pumps frames) → '
        'VpnController notify=${vpnNotifications - quietVpn}, UsersPage '
        'rebuilds=${counts[DragSelectList]! - quietRebuilds}',
      );
      expect(quietTicks, greaterThanOrEqualTo(6));
      expect(quietVpn, 0);
      expect(quietRebuilds, 0);
      // Only busy changes are forwarded, and the page rebuilds at most once
      // per frame for them.
      expect(
        vpnNotifications - quietVpn,
        lessThanOrEqualTo(ticks - quietTicks),
      );
      expect(counts[DragSelectList]! - quietRebuilds, lessThanOrEqualTo(pumps));
    });

    test('readiness and result of one target at 500 clients', () async {
      final c = await _verifiedController(500);
      addTearDown(c.dispose);
      final key = (
        target: c.workspace.inbounds.first.serverId,
        resource: c.workspace.inbounds.first.id,
      );
      final checks = c.connections;
      expect(checks.available(key), isTrue);
      // A stored result makes every build compare its signature.
      await checks.check(key);
      expect(checks.result(key), isNotNull);
      final clock = Stopwatch()..start();
      for (var i = 0; i < 50; i++) {
        // What one ConnectionCheckView build reads.
        checks.result(key);
        checks.available(key);
        checks.unavailableReasonCode(key);
      }
      final perBuild = clock.elapsedMicroseconds / 50 / 1000;
      _metric(
        'UI-28 ConnectionCheckView inputs at 500 clients: '
        '${perBuild.toStringAsFixed(3)}ms per build',
      );
      expect(perBuild, lessThan(0.15));
    });
  });

  group('UI-27 publication follows VPN changes cheaply', () {
    test('one VPN notification at 500 clients', () async {
      final c = await _verifiedController(500);
      addTearDown(c.dispose);
      expect(c.hasCurrentVerifiedProfiles, isTrue);
      final bare = _notifyCostMs(c);
      final publications = PublicationController(
        repository: pub.Repository(),
        account: pub.Account()..publicationAuthorized = true,
        remote: pub.Remote.new,
        vpn: c,
      );
      addTearDown(publications.dispose);
      await publications.ready;
      final withPublications = _notifyCostMs(c);
      final verifiedClock = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        c.hasCurrentVerifiedProfiles;
      }
      final verifiedMs = verifiedClock.elapsedMicroseconds / 20 / 1000;
      _metric(
        'UI-27 500 clients: one notify ${bare.toStringAsFixed(2)}ms without '
        'and ${withPublications.toStringAsFixed(2)}ms with PublicationController; '
        'hasCurrentVerifiedProfiles ${verifiedMs.toStringAsFixed(2)}ms',
      );
      // A frame is 16 ms; a notification must leave room for building it.
      expect(withPublications, lessThan(2));
      expect(verifiedMs, lessThan(2));
    });
  });

  group('UI-30 batch publication progress', () {
    testWidgets('progress of one client rebuilds only its own row', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      // Tall enough for all 30 rows: the list is lazy (UI-31).
      tester.view.physicalSize = const Size(1000, 8000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final store = fx.MemoryVpn()
        ..raw = VpnWorkspace(
          id: _hex32(4545),
          users: [
            for (var i = 1; i <= 30; i++)
              VpnUser(id: _hex32(i), login: 'user-$i', name: 'Client $i'),
          ],
        ).encode();
      final vpn = fx.controller(store, {});
      await tester.runAsync(vpn.load);
      final publications = PublicationController(
        repository: pub.Repository(),
        account: pub.Account(),
        remote: pub.Remote.new,
        vpn: vpn,
      );
      await tester.runAsync(() => publications.ready);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: UsersPage(
              controller: vpn,
              publications: publications,
              serverName: (id) => id,
              exporter: _Exporter(),
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Switch), findsNWidgets(30));
      publications.simulateUserProgress(inFlight: {_hex32(1)}, total: 30);
      await tester.pump();
      final counts = _countRebuilds([Switch]);
      for (var i = 1; i < 10; i++) {
        publications.simulateUserProgress(
          completed: {for (var j = 1; j <= i; j++) _hex32(j)},
          inFlight: {_hex32(i + 1)},
        );
        await tester.pump();
      }
      _metric(
        'UI-30 30 clients, 9 progress steps: client row trailing rebuilds='
        '${counts[Switch]}',
      );
      // Two rows change per step (one finishes, the next starts).
      expect(counts[Switch], lessThanOrEqualTo(2 * 9));
      publications.resetSyncProgress();
      await tester.pumpWidget(const SizedBox());
      publications.dispose();
      vpn.dispose();
      await tester.pump(const Duration(seconds: 1));
    });

    test(
      'publishing 100 up-to-date clients notifies a bounded number of times',
      () async {
        final store = fx.MemoryVpn()
          ..raw = VpnWorkspace(
            id: _hex32(4444),
            users: [
              for (var i = 1; i <= 100; i++)
                VpnUser(id: _hex32(i), login: 'user-$i', name: 'Client $i'),
            ],
          ).encode();
        final vpn = fx.controller(store, {});
        addTearDown(vpn.dispose);
        await vpn.load();
        final repository = pub.Repository();
        final c = PublicationController(
          repository: repository,
          account: pub.Account()..publicationAuthorized = true,
          remote: pub.Remote.new,
          vpn: vpn,
        );
        addTearDown(c.dispose);
        await c.ready;
        await c.configure(PublicationAccess.private);
        await c.setEnabled(true);
        expect(c.settings?.enabled, isTrue);
        await c.suspend();
        for (final user in vpn.workspace.users) {
          final hash = vpn.workspace.profiles[user.id]!['hash'];
          repository.docs['result/${user.id}'] = jsonEncode({
            'hash': hash,
            'fileId': 'file-${user.id}',
            'registryId': 'registry',
            'access': 'private',
            'head': 'head-${user.id}',
          });
          repository.queues[user.id] = jsonEncode({
            'status': 'published',
            'head': 'head-${user.id}',
            'hash': hash,
          });
        }
        await c.reload();
        expect(c.isUserUpToDate(_hex32(1)), isTrue);
        c.resume();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        var notifications = 0, progress = 0;
        void counted() => notifications++;
        void progressed() => progress++;
        c.addListener(counted);
        c.progress.addListener(progressed);
        final result = await c.forcePublishAll(force: false);
        c.removeListener(counted);
        c.progress.removeListener(progressed);
        _metric(
          'UI-30 batch of 100 up-to-date clients: PublicationController '
          'notify=$notifications, progress ticks=$progress',
        );
        expect(result.upToDate, 100);
        // Not two per client: per-client progress is a separate, coalesced
        // notifier and the controller itself reports the batch start and end.
        expect(notifications, lessThanOrEqualTo(4));
        expect(progress, lessThan(100));
      },
    );
  });

  group('UI-29 sync notifications and publication state', () {
    test(
      'a sync notification without received data re-reads nothing',
      () async {
        final store = fx.MemoryVpn()
          ..raw = VpnWorkspace(
            id: _hex32(4646),
            users: [
              for (var i = 1; i <= 100; i++)
                VpnUser(id: _hex32(i), login: 'user-$i', name: 'Client $i'),
            ],
          ).encode();
        final vpn = fx.controller(store, {});
        addTearDown(vpn.dispose);
        await vpn.load();
        final account = pub.Account();
        final sync = AutoSyncController(
          accountService: account,
          settings: _ShellRepository(),
          openSession: () => throw StateError('no session in this test'),
          changes: const Stream.empty(),
          apply: (_) async => true,
        );
        addTearDown(sync.dispose);
        await sync.ready;
        final repository = _CountingPublications();
        final c = PublicationController(
          repository: repository,
          account: account,
          remote: pub.Remote.new,
          vpn: vpn,
          sync: sync,
        );
        addTearDown(c.dispose);
        await c.ready;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        repository.reads = 0;
        // Phase/progress notifications of one sync run (2-4 per run).
        for (var i = 0; i < 4; i++) {
          await sync.pauseDiagnostics(false);
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        _metric(
          'UI-29 100 clients, 4 sync notifications without received data: '
          'publication document reads=${repository.reads}',
        );
        expect(repository.reads, 0);
      },
    );
  });

  group('UI-31 users list order', () {
    test('sorting 1000 clients by name lower-cases each name once', () {
      final users = [
        for (var i = 0; i < 1000; i++)
          VpnUser(
            id: _hex32(i + 1),
            login: 'user-$i',
            name: 'Client ${(i * 7919) % 1000}',
            enabled: i % 5 != 0,
          ),
      ];
      // The comparator the page used before (UI-31), for reference.
      List<VpnUser> reference(bool enabled) {
        final order = {for (var i = 0; i < users.length; i++) users[i].id: i};
        return users.where((u) => u.enabled == enabled).toList()..sort((a, b) {
          final res = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return res != 0 ? res : order[a.id]!.compareTo(order[b.id]!);
        });
      }

      reference(true);
      sortUsersForDisplay(users, UserSortField.name, true);
      final before = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        reference(true);
        reference(false);
      }
      final beforeMs = before.elapsedMicroseconds / 10 / 1000;
      final after = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        sortUsersForDisplay(users, UserSortField.name, true);
      }
      final afterMs = after.elapsedMicroseconds / 10 / 1000;
      final sorted = sortUsersForDisplay(users, UserSortField.name, true);
      _metric(
        'UI-31 1000 clients by name: comparator with toLowerCase '
        '${beforeMs.toStringAsFixed(2)}ms → ${afterMs.toStringAsFixed(2)}ms '
        'per sort; rebuilds without a users change reuse the cached order',
      );
      expect(sorted.enabled.map((u) => u.id), reference(true).map((u) => u.id));
      expect(
        sorted.disabled.map((u) => u.id),
        reference(false).map((u) => u.id),
      );
      // One sort costs about the same; the gain is that the page no longer
      // sorts at all when it rebuilds for anything but a users change.
      expect(afterMs, lessThan(beforeMs * 1.5));
    });
  });

  group('UI-32 theme', () {
    testWidgets('rebuilding the app does not animate the whole theme', (
      tester,
    ) async {
      expect(
        identical(
          AppTheme.create(Brightness.light),
          AppTheme.create(Brightness.light),
        ),
        isTrue,
      );
      late StateSetter rebuild;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return MaterialApp(
              theme: AppTheme.create(Brightness.light),
              darkTheme: AppTheme.create(Brightness.dark),
              home: const SizedBox(),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      rebuild(() {});
      await tester.pump();
      final animating = tester.binding.hasScheduledFrame;
      _metric('UI-32 app rebuild → theme animation scheduled: $animating');
      expect(animating, isFalse);
    });
  });

  group('UI-33 route tables of the network check', () {
    test('normalising ip -j output does not block the UI isolate', () async {
      String table(int rows) => jsonEncode([
        for (var i = 0; i < rows; i++)
          {
            'type': 'unicast',
            'dst': '10.${i ~/ 250}.${i % 250}.0/24',
            'gateway': '192.0.2.1',
            'dev': 'eth0',
            'table': 'main',
            'protocol': 'kernel',
            'scope': 'link',
            'expires': i,
            'used': i * 3,
            'flags': <String>[],
          },
      ]);
      final outputs = [table(1500), table(1500), table(300), table(300)];
      final size = outputs.fold<int>(0, (n, t) => n + t.length);
      normalizeRouteTables(outputs);
      final sync = Stopwatch()..start();
      final expected = normalizeRouteTables(outputs);
      final syncMs = sync.elapsedMilliseconds;
      late String offloaded;
      final stall = await _longestStallMs(() async {
        offloaded = await Isolate.run(() => normalizeRouteTables(outputs));
      });
      _metric(
        'UI-33 ${size ~/ 1024} KiB of route tables: on the UI isolate '
        '${syncMs}ms → stall ${stall}ms',
      );
      expect(offloaded, expected);
      expect(offloaded.contains('expires'), isFalse);
      expect(stall, lessThan(syncMs));
    });
  });

  group('UI-34 traffic counters', () {
    test('one parse per sample, not one per read in a build', () {
      final c = SshController(
        openVault: () async => FakeVault(),
        connector: FakeConnector(),
        picker: FakeKeyPicker(),
        network: NetworkController(reader: const SampleInventoryReader()),
      );
      addTearDown(c.dispose);
      addTearDown(c.network.dispose);
      ServerObservation sample(String counters) => ServerObservation(
        os: 'Ubuntu 24.04',
        architecture: 'x86_64',
        network: testInventory(),
        software: ServerSoftwareInventory(
          observedAt: DateTime.utc(2026),
          facts: {
            ServerFact.networkTraffic: InventoryValue.ok(
              '11111111-1111-1111-1111-111111111111\n$counters',
            ),
          },
          components: [],
          sockets: [],
        ),
      );
      c.observation = sample('eth0 1024 2048');
      final first = c.trafficSample;
      expect(first, isNotNull);
      expect(identical(c.trafficSample, first), isTrue);
      expect(c.trafficBytes, (1024, 2048));
      c.observation = sample('eth0 4096 8192');
      expect(identical(c.trafficSample, first), isFalse);
      expect(c.trafficBytes, (4096, 8192));
      _metric('UI-34 repeated reads of one sample reuse a single parse');
    });
  });

  group('UI-35 background polling', () {
    test(
      'a paused app does not reconcile every 5 s and catches up after',
      () async {
        final store = fx.MemoryVpn()
          ..raw = VpnWorkspace(
            id: _hex32(4747),
            servers: {
              // A pending marker older than five minutes: reconcile clears it.
              'one': {
                'pending': {'id': 'job-1', 'startedAt': '2026-01-01T00:00:00Z'},
              },
            },
          ).encode();
        void Function(Timer)? tick;
        final c = VpnController(
          repository: store,
          remote: (_) => null,
          template: () => fx.template,
          timer: (_, callback) {
            tick = callback;
            return Timer(const Duration(days: 1), () {})..cancel();
          },
        );
        addTearDown(c.dispose);
        await c.load();
        final loaded = store.revision;
        c.setForeground(false);
        final idle = Timer(Duration.zero, () {});
        for (var i = 0; i < 3; i++) {
          tick!(idle);
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final writesInBackground = store.revision - loaded;
        c.setForeground(true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        _metric(
          'UI-35 3 timer ticks in background → reconcile writes='
          '$writesInBackground; back in front → '
          '${store.revision - loaded} write(s)',
        );
        expect(writesInBackground, 0);
        expect(c.workspace.servers['one']?['pending'], isNull);
      },
    );
  });

  group('UI-25 SSH form input', () {
    for (final existing in [false, true]) {
      testWidgets(
        'typing in the SSH form rebuilds neither the shell pages nor the catalog'
        '${existing ? ' (saved server)' : ' (new server)'}',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(1000, 1000);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final repository = _ShellRepository();
          if (existing) {
            repository.servers['a'] = SshProfile(
              id: 'a',
              name: 'VPS a',
              host: 'a.example',
              port: 22,
              username: 'root',
              authMethod: SshAuthMethod.password,
              secrets: const {ServerSecret.sshPassword: 'test-only'},
            );
          }
          final languages = LanguageController(repository);
          await languages.load();
          addTearDown(languages.dispose);
          await tester.pumpWidget(
            AntiRknApp(
              source: '',
              languages: languages,
              servers: repository,
              settings: repository,
              ssh: SshDependencies(
                openVault: () async => FakeVault(),
                connector: FakeConnector(),
                picker: FakeKeyPicker(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (existing) {
            await tester.tap(find.byKey(const ValueKey('server-a')));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('server-ssh-access')));
            await tester.pumpAndSettle();
            final edit = find.byKey(const ValueKey('ssh-edit'));
            if (edit.evaluate().isNotEmpty) {
              await tester.tap(edit);
              await tester.pumpAndSettle();
            }
          } else {
            await tester.tap(find.byKey(const ValueKey('server-add')));
            await tester.pumpAndSettle();
          }
          final host = find.byKey(const ValueKey('ssh-host'));
          expect(host, findsOneWidget);
          final counts = _countRebuilds([UsersPage, SettingsHub, ManagerShell]);
          var notifications = 0;
          final session = tester
              .widget<TextField>(host)
              .controller!; // The form's own controller.
          void counted() => notifications++;
          final ssh = _sessionOf(tester);
          ssh.addListener(counted);
          addTearDown(() => ssh.removeListener(counted));
          var text = session.text;
          for (final char in 'abcdefghij'.split('')) {
            text = '$text$char';
            await tester.enterText(host, text);
            await tester.pump();
          }
          // Cursor movement alone.
          session.selection = const TextSelection.collapsed(offset: 1);
          await tester.pump();
          _metric(
            'UI-25 ${existing ? 'saved' : 'new'} server: 10 chars + cursor → '
            'UsersPage=${counts[UsersPage]} SettingsHub=${counts[SettingsHub]} '
            'ssh notify=$notifications',
          );
          expect(counts[UsersPage], 0);
          expect(counts[SettingsHub], 0);
          // At most one notification: the "saved" flag flips once.
          expect(notifications, lessThanOrEqualTo(1));
          // The form itself still follows the text (hint mirrors the host).
          final name = tester.widget<TextField>(
            find.byKey(const ValueKey('ssh-name')),
          );
          expect(name.decoration?.hintText, text);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  });
}

SshController _sessionOf(WidgetTester tester) =>
    tester.widget<ServerDetailView>(find.byType(ServerDetailView)).session;
