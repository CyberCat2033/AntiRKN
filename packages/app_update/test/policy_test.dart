import 'dart:async';
import 'dart:typed_data';

import 'package:antirkn_app_update/antirkn_app_update.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:test/test.dart';

import 'support.dart';

const android = InstalledApp(
  platform: AppUpdatePlatform.android,
  build: 10200,
  version: '1.2.0',
  installKind: AppUpdateKind.androidApk,
  supportedAbis: ['x86_64', 'arm64-v8a'],
  androidAbi: 'arm64-v8a',
);

final class FakeFeed implements AppUpdateFeed {
  FakeFeed(this.bytes);
  Uint8List bytes;
  @override
  Future<Uint8List> fetch(String channel, CancellationToken token) async =>
      bytes;
}

final class FakeDownloader implements AppUpdateDownloader {
  Completer<String>? gate;
  String? failure;
  @override
  Future<String> download(
    AppUpdateArtifact artifact, {
    required void Function(int, int) onProgress,
    required CancellationToken token,
  }) async {
    onProgress(artifact.size ~/ 2, artifact.size);
    if (gate != null) await token.bind(gate!.future);
    if (failure != null) throw AppUpdateFailure(failure!);
    return '/cache/${artifact.fileName}';
  }
}

final class FakeInstaller implements AppUpdateInstaller {
  AppUpdateInstallMode allowed = AppUpdateInstallMode.automatic;
  AppUpdateInstallResult result = AppUpdateInstallResult.handedToSystem;
  String? verifyFailure;
  final installs = <String>[];
  final startups = <bool>[];
  final revealed = <String>[];
  @override
  Future<AppUpdateInstallMode> mode(AppUpdateArtifact artifact) async =>
      allowed;
  @override
  Future<void> verify(String path, AppUpdateArtifact artifact) async {
    if (verifyFailure != null) throw AppUpdateFailure(verifyFailure!);
  }

  @override
  Future<AppUpdateInstallResult> install(
    String path,
    AppUpdateArtifact artifact,
    AppUpdatePayload payload,
  ) async {
    installs.add(path);
    return result;
  }

  @override
  Future<void> reveal(String path) async => revealed.add(path);
  @override
  Future<void> finishStartup({required bool confirmed}) async =>
      startups.add(confirmed);
}

final class MemoryStore implements AppUpdateStateStore {
  AppUpdateRecord record = const AppUpdateRecord();
  @override
  Future<AppUpdateRecord> read() async => record;
  @override
  Future<void> write(AppUpdateRecord value) async => record = value;
}

final class FakeCore implements CoreLifecycle {
  bool idle = true;
  int quiesced = 0, resumed = 0;
  @override
  Future<bool> quiesce(Duration timeout) async {
    quiesced++;
    return idle;
  }

  @override
  void resume() => resumed++;
}

