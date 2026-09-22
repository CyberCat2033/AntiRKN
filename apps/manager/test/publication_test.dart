import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/publication/publication_panel.dart';
import 'package:antirkn_manager/sync/auto_sync_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'vpn_controller_test.dart' as fixtures;

class Account
    implements GoogleSyncAccountService, GooglePublicationAuthorization {
  @override
  bool publicationAuthorized = false;
  @override
  String get accountKey => 'account';
  @override
  bool get supported => true;
  GoogleDriveAccount? account;
  @override
  Future<GoogleDriveAccount?> restore() async => account;
  @override
  Future<GoogleDriveAccount?> authorizePublications() async {
    publicationAuthorized = true;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Repository implements PublicationRepository {
  final docs = <String, String>{}, queues = <String, String>{};
  PublicationDraft? draft;
  final drafts = <String, PublicationDraft>{};
  @override
  Future<String?> readPublicationDocument(String id) async => docs[id];
  @override
  Future<String?> readPublicationQueue(String id) async => queues[id];
  @override
  Future<PublicationDraft?> readPublicationDraft(String id) async =>
      drafts[id] ?? (draft?.userId == id ? draft : null);
  @override
  Future<void> checkPublicationDraft(PublicationDraft value) async {
    final d = drafts[value.userId] ?? draft;
    if (d?.stamp != value.stamp) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
  }

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

  int failQueueWrites = 0;
  @override
  Future<void> writePublicationQueue(
    String id,
    String source, {
    required String? expectedSource,
  }) async {
    if (failQueueWrites > 0) {
      failQueueWrites--;
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
    if (queues[id] != expectedSource) {
      throw const SyncMergeFailure(SyncMergeIssue.changed);
    }
    queues[id] = source;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Remote implements PublicationRemoteStore {
  final folders = <String, PublicationFile>{};
  final contents = <String, Uint8List>{};
  int ids = 0, creates = 0;
  bool lost = false;
  PublicationIssue? failWithIssue;
  @override
  String get accountKey => 'account';
  @override
  Future<String> generateFileId() async => 'folder-${++ids}';
  @override
  Future<PublicationFile> getFile(String id) async {
    if (failWithIssue != null) throw PublicationFailure(failWithIssue!);
    return folders[id] ?? (throw const PublicationFailure(PublicationIssue.missing));
  }
  @override
  Future<void> createFolder(String id, String name) async {
    creates++;
    folders[id] = PublicationFile(
      id: id,
      name: name,
      mimeType: 'application/vnd.google-apps.folder',
      version: '1',
      etag: 'etag',
      editable: true,
      properties: {},
    );
    if (lost) {
      lost = false;
      throw const PublicationFailure(PublicationIssue.network);
    }
  }

  @override
  Future<Uint8List> download(String id) async => contents[id] ?? Uint8List(0);

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
    final digest = sha256.convert(bytes).toString();
    final created = PublicationFile(
      id: fileId,
      name: name,
      mimeType: 'application/x-yaml',
      version: '1',
      etag: 'etag-1',
      editable: true,
      properties: {
        'antirknWorkspace': workspaceId,
        'antirknUser': userId,
        'antirknHead': headId,
        'antirknExecutor': executorId,
        'antirknHash': digest,
      },
      downloadUrl: 'https://drive.google.com/uc?id=$fileId',
    );
    folders[fileId] = created;
    contents[fileId] = bytes;
    return created;
  }

  @override
  Future<void> checkPrivate(String id) async {}

  @override
  Future<PublicationFile> updateFile(
    PublicationFile expected,
    Uint8List bytes, {
    required Map<String, String> properties,
  }) async {
    contents[expected.id] = bytes;
    final digest = sha256.convert(bytes).toString();
    final f = folders[expected.id]!;
    final v = int.tryParse(f.version) ?? 1;
    final updated = PublicationFile(
      id: f.id,
      name: f.name,
      mimeType: f.mimeType,
      version: '${v + 1}',
      etag: 'etag-${v + 1}',
      editable: true,
      properties: {...f.properties, ...properties, 'antirknHash': digest},
      downloadUrl: f.downloadUrl,
    );
    folders[expected.id] = updated;
    return updated;
  }

  @override
  Future<PublicationFile> updateProperties(
    PublicationFile expected,
    Map<String, String> properties,
  ) async {
    final f = folders[expected.id]!;
    final updated = PublicationFile(
      id: f.id,
      name: f.name,
      mimeType: f.mimeType,
      version: f.version,
      etag: f.etag,
      editable: true,
      properties: {...f.properties, ...properties},
      downloadUrl: f.downloadUrl,
    );
    folders[expected.id] = updated;
    return updated;
  }

  @override
  Future<String> enableLink(String fileId) async => 'perm-$fileId';

  @override
  Future<void> verifyPublicLink(String url, Uint8List expected) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('waiting publication exposes an immediate retry action', (
    tester,
  ) async {
    final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
    final c = PublicationController(
      repository: Repository(),
      account: Account()..publicationAuthorized = true,
      remote: Remote.new,
      vpn: vpn,
      canPublish: () => false,
    )..foreground(false);
    await c.ready;
    await tester.runAsync(() async {
      await vpn.load();
      await vpn.saveUser(
        VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice'),
      );
    });
    c.settings = const PublicationSettings(
      accountKey: 'account',
      folderId: 'folder',
      folderName: 'Profiles',
      access: PublicationAccess.link,
      enabled: true,
      folderReady: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: UserPublicationView(controller: c, userId: fixtures.alice),
        ),
      ),
    );
    expect(find.text('Waiting to publish'), findsOneWidget);
    final retry = find.byKey(
      const ValueKey('publication-retry-${fixtures.alice}'),
    );
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.suspend();
    c.dispose();
    vpn.dispose();
  });

  testWidgets(
    'retained saved profile remains publishable while current compilation is blocked',
    (tester) async {
      var source = fixtures.template;
      final vpn = fixtures.controller(
        fixtures.MemoryVpn(),
        {},
        source: () => source,
      );
      final account = Account()..publicationAuthorized = true;
      final repo = Repository();
      final remote = Remote();
      final c = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      )..foreground(false);
      addTearDown(() {
        c.dispose();
        vpn.dispose();
      });
      await c.ready;
      late Map<String, dynamic> saved;
      await tester.runAsync(() async {
        await vpn.load();
        await vpn.saveUser(
          VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice'),
        );
        saved = vpn.workspace.profiles[fixtures.alice]!;
        source = '[invalid';
        await vpn.reconcile();
      });
      final savedYaml = saved['yaml'] as String;
      final savedHash = saved['hash'] as String;
      expect(vpn.results[fixtures.alice]!.hasBlockingErrors, isTrue);
      expect(vpn.workspace.profiles[fixtures.alice]!['hash'], savedHash);

      repo.docs['settings'] = canonicalJson(
        const PublicationSettings(
          accountKey: 'account',
          folderId: 'folder',
          folderName: 'Profiles',
          access: PublicationAccess.link,
          enabled: true,
          folderReady: true,
        ).toJson(),
      );
      repo.draft = PublicationDraft(
        workspaceId: vpn.workspace.id,
        deviceId: 'd' * 32,
        userId: fixtures.alice,
        name: 'Alice',
        headId: 'h' * 64,
        hash: savedHash,
        stamp: 'retained-profile',
        bytes: Uint8List.fromList(utf8.encode(savedYaml)),
        ancestors: {'h' * 64},
      );
      remote.folders['folder'] = const PublicationFile(
        id: 'folder',
        name: 'Profiles',
        mimeType: 'application/vnd.google-apps.folder',
        version: '1',
        etag: 'folder-etag',
        editable: true,
        properties: {},
      );
      remote.folders['existing'] = const PublicationFile(
        id: 'existing',
        name: 'alice.yml',
        mimeType: 'application/yaml',
        version: '1',
        etag: 'profile-etag',
        editable: true,
        properties: {},
      );
      remote.contents['existing'] = Uint8List.fromList(
        utf8.encode('old: profile'),
      );
      await c.reload();

      final preview = await c.inspectFile(
        fixtures.alice,
        PublicationTarget('existing'),
      );
      expect(preview.draft!.hash, savedHash);

      c.results[fixtures.alice] = {
        'fileId': 'existing',
        'hash': savedHash,
        'access': 'link',
        'url': 'https://drive.google.com/uc?id=existing',
      };
      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: UserPublicationView(controller: c, userId: fixtures.alice),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Profile published'), findsOneWidget);
      expect(find.text('Waiting to publish'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  for (final locale in ['ru', 'en']) {
    testWidgets(
      '$locale setup recovers lost folder response; received result and failed update retain verified URL without duplicate copy button',
      (tester) async {
        final account = Account(),
            repo = Repository(),
            remote = Remote()..lost = true;
        final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
        final c = PublicationController(
          repository: repo,
          account: account,
          remote: () => remote,
          vpn: vpn,
          canPublish: () => false,
        );
        addTearDown(() {
          c.dispose();
          vpn.dispose();
        });
        await c.ready;
        await tester.runAsync(() async {
          await vpn.load();
          await vpn.saveUser(
            VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice'),
          );
        });
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: ListView(
                children: [
                  PublicationSettingsPanel(
                    controller: c,
                    configuration: true,
                  ),
                  UserPublicationView(controller: c, userId: fixtures.alice),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('publication-configure')),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('publication-authorize')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('publication-configure')),
          findsOneWidget,
        );
        await c.configure(PublicationAccess.link);
        expect(c.settings!.folderReady, isFalse);
        final allocated = c.settings!.folderId;
        await c.completeSetup();
        expect(c.settings!.folderReady, isTrue);
        expect(c.settings!.folderId, allocated);
        expect(remote.ids, 1);
        expect(remote.creates, 1);
        repo.docs['result/${fixtures.alice}'] = jsonEncode({
          'fileId': 'fixture',
          'hash': vpn.results[fixtures.alice]!.sha256Hash,
          'access': 'link',
          'url': 'https://drive.google.com/uc?id=fixture',
        });
        await c.reload();
        await tester.pumpAndSettle();
        expect(
          find.text(
            locale == 'ru' ? 'Профиль опубликован' : 'Profile published',
          ),
          findsOneWidget,
        );
        repo.queues[fixtures.alice] = '{"status":"error","issue":"network"}';
        await c.reload();
        await tester.pumpAndSettle();
        expect(
          find.text(
            locale == 'ru' ? 'Профиль опубликован' : 'Profile published',
          ),
          findsNothing,
        );
        expect(find.byIcon(Icons.copy), findsNothing);
        expect(
          c.verifiedLinkFor(fixtures.alice),
          'https://drive.google.com/uc?id=fixture',
        );
        repo.queues[fixtures.alice] =
            '{"status":"error","issue":"linkUnavailable"}';
        await c.reload();
        expect(c.verifiedLinkFor(fixtures.alice), isNull);
        repo.queues.remove(fixtures.alice);
        await c.reload();
        // Per-user issues are stored in queues, not the global error field.
        c.queues[fixtures.alice] = {'issue': 'missing', 'userId': fixtures.alice};
        expect(c.verifiedLinkFor(fixtures.alice), isNull);
        c.queues.remove(fixtures.alice);
        // Global errors like 'unauthorized' still block all links.
        c.error = PublicationIssue.unauthorized;
        expect(c.verifiedLinkFor(fixtures.alice), isNull);
        c.error = PublicationIssue.network;
        expect(c.verifiedLinkFor(fixtures.alice), isNotNull);
        await c.setEnabled(false);
        expect(c.settings!.enabled, isFalse);
        expect(tester.takeException(), isNull);
        await c.suspend();
      },
    );
  }

  test('bindFile publishes immediately and persists new link across reload', () async {
    final account = Account()..publicationAuthorized = true;
    final repo = Repository();
    final remote = Remote();
    final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
    addTearDown(vpn.dispose);
    final c = PublicationController(
      repository: repo,
      account: account,
      remote: () => remote,
      vpn: vpn,
    );
    addTearDown(c.dispose);
    await c.ready;
    final user = VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice');
    await vpn.load();
    await vpn.saveUser(user);
    final saved = vpn.workspace.profiles[fixtures.alice]!;
    final savedYaml = saved['yaml'] as String;
    final savedHash = saved['hash'] as String;
    final draft = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.alice,
      name: 'Alice',
      headId: 'head-1',
      hash: savedHash,
      stamp: 'stamp-1',
      bytes: Uint8List.fromList(utf8.encode(savedYaml)),
      ancestors: {},
    );
    repo.draft = draft;
    c.settings = const PublicationSettings(
      accountKey: 'account',
      folderId: 'folder-1',
      folderName: 'Folder',
      access: PublicationAccess.link,
      enabled: true,
      folderReady: true,
    );
    repo.docs['settings'] = canonicalJson(c.settings!.toJson());
    remote.folders['folder-1'] = PublicationFile(
      id: 'folder-1',
      name: 'Folder',
      mimeType: 'application/vnd.google-apps.folder',
      version: '1',
      etag: 'etag-f',
      editable: true,
      properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
    );
    final regBytes = Uint8List.fromList(utf8.encode(canonicalJson({
      'version': 2,
      'workspaceId': vpn.workspace.id,
      'users': <String, dynamic>{},
    })));
    final regHash = sha256.convert(regBytes).toString();
    remote.folders['registry-1'] = PublicationFile(
      id: 'registry-1',
      name: 'registry.json',
      mimeType: 'application/json',
      version: '1',
      etag: 'etag-r',
      editable: true,
      properties: {
        'antirknWorkspace': vpn.workspace.id,
        'antirknUser': 'registry',
        'antirknHash': regHash,
      },
      downloadUrl: 'https://drive.google.com/uc?id=registry-1',
    );
    remote.contents['registry-1'] = regBytes;

    remote.folders['custom-file-1'] = const PublicationFile(
      id: 'custom-file-1',
      name: 'custom.yml',
      mimeType: 'text/yaml',
      version: '1',
      etag: 'etag-c',
      editable: true,
      properties: {},
      downloadUrl: 'https://drive.google.com/uc?id=custom-file-1',
    );
    remote.contents['custom-file-1'] = Uint8List.fromList(utf8.encode('old: content'));

    final preview = await c.inspectFile(user.id, PublicationTarget('custom-file-1'));
    expect(preview.file.id, 'custom-file-1');

    await c.bindFile(preview);

    expect(c.verifiedLinkFor(user.id), 'https://drive.google.com/uc?id=custom-file-1');
    expect(c.results[user.id]?['fileId'], 'custom-file-1');
    expect(c.bindingPending(user.id), isFalse);

    // Simulate reload / restart
    await c.reload();
    expect(c.verifiedLinkFor(user.id), 'https://drive.google.com/uc?id=custom-file-1');
    expect(c.results[user.id]?['fileId'], 'custom-file-1');
  });

  test('forcePublishAll waits if suspended and completes once resumed', () async {
    final account = Account()..publicationAuthorized = true;
    final repo = Repository();
    final remote = Remote();
    final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
    addTearDown(vpn.dispose);
    final c = PublicationController(
      repository: repo,
      account: account,
      remote: () => remote,
      vpn: vpn,
    );
    addTearDown(c.dispose);
    await c.ready;
    final user = VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice');
    await vpn.load();
    await vpn.saveUser(user);
    final saved = vpn.workspace.profiles[fixtures.alice]!;
    final savedYaml = saved['yaml'] as String;
    final savedHash = saved['hash'] as String;
    final draft = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.alice,
      name: 'Alice',
      headId: 'head-1',
      hash: savedHash,
      stamp: 'stamp-1',
      bytes: Uint8List.fromList(utf8.encode(savedYaml)),
      ancestors: {},
    );
    repo.draft = draft;
    final settings = const PublicationSettings(
      accountKey: 'account',
      folderId: 'test-folder',
      folderName: 'Folder',
      access: PublicationAccess.link,
      enabled: true,
      folderReady: true,
    );
    repo.docs['settings'] = canonicalJson(settings.toJson());
    await c.reload();
    remote.folders['test-folder'] = PublicationFile(
      id: 'test-folder',
      name: 'Folder',
      mimeType: 'application/vnd.google-apps.folder',
      version: '1',
      etag: 'etag-f',
      editable: true,
      properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
    );
    final regBytes = Uint8List.fromList(utf8.encode(canonicalJson({
      'version': 2,
      'workspaceId': vpn.workspace.id,
      'users': <String, dynamic>{},
    })));
    final regHash = sha256.convert(regBytes).toString();
    remote.folders['registry-1'] = PublicationFile(
      id: 'registry-1',
      name: 'registry.json',
      mimeType: 'application/json',
      version: '1',
      etag: 'etag-r',
      editable: true,
      properties: {
        'antirknWorkspace': vpn.workspace.id,
        'antirknUser': 'registry',
        'antirknHash': regHash,
      },
      downloadUrl: 'https://drive.google.com/uc?id=registry-1',
    );
    remote.contents['registry-1'] = regBytes;

    await c.suspend();
    final publishFuture = c.forcePublishAll();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    c.resume();
    await publishFuture;

    expect(c.queues[fixtures.alice]?['issue'], isNull);
    expect(c.queues[fixtures.alice]?['status'], 'published');
    expect(c.results[fixtures.alice]?['hash'], savedHash);
  });

  test('PublicationController retries transient SyncMergeFailure up to 3 times', () async {
    final account = Account()..publicationAuthorized = true;
    final repo = Repository();
    final remote = Remote();
    final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
    addTearDown(vpn.dispose);
    final c = PublicationController(
      repository: repo,
      account: account,
      remote: () => remote,
      vpn: vpn,
    );
    addTearDown(c.dispose);
    await c.ready;
    final user = VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice');
    await vpn.load();
    await vpn.saveUser(user);
    final saved = vpn.workspace.profiles[fixtures.alice]!;
    final savedYaml = saved['yaml'] as String;
    final savedHash = saved['hash'] as String;
    final draft = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.alice,
      name: 'Alice',
      headId: 'head-1',
      hash: savedHash,
      stamp: 'stamp-1',
      bytes: Uint8List.fromList(utf8.encode(savedYaml)),
      ancestors: {},
    );
    repo.draft = draft;
    final settings = const PublicationSettings(
      accountKey: 'account',
      folderId: 'test-folder',
      folderName: 'Folder',
      access: PublicationAccess.link,
      enabled: true,
      folderReady: true,
    );
    repo.docs['settings'] = canonicalJson(settings.toJson());
    await c.reload();
    remote.folders['test-folder'] = PublicationFile(
      id: 'test-folder',
      name: 'Folder',
      mimeType: 'application/vnd.google-apps.folder',
      version: '1',
      etag: 'etag-f',
      editable: true,
      properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
    );
    final regBytes = Uint8List.fromList(utf8.encode(canonicalJson({
      'version': 2,
      'workspaceId': vpn.workspace.id,
      'users': <String, dynamic>{},
    })));
    final regHash = sha256.convert(regBytes).toString();
    remote.folders['registry-1'] = PublicationFile(
      id: 'registry-1',
      name: 'registry.json',
      mimeType: 'application/json',
      version: '1',
      etag: 'etag-r',
      editable: true,
      properties: {
        'antirknWorkspace': vpn.workspace.id,
        'antirknUser': 'registry',
        'antirknHash': regHash,
      },
      downloadUrl: 'https://drive.google.com/uc?id=registry-1',
    );
    remote.contents['registry-1'] = regBytes;

    // First attempt will fail due to transient merge issue, second attempt will succeed
    repo.failQueueWrites = 1;
    await c.forcePublishAll();

    expect(c.queues[fixtures.alice]?['issue'], isNull);
    expect(c.queues[fixtures.alice]?['status'], 'published');
    expect(c.results[fixtures.alice]?['hash'], savedHash);
  });

  test('active publication count strictly filters deleted users and requires matching hashes', () {
    final active1 = VpnUser(id: '1' * 32, login: 'active1', name: 'Active 1');
    final active2 = VpnUser(id: '2' * 32, login: 'active2', name: 'Active 2');
    final active3 = VpnUser(id: '3' * 32, login: 'active3', name: 'Active 3');
    final deleted = VpnUser(
      id: '4' * 32,
      login: 'deleted',
      name: 'Deleted',
      enabled: false,
      deletion: {
        'version': 1,
        'id': 'd' * 32,
        'targets': <String, dynamic>{},
        'deletedAt': '2026-09-01T00:00:00.000Z',
      },
    );

    final users = [active1, active2, active3, deleted];
    final profiles = {
      active1.id: {'hash': 'hash-active1'},
      active2.id: {'hash': 'hash-active2-current'},
      active3.id: {'hash': 'hash-active3'},
      deleted.id: {'hash': 'hash-deleted'},
    };

    // active1: properly published
    final queues = <String, Map<String, dynamic>>{
      active1.id: {'status': 'published', 'issue': null},
      active2.id: {'status': 'error', 'issue': 'changed'}, // failed with issue
      active3.id: {'status': 'published', 'issue': null}, // published with outdated hash
      deleted.id: {'status': 'published', 'issue': null}, // deleted user with old published record
    };
    final results = <String, Map<String, dynamic>>{
      active1.id: {'hash': 'hash-active1'},
      active2.id: {'hash': 'hash-active2-old'},
      active3.id: {'hash': 'hash-active3-outdated'},
      deleted.id: {'hash': 'hash-deleted'},
    };

    final activeUsers = users
        .where((u) => u.enabled && !u.deleted)
        .toList(growable: false);
    expect(activeUsers.length, 3);

    final published = activeUsers
        .where((u) {
          final q = queues[u.id];
          final r = results[u.id];
          final expectedHash = profiles[u.id]?['hash'];
          return q?['status'] == 'published' &&
              q?['issue'] == null &&
              r != null &&
              r['hash'] == expectedHash;
        })
        .length;

    // Only active1 satisfies all conditions
    expect(published, 1);
    // Deleted users must never be included even if present in results
    expect(activeUsers.any((u) => u.id == deleted.id), isFalse);
  });

  test('PublicationController does not abort in-flight publication or break loop when window loses focus (foreground false)', () async {
    final account = Account()..publicationAuthorized = true;
    final repo = Repository();
    final remote = Remote();
    final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
    addTearDown(vpn.dispose);
    final c = PublicationController(
      repository: repo,
      account: account,
      remote: () => remote,
      vpn: vpn,
    );
    addTearDown(c.dispose);
    await c.ready;

    final userAlice = VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice');
    final userBob = VpnUser(id: fixtures.bob, login: 'bob', name: 'Bob');
    await vpn.load();
    await vpn.saveUser(userAlice);
    await vpn.saveUser(userBob);

    final aliceSaved = vpn.workspace.profiles[fixtures.alice]!;
    final bobSaved = vpn.workspace.profiles[fixtures.bob]!;

    final aliceDraft = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.alice,
      name: 'Alice',
      headId: 'head-alice',
      hash: aliceSaved['hash'] as String,
      stamp: 'stamp-alice',
      bytes: Uint8List.fromList(utf8.encode(aliceSaved['yaml'] as String)),
      ancestors: {},
    );
    final bobDraft = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.bob,
      name: 'Bob',
      headId: 'head-bob',
      hash: bobSaved['hash'] as String,
      stamp: 'stamp-bob',
      bytes: Uint8List.fromList(utf8.encode(bobSaved['yaml'] as String)),
      ancestors: {},
    );

    repo.drafts[fixtures.alice] = aliceDraft;
    repo.drafts[fixtures.bob] = bobDraft;

    final settings = const PublicationSettings(
      accountKey: 'account',
      folderId: 'test-folder',
      folderName: 'Folder',
      access: PublicationAccess.link,
      enabled: true,
      folderReady: true,
    );
    repo.docs['settings'] = canonicalJson(settings.toJson());
    await c.reload();

    remote.folders['test-folder'] = PublicationFile(
      id: 'test-folder',
      name: 'Folder',
      mimeType: 'application/vnd.google-apps.folder',
      version: '1',
      etag: 'etag-f',
      editable: true,
      properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
    );
    final regBytes = Uint8List.fromList(utf8.encode(canonicalJson({
      'version': 2,
      'workspaceId': vpn.workspace.id,
      'users': <String, dynamic>{},
    })));
    final regHash = sha256.convert(regBytes).toString();
    remote.folders['registry-1'] = PublicationFile(
      id: 'registry-1',
      name: 'registry.json',
      mimeType: 'application/json',
      version: '1',
      etag: 'etag-r',
      editable: true,
      properties: {
        'antirknWorkspace': vpn.workspace.id,
        'antirknUser': 'registry',
        'antirknHash': regHash,
      },
      downloadUrl: 'https://drive.google.com/uc?id=registry-1',
    );
    remote.contents['registry-1'] = regBytes;

    // Start publishing and immediately simulate window becoming inactive / losing focus
    final future = c.forcePublishAll(force: false);
    c.foreground(false);
    await future;

    expect(c.queues[fixtures.alice]?['status'], 'published');
    expect(c.queues[fixtures.alice]?['issue'], isNull);
    expect(c.queues[fixtures.bob]?['status'], 'published');
    expect(c.queues[fixtures.bob]?['issue'], isNull);
  });

  test('background proxy latency checks (vpn.connections.busy) do not block publication or mark drafts as changed', () async {
    final account = Account()..publicationAuthorized = true;
    final repo = Repository();
    final remote = Remote();
    final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
    addTearDown(vpn.dispose);
    final c = PublicationController(
      repository: repo,
      account: account,
      remote: () => remote,
      vpn: vpn,
    );
    addTearDown(c.dispose);
    await c.ready;

    final userAlice = VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice');
    final userBob = VpnUser(id: fixtures.bob, login: 'bob', name: 'Bob');
    await vpn.load();
    await vpn.saveUser(userAlice);
    await vpn.saveUser(userBob);

    final aliceSaved = vpn.workspace.profiles[fixtures.alice]!;
    final bobSaved = vpn.workspace.profiles[fixtures.bob]!;

    repo.drafts[fixtures.alice] = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.alice,
      name: 'Alice',
      headId: 'head-alice',
      hash: aliceSaved['hash'] as String,
      stamp: 'stamp-alice',
      bytes: Uint8List.fromList(utf8.encode(aliceSaved['yaml'] as String)),
      ancestors: {},
    );
    repo.drafts[fixtures.bob] = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.bob,
      name: 'Bob',
      headId: 'head-bob',
      hash: bobSaved['hash'] as String,
      stamp: 'stamp-bob',
      bytes: Uint8List.fromList(utf8.encode(bobSaved['yaml'] as String)),
      ancestors: {},
    );

    final settings = const PublicationSettings(
      accountKey: 'account',
      folderId: 'test-folder',
      folderName: 'Folder',
      access: PublicationAccess.link,
      enabled: true,
      folderReady: true,
    );
    repo.docs['settings'] = canonicalJson(settings.toJson());
    await c.reload();

    remote.folders['test-folder'] = PublicationFile(
      id: 'test-folder',
      name: 'Folder',
      mimeType: 'application/vnd.google-apps.folder',
      version: '1',
      etag: 'etag-f',
      editable: true,
      properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
    );
    final regBytes = Uint8List.fromList(utf8.encode(canonicalJson({
      'version': 2,
      'workspaceId': vpn.workspace.id,
      'users': <String, dynamic>{},
    })));
    final regHash = sha256.convert(regBytes).toString();
    remote.folders['registry-1'] = PublicationFile(
      id: 'registry-1',
      name: 'registry.json',
      mimeType: 'application/json',
      version: '1',
      etag: 'etag-r',
      editable: true,
      properties: {
        'antirknWorkspace': vpn.workspace.id,
        'antirknUser': 'registry',
        'antirknHash': regHash,
      },
      downloadUrl: 'https://drive.google.com/uc?id=registry-1',
    );
    remote.contents['registry-1'] = regBytes;

    // Simulate active background proxy connection check
    vpn.connections.current = (target: 'server-1', resource: 'inbound-1');
    expect(vpn.busy, isTrue);
    expect(vpn.workspaceBusy, isFalse);

    await c.forcePublishAll(force: false);

    expect(c.queues[fixtures.alice]?['status'], 'published');
    expect(c.queues[fixtures.alice]?['issue'], isNull);
    expect(c.queues[fixtures.bob]?['status'], 'published');
    expect(c.queues[fixtures.bob]?['issue'], isNull);
  });

  test('single user failure is isolated and does not abort remaining users in batch publication', () async {
    final account = Account()..publicationAuthorized = true;
    final repo = Repository();
    final remote = Remote();
    final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
    addTearDown(vpn.dispose);
    final c = PublicationController(
      repository: repo,
      account: account,
      remote: () => remote,
      vpn: vpn,
    );
    addTearDown(c.dispose);
    await c.ready;

    final userAlice = VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice');
    final userBob = VpnUser(id: fixtures.bob, login: 'bob', name: 'Bob');
    await vpn.load();
    await vpn.saveUser(userAlice);
    await vpn.saveUser(userBob);

    final aliceSaved = vpn.workspace.profiles[fixtures.alice]!;
    final bobSaved = vpn.workspace.profiles[fixtures.bob]!;

    repo.drafts[fixtures.alice] = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.alice,
      name: 'Alice',
      headId: 'head-alice',
      hash: aliceSaved['hash'] as String,
      stamp: 'stamp-alice',
      bytes: Uint8List.fromList(utf8.encode(aliceSaved['yaml'] as String)),
      ancestors: {},
    );
    repo.drafts[fixtures.bob] = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.bob,
      name: 'Bob',
      headId: 'head-bob',
      hash: bobSaved['hash'] as String,
      stamp: 'stamp-bob',
      bytes: Uint8List.fromList(utf8.encode(bobSaved['yaml'] as String)),
      ancestors: {},
    );

    final settings = const PublicationSettings(
      accountKey: 'account',
      folderId: 'test-folder',
      folderName: 'Folder',
      access: PublicationAccess.link,
      enabled: true,
      folderReady: true,
    );
    repo.docs['settings'] = canonicalJson(settings.toJson());
    await c.reload();

    remote.folders['test-folder'] = PublicationFile(
      id: 'test-folder',
      name: 'Folder',
      mimeType: 'application/vnd.google-apps.folder',
      version: '1',
      etag: 'etag-f',
      editable: true,
      properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
    );
    final regBytes = Uint8List.fromList(utf8.encode(canonicalJson({
      'version': 2,
      'workspaceId': vpn.workspace.id,
      'users': <String, dynamic>{},
    })));
    final regHash = sha256.convert(regBytes).toString();
    remote.folders['registry-1'] = PublicationFile(
      id: 'registry-1',
      name: 'registry.json',
      mimeType: 'application/json',
      version: '1',
      etag: 'etag-r',
      editable: true,
      properties: {
        'antirknWorkspace': vpn.workspace.id,
        'antirknUser': 'registry',
        'antirknHash': regHash,
      },
      downloadUrl: 'https://drive.google.com/uc?id=registry-1',
    );
    remote.contents['registry-1'] = regBytes;

    // Fail Alice by throwing PublicationFailure
    remote.folders['folder-1'] = PublicationFile(
      id: 'folder-1',
      name: 'broken',
      mimeType: 'application/x-yaml',
      version: '1',
      etag: 'etag',
      editable: false, // Invalid
      properties: const {},
    );

    final batchResult = await c.forcePublishAll(force: true);

    // Alice should fail with invalid or conflict
    expect(c.queues[fixtures.alice]?['issue'], isNotNull);
    // Bob must succeed despite Alice failing
    expect(c.queues[fixtures.bob]?['status'], 'published');
    expect(c.queues[fixtures.bob]?['issue'], isNull);
    expect(batchResult.uploaded, 1);
    expect(batchResult.failed, 1);
    expect(batchResult.upToDate, 0);
  });

  test('forcePublishAll returns honest PublicationBatchResult with upToDate count on fast-path', () async {
    final account = Account()..publicationAuthorized = true;
    final repo = Repository();
    final remote = Remote();
    final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
    addTearDown(vpn.dispose);
    final c = PublicationController(
      repository: repo,
      account: account,
      remote: () => remote,
      vpn: vpn,
    );
    addTearDown(c.dispose);
    await c.ready;

    final userAlice = VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice');
    final userBob = VpnUser(id: fixtures.bob, login: 'bob', name: 'Bob');
    await vpn.load();
    await vpn.saveUser(userAlice);
    await vpn.saveUser(userBob);

    final aliceSaved = vpn.workspace.profiles[fixtures.alice]!;
    final bobSaved = vpn.workspace.profiles[fixtures.bob]!;

    repo.drafts[fixtures.alice] = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'a' * 32,
      userId: fixtures.alice,
      name: 'Alice',
      headId: 'head-alice',
      hash: aliceSaved['hash'] as String,
      stamp: 'stamp-1',
      bytes: Uint8List.fromList(utf8.encode(aliceSaved['yaml'] as String)),
      ancestors: {},
    );
    repo.drafts[fixtures.bob] = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: fixtures.bob,
      name: 'Bob',
      headId: 'head-bob',
      hash: bobSaved['hash'] as String,
      stamp: 'stamp-1',
      bytes: Uint8List.fromList(utf8.encode(bobSaved['yaml'] as String)),
      ancestors: {},
    );

    final settings = const PublicationSettings(
      accountKey: 'account',
      folderId: 'test-folder',
      folderName: 'Folder',
      access: PublicationAccess.link,
      enabled: true,
      folderReady: true,
    );
    repo.docs['settings'] = canonicalJson(settings.toJson());
    await c.reload();

    remote.folders['test-folder'] = PublicationFile(
      id: 'test-folder',
      name: 'Folder',
      mimeType: 'application/vnd.google-apps.folder',
      version: '1',
      etag: 'etag-f',
      editable: true,
      properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
    );
    final regBytes = Uint8List.fromList(utf8.encode(canonicalJson({
      'version': 2,
      'workspaceId': vpn.workspace.id,
      'users': <String, dynamic>{},
    })));
    final regHash = sha256.convert(regBytes).toString();
    remote.folders['registry-1'] = PublicationFile(
      id: 'registry-1',
      name: 'registry.json',
      mimeType: 'application/json',
      version: '1',
      etag: 'etag-r',
      editable: true,
      properties: {
        'antirknWorkspace': vpn.workspace.id,
        'antirknUser': 'registry',
        'antirknHash': regHash,
      },
      downloadUrl: 'https://drive.google.com/uc?id=registry-1',
    );
    remote.contents['registry-1'] = regBytes;

    // First publish: initial upload of both users
    final initialResult = await c.forcePublishAll(force: true);
    expect(initialResult.uploaded, 2);
    expect(initialResult.upToDate, 0);
    expect(initialResult.failed, 0);
    expect(c.isUserUpToDate(fixtures.alice), isTrue);
    expect(c.isUserUpToDate(fixtures.bob), isTrue);

    // Second publish with force: false (no changes): both should skip via fast-path
    final fastPathResult = await c.forcePublishAll(force: false);
    expect(fastPathResult.uploaded, 0);
    expect(fastPathResult.upToDate, 2);
    expect(fastPathResult.failed, 0);

    // Third publish with force: true: should re-upload both despite being up to date
    final forcedResult = await c.forcePublishAll(force: true);
    expect(forcedResult.uploaded, 2);
    expect(forcedResult.upToDate, 0);
    expect(forcedResult.failed, 0);
  });

  test(
    'concurrent AutoSync exchange and batch publication run simultaneously without busy or conflict errors',
    () async {
      final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
      final repo = Repository();
      final remote = Remote();
      final account = Account()..publicationAuthorized = true;
      account.account = const GoogleDriveAccount(
        email: 'test@example.com',
        displayName: 'Test',
        permissionId: 'perm-1',
      );
      final c = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );
      addTearDown(c.dispose);
      addTearDown(vpn.dispose);

      final session = _TestAutoSyncSession();
      final changes = StreamController<void>.broadcast();
      addTearDown(changes.close);
      final autoSync = AutoSyncController(
        accountService: account,
        settings: _TestSettingsStore(),
        changes: changes.stream,
        openSession: () async => session,
        apply: (_) async => true,
      );
      addTearDown(autoSync.dispose);

      await vpn.load();
      await vpn.saveUser(
        VpnUser(id: fixtures.alice, login: 'alice', name: 'Alice'),
      );
      await vpn.saveUser(VpnUser(id: fixtures.bob, login: 'bob', name: 'Bob'));
      final aliceSaved = vpn.workspace.profiles[fixtures.alice]!;
      final bobSaved = vpn.workspace.profiles[fixtures.bob]!;

      repo.drafts[fixtures.alice] = PublicationDraft(
        workspaceId: vpn.workspace.id,
        deviceId: 'a' * 32,
        userId: fixtures.alice,
        name: 'Alice',
        headId: 'head-alice',
        hash: aliceSaved['hash'] as String,
        stamp: 'stamp-1',
        bytes: Uint8List.fromList(utf8.encode(aliceSaved['yaml'] as String)),
        ancestors: {},
      );
      repo.drafts[fixtures.bob] = PublicationDraft(
        workspaceId: vpn.workspace.id,
        deviceId: 'b' * 32,
        userId: fixtures.bob,
        name: 'Bob',
        headId: 'head-bob',
        hash: bobSaved['hash'] as String,
        stamp: 'stamp-1',
        bytes: Uint8List.fromList(utf8.encode(bobSaved['yaml'] as String)),
        ancestors: {},
      );

      final settings = const PublicationSettings(
        accountKey: 'account',
        folderId: 'test-folder',
        folderName: 'Folder',
        access: PublicationAccess.link,
        enabled: true,
        folderReady: true,
      );
      repo.docs['settings'] = canonicalJson(settings.toJson());
      await c.reload();

      remote.folders['test-folder'] = PublicationFile(
        id: 'test-folder',
        name: 'Folder',
        mimeType: 'application/vnd.google-apps.folder',
        version: '1',
        etag: 'etag-f',
        editable: true,
        properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
      );
      final regBytes = Uint8List.fromList(utf8.encode(canonicalJson({
        'version': 2,
        'workspaceId': vpn.workspace.id,
        'users': <String, dynamic>{},
      })));
      final regHash = sha256.convert(regBytes).toString();
      remote.folders['registry-1'] = PublicationFile(
        id: 'registry-1',
        name: 'registry.json',
        mimeType: 'application/json',
        version: '1',
        etag: 'etag-r',
        editable: true,
        properties: {
          'antirknWorkspace': vpn.workspace.id,
          'antirknUser': 'registry',
          'antirknHash': regHash,
        },
        downloadUrl: 'https://drive.google.com/uc?id=registry-1',
      );
      remote.contents['registry-1'] = regBytes;

      await autoSync.ready;
      // Trigger concurrent AutoSync request and batch publication
      autoSync.request(immediate: true);
      final publishResult = await c.forcePublishAll(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(publishResult.uploaded, 2);
      expect(publishResult.failed, 0);
      expect(c.error, isNull);
      expect(c.accountError, isNull);
      expect(session.executed, isTrue);
      expect(autoSync.phase, AutoSyncPhase.synced);
    },
  );

  test(
    'unauthorized error aborts batch immediately and fails subsequent calls fast',
    () async {
      final repo = Repository(), remote = Remote(), account = Account();
      account.publicationAuthorized = true;
      final vpn = fixtures.controller(fixtures.MemoryVpn(), {});
      final c = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );
      addTearDown(c.dispose);
      addTearDown(vpn.dispose);

      await vpn.load();
      final userIds = [
        fixtures.alice,
        fixtures.bob,
        'c' * 32,
        'd' * 32,
        'e' * 32,
        'f' * 32,
      ];
      for (var i = 0; i < userIds.length; i++) {
        final uid = userIds[i];
        final login = 'user$i';
        await vpn.saveUser(VpnUser(id: uid, login: login, name: 'User $i'));
        final saved = vpn.workspace.profiles[uid]!;
        repo.drafts[uid] = PublicationDraft(
          workspaceId: vpn.workspace.id,
          deviceId: 'a' * 32,
          userId: uid,
          name: 'User $i',
          headId: 'head-$uid',
          hash: saved['hash'] as String,
          stamp: 'stamp-$uid',
          bytes: Uint8List.fromList(utf8.encode(saved['yaml'] as String)),
          ancestors: {},
        );
      }

      final settings = const PublicationSettings(
        accountKey: 'account',
        folderId: 'test-folder',
        folderName: 'Folder',
        access: PublicationAccess.link,
        enabled: true,
        folderReady: true,
      );
      repo.docs['settings'] = canonicalJson(settings.toJson());
      await c.reload();

      // Remote fails with unauthorized
      remote.failWithIssue = PublicationIssue.unauthorized;

      final batchResult = await c.forcePublishAll(force: true);

      // Circuit breaker stops workers: only the initial concurrent batch (4) runs,
      // remaining users (user-5, user-6) are not attempted (failed is 4, not 6).
      expect(batchResult.failed, 4);
      expect(batchResult.failed, lessThan(userIds.length));
      expect(batchResult.uploaded, 0);
      expect(c.error, PublicationIssue.unauthorized);
      expect(c.accountError, GoogleAccountIssue.reauthorize);
      expect(c.needsAuthorization, isTrue);

      // Subsequent call fails fast with failed: 1 without performing remote calls
      final secondResult = await c.forcePublishAll(force: true);
      expect(secondResult.failed, 1);

      // User publish also immediately aborts without remote work
      await c.publishUser('e' * 32);
      expect(c.needsAuthorization, isTrue);
    },
  );
}

class _TestAutoSyncSession implements AutoSyncSession {
  bool executed = false;
  @override
  Future<AutoSyncResult> exchange({
    required SyncApplyGate apply,
    required SyncCancellation cancellation,
    bool forceRecovery = false,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    executed = true;
    return AutoSyncResult(
      otherWorkspaces: 0,
      waitingForEditor: false,
      lastSuccess: DateTime.now(),
    );
  }

  @override
  Future<void> close() async {}
}

class _TestSettingsStore implements SettingsStore {
  final map = <String, String>{};
  @override
  Future<String?> readSetting(String key) async => map[key];
  @override
  Future<void> writeSetting(String key, String value) async {
    map[key] = value;
  }
}

