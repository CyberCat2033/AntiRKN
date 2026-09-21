import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

const workspace = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    user = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
Future<String> hash(Uint8List b) async => (await Sha256().hash(
  b,
)).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
Future<PublicationDraft> draft(
  String head, {
  Set<String> ancestors = const {},
  String? content,
  String device = 'cccccccccccccccccccccccccccccccc',
  String? user,
}) async {
  final b = bytes(content ?? 'proxies: []\n# $head');
  return PublicationDraft(
    workspaceId: workspace,
    deviceId: device,
    userId: user ?? 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    name: 'alice',
    headId: head,
    hash: await hash(b),
    stamp: head,
    bytes: b,
    ancestors: {head, ...ancestors},
  );
}

class Repository implements PublicationRepository {
  Repository(this.current) {
    documents['settings'] = canonicalJson(
      const PublicationSettings(
        accountKey: 'account',
        folderId: 'folder',
        folderName: 'Test',
        access: PublicationAccess.link,
      ).toJson(),
    );
  }
  PublicationDraft? current;
  final documents = <String, String>{}, queues = <String, String>{};
  bool reject = false;
  @override
  Future<String?> readPublicationDocument(String id) async => documents[id];
  @override
  Future<void> writePublicationDocument(
    String id,
    String source, {
    required String? expectedSource,
  }) async {
    if (documents[id] != expectedSource) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
    documents[id] = source;
  }

  bool failErrorQueueWrite = false;
  @override
  Future<String?> readPublicationQueue(String id) async => queues[id];
  @override
  Future<void> writePublicationQueue(
    String id,
    String source, {
    required String? expectedSource,
  }) async {
    if (failErrorQueueWrite && !source.contains('"issue":null')) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
    if (queues[id] != expectedSource) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
    queues[id] = source;
  }

  final drafts = <String, PublicationDraft>{};
  @override
  Future<PublicationDraft?> readPublicationDraft(String id) async =>
      drafts[id] ?? current;
  @override
  Future<void> checkPublicationDraft(PublicationDraft d) async {
    final expected = drafts[d.userId] ?? current;
    if (reject || expected?.headId != d.headId) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
  }
}

class Blob {
  Blob(this.content, this.properties, {this.folder = false});
  Uint8List content;
  Map<String, String> properties;
  final bool folder;
  int version = 1;
}

class Remote implements PublicationRemoteStore {
  @override
  Future<void> trashFile(PublicationFile expected, String deletionId) async =>
      throw UnimplementedError();
  final blobs = <String, Blob>{'folder': Blob(bytes(''), {}, folder: true)};
  int ids = 0,
      createdProfiles = 0,
      updatedProfiles = 0,
      enableLinkCalls = 0,
      verifyPublicLinkCalls = 0,
      downloadCalls = 0,
      registryDownloadCalls = 0,
      profileDownloadCalls = 0;
  bool loseCreate = false, loseUpdate = false, linkBroken = false;
  String? pauseContent;
  final paused = Completer<void>(), release = Completer<void>();
  final shared = <String>{};
  @override
  String get accountKey => 'account';
  @override
  Future<String> generateFileId() async => 'id-${++ids}';
  @override
  Future<PublicationFile> getFile(String id) async {
    await Future<void>.value();
    final b = blobs[id];
    if (b == null) throw const PublicationFailure(PublicationIssue.missing);
    return PublicationFile(
      id: id,
      name: id,
      mimeType: b.folder
          ? 'application/vnd.google-apps.folder'
          : 'application/yaml',
      version: '${b.version}',
      etag: '"${b.version}"',
      editable: true,
      properties: Map.from(b.properties),
      downloadUrl: 'https://drive.google.com/uc?id=$id',
    );
  }

  @override
  Future<List<PublicationFile>> listFolders() async => [
    await getFile('folder'),
  ];
  @override
  Future<void> createFolder(String id, String name) async {
    if (blobs.containsKey(id)) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    blobs[id] = Blob(bytes(''), {}, folder: true);
  }

  @override
  Future<PublicationFile> createYaml({
    required String fileId,
    required String folderId,
    required String name,
    required String workspaceId,
    required String userId,
    required String headId,
    required String executorId,
    required Uint8List bytes,
  }) async {
    final digest = await hash(bytes);
    if (blobs.containsKey(fileId)) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    blobs[fileId] = Blob(Uint8List.fromList(bytes), {
      'antirknWorkspace': workspaceId,
      'antirknUser': userId,
      'antirknHead': headId,
      'antirknExecutor': executorId,
      'antirknHash': digest,
    });
    if (userId != 'registry') {
      createdProfiles++;
      if (loseCreate) {
        loseCreate = false;
        throw const PublicationFailure(PublicationIssue.network);
      }
    }
    return getFile(fileId);
  }

