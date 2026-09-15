import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'secret_vault.dart';

/// Device-local OAuth record. It is never a workspace entity or a backup entry.
abstract interface class GoogleSessionStore {
  Future<String?> read();
  Future<void> replace(String? expected, String? value);
}

final class EncryptedGoogleSessionStore implements GoogleSessionStore {
  EncryptedGoogleSessionStore({required File file, required SecretKey key})
    : _files = LocalVaultFileStore(file),
      _key = key;
  final VaultFileStore _files;
  final SecretKey _key;
  static final _cipher = AesGcm.with256bits();
  static final _aad = utf8.encode('antirkn-device-google-session-v1');

  Future<String?> _decode(String? encoded) async {
    if (encoded == null) return null;
    final envelope = jsonDecode(encoded) as Map<String, dynamic>;
    if (envelope['version'] != 1) throw const FormatException();
    final plain = await _cipher.decrypt(
      SecretBox.fromConcatenation(
        base64Decode(envelope['box'] as String),
        nonceLength: 12,
        macLength: 16,
      ),
      secretKey: _key,
      aad: _aad,
    );
    try {
      final value = jsonDecode(utf8.decode(plain));
      if (value != null && (value is! String || value.length > 131072)) {
        throw const FormatException();
      }
      return value as String?;
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  @override
  Future<String?> read() async => _decode(await _files.read());

  @override
  Future<void> replace(String? expected, String? value) async {
    if (value != null && value.length > 131072) throw const FormatException();
    final previous = await _files.read();
    if (await _decode(previous) != expected) throw const FormatException();
    final plain = utf8.encode(jsonEncode(value));
    try {
      final box = await _cipher.encrypt(plain, secretKey: _key, aad: _aad);
      await _files.replace(
        previous,
        jsonEncode({'version': 1, 'box': base64Encode(box.concatenation())}),
      );
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }
}
