import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:test/test.dart';

import '../../../tool/app_update_manifest.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('antirkn-cli-'),
  );
  tearDown(() => root.delete(recursive: true));

  Future<(int, String, String)> run(
    List<String> args, [
    Map<String, String> env = const {},
  ]) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runAppUpdateManifest(
      args,
      environment: env,
      out: out,
      err: err,
    );
    return (code, '$out', '$err');
  }

  void changelogs({bool ruSection = true}) {
    File('${root.path}/CHANGELOG.md').writeAsStringSync(
      '# Changelog\n\n## [Unreleased]\n\n## [1.2.3] - 2026-11-27\n\n### Fixed\n\n- Fix\n\n## [1.2.2] - 2026-11-20\n\n- Old\n',
    );
    File('${root.path}/CHANGELOG.ru.md').writeAsStringSync(
      '# Список изменений\n\n## [Unreleased]\n\n'
      '${ruSection ? '## [1.2.3] - 2026-11-27\n\n### Исправлено\n\n- Исправление\n\n' : ''}'
      '## [1.2.2] - 2026-11-20\n\n- Старое\n',
    );
  }

  List<String> buildArgs() => [
    'build',
    '--channel',
    'stable',
    '--tag',
    'v1.2.3',
    '--commit',
    'a' * 40,
    '--notes-url',
    'https://github.com/CyberCat2033/AntiRKN/releases/tag/v1.2.3',
    '--artifacts-dir',
    '${root.path}/dist',
    '--base-url',
    'https://github.com/CyberCat2033/AntiRKN/releases/download/v1.2.3',
    '--changelog-dir',
    root.path,
    '--android-cert-sha256',
    'AB' * 32,
    '--android-version-codes',
    '${root.path}/codes.json',
    '--released-at',
    '2026-11-27T10:00:00Z',
    '--out',
    '${root.path}/payload.json',
  ];

  void artifacts() {
    final dist = Directory('${root.path}/dist')..createSync();
    for (final name in [
      'AntiRKN-v1.2.3-android-arm64-v8a.apk',
      'AntiRKN-v1.2.3-android-universal.apk',
      'AntiRKN-v1.2.3-linux-x64.tar.gz',
      'AntiRKN-v1.2.3-linux-x64.AppImage',
      'AntiRKN-v1.2.3-windows-x64-setup.exe',
      'AntiRKN-v1.2.3-windows-x64-portable.zip',
      'SHA256SUMS',
    ]) {
      File('${dist.path}/$name').writeAsStringSync(name);
    }
    File(
      '${root.path}/codes.json',
    ).writeAsStringSync(jsonEncode({'arm64-v8a': 102032, 'universal': 102030}));
  }

  test(
    'keygen, build, sign and verify round-trip with a throwaway key',
    () async {
      changelogs();
      artifacts();
      final key = '${root.path}/k1.key';
      final (keygen, printed, _) = await run(['keygen', '--private-out', key]);
      expect(keygen, 0);
      final seed = File(key).readAsStringSync();
      expect(
        printed,
        isNot(contains(seed)),
        reason: 'only the public key is printed',
      );
      expect((await File(key).stat()).modeString(), 'rw-------');
      final publicKey = RegExp(
        r'publicKey (\S+)',
      ).firstMatch(printed)!.group(1)!;

      final (build, _, buildErr) = await run(buildArgs());
      expect(build, 0, reason: buildErr);
      final payload = parseAppUpdatePayload(
        File('${root.path}/payload.json').readAsBytesSync(),
      );
      expect(payload.artifacts, hasLength(6));
      expect(
        payload.artifacts.firstWhere((a) => a.arch == 'arm64-v8a').versionCode,
        102032,
      );
      expect(
        payload.changelog['ru']!.first.markdown,
        '### Исправлено\n\n- Исправление',
      );

      final signArgs = [
        'sign',
        '--payload',
        '${root.path}/payload.json',
        '--key-id',
        'k1',
        '--out',
        '${root.path}/app-update-stable.json',
      ];
      final (missing, _, missingErr) = await run(signArgs);
      expect(missing, 1);
      expect(missingErr.trim(), 'app_update_manifest: signing_key_missing');
      final (sign, signOut, signErr) = await run(signArgs, {
        'ANTIRKN_UPDATE_SIGNING_KEY': seed,
      });
      expect(sign, 0, reason: signErr);
      expect('$signOut$signErr', isNot(contains(seed)));

      final verifyArgs = [
        'verify',
        '--manifest',
        '${root.path}/app-update-stable.json',
        '--channel',
        'stable',
      ];
      final (verified, out, _) = await run([
        ...verifyArgs,
        '--trusted-key',
        'k1:$publicKey',
      ]);
      expect(verified, 0);
      expect(out.trim(), 'ok v1.2.3 build 10203 6 artifacts');
      final (embedded, _, embeddedErr) = await run(verifyArgs);
      expect(embedded, 1, reason: 'a throwaway k1 is not the release k1');
      expect(embeddedErr.trim(), 'app_update_manifest: update_signature');
      final (wrong, _, wrongErr) = await run([
        ...verifyArgs,
        '--trusted-key',
        'k2:$publicKey',
      ]);
      expect(wrong, 1);
      expect(wrongErr.trim(), 'app_update_manifest: update_unknown_key');
    },
  );

  test('build fails without the release section in either changelog', () async {
    changelogs(ruSection: false);
    artifacts();
    final (code, _, err) = await run(buildArgs());
    expect(code, 1);
    expect(err.trim(), 'app_update_manifest: changelog_missing');
  });

  test('build refuses wrong versionCodes and foreign base urls', () async {
    changelogs();
    artifacts();
    File('${root.path}/codes.json').writeAsStringSync(
      jsonEncode({'arm64-v8a': 2010203, 'universal': 102030}),
    );
    expect((await run(buildArgs())).$1, 1);
    final args = buildArgs();
    args[args.indexOf('--base-url') + 1] = 'https://example.com/v1.2.3';
    expect(
      (await run(args)).$3.trim(),
      'app_update_manifest: base_url_invalid',
    );
  });

  test('release-notes writes the bilingual body', () async {
    changelogs();
    final (code, _, _) = await run([
      'release-notes',
      '--tag',
      'v1.2.3',
      '--changelog-dir',
      root.path,
      '--out',
      '${root.path}/notes.md',
    ]);
    expect(code, 0);
    expect(
      File('${root.path}/notes.md').readAsStringSync(),
      '## English\n\n### Fixed\n\n- Fix\n\n## Русский\n\n### Исправлено\n\n- Исправление\n',
    );
  });

  test('the repository changelogs carry the current entries', () {
    final repo = Directory.current.parent.parent.path;
    final changelog = appUpdateChangelogForRelease(
      version: '0.1.0',
      files: {
        'en': File('$repo/CHANGELOG.md').readAsStringSync(),
        'ru': File('$repo/CHANGELOG.ru.md').readAsStringSync(),
      },
    );
    expect(changelog['en']!.single.version, '0.1.0');
  });
}
