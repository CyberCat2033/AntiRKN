import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

abstract interface class VaultKeyStore {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
}

final class PlatformVaultKeyStore implements VaultKeyStore {
  const PlatformVaultKeyStore();
  static const _store = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      storageNamespace: 'antirkn.vault.v1',
    ),
  );
  String _key(String id) => 'antirkn.vault.v1.$id';
  @override
  Future<String?> read(String id) => _store.read(key: _key(id));
  @override
  Future<void> write(String id, String value) =>
      _store.write(key: _key(id), value: value);
  @override
  Future<void> delete(String id) => _store.delete(key: _key(id));
}

/// The backend receives ciphertext only. Compare-and-replace prevents stale
/// instances from silently overwriting newer credentials or host-key trust.
abstract interface class VaultFileStore {
  Future<String?> read();
  Future<void> replace(String? expected, String encoded);
}

final class LocalVaultFileStore implements VaultFileStore {
  LocalVaultFileStore(this.file);
  final File file;
  static final _writers = <String>{};
  static const maxBytes = 2 * 1024 * 1024;

  @override
  Future<String?> read() async {
    if (!await file.exists()) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const VaultFailure(VaultIssue.corrupt);
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes());
  }

  @override
  Future<void> replace(String? expected, String encoded) async {
    if (utf8.encode(encoded).length > maxBytes) {
      throw const VaultFailure(VaultIssue.writeFailed);
    }
    final path = file.absolute.path;
    if (!_writers.add(path)) throw const VaultFailure(VaultIssue.busy);
    RandomAccessFile? guard;
    File? temporary;
    try {
      await file.parent.create(recursive: true);
      guard = await File('$path.lock').open(mode: FileMode.append);
      await guard.lock(FileLock.exclusive);
      if (await read() != expected) throw const VaultFailure(VaultIssue.busy);
      temporary = File('$path.${_randomId()}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      // Both source and temporary file contain authenticated ciphertext only.
      // Dart's rename replaces the destination atomically on supported hosts.
      await temporary.rename(path);
      temporary = null;
    } on VaultFailure {
      rethrow;
    } catch (_) {
      throw const VaultFailure(VaultIssue.writeFailed);
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete();
        } catch (_) {
          /* ciphertext only */
        }
      }
      try {
        await guard?.close();
      } catch (_) {
        /* best effort release */
      }
      _writers.remove(path);
    }
  }
}

String _randomId() => base64UrlEncode(
  List<int>.generate(24, (_) => Random.secure().nextInt(256)),
);

Future<SecretVault> openLocalSecretVault() async {
  final directory = await getApplicationSupportDirectory();
  return EncryptedSecretVault(
    files: LocalVaultFileStore(File('${directory.path}/vault/v1.json')),
    keys: const PlatformVaultKeyStore(),
  );
}

/// AES-256-GCM envelope. KDF parameters are fixed by version, so malicious
/// metadata cannot request unbounded memory/CPU. No plaintext backup/temp file.
final class EncryptedSecretVault implements SecretVault {
  EncryptedSecretVault({required this.files, required this.keys});
  final VaultFileStore files;
  final VaultKeyStore keys;
  SecretKeyData? _key;
  Map<String, Object?>? _header;
  String? _encoded;
  SshProfile? _profile;
  bool _busy = false;
  int _generation = 0;
  static final _cipher = AesGcm.with256bits();

  @override
  bool get isUnlocked => _key != null;
  @override
  SshProfile? get profile {
    if (!isUnlocked) throw const VaultFailure(VaultIssue.locked);
    return _profile;
  }

  @override
  Future<VaultMode?> inspect() async {
    try {
      final encoded = await files.read();
      return encoded == null ? null : _mode(_decode(encoded));
    } on VaultFailure {
      rethrow;
    } catch (_) {
      throw const VaultFailure(VaultIssue.unavailable);
    }
  }

  Future<T> _operation<T>(Future<T> Function(int) body) async {
    if (_busy) throw const VaultFailure(VaultIssue.busy);
    _busy = true;
    try {
      return await body(_generation);
    } on VaultFailure {
      rethrow;
    } catch (_) {
      throw const VaultFailure(VaultIssue.unavailable);
    } finally {
      _busy = false;
    }
  }

