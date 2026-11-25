// Invoked by tool/google_drive_setup.py; credentials arrive on stdin, never argv.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';

final class _Tokens implements SyncAccessTokenProvider {
  _Tokens(this.accountKey, this.token);
  @override
  final String accountKey;
  final String token;
  @override
  Future<String> accessToken() async => token;
}

/// The requests of automatic sync on a synthetic snapshot and key of its own
/// names: the account's real snapshot is never read or written.
Future<void> main() async {
  final result = <String, Object?>{
    'kind': 'real-google-drive-synthetic-probe',
    'checks': <String, bool>{},
  };
  final checks = result['checks'] as Map<String, bool>;
  final cleanup = <String>{};
  _Tokens? tokens;
  final http = NativeDriveHttp();
  try {
    final input =
        jsonDecode(await stdin.transform(utf8.decoder).join())
            as Map<String, dynamic>;
    tokens = _Tokens(
      input['accountKey'] as String,
      input['accessToken'] as String,
    );
    input.clear();
    final random = Random.secure();
    final tag = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final store = GoogleDriveSyncStore(
      tokens: tokens,
      http: http,
      snapshotName: 'antirkn-probe-snapshot-$tag',
      keyName: 'antirkn-probe-key-$tag',
    );
    Uint8List bytes(int length) =>
        Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));

    if (await store.findSnapshot() != null) throw StateError('fresh');
    final key = bytes(32);
    final stored = await store.createSnapshotKey(key);
    final keyFile = await store.readSnapshotKey();
    if (base64Encode(stored) != base64Encode(key) ||
        keyFile == null ||
        base64Encode(keyFile) != base64Encode(key)) {
      throw StateError('key');
    }
    // The key's file id, through a store that sees the key as its snapshot.
    final keyMetadata = await GoogleDriveSyncStore(
      tokens: tokens,
      http: http,
      snapshotName: store.keyName,
    ).findSnapshot();
    if (keyMetadata == null) throw StateError('key');
    cleanup.add(keyMetadata.id);
    checks['keyCreatedAndRead'] = true;
    final first = bytes(4096);
    final created = await store.writeSnapshot(null, first);
    cleanup.add(created.id);
    final found = await store.findSnapshot();
    if (found == null || found.id != created.id || found.etag.isEmpty) {
      throw StateError('listing');
    }
    checks['createdAndListedWithEtag'] = true;
    final second = bytes(4096);
    final written = await store.writeSnapshot(found, second);
    if (written.version == found.version ||
        base64Encode(await store.readSnapshot(found.id)) !=
            base64Encode(second)) {
      throw StateError('conditional');
    }
    checks['conditionalWriteAndReadback'] = true;
    try {
      // The etag seen before the last write no longer matches.
      await store.writeSnapshot(found, bytes(16));
      throw StateError('stale');
    } on SyncTransportFailure catch (error) {
      if (error.issue != SyncTransportIssue.conflict) rethrow;
    }
    if (base64Encode(await store.readSnapshot(found.id)) !=
        base64Encode(second)) {
      throw StateError('stale');
    }
    checks['staleWriteRejected'] = true;
    result['status'] = 'PASS';
  } on SyncTransportFailure catch (error) {
    result['status'] = 'FAIL';
    result['issue'] = error.issue.name;
    exitCode = 1;
  } catch (_) {
    result['status'] = 'FAIL';
    result['issue'] = 'probe';
    exitCode = 1;
  } finally {
    var clean = true;
    if (tokens != null) {
      for (final id in cleanup) {
        try {
          // Only IDs created by THIS probe. No listing-driven cleanup.
          final response = await http.send(
            'DELETE',
            Uri.https('www.googleapis.com', '/drive/v3/files/$id'),
            headers: {'Authorization': 'Bearer ${tokens.token}'},
            responseLimit: 65536,
          );
          clean &= response.status == 204 || response.status == 404;
        } catch (_) {
          clean = false;
        }
      }
    }
    checks['syntheticFilesRemoved'] = clean;
    if (!clean) {
      result['status'] = 'FAIL';
      result['issue'] = 'cleanup';
      exitCode = 1;
    }
    stdout.writeln(jsonEncode(result));
  }
}
