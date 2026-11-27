import 'dart:async';
import 'dart:typed_data';

import 'package:antirkn_app_update/release_tool.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/language_controller.dart';
import 'package:antirkn_manager/main.dart';
import 'package:antirkn_manager/update/app_update_controller.dart';
import 'package:antirkn_manager/update/app_update_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Settings implements SettingsStore {
  final values = <String, String>{};
  @override
  Future<String?> readSetting(String key) async => values[key];
  @override
  Future<void> writeSetting(String key, String value) async =>
      values[key] = value;
}

AppUpdatePayload release() {
  const tag = 'v1.3.0';
  AppUpdateArtifact apk(String arch, int id) => AppUpdateArtifact(
    kind: AppUpdateKind.androidApk,
    arch: arch,
    fileName: 'AntiRKN-$tag-android-$arch.apk',
    url: '${appUpdateArtifactUrlPrefix}v1.3.0/AntiRKN-$tag-android-$arch.apk',
    size: 48 * 1024 * 1024,
    sha256: 'a' * 64,
    versionCode: 10300 * 10 + id,
    certSha256: 'b' * 64,
  );
  AppUpdateChangelogEntry entry(String version, String text) =>
      AppUpdateChangelogEntry(
        version: version,
        date: '2026-11-27',
        markdown: text,
      );
  return AppUpdatePayload(
    schemaVersion: 1,
    appId: appUpdateAppId,
    channel: 'stable',
    version: '1.3.0',
    build: 10300,
    tag: tag,
    commit: 'c' * 40,
    releasedAt: '2026-11-27T10:00:00Z',
    minSupportedBuild: 0,
    notesUrl: 'https://github.com/CyberCat2033/AntiRKN/releases/tag/$tag',
    changelog: {
      'en': [
        entry('1.3.0', '### Added\n- Client traffic'),
        entry('1.2.0', '### Fixed\n- Older fix'),
      ],
      'ru': [entry('1.3.0', '### Добавлено\n- Трафик клиентов')],
    },
    artifacts: [apk('arm64-v8a', 2), apk('universal', 0)],
  );
}

final class Feed implements AppUpdateFeed {
  @override
  Future<Uint8List> fetch(String channel, CancellationToken token) async =>
      AppUpdateEnvelope(encodeAppUpdatePayload(release()), [
        AppUpdateSignature('k1', Uint8List(64)),
      ]).encode();
}

final class AcceptAll implements AppUpdateSignatureVerifier {
  @override
  Future<bool> verify({
    required List<int> message,
    required List<int> signature,
    required List<int> publicKey,
  }) async => true;
}

final class Downloader implements AppUpdateDownloader {
  Completer<void>? gate;
  @override
  Future<String> download(
    AppUpdateArtifact artifact, {
    required void Function(int, int) onProgress,
    required CancellationToken token,
  }) async {
    onProgress(artifact.size * 62 ~/ 100, artifact.size);
    if (gate != null) await token.bind(gate!.future);
    return '/cache/${artifact.fileName}';
  }
}

final class Installer implements AppUpdateInstaller {
  String? verifyFailure;
  AppUpdateInstallResult result = AppUpdateInstallResult.permissionRequired;
  @override
  Future<AppUpdateInstallMode> mode(AppUpdateArtifact a) async =>
      AppUpdateInstallMode.automatic;
  @override
  Future<void> verify(String path, AppUpdateArtifact a) async {
    if (verifyFailure != null) throw AppUpdateFailure(verifyFailure!);
  }

  @override
  Future<AppUpdateInstallResult> install(
    String path,
    AppUpdateArtifact a,
    AppUpdatePayload p,
  ) async => result;
  @override
  Future<void> reveal(String path) async {}
  @override
  Future<void> finishStartup({required bool confirmed}) async {}
}

final class Core implements CoreLifecycle {
  @override
  Future<bool> quiesce(Duration timeout) async => true;
  @override
  void resume() {}
}

final class Harness {
  Harness({AppUpdatePlatform platform = AppUpdatePlatform.android}) {
    controller = AppUpdateController(
      settings: settings,
      backgroundChecks: false,
      openUrl: (uri) async => opened.add(uri),
      coordinator: AppUpdateCoordinator(
        installed: InstalledApp(
          platform: platform,
          build: 10200,
          version: '1.2.0',
          installKind: platform == AppUpdatePlatform.android
              ? AppUpdateKind.androidApk
              : null,
          androidAbi: 'arm64-v8a',
        ),
        trustedKeys: [
          AppUpdateTrustedKey('k1', appUpdateBase64(Uint8List(32))),
        ],
        feed: Feed(),
        verifier: AcceptAll(),
        downloader: downloader,
        installer: installer,
        store: SettingsAppUpdateStateStore(settings),
        core: Core(),
      ),
    );
  }
  final settings = Settings();
  final downloader = Downloader();
  final installer = Installer();
  final opened = <Uri>[];
  late final AppUpdateController controller;
}

