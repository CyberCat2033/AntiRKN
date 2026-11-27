import 'dart:async';
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/sync/restored_cache_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'auto_sync_test.dart' show Settings;
import 'vpn_controller_test.dart'
    show MemoryVpn, Remote, alice, bob, inbound, panel, template;
import 'package:antirkn_manager/vpn/vpn_controller.dart';

/// A device that pulled the snapshot: intent and bindings, no observations
/// for server one, a dated cache for server two.
String _restored({Map<String, dynamic> one = const {}}) {
  final workspace = VpnWorkspace(
    id: 'cccccccccccccccccccccccccccccccc',
    users: [VpnUser(id: alice, login: 'alice', name: 'Alice')],
    inbounds: [inbound('one', '1' * 32), inbound('two', '2' * 32)],
    servers: {
      'one': {'identity': 'identity-one', 'panelId': panel, ...one},
      'two': {
        'identity': 'identity-two',
        'panelId': panel,
        'observed': <Object>[],
        'verifiedAt': '2026-11-20T10:00:00.000Z',
      },
    },
  );
  return workspace.encode();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a restored device reads servers again in the background; one that does not answer keeps its dated cache',
    () async {
      final store = MemoryVpn()
        ..raw = _restored()
        ..revision = 1;
      final remotes = <String, Remote>{};
      final vpn = VpnController(
        repository: store,
        template: () => template,
        remote: (id) => remotes[id] == null
            ? null
            : VpnRemote(
                transport: remotes[id]!,
                panelId: panel,
                identity: 'identity-$id',
              ),
        timer: (d, f) => Timer(Duration.zero, () {}),
      );
      await vpn.load();
      final settings = Settings()
        ..values[restoredCacheSetting] = jsonEncode(['one', 'two']);
      final unreachable = Completer<bool>();
      final refresh = RestoredCacheRefresh(
        settings: settings,
        connect: (id) async {
          if (id == 'two') return unreachable.future;
          remotes[id] = Remote(store)
            ..customState = [
              {
                'id': '1' * 32,
                'workspaceId': vpn.workspace.resourceWorkspaceId('one'),
                'spec': inbound('one', '1' * 32).spec,
                'confirmed': true,
                'revision': 'f' * 64,
                'clients': <Object>[],
              },
            ];
          return true;
        },
        refresh: vpn.refreshConnectedInBackground,
        observedSince: vpn.serverObservedSince,
        observedAt: vpn.serverObservedAt,
        known: (id) => true,
        retryDelay: Duration.zero,
      );
      expect(vpn.serverObservedAt('one'), isNull);
      final running = refresh.start();
      for (var i = 0; i < 200 && vpn.serverObservedAt('one') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await vpn.waitForBackgroundReconcile();
      // Server one was read with the state request only; nothing submitted.
      expect(remotes['one']!.actions, everyElement('vless_state'));
      expect(vpn.serverObservedAt('one'), isNotNull);
      expect(refresh.running, isTrue);
      // The unanswered connection holds neither VPN work nor the interface.
      expect(vpn.busy, isFalse);
      await vpn.saveUser(VpnUser(id: bob, login: 'bob', name: 'Bob'));
      expect(vpn.workspace.userById(bob), isNotNull);
      unreachable.complete(false);
      await running;
      expect(refresh.running, isFalse);
      expect(refresh.failed, {'two'});
      expect(jsonDecode(settings.values[restoredCacheSetting]!), ['two']);
      expect(refresh.staleSince, DateTime.utc(2026, 11, 20, 10));
      vpn.dispose();
      refresh.dispose();
    },
  );

  test(
    'servers read in parallel wait for each other instead of being reported as not answering',
    () async {
      final store = MemoryVpn()
        ..raw = _restored()
        ..revision = 1;
      final remotes = <String, Remote>{};
      final vpn = VpnController(
        repository: store,
        template: () => template,
        remote: (id) => remotes[id] == null
            ? null
            : VpnRemote(
                transport: remotes[id]!,
                panelId: panel,
                identity: 'identity-$id',
              ),
        timer: (d, f) => Timer(Duration.zero, () {}),
      );
      await vpn.load();
      final settings = Settings()
        ..values[restoredCacheSetting] = jsonEncode(['one', 'two']);
      final refresh = RestoredCacheRefresh(
        settings: settings,
        connect: (id) async {
          remotes[id] = _SlowRemote(store)
            ..customState = [
              {
                'id': (id == 'one' ? '1' : '2') * 32,
                'workspaceId': vpn.workspace.resourceWorkspaceId(id),
                'spec': inbound(id, (id == 'one' ? '1' : '2') * 32).spec,
                'confirmed': true,
                'revision': 'f' * 64,
                'clients': <Object>[],
              },
            ];
          return true;
        },
        refresh: vpn.refreshConnectedInBackground,
        observedSince: vpn.serverObservedSince,
        observedAt: vpn.serverObservedAt,
        known: (id) => true,
        retryDelay: Duration.zero,
      );
      await refresh.start();
      expect(refresh.failed, isEmpty);
      expect(jsonDecode(settings.values[restoredCacheSetting]!), isEmpty);
      vpn.dispose();
      refresh.dispose();
    },
  );

  test(
    'a connected server whose target cannot be read reports that reason',
    () async {
      final store = MemoryVpn()
        ..raw = _restored()
        ..revision = 1;
      final vpn = VpnController(
        repository: store,
        template: () => template,
        remote: (id) => null,
        remoteIssue: (id) => 'vpn_panel_login',
        timer: (d, f) => Timer(Duration.zero, () {}),
      );
      await vpn.load();
      final settings = Settings()
        ..values[restoredCacheSetting] = jsonEncode(['one']);
      final refresh = RestoredCacheRefresh(
        settings: settings,
        connect: (_) async => true,
        refresh: vpn.refreshConnectedInBackground,
        observedSince: vpn.serverObservedSince,
        observedAt: vpn.serverObservedAt,
        known: (_) => true,
        retryDelay: Duration.zero,
      );
      await refresh.start();
      expect(refresh.failed, {'one'});
      expect(refresh.issues, {'one': 'vpn_panel_login'});
      expect(jsonDecode(settings.values[restoredCacheSetting]!), ['one']);
      vpn.dispose();
      refresh.dispose();
    },
  );

  // `null`: the record keeps the operation as the last owner but no job at
  // all (a target the operation did not touch, or a forgotten job).
  for (final (status, read) in [
    ('succeeded', true),
    ('running', false),
    (null, true),
  ]) {
    test(
      'another device\'s ${status ?? 'jobless'} operation ${read ? 'does not hold' : 'holds'} the read',
      () async {
        final store = MemoryVpn()
          ..raw = _restored(
            one: {
              // The executor keeps the operation as the last owner.
              'operation': {
                'version': 1,
                'operationId': '9' * 32,
                'executorDeviceId': 'a' * 32,
              },
              if (status != null)
                'job': {
                  'id': '9' * 32,
                  'kind': 'vless_apply',
                  'count': 2,
                  'interval': 1,
                  'status': status,
                  'checkpoint': read ? 2 : 1,
                  'sequence': 1,
                  'cancelRequested': false,
                  'events': <Object?>[],
                },
            },
          )
          ..revision = 1;
        final transport = Remote(store)
          ..customState = [
            {
              'id': '1' * 32,
              'workspaceId': 'c' * 32,
              'spec': inbound('one', '1' * 32).spec,
              'confirmed': true,
              'revision': 'f' * 64,
              'clients': <Object>[],
            },
          ];
        final vpn = VpnController(
          repository: store,
          template: () => template,
          remote: (id) => id == 'one'
              ? VpnRemote(
                  transport: transport,
                  panelId: panel,
                  identity: 'identity-one',
                )
              : null,
          timer: (d, f) => Timer(Duration.zero, () {}),
        );
        await vpn.load();
        expect(vpn.observesOperation('one'), isTrue);
        expect(vpn.followsOpenOperation('one'), !read);
        if (read && status != null) {
          // A runner that has forgotten an ended job offers no takeover.
          vpn.observedJobs['one'] = null;
          expect(vpn.followsOpenOperation('one'), isFalse);
          vpn.observedJobs.remove('one');
        }
        final since = DateTime.now().toUtc();
        final issues = await vpn.refreshConnectedInBackground(['one']);
        expect(vpn.serverObservedSince('one', since), read);
        expect(issues, read ? isEmpty : {'one': 'vpn_observing'});
        vpn.dispose();
      },
    );
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'stale server data says how old it is (${locale.languageCode})',
      (tester) async {
        final settings = Settings()
          ..values[restoredCacheSetting] = jsonEncode(['two']);
        final refresh = RestoredCacheRefresh(
          settings: settings,
          connect: (_) async => true,
          refresh: (_) async => {'two': 'vpn_panel_login'},
          observedSince: (_, _) => false,
          observedAt: (_) => DateTime.utc(2026, 11, 20, 10),
          known: (_) => true,
          serverName: (_) => 'NL',
        );
        await tester.runAsync(refresh.start);
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(body: RestoredCacheNotice(refresh: refresh)),
          ),
        );
        final l = lookupAppLocalizations(locale);
        expect(
          find.byKey(const ValueKey('restored-cache-stale')),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            l.restoredCacheStale(1, '').split('{').first.substring(0, 10),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('2026'), findsOneWidget);
        // The server is named with its own reason, not "not answering".
        expect(
          find.textContaining(
            l.restoredCacheServerIssue('NL', l.vpnPanelLogin),
          ),
          findsOneWidget,
        );
        expect(find.text(l.vaultRetry), findsOneWidget);
        refresh.dispose();
      },
    );
  }
}

/// A server whose state read takes a while, as over a real SSH connection.
class _SlowRemote extends Remote {
  _SlowRemote(super.store);
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken token, {
    String? sudoPassword,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return super.request(request, token, sudoPassword: sudoPassword);
  }
}
