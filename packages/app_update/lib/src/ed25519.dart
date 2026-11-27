import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

final _ed25519 = DartEd25519();

/// Ed25519 over the raw signed message; any failure is a negative result.
final class Ed25519UpdateVerifier implements AppUpdateSignatureVerifier {
  const Ed25519UpdateVerifier();

  @override
  Future<bool> verify({
    required List<int> message,
    required List<int> signature,
    required List<int> publicKey,
  }) async {
    if (signature.length != 64 || publicKey.length != 32) return false;
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }
}

/// Release-side signing (the manifest CLI). The seed never leaves memory
/// and is wiped by the caller.
Future<Uint8List> signAppUpdatePayload(
  List<int> payload,
  List<int> seed,
) async {
  if (seed.length != 32) throw const FormatException('signing_key_invalid');
  final keyPair = await _ed25519.newKeyPairFromSeed(seed);
  final signature = await _ed25519.sign(
    AppUpdateEnvelope.signedMessage(payload),
    keyPair: keyPair,
  );
  return Uint8List.fromList(signature.bytes);
}

/// The public key of a 32-byte seed, unpadded base64url.
Future<String> appUpdatePublicKeyOf(List<int> seed) async {
  if (seed.length != 32) throw const FormatException('signing_key_invalid');
  final keyPair = await _ed25519.newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  return appUpdateBase64(publicKey.bytes);
}

/// A streaming SHA-256 of a byte stream, lower-case hex.
final class Sha256Stream {
  final _sink = const DartSha256().newHashSink();
  int length = 0;

  void add(List<int> chunk) {
    length += chunk.length;
    _sink.add(chunk);
  }

  String close() {
    _sink.close();
    return _hex(_sink.hashSync().bytes);
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
