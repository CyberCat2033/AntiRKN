// Invoked by drive_publication_probe.py --coordinator. Credentials only on stdin.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:cryptography/cryptography.dart';

class _Tokens implements SyncAccessTokenProvider {
  _Tokens(this.accountKey, this.value);
  @override
  final String accountKey;
  final String value;
  @override
  Future<String> accessToken() async => value;
}

class _Repository implements PublicationRepository {
  _Repository(this.draft, String settings) {
    docs['settings'] = settings;
  }
  PublicationDraft draft;
  final docs = <String, String>{}, queues = <String, String>{};
  @override
  Future<String?> readPublicationDocument(String id) async => docs[id];
  @override
  Future<void> writePublicationDocument(
    String id,
    String source, {
    required String? expectedSource,
  }) async {
    if (docs[id] != expectedSource) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
    docs[id] = source;
  }

  @override
  Future<String?> readPublicationQueue(String id) async => queues[id];
  @override
  Future<void> writePublicationQueue(
    String id,
    String source, {
    required String? expectedSource,
  }) async {
    if (queues[id] != expectedSource) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
    queues[id] = source;
  }

  @override
  Future<PublicationDraft?> readPublicationDraft(String id) async =>
      draft.userId == id ? draft : null;
  @override
  Future<void> checkPublicationDraft(PublicationDraft expected) async {
    if (expected.headId != draft.headId) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
  }
}

// Persist allocated IDs before returning them to code that can create a file.
class _ReceiptHttp implements DriveHttp {
  _ReceiptHttp(this.receipt);
  final File receipt;
  final ids = <String>[];
  final counts = <String, int>{};
  final native = NativeDriveHttp();
  @override
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  }) async {
    final response = await native.send(
      method,
      uri,
      headers: headers,
      body: body,
      responseLimit: responseLimit,
    );
    if (uri.path.endsWith('/generateIds') && response.status == 200) {
      ids.addAll(
        (jsonDecode(utf8.decode(response.bytes))['ids'] as List).cast<String>(),
      );
      await receipt.writeAsString(
        jsonEncode({'allocatedIds': ids}),
        flush: true,
      );
    }
    if ((method == 'POST' || method == 'PUT') &&
        uri.path.startsWith('/upload/')) {
      counts[method] = (counts[method] ?? 0) + 1;
    }
    return response;
  }
}

Future<PublicationDraft> _draft(
  String user,
  String device,
  String head,
  String yaml,
  Set<String> ancestors,
) async {
  final bytes = Uint8List.fromList(utf8.encode(yaml));
  return PublicationDraft(
    workspaceId: 'a' * 32,
    deviceId: device,
    userId: user,
    name: 'Synthetic publication',
    headId: head,
    hash: (await Sha256().hash(
      bytes,
    )).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
    stamp: head,
    bytes: bytes,
    ancestors: ancestors,
  );
}

