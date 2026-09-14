import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/component_updates_controller.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:antirkn_manager/vpn/observed_inbound_dialog.dart';
import 'package:antirkn_manager/vpn/xhttp_options_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'component_updates_test.dart' show Source;
import 'runner_support.dart';

void main() {
  test(
    'XHTTP defaults match panel and retain an existing concurrency strategy',
    () {
      final defaults = xhttpFormDefaults();
      expect(defaults['xPaddingBytes'], '100-1000');
      expect(defaults['scMaxBufferedPosts'], 30);
      expect(defaults['serverMaxHeaderBytes'], 0);
      expect(defaults['scMinPostsIntervalMs'], isNull);
      expect((defaults['xmux'] as Map)['maxConnections'], '3');
      expect((defaults['xmux'] as Map)['hMaxRequestTimes'], '600-900');
      final existing = xhttpFormDefaults({
        'xmux': {'maxConcurrency': '16-32'},
      });
      expect((existing['xmux'] as Map)['maxConnections'], '0');
      expect((existing['xmux'] as Map)['maxConcurrency'], '16-32');
      final spec = {
        ...VlessInbound.defaults(),
        'transport': 'xhttp',
        'xhttp': defaults,
      };
      validateXhttpOptions(spec);
    },
  );
  test(
    'external inbound edits contain only changed fields, without old keys',
    () {
      final original = {
        'streamSettings': {
          'realitySettings': {
            'privateKey': 'secret',
            'serverNames': ['example.com'],
          },
          'xhttpSettings': {'path': '/old', 'unknown': 42},
        },
      };
      final modified = {
        'streamSettings': {
          'realitySettings': {
            'privateKey': 'secret',
            'serverNames': ['example.com'],
          },
          'xhttpSettings': {'path': '/new', 'unknown': 42},
        },
      };
      expect(changedFields(original, modified), {
        'streamSettings': {
          'xhttpSettings': {'path': '/new'},
        },
      });
    },
  );
  for (final locale in ['ru', 'en']) {
    for (final width in [390.0, 1400.0]) {
      testWidgets(
        'installed software has relevant actions and private access $locale $width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1100);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final store = MemoryRunnerJournal();
          final remote = FakeRunnerTransport(store)..installed = true;
          final versions = ['3.7.0', '26.7.28', '1.1.0', '3.1.20260828'];
          final c = RunnerController(
            serverId: 'fixture',
            transport: () => remote,
            identity: () => 'fixture',
            password: () => null,
            accessFailure: (_) {},
            store: store,
            software: () => ServerSoftwareInventory(
              observedAt: DateTime.now(),
              facts: {},
              sockets: [],
              components: [
                for (var i = 0; i < VpnComponent.values.length; i++)
                  ComponentObservation(
                    component: VpnComponent.values[i],
                    presence: ComponentPresence.detected,
                    issues: [],
                    installations: [
                      ComponentInstallation(
                        source: InstallationSource.binary,
                        identity: '/bin/component',
                        version: InventoryValue.ok(versions[i]),
                      ),
                    ],
                  ),
              ],
            ),
          );
          await c.refresh();
          c.panelAccess = PanelAccess.fromJson({
            'id': 'a' * 32,
            'port': 43127,
            'basePath': '/${'b' * 24}/',
            'username': 'antirkn',
            'password': 'A' * 43,
            'panelVersion': '3.7.0',
            'xrayVersion': '26.7.28',
          });
          c.selected = runnerJob('a' * 32, status: 'succeeded', progress: 10);
          c.jobs = [c.selected!, runnerJob('b' * 32, status: 'succeeded')];
          final updates = ComponentUpdatesController(source: Source())
            ..latest = {
              'panel': '3.8.0',
              'xray': '26.8.0',
              'trusttunnel': '1.1.0',
              'amneziawg': '3.1.20260828',
            };
          await tester.pumpWidget(
            ComponentUpdatesScope(
              controller: updates,
              child: MaterialApp(
                locale: Locale(locale),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: const TextScaler.linear(2),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    child: RunnerPanel(
                      controller: c,
                      motion: MotionPreference.system,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('components-choose')), findsNothing);
          expect(
            find.byKey(const ValueKey('component-trusttunnel')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('component-amneziawg')),
            findsNothing,
          );
          expect(find.byType(TextFormField), findsNothing);
          expect(find.text('Job events'), findsNothing);
          expect(find.text('Recent jobs'), findsNothing);
          expect(find.textContaining('3.8.0'), findsOneWidget);
          expect(find.textContaining('26.8.0'), findsOneWidget);
          final access = find.byKey(const ValueKey('panel-access'));
          await tester.ensureVisible(access);
          await tester.tap(access);
          await tester.pumpAndSettle();
          expect(find.byType(TextFormField), findsOneWidget);
          final field = tester.widget<TextFormField>(
            find.byType(TextFormField),
          );
          expect(field.initialValue, 'A' * 43);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
          updates.dispose();
        },
      );
    }
  }
  testWidgets(
    'XHTTP accepts empty upstream enums, preserves unknown options and allows choosing default',
    (tester) async {
      Map<String, Object?>? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: XhttpOptionsEditor(
                initial: {
                  'xPaddingPlacement': '',
                  'uplinkHTTPMethod': 'FUTURE',
                },
                onChanged: (value) => result = value,
                motion: MotionPreference.off,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final extra = find.byKey(const ValueKey('xhttp-extra'));
      await tester.ensureVisible(extra);
      await tester.tap(extra);
      await tester.pumpAndSettle();
      final method = find.byKey(const ValueKey('xhttp-uplinkHTTPMethod'));
      await tester.ensureVisible(method);
      await tester.tap(method);
      await tester.pumpAndSettle();
      expect(find.text('FUTURE'), findsWidgets);
      await tester.tap(find.text('POST').last);
      await tester.pumpAndSettle();
      expect(result!['uplinkHTTPMethod'], 'POST');
      expect(result!['xPaddingPlacement'], '');
      await tester.tap(method);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Default (leave empty)').last);
      await tester.pumpAndSettle();
      expect(result!.containsKey('uplinkHTTPMethod'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'panel login uses panel labels and retains credentials after API refusal',
    (tester) async {
      final store = MemoryRunnerJournal();
      final remote = ObservedRemote(store)..installed = true;
      final c = RunnerController(
        serverId: 'fixture',
        transport: () => remote,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
      await c.refresh();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ObservedInboundDialog(
              controller: c,
              inboundId: 42,
              port: 43127,
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Panel username'), findsOneWidget);
      expect(find.text('SSH user'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('observed-username')),
        'panel-admin',
      );
      await tester.enterText(
        find.byKey(const ValueKey('observed-password')),
        'panel-password',
      );
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.textContaining('3x-ui rejected'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('observed-password')))
            .controller!
            .text,
        'panel-password',
      );
      expect(c.responseCode, 'panel_auth_failed');
      remote.loginAccepted = true;
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Manual inbound'), findsOneWidget);
      expect(find.text('Panel username'), findsNothing);
      expect(store.value, contains('panel-admin'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
  testWidgets(
    'external inbound opens, previews only changed settings and explicitly applies',
    (tester) async {
      final store = MemoryRunnerJournal();
      final remote = ObservedRemote(store)..installed = true;
      final c = RunnerController(
        serverId: 'fixture',
        transport: () => remote,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
      await c.refresh();
      c.panelAccess = PanelAccess.fromJson({
        'id': 'a' * 32,
        'port': 43127,
        'username': 'antirkn',
        'password': 'A' * 43,
        'panelVersion': '3.7.0',
        'xrayVersion': '26.7.28',
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ObservedInboundDialog(
              controller: c,
              inboundId: 42,
              port: 43127,
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Manual inbound'), findsOneWidget);
      expect(find.textContaining('private-original-key'), findsNothing);
      final path = find.byKey(const ValueKey('observed-path'));
      await tester.ensureVisible(path);
      await tester.enterText(path, '/edited');
      final save = find.byKey(const ValueKey('observed-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(remote.submissions, 0);
      final planned =
          remote.requests
                  .lastWhere((r) => r.json['action'] == 'inbound_plan')
                  .json['payload']
              as String;
      expect(planned, contains('/edited'));
      expect(planned, isNot(contains('private-original-key')));
      expect(planned, isNot(contains('existing-client')));
      expect(planned, isNot(contains('xPaddingPlacement')));
      expect(planned, isNot(contains('futureOption')));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(remote.submissions, 1);
      expect(remote.submitWithoutPersistence, isFalse);
      expect(c.selected!.kind, 'inbound_update');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
  test(
    'APT requires a reviewed plan and persists request before submission',
    () async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store)..installed = true;
      final c = RunnerController(
        serverId: 'fixture',
        transport: () => remote,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
      await c.refresh();
      await c.applyApt();
      expect(remote.submissions, 0);
      await c.prepareApt(upgrade: true);
      expect(remote.submissions, 0);
      expect(c.aptPlan!['packages'], hasLength(1));
      await c.applyApt();
      expect(remote.submissions, 1);
      expect(remote.submitWithoutPersistence, isFalse);
      expect(c.selected!.kind, 'apt_upgrade');
      expect(store.value, contains('apt_upgrade'));
      c.dispose();
    },
  );
}

class ObservedRemote extends FakeRunnerTransport {
  ObservedRemote(super.store);
  bool loginAccepted = false;
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    if (request.json['action'] == 'panel_connect') {
      return RunnerResponse.fromJson({
        'version': 1,
        'code': loginAccepted ? 'ok' : 'panel_auth_failed',
        'alive': true,
        'jobs': <Object?>[],
        if (loginAccepted)
          'panelAccess': {
            'id': 'a' * 32,
            'port': 43127,
            'username': 'panel-admin',
            'password': 'panel-password',
            'managed': false,
            'panelVersion': '3.7.0',
            'xrayVersion': '26.7.28',
          },
        'panelVerified': loginAccepted,
      });
    }
    if (request.json['action'] == 'inbound_read' ||
        request.json['action'] == 'inbound_plan') {
      requests.add(request);
      return RunnerResponse.fromJson({
        'version': 1,
        'code': 'ok',
        'alive': true,
        'jobs': <Object?>[],
        if (request.json['action'] == 'inbound_read')
          'inboundSnapshot': {
            'fingerprint': 'c' * 64,
            'row': {
              'id': 42,
              'remark': 'Manual inbound',
              'enable': true,
              'listen': '0.0.0.0',
              'port': 2443,
              'protocol': 'vless',
              'settings': '{"clients":[{"id":"existing-client"}]}',
              'streamSettings':
                  '{"network":"xhttp","security":"reality","xhttpSettings":{"path":"/original","mode":"auto","xPaddingPlacement":"","xPaddingMethod":"","sessionIDPlacement":"","seqPlacement":"","uplinkDataPlacement":"","uplinkHTTPMethod":"","futureOption":"retain"},"realitySettings":{"target":"example.com:443","serverNames":["example.com"],"privateKey":"private-original-key"}}',
            },
          },
        if (request.json['action'] == 'inbound_plan')
          'inboundPlan': {
            'fingerprint': 'd' * 64,
            'inboundId': 42,
            'name': 'Manual inbound',
            'clients': 1,
          },
      });
    }
    return super.request(request, cancellation, sudoPassword: sudoPassword);
  }
}
