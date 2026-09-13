import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:antirkn_manager/ssh/ssh_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ssh_support.dart';

class _Languages implements LanguagePreferenceStore {
  @override
  Future<AppLanguage> readLanguage() async => AppLanguage.en;
  @override
  Future<void> writeLanguage(AppLanguage language) async {}
}

void main() {
  for (final language in ['ru', 'en']) {
    for (final width in [390.0, 1400.0]) {
      testWidgets('SSH form and trust prompt at $width, $language, text x2', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final vault = FakeVault();
        final connector = FakeConnector();
        final c = controller(vault, connector);
        await prepare(c);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(child: SshPanel(controller: c)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final work = c.connect();
        await tester.pumpAndSettle();
        expect(c.stage, SshStage.verifying);
        expect(connector.authentications, 0);
        final accept = find.byKey(const ValueKey('ssh-trust-accept'));
        await tester.ensureVisible(accept);
        await tester.pumpAndSettle();
        await tester.tap(accept);
        await tester.pumpAndSettle();
        await work;
        expect(c.stage, SshStage.connected);
        expect(tester.takeException(), isNull);
        c.lock();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ssh-password')), findsNothing);
        expect(c.password.text, isEmpty);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        c.network.dispose();
      });
    }
  }

  testWidgets(
    'app restores saved connection after restart and locks on background',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final vault = FakeVault();
      final connector = FakeConnector();
      final languages = LanguageController(_Languages());
      await languages.load();
      Future<void> launch() async {
        await tester.pumpWidget(
          AntiRknApp(
            source: '',
            languages: languages,
            ssh: SshDependencies(
              openVault: () async => vault,
              connector: connector,
              picker: FakeKeyPicker(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Server'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('vault-open')));
        await tester.pumpAndSettle();
      }

      await launch();
      Future<void> enter(String key, String text) async {
        final field = find.byKey(ValueKey(key));
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.enterText(field, text);
      }

      await enter('ssh-host', 'fixture.example');
      await enter('ssh-user', 'testuser');
      await enter('ssh-password', 'fixture-password-only');
      final save = find.byKey(const ValueKey('ssh-save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(vault.saved!.host, 'fixture.example');
      await languages.select(AppLanguage.ru);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ssh-host')))
            .controller!
            .text,
        'fixture.example',
      );
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(vault.unlocked, isFalse);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ssh-password')))
            .controller!
            .text,
        isEmpty,
      );
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ssh-password')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await languages.select(AppLanguage.en);
      await launch();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ssh-host')))
            .controller!
            .text,
        'fixture.example',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ssh-password')))
            .controller!
            .text,
        'fixture-password-only',
      );
      await tester.pumpWidget(const SizedBox());
      languages.dispose();
    },
  );
}
