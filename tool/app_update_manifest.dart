// Builds, signs and verifies the signed application update manifest.
//
//   build         --channel stable --tag vX.Y.Z --commit SHA --notes-url URL
//                 --artifacts-dir DIR --base-url URL --changelog-dir DIR
//                 [--android-cert-sha256 HEX] [--android-version-codes FILE]
//                 [--min-supported-build N] [--released-at ISO] --out FILE
//   sign          --payload FILE --key-id k1 --out FILE [--append]
//                 (seed only from env ANTIRKN_UPDATE_SIGNING_KEY)
//   verify        --manifest FILE [--channel stable] [--trusted-key ID:PUB]
//   keygen        --private-out FILE [--key-id k1]
//   release-notes --tag vX.Y.Z --changelog-dir DIR --out FILE
//
// Errors are printed as codes only; no key material is ever printed.
import 'dart:convert';
import 'dart:io';

import 'package:antirkn_app_update/antirkn_app_update.dart';
import 'package:antirkn_app_update/release_tool.dart';
import 'package:antirkn_domain/antirkn_domain.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runAppUpdateManifest(arguments);
}

Future<int> runAppUpdateManifest(
  List<String> arguments, {
  Map<String, String>? environment,
  StringSink? out,
  StringSink? err,
}) async {
  out ??= stdout;
  err ??= stderr;
  try {
    if (arguments.isEmpty) throw const ReleaseToolFailure('usage');
    final options = _Options.parse(arguments.skip(1).toList());
    switch (arguments.first) {
      case 'build':
        await _build(options);
      case 'sign':
        await _sign(options, environment ?? Platform.environment);
      case 'verify':
        out.writeln(await _verify(options));
      case 'keygen':
        out.writeln(await _keygen(options));
      case 'release-notes':
        await _releaseNotes(options);
      default:
        throw const ReleaseToolFailure('usage');
    }
    return 0;
  } on ReleaseToolFailure catch (error) {
    err.writeln('app_update_manifest: ${error.code}');
  } on AppUpdateFailure catch (error) {
    err.writeln('app_update_manifest: ${error.code}');
  } on FormatException catch (error) {
    final code = RegExp(r'^[a-z_]{1,40}$').hasMatch(error.message)
        ? error.message
        : 'invalid_input';
    err.writeln('app_update_manifest: $code');
  } on FileSystemException {
    err.writeln('app_update_manifest: file_error');
  }
  return 1;
}

Future<void> _build(_Options o) async {
  final codes = <String, int>{};
  final codesPath = o.optional('android-version-codes');
  if (codesPath != null) {
    final json = jsonDecode(await File(codesPath).readAsString());
    if (json is! Map<String, Object?>) {
      throw const ReleaseToolFailure('version_codes_invalid');
    }
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is! int) {
        throw const ReleaseToolFailure('version_codes_invalid');
      }
      codes[entry.key] = value;
    }
  }
  final releasedAt = o.optional('released-at');
  final payload = await buildAppUpdatePayload(
    channel: o.required('channel'),
    tag: o.required('tag'),
    commit: o.required('commit'),
    notesUrl: o.required('notes-url'),
    artifactsDirectory: o.required('artifacts-dir'),
    baseUrl: o.required('base-url'),
    changelogDirectory: o.required('changelog-dir'),
    androidCertSha256: o.optional('android-cert-sha256'),
    androidVersionCodes: codes,
    minSupportedBuild: int.parse(o.optional('min-supported-build') ?? '0'),
    releasedAt: releasedAt == null ? null : DateTime.parse(releasedAt),
  );
  await _write(o.required('out'), encodeAppUpdatePayload(payload));
}

