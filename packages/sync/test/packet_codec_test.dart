import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  late Map<String, dynamic> fixture, body;
  late Uint8List packet;
  late SecretKeyData key;
  late SyncPacketCodec codec;
  late LocalChange change;
  setUp(() {
    fixture =
        jsonDecode(
              File('test/fixtures/libsodium-packet.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    body = fixture['body'] as Map<String, dynamic>;
    key = SecretKeyData(List.generate(32, (i) => i));
    packet = base64Decode(fixture['packet'] as String);
    codec = SyncPacketCodec(workspaceId: 'a' * 32, keyVersion: 1, key: key);
    change = LocalChange(
      header: ChangeHeader.fromJson(body['header'] as Map<String, dynamic>),
      source: body['source'] as String,
    );
  });
  tearDown(() => key.destroy());
  Matcher issue(SyncPacketIssue value) =>
      isA<SyncPacketFailure>().having((e) => e.issue, 'issue', value);

  test(
    'decrypts an independent libsodium vector and preserves the full event',
    () async {
      final actual = await codec.open(packet);
      expect(actual.header.toJson(), change.header.toJson());
      expect(actual.source, change.source);
      expect(actual.toString(), isNot(contains('PUBLIC-test-vector')));
    },
  );

  test(
    'roundtrip hides entity metadata; fresh encryptions use distinct nonces',
    () async {
      final first = await codec.seal(change), second = await codec.seal(change);
      expect(first, isNot(second));
      expect(
        first.sublist(syncHeaderBytes, syncHeaderBytes + syncNonceBytes),
        isNot(
          second.sublist(syncHeaderBytes, syncHeaderBytes + syncNonceBytes),
        ),
      );
      expect((await codec.open(first)).source, change.source);
      final visible = latin1.decode(first);
      for (final text in [
        'fixture-server',
        'PUBLIC-test-vector',
        'entityKind',
        'deviceId',
      ]) {
        expect(visible, isNot(contains(text)));
      }
    },
  );

  test(
    'modification of every header byte, nonce, ciphertext and tag is rejected',
    () async {
      for (final offset in [
        ...List.generate(syncHeaderBytes, (i) => i),
        syncHeaderBytes,
        syncHeaderBytes + syncNonceBytes,
        packet.length - 1,
      ]) {
        final damaged = Uint8List.fromList(packet)..[offset] ^= 1;
        await expectLater(
          codec.open(damaged),
          throwsA(isA<SyncPacketFailure>()),
        );
      }
      await expectLater(
        codec.open(Uint8List.fromList([...packet, 0])),
        throwsA(issue(SyncPacketIssue.invalid)),
      );
      for (final length in [0, 8, 45, 85, packet.length - 1]) {
        await expectLater(
          codec.open(Uint8List.sublistView(packet, 0, length)),
          throwsA(isA<SyncPacketFailure>()),
        );
      }
    },
  );

  test(
    'wrong key, workspace and key version fail with safe typed errors',
    () async {
      final wrongKey = SecretKeyData(List.filled(32, 99));
      try {
        await expectLater(
          SyncPacketCodec(
            workspaceId: 'a' * 32,
            keyVersion: 1,
            key: wrongKey,
          ).open(packet),
          throwsA(issue(SyncPacketIssue.invalid)),
        );
        await expectLater(
          SyncPacketCodec(
            workspaceId: 'e' * 32,
            keyVersion: 1,
            key: key,
          ).open(packet),
          throwsA(issue(SyncPacketIssue.workspace)),
        );
        await expectLater(
          SyncPacketCodec(
            workspaceId: 'a' * 32,
            keyVersion: 2,
            key: key,
          ).open(packet),
          throwsA(issue(SyncPacketIssue.keyVersion)),
        );
        // Changing the routing header to the receiver still cannot forge its MAC.
        final moved = Uint8List.fromList(packet)
          ..fillRange(syncWorkspaceIdOffset, syncChangeIdOffset, 0xee);
        await expectLater(
          SyncPacketCodec(
            workspaceId: 'e' * 32,
            keyVersion: 1,
            key: key,
          ).open(moved),
          throwsA(issue(SyncPacketIssue.invalid)),
        );
      } finally {
        wrongKey.destroy();
      }
    },
  );

  Future<Uint8List> authenticated(String text) async {
    final aad = packet.sublist(0, syncHeaderBytes);
    final box = await Xchacha20.poly1305Aead().encrypt(
      utf8.encode(text),
      secretKey: key,
      aad: aad,
    );
    return Uint8List.fromList([...aad, ...box.concatenation()]);
  }

  test(
    'authentic but malformed, duplicate, incompatible or inconsistent bodies are refused',
    () async {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => (v['header'] as Map)['version'] = 99,
        (v) => (v['header'] as Map)['changeId'] = 'e' * 32,
        (v) => (v['header'] as Map)['workspaceId'] = 'e' * 32,
        (v) => (v['header'] as Map)['sequence'] = 0,
        (v) => (v['header'] as Map)['revision'] = 9,
        (v) => (v['header'] as Map)['transactionIndex'] = 1,
        (v) => v['source'] = null,
        (v) => v['extra'] = true,
      ]) {
        final value = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
        mutate(value);
        await expectLater(
          codec.open(await authenticated(canonicalJson(value))),
          throwsA(isA<SyncPacketFailure>()),
        );
      }
      final text = canonicalJson(body);
      await expectLater(
        codec.open(
          await authenticated('{"source":"duplicate",${text.substring(1)}'),
        ),
        throwsA(issue(SyncPacketIssue.invalid)),
      );
      await expectLater(
        codec.open(await authenticated('[' * 10 + ']' * 10)),
        throwsA(issue(SyncPacketIssue.invalid)),
      );
    },
  );

  test('a tombstone and a repeated valid packet are data only', () async {
    final header = Map<String, dynamic>.from(change.header.toJson())
      ..['deleted'] = true;
    final tombstone = LocalChange(
      header: ChangeHeader.fromJson(header),
      source: null,
    );
    final bytes = await codec.seal(tombstone);
    expect((await codec.open(bytes)).source, isNull);
    expect((await codec.open(bytes)).header.deleted, isTrue);
    expect(
      (await codec.open(packet)).header.changeId,
      (await codec.open(packet)).header.changeId,
    );
  });

  test('oversized input is refused before parsing or decryption', () async {
    await expectLater(
      codec.open(Uint8List(syncMaxPacketBytes + 1)),
      throwsA(issue(SyncPacketIssue.tooLarge)),
    );
    await expectLater(
      codec.seal(
        LocalChange(
          header: change.header,
          source: 'x' * (syncMaxSourceBytes + 1),
        ),
      ),
      throwsA(issue(SyncPacketIssue.tooLarge)),
    );
  });
}