  void _check(int generation) {
    if (generation != _generation) throw const VaultFailure(VaultIssue.locked);
  }

  @override
  Future<void> create(VaultMode mode, {String? password}) => _operation((
    generation,
  ) async {
    if (isUnlocked || await files.read() != null) {
      throw const VaultFailure(VaultIssue.alreadyExists);
    }
    if (mode == VaultMode.masterPassword &&
        (password == null || password.length < 12 || password.length > 1024)) {
      throw const VaultFailure(VaultIssue.weakPassword);
    }
    final header = <String, Object?>{
      'version': 1,
      'id': _randomId(),
      'mode': mode.name,
      'salt': base64Encode(
        _cipher.newNonce().followedBy(_cipher.newNonce()).take(16).toList(),
      ),
    };
    SecretKeyData? key;
    var keyWritten = false;
    var committed = false;
    try {
      key = mode == VaultMode.system
          ? SecretKeyData(
              await (await _cipher.newSecretKey()).extractBytes(),
              overwriteWhenDestroyed: true,
            )
          : await _derive(password!, header['salt']! as String);
      _check(generation);
      if (mode == VaultMode.system) {
        final encodedKey = base64Encode(key.bytes);
        await keys.write(header['id']! as String, encodedKey);
        keyWritten = true;
        if (await keys.read(header['id']! as String) != encodedKey) {
          throw const VaultFailure(VaultIssue.missingKey);
        }
      }
      final encoded = await _encrypt(header, key, null);
      _check(generation);
      await files.replace(null, encoded);
      committed = true;
      _check(generation);
      _header = header;
      _encoded = encoded;
      _profile = null;
      _key = key;
      key = null;
    } finally {
      key?.destroy();
      if (keyWritten && !committed) {
        try {
          await keys.delete(header['id']! as String);
        } catch (_) {
          /* no plaintext */
        }
      }
    }
  });

  @override
  Future<void> unlock({String? password}) => _operation((generation) async {
    if (isUnlocked) return;
    final encoded = await files.read();
    if (encoded == null) throw const VaultFailure(VaultIssue.corrupt);
    final envelope = _decode(encoded);
    final header = _getHeader(envelope);
    SecretKeyData? key;
    List<int>? plaintext;
    try {
      if (_mode(envelope) == VaultMode.masterPassword) {
        if (password == null || password.isEmpty || password.length > 1024) {
          throw const VaultFailure(VaultIssue.incorrectPasswordOrDamaged);
        }
        key = await _derive(password, header['salt']! as String);
      } else {
        final saved = await keys.read(header['id']! as String);
        if (saved == null) throw const VaultFailure(VaultIssue.missingKey);
        final bytes = base64Decode(saved);
        if (bytes.length != 32) throw const VaultFailure(VaultIssue.missingKey);
        key = SecretKeyData(bytes, overwriteWhenDestroyed: true);
      }
      _check(generation);
      try {
        plaintext = await _cipher.decrypt(
          SecretBox(
            base64Decode(envelope['ciphertext']! as String),
            nonce: base64Decode(envelope['nonce']! as String),
            mac: Mac(base64Decode(envelope['mac']! as String)),
          ),
          secretKey: key,
          aad: utf8.encode(jsonEncode(header)),
        );
      } on SecretBoxAuthenticationError {
        throw const VaultFailure(VaultIssue.incorrectPasswordOrDamaged);
      }
      final profile = _decodePayload(utf8.decode(plaintext));
      _check(generation);
      _profile = profile;
      _header = header;
      _encoded = encoded;
      _key = key;
      key = null;
    } finally {
      key?.destroy();
      plaintext?.fillRange(0, plaintext.length, 0);
    }
  });

  @override
  Future<void> saveProfile(SshProfile? profile) =>
      _operation((generation) async {
        final key = _key;
        if (key == null) throw const VaultFailure(VaultIssue.locked);
        if (profile != null && !profile.valid) {
          throw const VaultFailure(VaultIssue.corrupt);
        }
        final encoded = await _encrypt(_header!, key, profile);
        _check(generation);
        await files.replace(_encoded, encoded);
        _check(generation);
        _profile = profile;
        _encoded = encoded;
      });

