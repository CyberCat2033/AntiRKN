import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/network/android_ip_probe_transport.dart';
import 'package:antirkn_manager/ssh/server_about_view.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'ssh_support.dart';
import 'package:antirkn_manager/settings_hub.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Languages implements LanguagePreferenceStore {
  @override
  Future<AppLanguage> readLanguage() async => AppLanguage.en;
  @override
  Future<void> writeLanguage(AppLanguage value) async {}
}

class DiagnosticServers implements ServerRepository {
  final saved = SshProfile(
    id: 'fixture',
    name: 'Diagnostic fixture',
    host: 'server.example',
    port: 2222,
    username: 'test',
    authMethod: SshAuthMethod.password,
    lastInfo: ServerInfo(
      os: 'Ubuntu',
      architecture: 'x86_64',
      observedAt: DateTime.utc(2026, 9, 17),
      publicAddresses: [
        IpAddress.parse('93.184.215.15'),
        IpAddress.parse('2606:4700::1111'),
      ],
    ),
  );
  @override
  bool get needsLegacyPassword => false;
  @override
  Future<void> migrateLegacy({String? password}) async {}
  @override
  Future<List<SavedServer>> listServers() async => [
    SavedServer('fixture', saved, 1),
  ];
  @override
  Future<SecretVault> openServer(String id) async => FakeVault()
    ..mode = VaultMode.system
    ..saved = saved;
  @override
  String newServerId() => 'unused';
  @override
  Future<void> deleteServers(
    List<SavedServer> expected, {
    bool detachJumpReferences = false,
  }) async {}
}

void main() {
  for (final cancel in ['background', 'back', 'stop']) {
    testWidgets(
      'three shell destinations, About-only diagnostics and cancellation by $cancel',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final languages = LanguageController(Languages());
        await languages.load();
        final pending = Completer<Map<String, dynamic>>();
        var probes = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidIpProbeTransport.channel, (
              call,
            ) async {
              if (call.method == 'network') {
                return {
                  'identity': 'fixture',
                  'kind': 'wifi',
                  'vpn': false,
                  'bound': true,
                };
              }
              if (call.method == 'probe') {
                probes++;
                return pending.future;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(AndroidIpProbeTransport.channel, null),
        );
        final servers = DiagnosticServers();
        await tester.pumpWidget(
          AntiRknApp(
            source: '',
            languages: languages,
            servers: servers,
            ssh: SshDependencies(
              openVault: () => servers.openServer('fixture'),
              connector: FakeConnector(),
              picker: FakeKeyPicker(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
          hasLength(3),
        );
        expect(find.byIcon(Icons.network_check), findsNothing);
        await tester.tap(find.byKey(const ValueKey('server-fixture')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('server-about')));
        // ensureVisible scrolls without a frame; lay out before tapping.
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('server-about')));
        await tester.pumpAndSettle();
        expect(find.byType(ServerAboutView), findsOneWidget);
        expect(probes, 0);
        final c = tester
            .widget<ServerAboutView>(find.byType(ServerAboutView))
            .diagnostics!;
        await tester.tap(find.byKey(const ValueKey('server-ip-diagnostics')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('diagnostics-start')));
        await tester.pump(const Duration(milliseconds: 500));
        expect(c.busy, isTrue);
        expect(probes, greaterThan(0));
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .onDestinationSelected,
          isNull,
        );
        if (cancel == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        } else if (cancel == 'back') {
          await tester.tap(find.byKey(const ValueKey('server-list-back')));
        } else {
          await tester.tap(find.byKey(const ValueKey('server-ip-diagnostics')));
        }
        await tester.pumpAndSettle();
        expect(c.busy, isFalse);
        expect(c.current!.stage, IpDiagnosticStage.cancelled);
        pending.complete({'status': 'reachable', 'ms': 1});
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        final count = probes;
        await tester.pump(const Duration(seconds: 1));
        expect(probes, count);
        await tester.tap(find.byKey(const ValueKey('server-list-back')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('server-list-back')));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsHub), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        languages.dispose();
      },
    );
  }
}
