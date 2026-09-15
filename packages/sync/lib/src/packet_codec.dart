import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';
import 'packet_contract.g.dart';

export 'packet_contract.g.dart';

/// A successful MAC proves workspace key possession, not device authorship.
/// Device trust/revocation and causal merge are separate boundaries.
final class SyncPacketCodec {
  SyncPacketCodec({
    required this.workspaceId,
    required this.keyVersion,
    required SecretKey key,
  }) : _key = key {
    _idBytes(workspaceId);
    if (keyVersion < 1 || keyVersion > 0x7fffffff) {
      throw const SyncPacketFailure(SyncPacketIssue.keyVersion);
    }
  }
  final String workspaceId;
  final int keyVersion;
  final SecretKey _key;
  static final _cipher = Xchacha20.poly1305Aead();

  static Uint8List _idBytes(String id) {
    if (id.length != 32 || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
      throw const SyncPacketFailure(SyncPacketIssue.invalid);
    }
    return Uint8List.fromList([
      for (var i = 0; i < 32; i += 2)
        int.parse(id.substring(i, i + 2), radix: 16),
    ]);
  }

  static String _id(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<Uint8List> seal(LocalChange change) async {
    if (change.header.workspaceId != workspaceId) {
      throw const SyncPacketFailure(SyncPacketIssue.workspace);
    }
    _checkSource(change);
    final plain = utf8.encode(
      canonicalJson({
        'header': change.header.toJson(),
        'source': change.source,
      }),
    );
    try {
      if (plain.length + syncHeaderBytes + syncNonceBytes + syncTagBytes >
          syncMaxPacketBytes) {
        throw const SyncPacketFailure(SyncPacketIssue.tooLarge);
      }
      final header = Uint8List(syncHeaderBytes);
      header.setRange(0, 8, ascii.encode(syncMagic));
      header[syncVersionOffset] = syncVersion;
      header[syncSuiteOffset] = syncSuite;
      ByteData.sublistView(header).setUint32(syncKeyVersionOffset, keyVersion);
      header.setRange(
        syncWorkspaceIdOffset,
        syncChangeIdOffset,
        _idBytes(workspaceId),
      );
      header.setRange(
        syncChangeIdOffset,
        syncHeaderBytes,
        _idBytes(change.header.changeId),
      );
      final box = await _cipher.encrypt(plain, secretKey: _key, aad: header);
      return Uint8List.fromList([...header, ...box.concatenation()]);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  Future<LocalChange> open(Uint8List input) async {
    if (input.length > syncMaxPacketBytes) {
      throw const SyncPacketFailure(SyncPacketIssue.tooLarge);
    }
    if (input.length < syncHeaderBytes + syncNonceBytes + syncTagBytes) {
      throw const SyncPacketFailure(SyncPacketIssue.invalid);
    }
    final bytes = Uint8List.fromList(input);
    try {
      if (ascii.decode(bytes.sublist(0, 8)) != syncMagic) {
        throw const SyncPacketFailure(SyncPacketIssue.invalid);
      }
      if (bytes[syncVersionOffset] != syncVersion ||
          bytes[syncSuiteOffset] != syncSuite) {
        throw const SyncPacketFailure(SyncPacketIssue.version);
      }
      if (ByteData.sublistView(bytes).getUint32(syncKeyVersionOffset) !=
          keyVersion) {
        throw const SyncPacketFailure(SyncPacketIssue.keyVersion);
      }
      if (_id(bytes.sublist(syncWorkspaceIdOffset, syncChangeIdOffset)) !=
          workspaceId) {
        throw const SyncPacketFailure(SyncPacketIssue.workspace);
      }
      final plain = await _cipher.decrypt(
        SecretBox.fromConcatenation(
          bytes.sublist(syncHeaderBytes),
          nonceLength: syncNonceBytes,
          macLength: syncTagBytes,
        ),
        secretKey: _key,
        aad: bytes.sublist(0, syncHeaderBytes),
      );
      try {
        final text = utf8.decode(plain);
        _checkDepth(text);
        final value = jsonDecode(text) as Map<String, dynamic>;
        if (value.length != 2 ||
            !value.containsKey('source') ||
            canonicalJson(value) != text) {
          throw const SyncPacketFailure(SyncPacketIssue.invalid);
        }
        final h = value['header'] as Map<String, dynamic>;
        if (h['version'] != localChangeSchemaVersion) {
          throw const SyncPacketFailure(SyncPacketIssue.version);
        }
        final change = LocalChange(
          header: ChangeHeader.fromJson(h),
          source: value['source'] as String?,
        );
        if (change.header.workspaceId != workspaceId ||
            change.header.changeId !=
                _id(bytes.sublist(syncChangeIdOffset, syncHeaderBytes))) {
          throw const SyncPacketFailure(SyncPacketIssue.invalid);
        }
        _checkSource(change);
        return change;
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
    } on SyncPacketFailure {
      rethrow;
    } catch (_) {
      throw const SyncPacketFailure(SyncPacketIssue.invalid);
    }
  }

  static void _checkSource(LocalChange change) {
    if (change.source == null && !change.header.deleted) {
      throw const SyncPacketFailure(SyncPacketIssue.invalid);
    }
    if (change.source != null &&
        utf8.encode(change.source!).length > syncMaxSourceBytes) {
      throw const SyncPacketFailure(SyncPacketIssue.tooLarge);
    }
  }

  static void _checkDepth(String text) {
    var depth = 0, quoted = false, escaped = false;
    for (final c in text.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (c == 92) {
          escaped = true;
        } else if (c == 34) {
          quoted = false;
        }
      } else if (c == 34) {
        quoted = true;
      } else if (c == 123 || c == 91) {
        if (++depth > 8) throw const SyncPacketFailure(SyncPacketIssue.invalid);
      } else if (c == 125 || c == 93) {
        depth--;
      }
    }
  }
}
