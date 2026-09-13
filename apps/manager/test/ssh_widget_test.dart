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
        c.serverName.text =
            'Мой сервер / My server — длинное имя для узкого окна';
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: width == 1400,
              ),
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
        expect(find.byKey(const ValueKey('ssh-host')), findsNothing);
        expect(find.byKey(const ValueKey('ssh-password')), findsNothing);
        expect(find.text(c.serverName.text), findsOneWidget);
        expect(find.text('Ubuntu 24.04'), findsOneWidget);
        expect(find.textContaining('SHA256:fixture'), findsNothing);
        final sudoField = find.byKey(const ValueKey('sudo-password'));
        expect(sudoField, findsOneWidget);
        expect(tester.widget<TextField>(sudoField).obscureText, isTrue);
        final checkAccess = find.byKey(const ValueKey('sudo-check'));
        await tester.ensureVisible(checkAccess);
        await tester.pumpAndSettle();
        await tester.tap(checkAccess);
        await tester.pumpAndSettle();
        expect(c.privileges!.status, PrivilegeStatus.sudoWithoutPassword);
        expect(connector.connection.lastUseSudo, isTrue);
        expect(tester.takeException(), isNull);

        final edit = find.byKey(const ValueKey('ssh-edit'));
        await tester.ensureVisible(edit);
        await tester.pumpAndSettle();
        await tester.tap(edit);
        await tester.pumpAndSettle();
        final name = find.byKey(const ValueKey('ssh-name'));
        await tester.ensureVisible(name);
        await tester.pumpAndSettle();
        await tester.enterText(name, 'VPS 2');
        await tester.pumpAndSettle();
        final save = find.byKey(const ValueKey('ssh-save'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.text('VPS 2'), findsOneWidget);
        expect(find.byKey(const ValueKey('ssh-host')), findsNothing);
        expect(connector.connection.closed, isFalse);
        await c.refresh();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ssh-host')), findsNothing);
        c.disconnect();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ssh-host')), findsNothing);
        expect(find.byKey(const ValueKey('ssh-connect')), findsOneWidget);
        connector.key = const TrustedHostKey('ssh-ed25519', 'SHA256:second');
        connector.connection = FakeConnection();
        await c.connect();
        await tester.pumpAndSettle();
        expect(c.error, SshIssue.hostKeyChanged);
        final replace = find.byKey(const ValueKey('ssh-replace-server'));
        await tester.ensureVisible(replace);
        await tester.pumpAndSettle();
        await tester.tap(replace);
        await tester.pumpAndSettle();
        expect(c.stage, SshStage.verifying);
        expect(find.textContaining('SHA256:fixture'), findsOneWidget);
        expect(find.textContaining('SHA256:second'), findsOneWidget);
        expect(connector.authentications, 1);
        await tester.ensureVisible(accept);
        await tester.pumpAndSettle();
        await tester.tap(accept);
        await tester.pumpAndSettle();
        expect(c.stage, SshStage.connected);
        expect(connector.authentications, 2);
        expect(find.text('VPS 2'), findsOneWidget);
        expect(find.byKey(const ValueKey('ssh-host')), findsNothing);
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
    'app restores saved connection automatically and remains accessible on background',
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
        await tester.tap(find.text('Servers'));
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
      await enter('ssh-name', 'Домашний VPS');
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
      expect(find.text('Домашний VPS'), findsOneWidget);
      expect(find.byKey(const ValueKey('ssh-host')), findsNothing);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(vault.unlocked, isTrue);
      expect(find.byKey(const ValueKey('ssh-password')), findsNothing);
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
      expect(find.text('Домашний VPS'), findsOneWidget);
      expect(find.byKey(const ValueKey('ssh-host')), findsNothing);
      final edit = find.byKey(const ValueKey('ssh-edit'));
      await tester.ensureVisible(edit);
      await tester.pumpAndSettle();
      await tester.tap(edit);
      await tester.pumpAndSettle();
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
      await enter('ssh-name', 'Черновик');
      await languages.select(AppLanguage.ru);
      tester.view.physicalSize = const Size(390, 1000);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ssh-name')))
            .controller!
            .text,
        'Черновик',
      );
      final cancel = find.byKey(const ValueKey('ssh-edit-cancel'));
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(find.text('Домашний VPS'), findsOneWidget);
      expect(find.byKey(const ValueKey('ssh-password')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      languages.dispose();
    },
  );
}
