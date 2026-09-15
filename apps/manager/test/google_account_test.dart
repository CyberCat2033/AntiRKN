import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/sync/google_account_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class AccountService implements GoogleAccountService {
  @override
  bool get supported => true;
  GoogleDriveAccount? account;
  GoogleAccountIssue? error;
  bool cancel = false;
  Completer<GoogleDriveAccount?>? wait;
  @override
  Future<GoogleDriveAccount?> restore() async => account;
  @override
  Future<GoogleDriveAccount?> signIn() async {
    if (error != null) throw GoogleAccountFailure(error!);
    if (wait != null) return wait!.future;
    if (cancel) return null;
    return account = const GoogleDriveAccount(
      permissionId: 'fixture',
      email: 'fixture@example.com',
      displayName: 'Fixture User',
    );
  }

  @override
  Future<void> signOut() async {
    account = null;
  }
}

class Languages implements LanguagePreferenceStore {
  @override
  Future<AppLanguage> readLanguage() async => AppLanguage.ru;
  @override
  Future<void> writeLanguage(AppLanguage value) async {}
}

class DesktopAccountService extends AccountService
    implements CancelableGoogleSignIn {
  int cancellations = 0;
  @override
  void cancelSignIn() {
    cancellations++;
    if (wait != null && !wait!.isCompleted) wait!.complete(null);
  }

  @override
  Future<void> close() async => cancelSignIn();
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    AccountService service, {
    String locale = 'ru',
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(390, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(locale),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: ListView(children: [GoogleAccountPanel(service: service)]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final locale in ['ru', 'en']) {
    testWidgets(
      '$locale settings account sign-in, persistent identity and sign-out at text x2',
      (tester) async {
        final service = AccountService();
        await mount(tester, service, locale: locale, scale: 2);
        expect(
          find.text(locale == 'ru' ? 'Войти в Google' : 'Sign in to Google'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('google-sign-in')));
        await tester.pumpAndSettle();
        expect(find.text('fixture@example.com'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('google-sign-out')),
        );
        await tester.tap(find.byKey(const ValueKey('google-sign-out')));
        await tester.pumpAndSettle();
        expect(find.text('fixture@example.com'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'cancel keeps account, failure is localized, pending sign-in disables duplicate presses',
    (tester) async {
      final service = AccountService();
      await service.signIn();
      service.cancel = true;
      await mount(tester, service);
      await tester.tap(find.byKey(const ValueKey('google-sign-in')));
      await tester.pumpAndSettle();
      expect(find.text('fixture@example.com'), findsOneWidget);
      service.error = GoogleAccountIssue.network;
      await tester.tap(find.byKey(const ValueKey('google-sign-in')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Проверьте подключение'), findsOneWidget);
      service.error = null;
      service.wait = Completer();
      await tester.tap(find.byKey(const ValueKey('google-sign-in')));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('google-sign-in')),
            )
            .onPressed,
        isNull,
      );
      service.wait!.complete(null);
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'actual app Settings navigation contains Google sign-in at the top',
    (tester) async {
      final languages = LanguageController(Languages());
      await languages.load();
      addTearDown(languages.dispose);
      await tester.pumpWidget(
        AntiRknApp(
          source: '',
          languages: languages,
          googleAccount: AccountService(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Настройки').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('google-sign-in')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('Войти в Google'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in ['ru', 'en']) {
    testWidgets(
      '$locale desktop cancellation and platform-specific errors at text x2',
      (tester) async {
        final service = DesktopAccountService();
        await service.signIn();
        await mount(tester, service, locale: locale, scale: 2);
        service.wait = Completer();
        await tester.tap(find.byKey(const ValueKey('google-sign-in')));
        await tester.pump();
        final cancel = find.byKey(const ValueKey('google-cancel-sign-in'));
        await tester.ensureVisible(cancel);
        await tester.pump();
        expect(cancel.hitTestable(), findsOneWidget);
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(service.cancellations, 1);
        expect(find.text('fixture@example.com'), findsOneWidget);
        service.wait = null;
        service.error = GoogleAccountIssue.configuration;
        await tester.ensureVisible(
          find.byKey(const ValueKey('google-sign-in')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('google-sign-in')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Desktop OAuth'), findsOneWidget);
        expect(find.textContaining('Google Play services'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('leaving settings cancels pending desktop authorization', (
    tester,
  ) async {
    final service = DesktopAccountService()..wait = Completer();
    await mount(tester, service);
    await tester.tap(find.byKey(const ValueKey('google-sign-in')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(service.cancellations, 1);
    expect(tester.takeException(), isNull);
  });
}