Widget host(
  AppUpdateController controller,
  Widget child, {
  String locale = 'en',
  double scale = 1,
}) => MaterialApp(
  locale: Locale(locale),
  theme: AppTheme.create(Brightness.light),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: Scaffold(
    body: AppUpdateScope(
      controller: controller,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  ),
);

Future<void> size(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('controller', () {
    test('old component switches move to the app updater once', () async {
      final h = Harness();
      h.settings.values['componentUpdatesAutomatic'] = 'false';
      await h.controller.load();
      expect(h.controller.automatic, isFalse);
      expect(h.controller.suggestions, isTrue);
      expect(h.settings.values[AppUpdateController.automaticKey], 'false');
      expect(h.settings.values[AppUpdateController.suggestionsKey], 'true');
      // The legacy value is read once: later changes there are ignored.
      h.settings.values['componentUpdatesAutomatic'] = 'true';
      final again = AppUpdateController(
        settings: h.settings,
        backgroundChecks: false,
      );
      await again.load();
      expect(again.automatic, isFalse);
      await again.setPreference(automatic: true);
      expect(h.settings.values[AppUpdateController.automaticKey], 'true');
      again.dispose();
      h.controller.dispose();
    });

    test('skip hides the home offer until a download starts', () async {
      final h = Harness();
      await h.controller.load();
      await h.controller.check();
      expect(h.controller.showOnHome, isTrue);
      await h.controller.skip();
      expect(h.controller.showOnHome, isFalse);
      expect(h.settings.values[AppUpdateController.skippedKey], '1.3.0');
      await h.controller.setPreference(suggestions: false);
      expect(h.controller.showOnHome, isFalse);
      h.controller.dispose();
    });

    test('changes since the installed version follow the locale', () async {
      final h = Harness();
      await h.controller.load();
      await h.controller.check();
      expect(h.controller.changes('ru').map((e) => e.markdown), [
        '### Добавлено\n- Трафик клиентов',
      ]);
      expect(h.controller.changes('en'), hasLength(1));
      h.controller.dispose();
    });

    test('startup records the running build in the settings store', () async {
      final h = Harness();
      await h.controller.load();
      expect(
        h.settings.values[SettingsAppUpdateStateStore.key],
        contains('"confirmedBuild":10200'),
      );
      h.controller.dispose();
    });
  });

  group('settings card (variant А)', () {
    testWidgets('walks the states with the shared card', (tester) async {
      final h = Harness();
      await tester.runAsync(h.controller.load);
      await tester.pumpWidget(host(h.controller, const AppUpdateSettings()));
      expect(find.text('Check for new versions'), findsOneWidget);
      expect(find.textContaining('1.2.0 · installed'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('app-update-check')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.textContaining('1.2.0 → 1.3.0 · 48.0 MB'), findsOneWidget);
      await tester.tap(find.text("What's new in 1.3.0"));
      await tester.pumpAndSettle();
      expect(find.text('Client traffic'), findsOneWidget);

      h.downloader.gate = Completer();
      await tester.tap(find.byKey(const ValueKey('app-update-download')));
      await tester.pump();
      expect(find.byKey(const ValueKey('app-update-stop')), findsOneWidget);
      expect(
        find.textContaining('Downloading · 29.8 MB of 48.0 MB'),
        findsOneWidget,
      );
      h.downloader.gate!.complete();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text('Install'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('app-update-install')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('app-update-permission')),
        findsOneWidget,
      );
      expect(find.text('Waiting for the Android permission'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('app-update-automatic')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(h.settings.values[AppUpdateController.automaticKey], 'false');
      h.controller.dispose();
    });

    testWidgets('verification failure shows codes only behind Details', (
      tester,
    ) async {
      final h = Harness(platform: AppUpdatePlatform.linux);
      await tester.runAsync(h.controller.load);
      await tester.pumpWidget(host(h.controller, const AppUpdateSettings()));
      await tester.runAsync(h.controller.check);
      await tester.pump();
      expect(
        find.textContaining('cannot be updated from the app'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('app-update-release-page')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(h.opened.single.path, '/CyberCat2033/AntiRKN/releases/tag/v1.3.0');
      h.controller.dispose();

      final android = Harness();
      android.installer.verifyFailure = AppUpdateCode.signerMismatch;
      await tester.runAsync(android.controller.load);
      await tester.pumpWidget(
        host(android.controller, const AppUpdateSettings()),
      );
      await tester.runAsync(android.controller.check);
      await tester.runAsync(android.controller.download);
      await tester.pump();
      expect(find.text('The update failed verification'), findsOneWidget);
      expect(find.text(AppUpdateCode.signerMismatch), findsNothing);
      await tester.tap(find.byKey(const ValueKey('app-update-details')));
      await tester.pumpAndSettle();
      expect(find.text(AppUpdateCode.signerMismatch), findsOneWidget);
      android.controller.dispose();
    });

    for (final width in [390.0, 700.0, 1000.0, 1400.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('fits at $width px, text ×$scale (RU)', (tester) async {
          await size(tester, width);
          final h = Harness(platform: AppUpdatePlatform.linux);
          await tester.runAsync(h.controller.load);
          await tester.runAsync(h.controller.check);
          await tester.pumpWidget(
            host(
              h.controller,
              const Column(children: [AppUpdateBanner(), AppUpdateSettings()]),
              locale: 'ru',
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Доступна версия 1.3.0'), findsOneWidget);
          h.controller.dispose();
        });
      }
    }
  });

  group('home banner (variant Б)', () {
    testWidgets('opens a sheet on compact and a dialog on wide screens', (
      tester,
    ) async {
      for (final (width, sheet) in [(390.0, true), (1000.0, false)]) {
        await size(tester, width);
        final h = Harness();
        await tester.runAsync(h.controller.load);
        await tester.pumpWidget(host(h.controller, const AppUpdateBanner()));
        expect(find.byKey(const ValueKey('app-update-banner')), findsNothing);
        await tester.runAsync(h.controller.check);
        await tester.pumpAndSettle();
        expect(find.text('Version 1.3.0 is available'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('app-update-banner-more')));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), sheet ? findsOneWidget : findsNothing);
        expect(find.byType(Dialog), sheet ? findsNothing : findsOneWidget);
        expect(find.text("What's new in 1.3.0"), findsOneWidget);
        expect(find.text('Client traffic'), findsOneWidget);

        // Progress follows the controller while the sheet stays open.
        h.downloader.gate = Completer();
        await tester.tap(
          find.byKey(const ValueKey('app-update-download')).last,
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('app-update-stop')), findsOneWidget);
        h.controller.cancel();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('app-update-banner-skip')));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('app-update-banner')), findsNothing);
        expect(h.settings.values[AppUpdateController.skippedKey], '1.3.0');
        h.controller.dispose();
      }
    });

    testWidgets('download progress and ready state show in the banner', (
      tester,
    ) async {
      final h = Harness();
      await tester.runAsync(h.controller.load);
      await tester.pumpWidget(host(h.controller, const AppUpdateBanner()));
      await tester.runAsync(h.controller.check);
      h.downloader.gate = Completer();
      unawaited(h.controller.download());
      await tester.pump();
      expect(find.text('Downloading 1.3.0 · 61 %'), findsOneWidget);
      h.downloader.gate!.complete();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text('Update 1.3.0 is ready'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('app-update-banner-install')),
        findsOneWidget,
      );
      h.controller.dispose();
    });
  });

  testWidgets('Settings → Updates holds only the app update', (tester) async {
    await size(tester, 1000);
    final h = Harness();
    final languages = LanguageController(_English());
    await tester.runAsync(languages.load);
    await tester.pumpWidget(
      AntiRknApp(
        source: 'proxies: []',
        languages: languages,
        settings: h.settings,
        initialMotion: MotionPreference.off,
        appUpdates: (_) async => h.controller,
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final l = lookupAppLocalizations(const Locale('en'));
    await tester.tap(find.text(l.settings).last);
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(ListTile, l.uiUpdatesShort);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-update-automatic')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('app-update-suggestions')),
      findsOneWidget,
    );
    expect(find.byType(SwitchListTile), findsNWidgets(2));
    // Server components stay on the server screens only.
    expect(find.text('Ubuntu'), findsNothing);
    expect(find.textContaining('3x-ui'), findsNothing);
    expect(find.textContaining('Xray'), findsNothing);
    expect(find.text(l.protocolSoftware), findsNothing);
    expect(find.byKey(const ValueKey('apt-card')), findsNothing);
  });
}

class _English implements LanguagePreferenceStore {
  @override
  Future<AppLanguage> readLanguage() async => AppLanguage.en;
  @override
  Future<void> writeLanguage(AppLanguage value) async {}
}