  @override
  Future<void> createRegistry(
    String id,
    String folderId,
    String workspaceId,
    Uint8List data,
  ) async {
    await createYaml(
      fileId: id,
      folderId: folderId,
      name: 'registry',
      workspaceId: workspaceId,
      userId: 'registry',
      headId: 'registry',
      executorId: 'registry',
      bytes: data,
    );
  }
  Blob _check(PublicationFile expected) {
    final b = blobs[expected.id];
    if (b == null) throw const PublicationFailure(PublicationIssue.missing);
    if (expected.etag != '"${b.version}"') {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
    return b;
  }

  @override
  Future<PublicationFile> updateProperties(
    PublicationFile expected,
    Map<String, String> properties,
  ) async {
    await Future<void>.value();
    final b = _check(expected);
    b.properties = {...b.properties, ...properties};
    b.version++;
    return getFile(expected.id);
  }

  @override
  Future<PublicationFile> updateFile(
    PublicationFile expected,
    Uint8List data, {
    required Map<String, String> properties,
  }) async {
    final digest = await hash(data);
    if (pauseContent == utf8.decode(data)) {
      pauseContent = null;
      paused.complete();
      await release.future;
    }
    final b = _check(expected);
    b.content = Uint8List.fromList(data);
    b.properties = {...b.properties, ...properties, 'antirknHash': digest};
    b.version++;
    if (b.properties['antirknUser'] != 'registry') {
      updatedProfiles++;
      if (loseUpdate) {
        loseUpdate = false;
        throw const PublicationFailure(PublicationIssue.network);
      }
    }
    return getFile(expected.id);
  }

  @override
  Future<Uint8List> download(String id) async {
    downloadCalls++;
    if (blobs[id]?.properties['antirknUser'] == 'registry') {
      registryDownloadCalls++;
    } else {
      profileDownloadCalls++;
    }
    return Uint8List.fromList(blobs[id]!.content);
  }
  @override
  Future<void> checkPrivate(String id) async {
    if (shared.contains(id)) {
      throw const PublicationFailure(PublicationIssue.conflict);
    }
  }

  @override
  Future<String> enableLink(String id) async {
    enableLinkCalls++;
    shared.add(id);
    return 'anyoneWithLink';
  }

  @override
  Future<void> removeLink(String id, String permissionId) async {
    shared.remove(id);
  }

  @override
  Future<void> verifyPublicLink(String url, Uint8List expected) async {
    verifyPublicLinkCalls++;
    final id = Uri.parse(url).queryParameters['id'];
    if (linkBroken ||
        !shared.contains(id) ||
        base64Encode(blobs[id]!.content) != base64Encode(expected)) {
      throw const PublicationFailure(PublicationIssue.linkUnavailable);
    }
  }

  String get profileId => blobs.entries
      .singleWhere((e) => e.value.properties['antirknUser'] == user)
      .key;
}

PublicationCoordinator coordinator(Repository repo, Remote remote) =>
    PublicationCoordinator(repository: repo, remote: remote, jitter: (_) => 0);
Future<Map<String, dynamic>> publish(
  Repository repo,
  Remote remote, {
  bool force = true,
}) async => (await coordinator(repo, remote).publish(user, force: force))!;

void main() {
  test(
    'first publication with two devices reserves one ID; receiver verifies without duplicate upload',
    () async {
      final first = Repository(await draft('head-1')),
          second = Repository(
            await draft('head-1', device: 'dddddddddddddddddddddddddddddddd'),
          );
      final remote = Remote();
      await Future.wait([publish(first, remote), publish(second, remote)]);
      expect((await publish(first, remote))['status'], 'published');
      expect((await publish(second, remote))['status'], 'published');
      expect(remote.createdProfiles, 1);
      expect(remote.updatedProfiles, 0);
      expect(
        jsonDecode(first.documents['result/$user']!)['fileId'],
        jsonDecode(second.documents['result/$user']!)['fileId'],
      );
      expect(first.documents['result/$user'], second.documents['result/$user']);
    },
  );
  test(
    'lost create response recovers after coordinator restart using reserved ID',
    () async {
      final repo = Repository(await draft('head-1')),
          remote = Remote()..loseCreate = true;
      expect((await publish(repo, remote))['issue'], 'network');
      expect(repo.documents['result/$user'], isNull);
      expect((await publish(repo, remote))['status'], 'published');
      expect(remote.createdProfiles, 1);
    },
  );
  test(
    'lost update response reads back actual new revision without uploading again',
    () async {
      final repo = Repository(await draft('head-1')), remote = Remote();
      await publish(repo, remote);
      final prior = repo.documents['result/$user'];
      repo.current = await draft('head-2', ancestors: {'head-1'});
      remote.loseUpdate = true;
      expect((await publish(repo, remote))['issue'], 'network');
      expect(repo.documents['result/$user'], prior);
      expect((await publish(repo, remote))['status'], 'published');
      expect(remote.updatedProfiles, 1);
      expect(remote.createdProfiles, 1);
      expect(
        jsonDecode(repo.documents['result/$user']!)['url'],
        jsonDecode(prior!)['url'],
      );
    },
  );
  test('stalled old writer cannot overwrite a newer causal profile', () async {
    final old = Repository(await draft('head-1')), remote = Remote();
    await publish(old, remote);
    old.current = await draft('head-2', ancestors: {'head-1'});
    final newer = Repository(
      await draft('head-3', ancestors: {'head-1', 'head-2'}),
    );
    remote.pauseContent = utf8.decode(old.current!.bytes);
    final stale = publish(old, remote, force: false);
    await remote.paused.future;
    expect((await publish(newer, remote))['status'], 'published');
    remote.release.complete();
    expect((await stale)['issue'], 'conflict');
    expect(remote.blobs[remote.profileId]!.properties['antirknHead'], 'head-3');
    expect(remote.updatedProfiles, 1);
  });
  test(
    'force publish overrides remote conflict when local draft is not a descendant of remote head',
    () async {
      final repo = Repository(await draft('head-1')), remote = Remote();
      await publish(repo, remote);
      repo.current = await draft('head-2', ancestors: {'unrelated-base'});
      expect((await publish(repo, remote, force: false))['issue'], 'conflict');
      expect((await publish(repo, remote, force: true))['status'], 'published');
      expect(remote.blobs[remote.profileId]!.properties['antirknHead'], 'head-2');
    },
  );
  test(
    'external edit and deletion preserve previous publication and never create replacements',
    () async {
      final repo = Repository(await draft('head-1')), remote = Remote();
      await publish(repo, remote);
      final prior = repo.documents['result/$user'];
      final file = remote.blobs[remote.profileId]!;
      file.content = bytes('external edit');
      file.version++;
      repo.current = await draft('head-2', ancestors: {'head-1'});
      expect((await publish(repo, remote))['issue'], 'readback');
      expect(repo.documents['result/$user'], prior);
      expect(remote.updatedProfiles, 0);
      remote.blobs.remove(remote.profileId);
      expect((await publish(repo, remote))['issue'], 'missing');
      expect(remote.createdProfiles, 1);
      expect(repo.documents['result/$user'], prior);
    },
  );
  test(
    'broken public link stays retryable without re-uploading an already verified YAML',
    () async {
      final repo = Repository(await draft('head-1')),
          remote = Remote()..linkBroken = true;
      expect((await publish(repo, remote))['issue'], 'linkUnavailable');
      expect(repo.documents['result/$user'], isNull);
      remote.linkBroken = false;
      expect((await publish(repo, remote))['status'], 'published');
      expect(remote.createdProfiles, 1);
      expect(remote.updatedProfiles, 0);
    },
  );
  test(
    'local revision or conflict blocks effects; deleted users do not publish',
    () async {
      final repo = Repository(await draft('head-1'))..reject = true;
      final remote = Remote();
      expect((await publish(repo, remote))['issue'], 'changed');
      expect(remote.blobs.length, 1);
      repo.current = null;
      expect(await coordinator(repo, remote).publish(user), isNull);
      expect(remote.blobs.length, 1);
    },
  );
  test(
    'publish returns nextQueue with issue changed and status waiting even if queue persistence fails',
    () async {
      final repo = Repository(await draft('head-1'))
        ..reject = true
        ..failErrorQueueWrite = true;
      final remote = Remote();
      final res = await publish(repo, remote);
      expect(res['issue'], 'changed');
      expect(res['status'], 'waiting');
    },
  );
  test(
    'publish returns nextQueue with publication issue and status error even if queue persistence fails',
    () async {
      final repo = Repository(await draft('head-1'))..failErrorQueueWrite = true;
      final remote = Remote()..linkBroken = true;
      final res = await publish(repo, remote);
      expect(res['issue'], 'linkUnavailable');
      expect(res['status'], 'error');
      expect(res['attempt'], 1);
    },
  );
  test(
    'fast update path skips redundant enableLink and verifyPublicLink when updating already published profile',
    () async {
      final repo = Repository(await draft('head-1')), remote = Remote();
      final initialResult = await publish(repo, remote);
      expect(initialResult['status'], 'published');
      expect(remote.createdProfiles, 1);
      expect(remote.updatedProfiles, 0);
      expect(remote.enableLinkCalls, 1);
      expect(remote.verifyPublicLinkCalls, 1);

      final initialDoc = jsonDecode(repo.documents['result/$user']!);
      expect(initialDoc['head'], 'head-1');
      expect(initialDoc['url'], startsWith('https://drive.google.com/uc?id='));
      expect(initialDoc['permissionId'], 'anyoneWithLink');

      // Update to head-2
      repo.current = await draft('head-2', ancestors: {'head-1'});
      final updateResult = await publish(repo, remote);
      expect(updateResult['status'], 'published');
      expect(remote.createdProfiles, 1);
      expect(remote.updatedProfiles, 1);
      // Calls to enableLink and verifyPublicLink MUST NOT increase on update:
      expect(remote.enableLinkCalls, 1);
      expect(remote.verifyPublicLinkCalls, 1);

      final updatedDoc = jsonDecode(repo.documents['result/$user']!);
      expect(updatedDoc['head'], 'head-2');
      expect(updatedDoc['fileId'], initialDoc['fileId']);
      expect(updatedDoc['url'], initialDoc['url']);
      expect(updatedDoc['permissionId'], initialDoc['permissionId']);
    },
  );
  test(
    'fast update path still enables and verifies link if previous publication was private or unlinked',
    () async {
      final repo = Repository(await draft('head-1')), remote = Remote();
      // First publish with private access
      repo.documents['settings'] = canonicalJson(
        const PublicationSettings(
          accountKey: 'account',
          folderId: 'folder',
          folderName: 'Test',
          access: PublicationAccess.private,
        ).toJson(),
      );
      final privateResult = await publish(repo, remote);
      expect(privateResult['status'], 'published');
      expect(remote.enableLinkCalls, 0);
      expect(remote.verifyPublicLinkCalls, 0);

      // Now switch access to link
      repo.documents['settings'] = canonicalJson(
        const PublicationSettings(
          accountKey: 'account',
          folderId: 'folder',
          folderName: 'Test',
          access: PublicationAccess.link,
        ).toJson(),
      );
      repo.current = await draft('head-2', ancestors: {'head-1'});
      final linkResult = await publish(repo, remote);
      expect(linkResult['status'], 'published');
      expect(remote.enableLinkCalls, 1);
      expect(remote.verifyPublicLinkCalls, 1);
      final doc = jsonDecode(repo.documents['result/$user']!);
      expect(doc['permissionId'], 'anyoneWithLink');
      expect(doc['access'], 'link');
    },
  );
  test(
    'session registry cache reuses snapshot across multiple publications in same coordinator',
    () async {
      final user1 = '11111111111111111111111111111111';
      final user2 = '22222222222222222222222222222222';
      final draft1 = await draft('head-1', user: user1);
      final draft2 = await draft('head-1', user: user2);
      final repo = Repository(draft1);
      repo.drafts[user1] = draft1;
      repo.drafts[user2] = draft2;
      final remote = Remote();
      final coord = coordinator(repo, remote);

      // Initial publish sets up registry entries for both users:
      await coord.publish(user1);
      await coord.publish(user2);

      // Now create a coordinator to simulate batch update session:
      final batchCoord = coordinator(repo, remote);
      final registryDownloadsBefore = remote.registryDownloadCalls;

      repo.drafts[user1] =
          await draft('head-2', user: user1, ancestors: {'head-1'});
      repo.drafts[user2] =
          await draft('head-2', user: user2, ancestors: {'head-1'});

      final res1 = await batchCoord.publish(user1);
      expect(res1?['status'], 'published');
      final registryDownloadsAfterFirst = remote.registryDownloadCalls;
      // First user in batch downloads registry once:
      expect(registryDownloadsAfterFirst, registryDownloadsBefore + 1);

      // Second user in batch MUST reuse cached registry without downloading:
      final res2 = await batchCoord.publish(user2);
      expect(res2?['status'], 'published');
      expect(remote.registryDownloadCalls, registryDownloadsAfterFirst);
    },
  );
  test(
    '1-RTT fast update path skips redundant download after updateFile',
    () async {
      final repo = Repository(await draft('head-1')), remote = Remote();
      final coord = coordinator(repo, remote);
      final initialResult = await coord.publish(user);
      expect(initialResult?['status'], 'published');

      final profileDownloadsBeforeUpdate = remote.profileDownloadCalls;

      // Update to head-2 using the same coordinator
      repo.current = await draft('head-2', ancestors: {'head-1'});
      final updateResult = await coord.publish(user);
      expect(updateResult?['status'], 'published');
      expect(remote.updatedProfiles, 1);

      // Profile is NOT downloaded at all during fast update path (0 pre-download, 0 post-download):
      final profileDownloadsDuringUpdate =
          remote.profileDownloadCalls - profileDownloadsBeforeUpdate;
      expect(profileDownloadsDuringUpdate, 0);
    },
  );
}
