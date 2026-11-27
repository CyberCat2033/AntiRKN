import 'dart:typed_data';

import 'package:antirkn_app_update/release_tool.dart';
import 'package:antirkn_domain/antirkn_domain.dart';

/// A throwaway test seed: never a release key.
final testSeed = Uint8List.fromList(List.generate(32, (i) => i + 1));
final otherSeed = Uint8List.fromList(List.generate(32, (i) => 200 - i));

AppUpdateArtifact artifact(
  AppUpdateKind kind,
  String arch, {
  String tag = 'v1.2.3',
  int build = 10203,
  int size = 4,
  String sha256 =
      '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
}) {
  final suffix = switch (kind) {
    AppUpdateKind.androidApk => 'android-$arch.apk',
    AppUpdateKind.windowsInstaller => 'windows-x64-setup.exe',
    AppUpdateKind.windowsPortable => 'windows-x64-portable.zip',
    AppUpdateKind.linuxAppimage => 'linux-x64.AppImage',
    AppUpdateKind.linuxTarball => 'linux-x64.tar.gz',
  };
  final name = 'AntiRKN-$tag-$suffix';
  return AppUpdateArtifact(
    kind: kind,
    arch: arch,
    fileName: name,
    url: '$appUpdateArtifactUrlPrefix$tag/$name',
    size: size,
    sha256: sha256,
    versionCode: kind.isAndroid
        ? build * 10 + appUpdateAndroidAbiIds[arch]!
        : null,
    certSha256: kind.isAndroid ? 'ab' * 32 : null,
  );
}

AppUpdatePayload payload({
  String version = '1.2.3',
  String channel = 'stable',
  String appId = appUpdateAppId,
  int minSupportedBuild = 0,
  List<AppUpdateArtifact>? artifacts,
}) {
  final tag = 'v$version';
  AppUpdateChangelogEntry entry(String text) => AppUpdateChangelogEntry(
    version: version,
    date: '2026-11-27',
    markdown: text,
  );
  return AppUpdatePayload(
    schemaVersion: 1,
    appId: appId,
    channel: channel,
    version: version,
    build: appUpdateBuildOf(version),
    tag: tag,
    commit: 'a' * 40,
    releasedAt: '2026-11-27T10:00:00Z',
    minSupportedBuild: minSupportedBuild,
    notesUrl: 'https://github.com/CyberCat2033/AntiRKN/releases/tag/$tag',
    changelog: {
      'en': [entry('### Fixed\n\n- English')],
      'ru': [entry('### Исправлено\n\n- Русский')],
    },
    artifacts:
        artifacts ??
        [
          for (final arch in ['arm64-v8a', 'armeabi-v7a', 'universal'])
            artifact(
              AppUpdateKind.androidApk,
              arch,
              tag: tag,
              build: appUpdateBuildOf(version),
            ),
          artifact(AppUpdateKind.windowsInstaller, 'x64', tag: tag),
          artifact(AppUpdateKind.windowsPortable, 'x64', tag: tag),
          artifact(AppUpdateKind.linuxAppimage, 'x64', tag: tag),
          artifact(AppUpdateKind.linuxTarball, 'x64', tag: tag),
        ],
  );
}

Future<Uint8List> signed(
  AppUpdatePayload value, {
  Uint8List? seed,
  String keyId = 'k1',
}) async {
  final envelope = await signAppUpdateEnvelope(
    encodeAppUpdatePayload(value),
    keyId: keyId,
    seed: seed ?? testSeed,
  );
  return envelope.encode();
}

Future<List<AppUpdateTrustedKey>> trusted({
  Uint8List? seed,
  String keyId = 'k1',
}) async => [
  AppUpdateTrustedKey(keyId, await appUpdatePublicKeyOf(seed ?? testSeed)),
];
