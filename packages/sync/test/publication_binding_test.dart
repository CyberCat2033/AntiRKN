import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:test/test.dart';
import 'publication_coordinator_test.dart' as f;

Future<PublicationBindingPreview> inspect(
  f.Repository repo,
  f.Remote remote,
  String id,
) => f
    .coordinator(repo, remote)
    .inspectBinding(repo.current!.userId, PublicationTarget(id));
Future<void> accept(f.Repository repo, f.Remote remote, String id) async =>
    f.coordinator(repo, remote).acceptBinding(await inspect(repo, remote, id));

class FaultRemote extends f.Remote {
  bool loseRegistry = false, loseRetirement = false, pauseCreation = false;
  final creationStarted = Completer<void>(),
      creationRelease = Completer<void>();
  @override
  Future<PublicationFile> updateFile(
    PublicationFile expected,
    Uint8List data, {
    required Map<String, String> properties,
  }) async {
    final res = await super.updateFile(expected, data, properties: properties);
    if (loseRegistry && expected.properties['antirknUser'] == 'registry') {
      loseRegistry = false;
      throw const PublicationFailure(PublicationIssue.network);
    }
    return res;
  }

  @override
  Future<PublicationFile> updateProperties(
    PublicationFile expected,
    Map<String, String> properties,
  ) async {
    final res = await super.updateProperties(expected, properties);
    if (loseRetirement &&
        properties['antirknUser']?.startsWith('retired:') == true) {
      loseRetirement = false;
      throw const PublicationFailure(PublicationIssue.network);
    }
    return res;
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
    if (pauseCreation && userId == f.user) {
      pauseCreation = false;
      creationStarted.complete();
      await creationRelease.future;
    }
    return super.createYaml(
      fileId: fileId,
      folderId: folderId,
      name: name,
      workspaceId: workspaceId,
      userId: userId,
      headId: headId,
      executorId: executorId,
      bytes: bytes,
    );
  }
}

