import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/sync/auto_sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class TestSettings implements SettingsStore {
  final map = <String, String>{};
  @override
  Future<String?> readSetting(String key) async => map[key];
  @override
  Future<void> writeSetting(String key, String value) async => map[key] = value;
}

class TestLanguageStore implements LanguagePreferenceStore {
  @override
  Future<AppLanguage> readLanguage() async => AppLanguage.ru;
  @override
  Future<void> writeLanguage(AppLanguage language) async {}
}

class DesktopAccountService
    implements GoogleSyncAccountService, CancelableGoogleSignIn {
  @override
  String get accountKey => 'account';
  @override
  bool get supported => true;
  @override
  Future<GoogleDriveAccount?> restore() async => null;
  @override
  Future<GoogleDriveAccount?> signIn() async => null;
  @override
  Future<void> signOut() async {}
  @override
  void cancelSignIn() {}
  @override
  Future<String> accessToken() async => '';
  @override
  Future<void> close() async {}
}

class MockAutoSyncController extends AutoSyncController {
  MockAutoSyncController()
      : super(
          accountService: DesktopAccountService(),
          settings: TestSettings(),
          changes: const Stream<void>.empty(),
          openSession: () => throw UnimplementedError(),
          apply: (_) => throw UnimplementedError(),
        );

  final foregroundEvents = <bool>[];

  @override
  void foreground(bool value) {
    foregroundEvents.add(value);
    super.foreground(value);
  }
}

void main() {
  testWidgets(
    'desktop keeps autoSync in foreground on inactive and hidden, only detached disables it',
    (tester) async {
      final languages = LanguageController(TestLanguageStore());
      final autoSync = MockAutoSyncController();
      addTearDown(autoSync.dispose);
      final google = DesktopAccountService();

      await tester.pumpWidget(
        AntiRknApp(
          source: '',
          languages: languages,
          googleAccount: google,
          autoSync: autoSync,
        ),
      );
      await tester.pumpAndSettle();

      autoSync.foregroundEvents.clear();

      // Inactive (e.g. mouse moved away from desktop window or focus lost)
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(autoSync.foregroundEvents.last, isTrue);

      // Hidden (e.g. window obscured or minimized on desktop)
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(autoSync.foregroundEvents.last, isTrue);

      // Resumed
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(autoSync.foregroundEvents.last, isTrue);

      // Detached (app closing)
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      await tester.pump();
      expect(autoSync.foregroundEvents.last, isFalse);
    },
  );
}
