// Invoked by tool/google_drive_setup.py; credentials arrive on stdin, never argv.
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:cryptography/cryptography.dart';

final class _Tokens implements SyncAccessTokenProvider {
  _Tokens(this.accountKey, this.token);
  @override
  final String accountKey;
  final String token;
  @override
  Future<String> accessToken() async => token;
}

Future<void> main() async {
  final result = <String, Object?>{
    'kind': 'real-google-drive-synthetic-probe',
    'checks': <String, bool>{},
  };
  final checks = result['checks'] as Map<String, bool>;
  final cleanup = <String>[];
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
    final store = GoogleDriveSyncStore(tokens: tokens, http: http);
    final fixture =
        jsonDecode(
              await File.fromUri(
                Platform.script.resolve(
                  '../packages/sync/test/fixtures/libsodium-packet.json',
                ),
              ).readAsString(),
            )
            as Map<String, dynamic>;
    final body = fixture['body'] as Map<String, dynamic>;
    final key = await Xchacha20.poly1305Aead().newSecretKey();
    final codec = SyncPacketCodec(
      workspaceId: 'a' * 32,
      keyVersion: 1,
      key: key,
    );
    try {
      final bytes = await codec.seal(
        LocalChange(
          header: ChangeHeader.fromJson(body['header'] as Map<String, dynamic>),
          source: body['source'] as String,
        ),
      );
      final digest = (await Sha256().hash(
        bytes,
      )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      final name = '$syncTransportNamePrefix$digest';
      final start = await store.getStartPageToken();
      checks['startToken'] = start.isNotEmpty;
      final id = await store.generateFileId();
      cleanup.add(id);
      checks['generatedAppDataId'] = true;
      await store.createPacket(id, name, bytes);
      checks['resumableUpload'] = true;
      final downloaded = await store.download(id);
      if (base64Encode(downloaded) != base64Encode(bytes)) {
        throw StateError('readback');
      }
      if ((await codec.open(downloaded)).source != body['source']) {
        throw StateError('decrypt');
      }
      checks['exactCiphertextAndDecrypt'] = true;
      if (!(await store.getFile(id)).packet) throw StateError('metadata');
      checks['privateAppDataMetadata'] = true;
      try {
        await store.createPacket(id, name, bytes);
        throw StateError('duplicate');
      } on SyncTransportFailure catch (error) {
        if (error.issue != SyncTransportIssue.conflict) rethrow;
      }
      checks['sameIdRetry409'] = true;
      var page = await store.listFiles();
      var listed = page.files.any((f) => f.id == id);
      for (var i = 0; !listed && page.nextPageToken != null && i < 20; i++) {
        page = await store.listFiles(pageToken: page.nextPageToken);
        listed = page.files.any((f) => f.id == id);
      }
      if (!listed) throw StateError('listing');
      checks['appDataListing'] = true;
      page = await store.listChanges(start);
      var changed = page.files.any((f) => f.id == id);
      for (var i = 0; page.nextPageToken != null && i < 20; i++) {
        page = await store.listChanges(page.nextPageToken!);
        changed |= page.files.any((f) => f.id == id);
      }
      if (!changed || page.newStartPageToken == null) {
        throw StateError('changes');
      }
      checks['appDataChangesAndCursor'] = true;
      result['status'] = 'PASS';
    } finally {
      key.destroy();
    }
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
          // Only IDs allocated by THIS probe. No listing-driven cleanup.
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