  @override
  void lock() {
    _generation++;
    _key?.destroy();
    _key = null;
    _profile = null;
    _header = null;
    _encoded = null;
  }

  static Future<String> _encrypt(
    Map<String, Object?> header,
    SecretKey key,
    SshProfile? profile,
  ) async {
    final plaintext = utf8.encode(
      jsonEncode({
        'version': 1,
        'server': profile == null
            ? null
            : {
                'host': profile.host,
                'port': profile.port,
                'username': profile.username,
                'authMethod': profile.authMethod.name,
                'keyName': profile.keyName,
                'secrets': profile.secrets.map((k, v) => MapEntry(k.name, v)),
                'hostKey': profile.hostKey == null
                    ? null
                    : {
                        'algorithm': profile.hostKey!.algorithm,
                        'fingerprint': profile.hostKey!.fingerprint,
                      },
              },
      }),
    );
    try {
      final box = await _cipher.encrypt(
        plaintext,
        secretKey: key,
        aad: utf8.encode(jsonEncode(header)),
      );
      return jsonEncode({
        ...header,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
    } finally {
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  static Map<String, Object?> _decode(String encoded) {
    try {
      if (encoded.length > LocalVaultFileStore.maxBytes) {
        throw const FormatException();
      }
      final envelope = jsonDecode(encoded) as Map<String, Object?>;
      if (envelope['version'] != 1 ||
          envelope.length != 7 ||
          !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(envelope['id']! as String) ||
          base64Decode(envelope['salt']! as String).length != 16 ||
          base64Decode(envelope['nonce']! as String).length != 12 ||
          base64Decode(envelope['mac']! as String).length != 16 ||
          base64Decode(envelope['ciphertext']! as String).isEmpty) {
        throw const FormatException();
      }
      _mode(envelope);
      return envelope;
    } catch (_) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
  }

  static VaultMode _mode(Map<String, Object?> data) =>
      VaultMode.values.byName(data['mode']! as String);
  static Map<String, Object?> _getHeader(Map<String, Object?> data) => {
    'version': data['version'],
    'id': data['id'],
    'mode': data['mode'],
    'salt': data['salt'],
  };

  static SshProfile? _decodePayload(String text) {
    try {
      final data = jsonDecode(text) as Map<String, Object?>;
      if (data['version'] != 1) throw const FormatException();
      final server = data['server'] as Map<String, Object?>?;
      if (server == null) return null;
      final hostKey = server['hostKey'] as Map<String, Object?>?;
      final profile = SshProfile(
        host: server['host']! as String,
        port: server['port']! as int,
        username: server['username']! as String,
        authMethod: SshAuthMethod.values.byName(
          server['authMethod']! as String,
        ),
        keyName: server['keyName'] as String?,
        hostKey: hostKey == null
            ? null
            : TrustedHostKey(
                hostKey['algorithm']! as String,
                hostKey['fingerprint']! as String,
              ),
        secrets: (server['secrets']! as Map<String, Object?>).map(
          (k, v) => MapEntry(ServerSecret.values.byName(k), v! as String),
        ),
      );
      if (!profile.valid) throw const FormatException();
      return profile;
    } catch (_) {
      throw const VaultFailure(VaultIssue.corrupt);
    }
  }

  static Future<SecretKeyData> _derive(String password, String salt) async {
    final bytes = await Isolate.run(() async {
      final passwordKey = SecretKeyData(
        utf8.encode(password),
        overwriteWhenDestroyed: true,
      );
      try {
        final derived = await Argon2id(
          parallelism: 1,
          memory: 19456,
          iterations: 2,
          hashLength: 32,
        ).deriveKey(secretKey: passwordKey, nonce: base64Decode(salt));
        final result = Uint8List.fromList(await derived.extractBytes());
        derived.destroy();
        return result;
      } finally {
        passwordKey.destroy();
      }
    });
    final key = SecretKeyData(bytes, overwriteWhenDestroyed: true);
    return key;
  }
}
