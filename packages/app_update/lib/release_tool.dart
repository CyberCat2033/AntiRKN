/// Release-side manifest building and signing, used by
/// `tool/app_update_manifest.dart`. Not part of the app.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';

import 'src/ed25519.dart';
import 'src/github_http.dart';

export 'src/ed25519.dart' show signAppUpdatePayload, appUpdatePublicKeyOf;

/// Environment variable with the base64url 32-byte Ed25519 seed.
const appUpdateSigningKeyVariable = 'ANTIRKN_UPDATE_SIGNING_KEY';

final class ReleaseToolFailure implements Exception {
  const ReleaseToolFailure(this.code);
  final String code;
  @override
  String toString() => code;
}

/// `(kind, arch)` of a release file name, null for unrelated files.
(AppUpdateKind, String)? appUpdateArtifactOf(String fileName, String tag) {
  final prefix = 'AntiRKN-$tag-';
  if (!fileName.startsWith(prefix)) return null;
  final rest = fileName.substring(prefix.length);
  const desktop = {
    'windows-x64-setup.exe': (AppUpdateKind.windowsInstaller, 'x64'),
    'windows-x64-portable.zip': (AppUpdateKind.windowsPortable, 'x64'),
    'linux-x64.tar.gz': (AppUpdateKind.linuxTarball, 'x64'),
    'linux-x64.AppImage': (AppUpdateKind.linuxAppimage, 'x64'),
  };
  final known = desktop[rest];
  if (known != null) return known;
  final android = RegExp(r'^android-([a-z0-9_-]+)\.apk$').firstMatch(rest);
  final arch = android?.group(1);
  if (arch != null &&
      appUpdateKindArches[AppUpdateKind.androidApk]!.contains(arch)) {
    return (AppUpdateKind.androidApk, arch);
  }
  throw const ReleaseToolFailure('artifact_name_unknown');
}

/// Builds and validates the payload from the release directory and the two
/// CHANGELOG files. [androidVersionCodes] maps an APK arch to the real
/// versionCode read from it (split APKs carry Flutter's ABI offset).
Future<AppUpdatePayload> buildAppUpdatePayload({
  required String channel,
  required String tag,
  required String commit,
  required String notesUrl,
  required String artifactsDirectory,
  required String baseUrl,
  required String changelogDirectory,
  String? androidCertSha256,
  Map<String, int> androidVersionCodes = const {},
  int minSupportedBuild = 0,
  DateTime? releasedAt,
}) async {
  final version = tag.startsWith('v') ? tag.substring(1) : '';
  if (baseUrl.replaceAll(RegExp(r'/+$'), '') !=
      '$appUpdateArtifactUrlPrefix$tag') {
    throw const ReleaseToolFailure('base_url_invalid');
  }
  final changelog = appUpdateChangelogForRelease(
    version: version,
    files: {
      'en': await File('$changelogDirectory/CHANGELOG.md').readAsString(),
      'ru': await File('$changelogDirectory/CHANGELOG.ru.md').readAsString(),
    },
  );
  final artifacts = <AppUpdateArtifact>[];
  final entries = await Directory(
    artifactsDirectory,
  ).list(followLinks: false).where((e) => e is File).toList();
  entries.sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    final name = entry.uri.pathSegments.last;
    final parsed = appUpdateArtifactOf(name, tag);
    if (parsed == null) continue;
    final (kind, arch) = parsed;
    final android = kind.isAndroid;
    if (android &&
        (androidCertSha256 == null || androidVersionCodes[arch] == null)) {
      throw const ReleaseToolFailure('android_metadata_missing');
    }
    artifacts.add(
      AppUpdateArtifact(
        kind: kind,
        arch: arch,
        fileName: name,
        url: '$appUpdateArtifactUrlPrefix$tag/$name',
        size: await (entry as File).length(),
        sha256: await sha256OfFile(entry.path),
        versionCode: android ? androidVersionCodes[arch] : null,
        certSha256: android ? androidCertSha256!.toLowerCase() : null,
      ),
    );
  }
  if (artifacts.isEmpty) throw const ReleaseToolFailure('artifacts_missing');
  final at = (releasedAt ?? DateTime.now()).toUtc();
  final payload = AppUpdatePayload(
    schemaVersion: appUpdateSchemaVersion,
    appId: appUpdateAppId,
    channel: channel,
    version: version,
    build: RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version)
        ? appUpdateBuildOf(version)
        : 0,
    tag: tag,
    commit: commit,
    releasedAt: DateTime.utc(
      at.year,
      at.month,
      at.day,
      at.hour,
      at.minute,
      at.second,
    ).toIso8601String().replaceAll('.000', ''),
    minSupportedBuild: minSupportedBuild,
    notesUrl: notesUrl,
    changelog: changelog,
    artifacts: artifacts,
  );
  // The same strict parser the app uses: a payload the app would refuse is
  // never written.
  return parseAppUpdatePayload(encodeAppUpdatePayload(payload));
}

Uint8List encodeAppUpdatePayload(AppUpdatePayload payload) =>
    utf8.encode(jsonEncode(payload.toJson()));

/// Reads the seed from [environment] only; never from arguments or files
/// passed on the command line.
Uint8List readSigningSeed(Map<String, String> environment) {
  final value = environment[appUpdateSigningKeyVariable]?.trim();
  if (value == null || value.isEmpty) {
    throw const ReleaseToolFailure('signing_key_missing');
  }
  try {
    final seed = appUpdateBase64Decode(value);
    if (seed.length != 32) throw const FormatException();
    return seed;
  } catch (_) {
    throw const ReleaseToolFailure('signing_key_invalid');
  }
}

/// Signs [payload] bytes as they are; with [existing], adds the signature
/// to an envelope over the same bytes (a second key during rotation).
Future<AppUpdateEnvelope> signAppUpdateEnvelope(
  Uint8List payload, {
  required String keyId,
  required Uint8List seed,
  AppUpdateEnvelope? existing,
}) async {
  parseAppUpdatePayload(payload);
  if (!appUpdateKeyId.hasMatch(keyId)) {
    throw const ReleaseToolFailure('key_id_invalid');
  }
  if (existing != null &&
      (!_same(existing.payloadBytes, payload) ||
          existing.signatures.any((s) => s.keyId == keyId))) {
    throw const ReleaseToolFailure('envelope_mismatch');
  }
  final signature = await signAppUpdatePayload(payload, seed);
  return AppUpdateEnvelope(payload, [
    ...?existing?.signatures,
    AppUpdateSignature(keyId, signature),
  ]);
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List newSigningSeed() {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
}
