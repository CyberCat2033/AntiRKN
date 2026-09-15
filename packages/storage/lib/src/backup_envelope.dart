import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';
import 'password_key.dart';

/// Fixed binary header: magic (8), version (1), salt (16), followed by
/// nonce (12), ciphertext and GCM tag (16). The entire header is AAD.
/// Parameters cannot be selected by an unauthenticated file.
abstract final class BackupEnvelope {
  static const _magic = [65, 110, 116, 105, 82, 75, 78, 66]; // AntiRKNB
  static const _headerSize = 25;
  static const _overhead = _headerSize + 12 + 16;

  static void _password(String password) {
    if (password.runes.length < 12 || utf8.encode(password).length > 1024) {
      throw const BackupFailure(BackupIssue.password);
    }
  }

  static Future<Uint8List> seal(String source, String password) {
    _password(password);
    return Isolate.run(() async {
      final plain = utf8.encode(source);
      if (plain.length > maxWorkspaceBackupBytes - _overhead) {
        plain.fillRange(0, plain.length, 0);
        throw const BackupFailure(BackupIssue.tooLarge);
      }
      final salt = List.generate(16, (_) => Random.secure().nextInt(256));
      final header = [..._magic, 1, ...salt];
      final key = await derivePasswordKey(password, salt);
      try {
        final box = await AesGcm.with256bits().encrypt(
          plain,
          secretKey: key,
          aad: header,
        );
        return Uint8List.fromList([...header, ...box.concatenation()]);
      } finally {
        key.destroy();
        plain.fillRange(0, plain.length, 0);
      }
    });
  }

  static Future<String> open(Uint8List bytes, String password) {
    _password(password);
    if (bytes.length > maxWorkspaceBackupBytes) {
      throw const BackupFailure(BackupIssue.tooLarge);
    }
    if (bytes.length < _overhead ||
        !List.generate(8, (i) => bytes[i] == _magic[i]).every((v) => v)) {
      throw const BackupFailure(BackupIssue.invalid);
    }
    if (bytes[8] != 1) throw const BackupFailure(BackupIssue.version);
    final copy = Uint8List.fromList(bytes);
    return Isolate.run(() async {
      final key = await derivePasswordKey(password, copy.sublist(9, 25));
      try {
        final plain = await AesGcm.with256bits().decrypt(
          SecretBox.fromConcatenation(
            copy.sublist(_headerSize),
            nonceLength: 12,
            macLength: 16,
          ),
          secretKey: key,
          aad: copy.sublist(0, _headerSize),
        );
        try {
          return utf8.decode(plain);
        } finally {
          plain.fillRange(0, plain.length, 0);
        }
      } catch (_) {
        // Wrong password and failed authentication are intentionally identical.
        throw const BackupFailure(BackupIssue.invalid);
      } finally {
        key.destroy();
        copy.fillRange(0, copy.length, 0);
      }
    });
  }
}