void main() {
  group('policy', () {
    test('versionCode encodes build and variant', () {
      expect(InstalledApp.fromAndroidVersionCode(102032), (10203, 'arm64-v8a'));
      expect(InstalledApp.fromAndroidVersionCode(102030), (10203, 'universal'));
      expect(InstalledApp.fromAndroidVersionCode(102039), (10203, null));
    });

    test('keeps the installed variant, universal only when missing', () {
      const v7 = InstalledApp(
        platform: AppUpdatePlatform.android,
        build: 1,
        version: '0.0.1',
        installKind: AppUpdateKind.androidApk,
        supportedAbis: ['arm64-v8a', 'armeabi-v7a'],
        androidAbi: 'armeabi-v7a',
      );
      expect(selectAppUpdateArtifact(payload(), v7)!.arch, 'armeabi-v7a');
      const x86 = InstalledApp(
        platform: AppUpdatePlatform.android,
        build: 1,
        version: '0.0.1',
        installKind: AppUpdateKind.androidApk,
        androidAbi: 'x86_64',
      );
      expect(selectAppUpdateArtifact(payload(), x86)!.arch, 'universal');
    });

    test('without a known variant picks the preferred ABI, then universal', () {
      expect(selectAppUpdateArtifact(payload(), android)!.arch, 'arm64-v8a');
      const other = InstalledApp(
        platform: AppUpdatePlatform.android,
        build: 1,
        version: '0.0.1',
        installKind: AppUpdateKind.androidApk,
        supportedAbis: ['x86'],
      );
      expect(selectAppUpdateArtifact(payload(), other)!.arch, 'universal');
    });

    test('desktop follows the install-kind marker', () {
      for (final kind in [
        AppUpdateKind.linuxAppimage,
        AppUpdateKind.linuxTarball,
      ]) {
        final installed = InstalledApp(
          platform: AppUpdatePlatform.linux,
          build: 1,
          version: '0.0.1',
          installKind: kind,
        );
        expect(selectAppUpdateArtifact(payload(), installed)!.kind, kind);
      }
      const unmarked = InstalledApp(
        platform: AppUpdatePlatform.linux,
        build: 1,
        version: '0.0.1',
      );
      final decision = decideAppUpdate(
        payload: payload(),
        installed: unmarked,
        maxSeenBuild: 0,
      );
      expect(decision, isA<UpdateOffered>());
      expect((decision as UpdateOffered).mode, AppUpdateInstallMode.notifyOnly);
      expect(decision.artifact, isNull);
      const wrongPlatform = InstalledApp(
        platform: AppUpdatePlatform.windows,
        build: 1,
        version: '0.0.1',
        installKind: AppUpdateKind.linuxTarball,
      );
      expect(selectAppUpdateArtifact(payload(), wrongPlatform), isNull);
    });

    test('portable Windows is download-only', () {
      const portable = InstalledApp(
        platform: AppUpdatePlatform.windows,
        build: 1,
        version: '0.0.1',
        installKind: AppUpdateKind.windowsPortable,
      );
      final decision =
          decideAppUpdate(
                payload: payload(),
                installed: portable,
                maxSeenBuild: 0,
              )
              as UpdateOffered;
      expect(decision.mode, AppUpdateInstallMode.downloadOnly);
    });

    test('monotonic build, anti-replay, app and channel', () {
      UpdateDecision decide(
        AppUpdatePayload p, {
        int maxSeen = 0,
        int build = 10200,
      }) => decideAppUpdate(
        payload: p,
        installed: InstalledApp(
          platform: AppUpdatePlatform.android,
          build: build,
          version: '1.2.0',
          installKind: AppUpdateKind.androidApk,
        ),
        maxSeenBuild: maxSeen,
      );
      expect(decide(payload(), build: 10203), isA<UpdateUpToDate>());
      expect(decide(payload(), build: 10300), isA<UpdateUpToDate>());
      expect(
        (decide(payload(), maxSeen: 10300) as UpdateRejected).code,
        AppUpdateCode.replay,
      );
      expect(decide(payload(), maxSeen: 10203), isA<UpdateOffered>());
      expect(
        (decide(payload(channel: 'beta')) as UpdateRejected).code,
        AppUpdateCode.channelMismatch,
      );
      expect(
        (decide(payload(appId: 'org.other')) as UpdateRejected).code,
        AppUpdateCode.appMismatch,
      );
      expect(
        (decide(payload(minSupportedBuild: 10201)) as UpdateOffered).mandatory,
        isTrue,
      );
    });
  });

  group('changelog', () {
    const en = '''
# Changelog

## [Unreleased]

### Added
- Not yet

## [1.2.0] - 2026-11-20

### Fixed
* Star bullet



- Second

## [1.1.0] - 2026-11-01

### Added
- Old

[1.2.0]: https://github.com/CyberCat2033/AntiRKN/releases/tag/v1.2.0
''';
    const ru = '''
## [Unreleased]

## [1.2.0] - 2026-11-20

### Исправлено
- Русский
''';

    test('parses released sections and normalizes bullets', () {
      final entries = parseKeepAChangelog(en);
      expect(entries.map((e) => e.version), ['1.2.0', '1.1.0']);
      expect(entries.first.markdown, '### Fixed\n- Star bullet\n\n- Second');
      expect(entries.last.markdown, '### Added\n- Old');
      expect(entries.first.date, '2026-11-20');
    });

    test('release selection requires the version in both files', () {
      final changelog = appUpdateChangelogForRelease(
        version: '1.2.0',
        files: {'en': en, 'ru': ru},
      );
      expect(changelog['en']!.map((e) => e.version), ['1.2.0', '1.1.0']);
      expect(
        () => appUpdateChangelogForRelease(
          version: '1.3.0',
          files: {'en': en, 'ru': ru},
        ),
        throwsFormatException,
      );
      expect(
        () => appUpdateChangelogForRelease(
          version: '1.1.0',
          files: {'en': en, 'ru': ru},
        ),
        throwsFormatException,
      );
      final notes = appUpdateReleaseNotes(changelog, '1.2.0');
      expect(notes, startsWith('## English\n\n### Fixed'));
      expect(notes, contains('## Русский\n\n### Исправлено\n- Русский'));
    });

    test(
      'changes since the installed version, newest first, ru falls back to en',
      () {
        final changelog = appUpdateChangelogForRelease(
          version: '1.2.0',
          files: {'en': en, 'ru': ru},
        );
        final ruView = appUpdateChangesSince(
          changelog,
          installedVersion: '1.0.9',
          languageCode: 'ru',
        );
        expect(ruView.map((e) => e.markdown.split('\n').last), [
          '- Русский',
          '- Old',
        ]);
        expect(
          appUpdateChangesSince(
            changelog,
            installedVersion: '1.1.0',
            languageCode: 'de',
          ).map((e) => e.version),
          ['1.2.0'],
        );
        expect(
          appUpdateChangesSince(
            changelog,
            installedVersion: '1.2.0',
            languageCode: 'en',
          ),
          isEmpty,
        );
        expect(compareAppVersions('1.10.0', '1.9.9'), greaterThan(0));
      },
    );
  });

  group('coordinator', () {
    late FakeFeed feed;
    late FakeDownloader downloader;
    late FakeInstaller installer;
    late MemoryStore store;
    late FakeCore core;

    Future<AppUpdateCoordinator> coordinator({
      InstalledApp installed = android,
      bool keys = true,
    }) async {
      feed = FakeFeed(await signed(payload()));
      downloader = FakeDownloader();
      installer = FakeInstaller();
      store = MemoryStore();
      core = FakeCore();
      return AppUpdateCoordinator(
        installed: installed,
        trustedKeys: keys ? await trusted() : const [],
        feed: feed,
        verifier: const Ed25519UpdateVerifier(),
        downloader: downloader,
        installer: installer,
        store: store,
        core: core,
      );
    }

    test('without keys stays unavailable', () async {
      final c = await coordinator(keys: false);
      expect(c.state, isA<AppUpdateUnavailable>());
      await c.check();
      expect(c.state, isA<AppUpdateUnavailable>());
    });

    test('check, download, verify, install', () async {
      final c = await coordinator();
      final seen = <Type>[];
      c.states.listen((s) => seen.add(s.runtimeType));
      await c.check();
      expect(c.state, isA<AppUpdateAvailable>());
      expect(store.record.maxSeenBuild, 10203);
      await c.download();
      expect(c.state, isA<AppUpdateReadyToInstall>());
      await c.install();
      expect(installer.installs.single, endsWith('android-arm64-v8a.apk'));
      expect(store.record.pendingBuild, 10203);
      expect(core.quiesced, 0, reason: 'Android has no desktop worker swap');
      expect(seen, [
        AppUpdateChecking,
        AppUpdateAvailable,
        AppUpdateDownloading,
        AppUpdateDownloading,
        AppUpdateVerifying,
        AppUpdateReadyToInstall,
        AppUpdateInstalling,
      ]);
    });

    test('a replayed older manifest is refused', () async {
      final c = await coordinator();
      store.record = const AppUpdateRecord(maxSeenBuild: 10300);
      await c.check();
      expect((c.state as AppUpdateFailed).code, AppUpdateCode.replay);
    });

    test('installer narrows the mode to notify-only', () async {
      final c = await coordinator();
      installer.allowed = AppUpdateInstallMode.notifyOnly;
      await c.check();
      final offer = (c.state as AppUpdateAvailable).offer;
      expect(offer.mode, AppUpdateInstallMode.notifyOnly);
      expect(offer.artifact, isNull);
      await c.download();
      expect(c.state, isA<AppUpdateAvailable>());
    });

    test('cancelled download returns to the offer; failures keep it', () async {
      final c = await coordinator();
      await c.check();
      downloader.gate = Completer();
      final running = c.download();
      await Future<void>.delayed(Duration.zero);
      expect(c.state, isA<AppUpdateDownloading>());
      c.cancel();
      await running;
      expect(c.state, isA<AppUpdateAvailable>());
      downloader
        ..gate = null
        ..failure = AppUpdateCode.checksum;
      await c.download();
      final failed = c.state as AppUpdateFailed;
      expect(failed.code, AppUpdateCode.checksum);
      expect(failed.offer, isNotNull);
      downloader.failure = null;
      installer.verifyFailure = AppUpdateCode.signerMismatch;
      await c.download();
      expect((c.state as AppUpdateFailed).code, AppUpdateCode.signerMismatch);
    });

    test('permission request returns to ready with the flag', () async {
      final c = await coordinator();
      await c.check();
      await c.download();
      installer.result = AppUpdateInstallResult.permissionRequired;
      await c.install();
      expect((c.state as AppUpdateReadyToInstall).permissionRequired, isTrue);
      expect(store.record.pendingBuild, isNull);
    });

    test('desktop install waits for the core and fails when busy', () async {
      const linux = InstalledApp(
        platform: AppUpdatePlatform.linux,
        build: 10200,
        version: '1.2.0',
        installKind: AppUpdateKind.linuxTarball,
      );
      final c = await coordinator(installed: linux);
      await c.check();
      await c.download();
      core.idle = false;
      await c.install();
      expect((c.state as AppUpdateFailed).code, AppUpdateCode.coreBusy);
      expect(installer.installs, isEmpty);
      core.idle = true;
      await c.download();
      await c.install();
      expect(core.quiesced, 2);
      expect(installer.installs, hasLength(1));
    });

    test('download-only reveals the file instead of installing', () async {
      const portable = InstalledApp(
        platform: AppUpdatePlatform.windows,
        build: 10200,
        version: '1.2.0',
        installKind: AppUpdateKind.windowsPortable,
      );
      final c = await coordinator(installed: portable);
      installer.allowed = AppUpdateInstallMode.downloadOnly;
      await c.check();
      await c.download();
      await c.install();
      expect(installer.revealed, hasLength(1));
      expect(installer.installs, isEmpty);
    });

    test('startup confirms the pending build by the running build', () async {
      final c = await coordinator();
      store.record = const AppUpdateRecord(
        pendingBuild: 10200,
        maxSeenBuild: 10100,
      );
      await c.confirmStartup();
      expect(installer.startups, [true]);
      expect(store.record.pendingBuild, isNull);
      expect(store.record.confirmedBuild, 10200);
      expect(store.record.maxSeenBuild, 10200);
      store.record = const AppUpdateRecord(pendingBuild: 10203);
      await c.confirmStartup();
      expect(installer.startups, [true, false]);
    });
  });
}
