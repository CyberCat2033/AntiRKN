import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';

final class FakeSnapshotTokens implements SyncAccessTokenProvider {
  @override
  String get accountKey => 'snapshot-test-account';
  @override
  Future<String> accessToken() async => 'fixture';
}

final class FakeSnapshotRemote implements SyncSnapshotStore {
  @override
  String get accountKey => 'snapshot-test-account';
  Uint8List? snapshot, key;
  int version = 0, writes = 0;
  bool unavailable = false, loseResponse = false;

  /// Like Drive, a download may change the etag (view metadata) while the
  /// content and its version stay the same.
  bool etagDriftOnRead = false;
  int _drift = 0;

  /// Store calls in order. Drive cost: a key read is a list plus a download.
  final calls = <String>[];
  int get requests =>
      calls.fold(0, (sum, call) => sum + (call == 'readSnapshotKey' ? 2 : 1));

  /// Runs inside the next write, before Drive applies it (a racing device).
  Future<void> Function()? beforeWrite;

  /// Another device's key created at the same moment as ours, and winning.
  Uint8List? racingKey;

  /// Holds snapshot downloads, as on a stalled mobile link.
  Completer<void>? holdRead;

  @override
  Future<SyncRemoteFile?> findSnapshot() async {
    calls.add('findSnapshot');
    return _current();
  }

  SyncRemoteFile? _current() => snapshot == null
      ? null
      : SyncRemoteFile(
          id: 'snapshot-id',
          name: syncSnapshotName,
          size: snapshot!.length,
          version: '$version',
          etag: _etag,
        );

  String get _etag => 'etag-$version-$_drift';

  @override
  Future<Uint8List> readSnapshot(String fileId) async {
    calls.add('readSnapshot');
    await holdRead?.future;
    if (etagDriftOnRead) _drift++;
    return Uint8List.fromList(snapshot!);
  }

  /// Conditional like Drive v2 If-Match: a stale expectation writes nothing.
  @override
  Future<SyncRemoteFile> writeSnapshot(
    SyncRemoteFile? expected,
    Uint8List bytes,
  ) async {
    calls.add('writeSnapshot');
    final race = beforeWrite;
    beforeWrite = null;
    if (race != null) await race();
    if (unavailable) {
      throw const SyncTransportFailure(SyncTransportIssue.network);
    }
    if (expected != null && snapshot == null) {
      throw const SyncTransportFailure(SyncTransportIssue.notFound);
    }
    if (expected == null ? snapshot != null : expected.etag != _etag) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
    snapshot = Uint8List.fromList(bytes);
    version++;
    writes++;
    if (loseResponse) {
      loseResponse = false;
      throw const SyncTransportFailure(SyncTransportIssue.network);
    }
    return _current()!;
  }

  @override
  Future<Uint8List?> readSnapshotKey() async {
    calls.add('readSnapshotKey');
    return key == null ? null : Uint8List.fromList(key!);
  }

  /// A key created by another device first wins and is returned instead.
  @override
  Future<Uint8List> createSnapshotKey(Uint8List bytes) async {
    calls.add('createSnapshotKey');
    key ??= racingKey ?? Uint8List.fromList(bytes);
    return Uint8List.fromList(key!);
  }
}

const _magic = [65, 110, 116, 105, 82, 75, 78, 83, 1];
List<int> _aad(String accountKey) =>
    utf8.encode('antirkn:single-snapshot:1:cloud:$accountKey');

/// Reads the plain JSON of the cloud snapshot, as another device would.
Future<Map<String, dynamic>> openFakeSnapshot(FakeSnapshotRemote remote) async {
  final bytes = remote.snapshot!;
  final plain = await AesGcm.with256bits().decrypt(
    SecretBox.fromConcatenation(
      Uint8List.sublistView(bytes, _magic.length),
      nonceLength: 12,
      macLength: 16,
    ),
    secretKey: SecretKeyData(remote.key!),
    aad: _aad(remote.accountKey),
  );
  return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
}

/// Writes [value] as the cloud snapshot, as another app version would.
Future<void> sealFakeSnapshot(
  FakeSnapshotRemote remote,
  Map<String, dynamic> value,
) async {
  remote.key ??= Uint8List.fromList(List.filled(32, 77));
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode(value)),
    secretKey: SecretKeyData(remote.key!),
    aad: _aad(remote.accountKey),
  );
  remote.snapshot = Uint8List.fromList([
    ..._magic,
    ...box.nonce,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
  remote.version++;
}
