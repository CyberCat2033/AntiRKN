import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_app_update/antirkn_app_update.dart';
import 'package:antirkn_app_update/release_tool.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/dart.dart';
import 'package:test/test.dart';

import 'support.dart';

Future<String> failure(Future<Object?> Function() run) async {
  try {
    await run();
  } on AppUpdateFailure catch (error) {
    return error.code;
  }
  return 'no failure';
}

Map<String, Object?> envelopeJson(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

void main() {
  const verifier = Ed25519UpdateVerifier();

  test('a signed manifest verifies and round-trips its payload', () async {
    final bytes = await signed(payload());
    final result = await verifyAppUpdateManifest(
      bytes,
      trustedKeys: await trusted(),
      verifier: verifier,
    );
    expect(result.toJson(), payload().toJson());
    expect(result.changelog['ru']!.single.markdown, contains('Русский'));
  });

  test('no trusted keys means updates are unavailable', () async {
    expect(
      await failure(
        () async => verifyAppUpdateManifest(
          await signed(payload()),
          trustedKeys: const [],
          verifier: verifier,
        ),
      ),
      AppUpdateCode.unavailable,
    );
  });

  test('a tampered payload fails the signature before parsing', () async {
    final json = envelopeJson(await signed(payload()));
    final raw = utf8.decode(appUpdateBase64Decode(json['payload'] as String));
    json['payload'] = appUpdateBase64(
      utf8.encode(raw.replaceFirst('"build":10203', '"build":10204')),
    );
    expect(
      await failure(
        () async => verifyAppUpdateManifest(
          utf8.encode(jsonEncode(json)),
          trustedKeys: await trusted(),
          verifier: verifier,
        ),
      ),
      AppUpdateCode.signature,
    );
  });

  test('an unknown key id and a wrong key are refused', () async {
    final bytes = await signed(payload(), keyId: 'k9');
    expect(
      await failure(
        () async => verifyAppUpdateManifest(
          bytes,
          trustedKeys: await trusted(),
          verifier: verifier,
        ),
      ),
      AppUpdateCode.unknownKey,
    );
    expect(
      await failure(
        () async => verifyAppUpdateManifest(
          await signed(payload(), seed: otherSeed),
          trustedKeys: await trusted(),
          verifier: verifier,
        ),
      ),
      AppUpdateCode.signature,
    );
  });

  test('a signature without the domain prefix is refused', () async {
    final body = encodeAppUpdatePayload(payload());
    final keyPair = await DartEd25519().newKeyPairFromSeed(testSeed);
    final raw = await DartEd25519().sign(body, keyPair: keyPair);
    final bytes = AppUpdateEnvelope(body, [
      AppUpdateSignature('k1', Uint8List.fromList(raw.bytes)),
    ]).encode();
    expect(
      await failure(
        () async => verifyAppUpdateManifest(
          bytes,
          trustedKeys: await trusted(),
          verifier: verifier,
        ),
      ),
      AppUpdateCode.signature,
    );
  });

  test('a second trusted key verifies during rotation', () async {
    final first = AppUpdateEnvelope.decode(await signed(payload()));
    final both = await signAppUpdateEnvelope(
      first.payloadBytes,
      keyId: 'k2',
      seed: otherSeed,
      existing: first,
    );
    final result = await verifyAppUpdateManifest(
      both.encode(),
      trustedKeys: await trusted(seed: otherSeed, keyId: 'k2'),
      verifier: verifier,
    );
    expect(result.build, 10203);
  });

  test('malformed envelopes are refused', () async {
    final good = envelopeJson(await signed(payload()));
    final cases = <Map<String, Object?>>[
      {...good, 'format': 'other'},
      {...good, 'extra': 1},
      {...good, 'payload': '${good['payload']}='},
      {...good, 'payload': 'a+b/'},
      {...good, 'signatures': []},
      {
        ...good,
        'signatures': [
          (good['signatures'] as List).single,
          (good['signatures'] as List).single,
        ],
      },
      {
        ...good,
        'signatures': [
          {'keyId': 'K1', 'sig': 'AA'},
        ],
      },
    ];
    for (final json in cases) {
      expect(
        await failure(
          () async => AppUpdateEnvelope.decode(utf8.encode(jsonEncode(json))),
        ),
        AppUpdateCode.manifestInvalid,
      );
    }
    expect(
      await failure(
        () async =>
            AppUpdateEnvelope.decode(Uint8List(appUpdateManifestMaxBytes + 1)),
      ),
      AppUpdateCode.size,
    );
  });

  group('payload schema', () {
    Map<String, Object?> json() =>
        jsonDecode(jsonEncode(payload().toJson())) as Map<String, Object?>;
    String parse(Map<String, Object?> value) {
      try {
        parseAppUpdatePayload(utf8.encode(jsonEncode(value)));
        return 'ok';
      } on AppUpdateFailure catch (error) {
        return error.code;
      }
    }

    test('accepts the fixture', () => expect(parse(json()), 'ok'));

    test('refuses unknown, missing and mistyped fields', () {
      expect(parse(json()..['extra'] = 1), AppUpdateCode.manifestInvalid);
      expect(parse(json()..remove('commit')), AppUpdateCode.manifestInvalid);
      expect(parse(json()..['build'] = '10203'), AppUpdateCode.manifestInvalid);
      expect(
        parse(json()..['schemaVersion'] = 2),
        AppUpdateCode.manifestInvalid,
      );
    });

    test('refuses inconsistent tag, build and artifact urls', () {
      expect(parse(json()..['tag'] = 'v1.2.4'), AppUpdateCode.manifestInvalid);
      expect(parse(json()..['build'] = 10204), AppUpdateCode.manifestInvalid);
      final foreign = json();
      ((foreign['artifacts'] as List).first as Map)['url'] =
          'https://example.com/AntiRKN-v1.2.3-android-arm64-v8a.apk';
      expect(parse(foreign), AppUpdateCode.manifestInvalid);
      final desktopCode = json();
      ((desktopCode['artifacts'] as List).last as Map)['versionCode'] = 1;
      expect(parse(desktopCode), AppUpdateCode.manifestInvalid);
      final wrongCode = json();
      ((wrongCode['artifacts'] as List).first as Map)['versionCode'] = 102031;
      expect(parse(wrongCode), AppUpdateCode.manifestInvalid);
      final wrongArch = json();
      ((wrongArch['artifacts'] as List).last as Map)['arch'] = 'arm64-v8a';
      expect(parse(wrongArch), AppUpdateCode.manifestInvalid);
    });

    test('refuses a changelog without the release or out of order', () {
      final missing = json();
      ((missing['changelog'] as Map)['ru'] as List).clear();
      expect(parse(missing), AppUpdateCode.manifestInvalid);
      final older = json();
      (((older['changelog'] as Map)['en'] as List).first as Map)['version'] =
          '1.2.2';
      expect(parse(older), AppUpdateCode.manifestInvalid);
      final control = json();
      (((control['changelog'] as Map)['en'] as List).first as Map)['markdown'] =
          'bad\u0007';
      expect(parse(control), AppUpdateCode.manifestInvalid);
    });
  });
}