Future<void> main() async {
  final input =
      jsonDecode(await stdin.transform(utf8.decoder).join())
          as Map<String, dynamic>;
  final tokens = _Tokens(
    input['accountKey'] as String,
    input['accessToken'] as String,
  );
  final receipt = File(input['receipt'] as String);
  input.clear();
  final http = _ReceiptHttp(receipt), checks = <String, bool>{};
  final remote = GoogleDrivePublisher(tokens: tokens, http: http);
  final result = <String, Object?>{
    'kind': 'real-dart-publication-coordinator',
    'checks': checks,
  };
  void check(String key, bool value) {
    checks[key] = value;
    if (!value) throw StateError(key);
  }

  try {
    final folder = await remote.generateFileId();
    await remote.createFolder(folder, 'AntiRKN synthetic P5 acceptance');
    check('folder_created_private', !(await remote.getFile(folder)).shared);
    final settings = canonicalJson(
      PublicationSettings(
        accountKey: tokens.accountKey,
        folderId: folder,
        folderName: 'synthetic',
        access: PublicationAccess.link,
      ).toJson(),
    );
    final user = '1' * 32, head = '2' * 32;
    const one =
        'mode: rule\nproxies: []\nrules: ["MATCH,DIRECT"]\n# synthetic one\n';
    final a = _Repository(
      await _draft(user, '3' * 32, head, one, {}),
      settings,
    );
    final b = _Repository(
      await _draft(user, '4' * 32, head, one, {}),
      settings,
    );
    final ca = PublicationCoordinator(repository: a, remote: remote),
        cb = PublicationCoordinator(repository: b, remote: remote);
    final both = await Future.wait([
      ca.publish(user, force: true),
      cb.publish(user, force: true),
    ]);
    // A transient permission propagation race can require an ordinary retry.
    for (final pair in [(ca, a), (cb, b)]) {
      if (jsonDecode(pair.$2.queues[user]!)['status'] != 'published') {
        await pair.$1.publish(user, force: true);
      }
    }
    check(
      'two_devices_publish',
      [a, b].every((r) => jsonDecode(r.queues[user]!)['status'] == 'published'),
    );
    final first = jsonDecode(a.docs['result/$user']!) as Map<String, dynamic>;
    final second = jsonDecode(b.docs['result/$user']!) as Map<String, dynamic>;
    check(
      'same_file_for_two_devices',
      first['fileId'] == second['fileId'] && both.length == 2,
    );
    final posts = http.counts['POST'], puts = http.counts['PUT'];
    await PublicationCoordinator(
      repository: b,
      remote: remote,
    ).publish(user, force: true);
    check(
      'receiver_no_repeat_upload',
      http.counts['POST'] == posts && http.counts['PUT'] == puts,
    );
    a.draft = await _draft(
      user,
      '3' * 32,
      '5' * 32,
      one.replaceFirst('one', 'two'),
      {head},
    );
    final updated = await ca.publish(user, force: true);
    check('update_published', updated?['status'] == 'published');
    final next = jsonDecode(a.docs['result/$user']!) as Map<String, dynamic>;
    check(
      'stable_file_and_url',
      next['fileId'] == first['fileId'] && next['url'] == first['url'],
    );
    await remote.verifyPublicLink(first['url'] as String, a.draft.bytes);
    check('previous_url_downloads_new_yaml_without_auth', true);
    check(
      'stale_device_blocked',
      (await cb.publish(user, force: true))?['issue'] == 'conflict',
    );
    await remote.verifyPublicLink(first['url'] as String, a.draft.bytes);
    check('stale_device_did_not_overwrite', true);
    final privateUser = '6' * 32;
    final p = _Repository(
      await _draft(privateUser, '3' * 32, '7' * 32, one, {}),
      canonicalJson(
        PublicationSettings(
          accountKey: tokens.accountKey,
          folderId: folder,
          folderName: 'synthetic',
          access: PublicationAccess.private,
        ).toJson(),
      ),
    );
    check(
      'private_publication',
      (await PublicationCoordinator(
            repository: p,
            remote: remote,
          ).publish(privateUser, force: true))?['status'] ==
          'published',
    );
    final privateResult =
        jsonDecode(p.docs['result/$privateUser']!) as Map<String, dynamic>;
    await remote.checkPrivate(privateResult['fileId'] as String);
    check('private_file_has_no_public_link', privateResult['url'] == null);
  } on PublicationFailure catch (e) {
    result['issue'] = e.issue.name;
  } catch (e) {
    result['issue'] = e is StateError ? e.message : e.runtimeType.toString();
  } finally {
    var cleaned = true;
    for (final id in http.ids.reversed) {
      try {
        final response = await http.native.send(
          'DELETE',
          Uri.https('www.googleapis.com', '/drive/v3/files/$id'),
          headers: {'Authorization': 'Bearer ${tokens.value}'},
          responseLimit: 65536,
        );
        cleaned &= [204, 404].contains(response.status);
      } catch (_) {
        cleaned = false;
      }
    }
    checks['allocated_files_removed'] = cleaned;
    if (cleaned && await receipt.exists()) await receipt.delete();
    result['status'] =
        !result.containsKey('issue') && checks.values.every((v) => v)
        ? 'PASS'
        : 'FAIL';
    stdout.writeln(jsonEncode(result));
    if (result['status'] != 'PASS') exitCode = 1;
  }
}
