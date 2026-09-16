import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/network/android_ip_probe_transport.dart';
import 'package:antirkn_manager/network/ip_diagnostics_page.dart';
import 'package:antirkn_manager/settings_hub.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Languages implements LanguagePreferenceStore {
  @override
  Future<AppLanguage> readLanguage() async => AppLanguage.en;
  @override
  Future<void> writeLanguage(AppLanguage value) async {}
}

void main() {
  testWidgets(
    'shell shows diagnostics, prevents navigation while running and stops in background',
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
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidIpProbeTransport.channel, null),
      );
      await tester.pumpWidget(AntiRknApp(source: '', languages: languages));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations,
        hasLength(4),
      );
      await tester.tap(find.byIcon(Icons.network_check));
      await tester.pumpAndSettle();
      expect(find.byType(IpDiagnosticsPage), findsOneWidget);
      expect(probes, 0);
      final c = tester
          .widget<IpDiagnosticsPage>(find.byType(IpDiagnosticsPage))
          .controller;
      c.seed('1.1.1.1');
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('diagnostics-start')),
      );
      await tester.tap(find.byKey(const ValueKey('diagnostics-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('diagnostics-confirm')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.busy, isTrue);
      expect(probes, greaterThan(0));
      expect(
        tester
            .widget<NavigationBar>(find.byType(NavigationBar))
            .onDestinationSelected,
        isNull,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(c.busy, isFalse);
      expect(c.current!.stage, IpDiagnosticStage.cancelled);
      pending.complete({'status': 'reachable', 'ms': 1});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      final count = probes;
      await tester.pump(const Duration(seconds: 1));
      expect(probes, count);
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHub), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      languages.dispose();
    },
  );
}
