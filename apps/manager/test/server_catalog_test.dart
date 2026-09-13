import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/ssh/ssh_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ssh_support.dart';

class _Repository
    implements ServerRepository, LanguagePreferenceStore, SettingsStore {
  final servers = <String, SshProfile>{};
  final settings = <String, String>{};
  int sequence = 0;
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
  Future<SecretVault> openServer(String id) async => _Handle(this, id);
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

class _Handle extends FakeVault {
  _Handle(this.repository, this.id) {
    saved = repository.servers[id];
  }
  final _Repository repository;
  final String id;
  @override
  Future<void> saveProfile(SshProfile? profile) async {
    await super.saveProfile(profile);
    if (profile == null) {
      repository.servers.remove(id);
    } else {
      repository.servers[id] = profile;
    }
  }
}

void main() {
  for (final language in ['en', 'ru']) {
    testWidgets(
      'multiple servers CRUD, restart, reveal password, background and large text: $language',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final repository = _Repository();
        final languages = LanguageController(repository);
        await languages.load();
        await languages.select(AppLanguage.values.byName(language));
        addTearDown(languages.dispose);
        Future<void> launch() async {
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
        }

        Future<void> tap(String key) async {
          final target = find.byKey(ValueKey(key));
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        Future<void> enter(String key, String text) async {
          final field = find.byKey(ValueKey(key));
          await tester.ensureVisible(field);
          await tester.pumpAndSettle();
          await tester.enterText(field, text);
          await tester.pumpAndSettle();
        }

        await launch();
        expect(find.text('Protected storage'), findsNothing);
        expect(find.byKey(const ValueKey('vault-open')), findsNothing);
        for (final letter in ['A', 'B']) {
          await tap('server-add');
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('ssh-host')))
                .controller!
                .text,
            isEmpty,
          );
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('ssh-password')))
                .controller!
                .text,
            isEmpty,
          );
          await enter('ssh-name', 'VPS $letter');
          await enter('ssh-host', '${letter.toLowerCase()}.example');
          await enter('ssh-password', 'fixture-password-$letter');
          await tap('ssh-save');
          expect(find.text('VPS $letter'), findsOneWidget);
          await tap('server-list-back');
        }
        expect(repository.servers, hasLength(2));
        expect(find.text('VPS A'), findsOneWidget);
        expect(find.text('VPS B'), findsOneWidget);
        final firstId = repository.servers.keys.first;
        final secondId = repository.servers.keys.last;
        expect(repository.servers[firstId]!.id, firstId);
        expect(repository.servers[secondId]!.hostKey, isNull);
        await tester.pumpWidget(const SizedBox());
        await launch();
        await tap('server-$firstId');
        expect(
          find.text(language == 'en' ? 'Connect' : 'Подключиться'),
          findsOneWidget,
        );
        await tap('ssh-edit');
        await tap('show-ssh-password');
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('ssh-password')),
        );
        expect(field.obscureText, isFalse);
        expect(field.controller!.text, 'fixture-password-A');
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pump(const Duration(minutes: 6));
        expect(field.controller!.text, 'fixture-password-A');
        await enter('ssh-name', 'Renamed A');
        expect(
          find.text(
            language == 'en' ? 'Save and connect' : 'Сохранить и подключиться',
          ),
          findsOneWidget,
        );
        await tap('ssh-save');
        await tap('ssh-connect');
        await tap('ssh-trust-accept');
        await tap('server-list-back');
        expect(find.text('Renamed A'), findsOneWidget);
        expect(repository.servers[firstId]!.host, 'a.example');
        expect(repository.servers[firstId]!.lastInfo!.os, 'Ubuntu 24.04');
        await tester.pumpWidget(const SizedBox());
        await launch();
        expect(find.textContaining('Ubuntu 24.04'), findsOneWidget);
        await tap('server-$secondId');
        await tap('ssh-edit');
        final deleteText = language == 'en'
            ? 'Delete saved connection'
            : 'Удалить сохранённое подключение';
        // Locate the actual localized action by its stable key.
        await tap('ssh-delete');
        final confirm = find.byKey(const ValueKey('ssh-delete-confirm'));
        expect(confirm, findsOneWidget, reason: deleteText);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        await tap('server-list-back');
        expect(repository.servers.keys, [firstId]);
        expect(find.text('VPS B'), findsNothing);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final width in [390.0, 700.0, 1400.0]) {
          tester.view.physicalSize = Size(width, 1000);
          await tester.pumpAndSettle();
          expect(find.text('Renamed A'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