void main() {
  test(
    'changed access policy cannot apply an earlier public-link consent',
    () async {
      final repo = f.Repository(await f.draft('one')), remote = f.Remote();
      remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
      await accept(repo, remote, 'legacy');
      repo.documents['settings'] = canonicalJson(
        const PublicationSettings(
          accountKey: 'account',
          folderId: 'folder',
          folderName: 'Folder',
          access: PublicationAccess.private,
        ).toJson(),
      );
      expect((await f.publish(repo, remote))['issue'], 'conflict');
      expect(remote.shared, isEmpty);
      expect(utf8.decode(remote.blobs['legacy']!.content), 'external');
    },
  );

  for (final phase in ['registry', 'retirement']) {
    test('lost $phase response resumes without another file ID', () async {
      final repo = f.Repository(await f.draft('one')), remote = FaultRemote();
      await f.publish(repo, remote);
      final old = repo.documents['result/${f.user}'];
      remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
      await accept(repo, remote, 'legacy');
      remote.loseRegistry = phase == 'registry';
      remote.loseRetirement = phase == 'retirement';
      expect((await f.publish(repo, remote))['issue'], 'network');
      expect(repo.documents['result/${f.user}'], old);
      expect((await f.publish(repo, remote))['status'], 'published');
      expect(remote.createdProfiles, 1);
      expect(remote.updatedProfiles, 1);
    });
  }
  test(
    'stalled creation is fenced using the previously reserved file ID',
    () async {
      final old = f.Repository(await f.draft('one')),
          remote = FaultRemote()..pauseCreation = true;
      final running = f.publish(old, remote);
      await remote.creationStarted.future;
      final newer = f.Repository(await f.draft('one'));
      remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
      await accept(newer, remote, 'legacy');
      expect((await f.publish(newer, remote))['status'], 'published');
      remote.creationRelease.complete();
      expect((await running)['status'], 'error');
      expect(remote.ids, 2); // registry + one original reservation
      expect(remote.createdProfiles, 1);
      expect(
        jsonDecode(newer.documents['result/${f.user}']!)['fileId'],
        'legacy',
      );
    },
  );
  test(
    'a conflicted pending attempt can be replaced with another reviewed file',
    () async {
      final repo = f.Repository(await f.draft('one')), remote = f.Remote();
      await f.publish(repo, remote);
      remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
      remote.blobs['other'] = f.Blob(f.bytes('other external'), {});
      await accept(repo, remote, 'legacy');
      remote.blobs['legacy']!.version++;
      expect((await f.publish(repo, remote))['issue'], 'conflict');
      await accept(repo, remote, 'other');
      expect((await f.publish(repo, remote))['status'], 'published');
      expect(utf8.decode(remote.blobs['legacy']!.content), 'external');
      expect(
        jsonDecode(repo.documents['result/${f.user}']!)['fileId'],
        'other',
      );
    },
  );
  test('replacing a stalled pending upload prevents its late write', () async {
    final first = f.Repository(await f.draft('one')), remote = f.Remote();
    await f.publish(first, remote);
    remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
    remote.blobs['other'] = f.Blob(f.bytes('other external'), {});
    await accept(first, remote, 'legacy');
    remote.pauseContent = utf8.decode(first.current!.bytes);
    final running = f.publish(first, remote);
    await remote.paused.future;
    final second = f.Repository(await f.draft('one'));
    await accept(second, remote, 'other');
    expect((await f.publish(second, remote))['status'], 'published');
    remote.release.complete();
    expect((await running)['status'], 'error');
    expect(utf8.decode(remote.blobs['legacy']!.content), 'external');
    expect(remote.blobs['other']!.content, second.current!.bytes);
  });

  test(
    'preview is read only; binding keeps existing ID and future updates preserve its URL',
    () async {
      final repo = f.Repository(await f.draft('one')), remote = f.Remote();
      await f.publish(repo, remote);
      final old = remote.profileId,
          oldBytes = remote.blobs[remote.profileId]!.content.toList();
      remote.blobs['legacy'] = f.Blob(f.bytes('old external config'), {});
      final preview = await inspect(repo, remote, 'legacy');
      expect(preview.content, 'old external config');
      expect(remote.blobs['legacy']!.version, 1);
      expect(repo.documents['binding/${f.user}'], isNull);
      await f.coordinator(repo, remote).acceptBinding(preview);
      expect(remote.blobs['legacy']!.version, 1);
      expect((await f.publish(repo, remote))['status'], 'published');
      final result = jsonDecode(repo.documents['result/${f.user}']!) as Map;
      expect(result['fileId'], 'legacy');
      expect(result['version'], 2);
      expect(remote.blobs[old]!.content, oldBytes);
      expect(remote.shared, contains(old));
      expect(remote.blobs[old]!.properties['antirknUser'], 'retired:${f.user}');
      repo.current = await f.draft('two', ancestors: {'one'});
      expect((await f.publish(repo, remote))['status'], 'published');
      expect(
        jsonDecode(repo.documents['result/${f.user}']!)['url'],
        result['url'],
      );
      expect(remote.blobs['legacy']!.content, repo.current!.bytes);
      expect(remote.createdProfiles, 1);
    },
  );

  test(
    'changed preview or local draft rejects consent before remote mutation',
    () async {
      final repo = f.Repository(await f.draft('one')), remote = f.Remote();
      remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
      final preview = await inspect(repo, remote, 'legacy');
      remote.blobs['legacy']!.version++;
      await expectLater(
        f.coordinator(repo, remote).acceptBinding(preview),
        throwsA(isA<PublicationFailure>()),
      );
      expect(repo.documents['binding/${f.user}'], isNull);
      final fresh = await inspect(repo, remote, 'legacy');
      repo.reject = true;
      await expectLater(
        f.coordinator(repo, remote).acceptBinding(fresh),
        throwsA(isA<SyncMergeFailure>()),
      );
      expect(remote.blobs.length, 2);
    },
  );

  test(
    'lost upload response resumes persisted consent without a second replacement',
    () async {
      final repo = f.Repository(await f.draft('one')), remote = f.Remote();
      await f.publish(repo, remote);
      final prior = repo.documents['result/${f.user}'];
      remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
      await accept(repo, remote, 'legacy');
      remote.loseUpdate = true;
      expect((await f.publish(repo, remote))['issue'], 'network');
      expect(repo.documents['result/${f.user}'], prior);
      expect((await f.publish(repo, remote))['status'], 'published');
      expect(remote.updatedProfiles, 1);
      expect(
        jsonDecode(repo.documents['result/${f.user}']!)['fileId'],
        'legacy',
      );
    },
  );

  test(
    'failed link verification keeps previous result and retries without rewriting',
    () async {
      final repo = f.Repository(await f.draft('one')), remote = f.Remote();
      await f.publish(repo, remote);
      final prior = repo.documents['result/${f.user}'];
      remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
      await accept(repo, remote, 'legacy');
      remote.linkBroken = true;
      expect((await f.publish(repo, remote))['issue'], 'linkUnavailable');
      expect(repo.documents['result/${f.user}'], prior);
      remote.linkBroken = false;
      repo.current = await f.draft('two', ancestors: {'one'});
      expect((await f.publish(repo, remote))['status'], 'published');
      expect(remote.blobs['legacy']!.content, repo.current!.bytes);
      expect(remote.updatedProfiles, 2);
    },
  );

  test(
    'two clients on different devices cannot claim the same external file',
    () async {
      final first = f.Repository(await f.draft('one'));
      final original = await f.draft('one');
      final second = f.Repository(
        PublicationDraft(
          workspaceId: original.workspaceId,
          deviceId: 'd' * 32,
          userId: 'e' * 32,
          name: 'second',
          headId: original.headId,
          hash: original.hash,
          stamp: original.stamp,
          bytes: original.bytes,
          ancestors: original.ancestors,
        ),
      );
      final remote = f.Remote()
        ..blobs['legacy'] = f.Blob(f.bytes('external'), {});
      await accept(first, remote, 'legacy');
      await accept(second, remote, 'legacy');
      final results = await Future.wait([
        f
            .coordinator(first, remote)
            .publish(first.current!.userId, force: true),
        f
            .coordinator(second, remote)
            .publish(second.current!.userId, force: true),
      ]);
      expect(results.where((r) => r?['status'] == 'published'), hasLength(1));
      expect(results.where((r) => r?['issue'] == 'conflict'), hasLength(1));
      expect(remote.updatedProfiles, 1);
    },
  );

  test(
    'competing destinations for one client require the winning shared intent',
    () async {
      final first = f.Repository(await f.draft('one')), remote = f.Remote();
      await f.publish(first, remote);
      final second = f.Repository(await f.draft('one'));
      remote.blobs['first'] = f.Blob(f.bytes('external first'), {});
      remote.blobs['second'] = f.Blob(f.bytes('external second'), {});
      await accept(first, remote, 'first');
      await accept(second, remote, 'second');
      expect((await f.publish(first, remote))['status'], 'published');
      expect((await f.publish(second, remote))['issue'], 'conflict');
      expect(utf8.decode(remote.blobs['second']!.content), 'external second');
      second.documents['binding/${f.user}'] =
          first.documents['binding/${f.user}']!;
      expect((await f.publish(second, remote))['status'], 'published');
      expect(remote.updatedProfiles, 1);
    },
  );

  test(
    'stalled writer from the previous destination is fenced by metadata and ETag',
    () async {
      final old = f.Repository(await f.draft('one')), remote = f.Remote();
      await f.publish(old, remote);
      final oldId = remote.profileId;
      old.current = await f.draft('two', ancestors: {'one'});
      remote.pauseContent = utf8.decode(old.current!.bytes);
      final running = f.publish(old, remote);
      await remote.paused.future;
      final newer = f.Repository(
        await f.draft('three', ancestors: {'one', 'two'}),
      );
      remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
      await accept(newer, remote, 'legacy');
      expect((await f.publish(newer, remote))['status'], 'published');
      remote.release.complete();
      expect((await running)['status'], 'error');
      expect(remote.blobs[oldId]!.properties['antirknHead'], 'one');
      expect(remote.blobs['legacy']!.properties['antirknHead'], 'three');
    },
  );

  test(
    'external edit after consent requires a fresh confirmation of the same file',
    () async {
      final repo = f.Repository(await f.draft('one')), remote = f.Remote();
      remote.blobs['legacy'] = f.Blob(f.bytes('external'), {});
      await accept(repo, remote, 'legacy');
      remote.blobs['legacy']!.content = f.bytes('external newer');
      remote.blobs['legacy']!.version++;
      expect((await f.publish(repo, remote))['issue'], 'conflict');
      expect(utf8.decode(remote.blobs['legacy']!.content), 'external newer');
      final reviewed = await inspect(repo, remote, 'legacy');
      expect(reviewed.content, 'external newer');
      await f.coordinator(repo, remote).acceptBinding(reviewed);
      expect((await f.publish(repo, remote))['status'], 'published');
    },
  );

  test(
    'folder, foreign ownership and private policy on public files are rejected',
    () async {
      final repo = f.Repository(await f.draft('one')), remote = f.Remote();
      await expectLater(
        inspect(repo, remote, 'folder'),
        throwsA(isA<PublicationFailure>()),
      );
      remote.blobs['foreign'] = f.Blob(f.bytes('external'), {
        'antirknUser': 'other',
      });
      await expectLater(
        inspect(repo, remote, 'foreign'),
        throwsA(isA<PublicationFailure>()),
      );
      remote.blobs['public'] = f.Blob(f.bytes('external'), {});
      remote.shared.add('public');
      repo.documents['settings'] = canonicalJson(
        const PublicationSettings(
          accountKey: 'account',
          folderId: 'folder',
          folderName: 'Folder',
          access: PublicationAccess.private,
        ).toJson(),
      );
      await expectLater(
        inspect(repo, remote, 'public'),
        throwsA(isA<PublicationFailure>()),
      );
      expect(remote.updatedProfiles, 0);
    },
  );

  test(
    're-binding client own previously published file or existing file ID is accepted',
    () async {
      final repo = f.Repository(await f.draft('one')), remote = f.Remote();
      await f.publish(repo, remote);
      final publishedId = remote.profileId;
      // Re-inspecting and re-binding the same file for this user should succeed without conflict
      final reviewed = await inspect(repo, remote, publishedId);
      expect(reviewed.file.id, publishedId);
      await f.coordinator(repo, remote).acceptBinding(reviewed);
      repo.current = await f.draft('two', ancestors: {'one'});
      expect((await f.publish(repo, remote))['status'], 'published');
      expect(remote.blobs[publishedId]!.properties['antirknHead'], 'two');
    },
  );
}