Future<void> _sign(_Options o, Map<String, String> environment) async {
  final seed = readSigningSeed(environment);
  try {
    final payload = await File(o.required('payload')).readAsBytes();
    final target = o.required('out');
    AppUpdateEnvelope? existing;
    if (o.flag('append')) {
      existing = AppUpdateEnvelope.decode(await File(target).readAsBytes());
    }
    final envelope = await signAppUpdateEnvelope(
      payload,
      keyId: o.required('key-id'),
      seed: seed,
      existing: existing,
    );
    await _write(target, envelope.encode());
  } finally {
    seed.fillRange(0, seed.length, 0);
  }
}

Future<String> _verify(_Options o) async {
  final keys = [
    for (final value in o.all('trusted-key'))
      () {
        final split = value.indexOf(':');
        if (split < 1) throw const ReleaseToolFailure('trusted_key_invalid');
        return AppUpdateTrustedKey(
          value.substring(0, split),
          value.substring(split + 1),
        );
      }(),
  ];
  final payload = await verifyAppUpdateManifest(
    await File(o.required('manifest')).readAsBytes(),
    trustedKeys: keys.isEmpty ? appUpdateTrustedKeys : keys,
    verifier: const Ed25519UpdateVerifier(),
  );
  final channel = o.optional('channel');
  if (channel != null && payload.channel != channel) {
    throw const AppUpdateFailure(AppUpdateCode.channelMismatch);
  }
  return 'ok ${payload.tag} build ${payload.build} '
      '${payload.artifacts.length} artifacts';
}

Future<String> _keygen(_Options o) async {
  final path = o.required('private-out');
  final keyId = o.optional('key-id') ?? 'k1';
  if (!appUpdateKeyId.hasMatch(keyId)) {
    throw const ReleaseToolFailure('key_id_invalid');
  }
  final seed = newSigningSeed();
  try {
    final file = File(path);
    await file.create(exclusive: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['600', '--', path]);
      if (chmod.exitCode != 0) {
        await file.delete();
        throw const ReleaseToolFailure('key_file_mode');
      }
    }
    await file.writeAsString(appUpdateBase64(seed), flush: true);
    final publicKey = await appUpdatePublicKeyOf(seed);
    return "keyId $keyId publicKey $publicKey\n"
        "AppUpdateTrustedKey('$keyId', '$publicKey'),";
  } finally {
    seed.fillRange(0, seed.length, 0);
  }
}

Future<void> _releaseNotes(_Options o) async {
  final tag = o.required('tag');
  final directory = o.required('changelog-dir');
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  final changelog = appUpdateChangelogForRelease(
    version: version,
    files: {
      'en': await File('$directory/CHANGELOG.md').readAsString(),
      'ru': await File('$directory/CHANGELOG.ru.md').readAsString(),
    },
  );
  await _write(
    o.required('out'),
    utf8.encode(appUpdateReleaseNotes(changelog, version)),
  );
}

Future<void> _write(String path, List<int> bytes) async {
  final part = File('$path.part');
  await part.writeAsBytes(bytes, flush: true);
  await part.rename(path);
}

final class _Options {
  _Options(this._values, this._flags);
  final Map<String, List<String>> _values;
  final Set<String> _flags;
  static const _flagNames = {'append'};

  static _Options parse(List<String> arguments) {
    final values = <String, List<String>>{};
    final flags = <String>{};
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (!argument.startsWith('--')) {
        throw const ReleaseToolFailure('usage');
      }
      final name = argument.substring(2);
      if (_flagNames.contains(name)) {
        flags.add(name);
        continue;
      }
      if (i + 1 >= arguments.length) throw const ReleaseToolFailure('usage');
      values.putIfAbsent(name, () => []).add(arguments[++i]);
    }
    return _Options(values, flags);
  }

  String required(String name) =>
      optional(name) ??
      (throw ReleaseToolFailure('missing_$name'.replaceAll('-', '_')));

  String? optional(String name) {
    final list = _values[name];
    if (list != null && list.length > 1) {
      throw const ReleaseToolFailure('usage');
    }
    return list?.single;
  }

  List<String> all(String name) => _values[name] ?? const [];

  bool flag(String name) => _flags.contains(name);
}
