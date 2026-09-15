import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Version 1 password protection, shared with the existing portable vault.
/// Run in an isolate: Argon2 is deliberately CPU/memory intensive.
Future<SecretKeyData> derivePasswordKey(String password, List<int> salt) async {
  final input = SecretKeyData(
    utf8.encode(password),
    overwriteWhenDestroyed: true,
  );
  try {
    final derived = await Argon2id(
      parallelism: 1,
      memory: 19456,
      iterations: 2,
      hashLength: 32,
    ).deriveKey(secretKey: input, nonce: salt);
    try {
      return SecretKeyData(
        Uint8List.fromList(await derived.extractBytes()),
        overwriteWhenDestroyed: true,
      );
    } finally {
      derived.destroy();
    }
  } finally {
    input.destroy();
  }
}
