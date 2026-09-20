import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/publication/publication_panel.dart';
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
  @override
  Future<String?> readPublicationDocument(String id) async => docs[id];
  @override
  Future<String?> readPublicationQueue(String id) async => queues[id];
  @override
  Future<PublicationDraft?> readPublicationDraft(String id) async =>
      draft?.userId == id ? draft : null;
  @override
  Future<void> checkPublicationDraft(PublicationDraft value) async {
    if (draft?.stamp != value.stamp) {
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Remote implements PublicationRemoteStore {
  final folders = <String, PublicationFile>{};
  final contents = <String, Uint8List>{};
  int ids = 0, creates = 0;
  bool lost = false;
  @override
  String get accountKey => 'account';
  @override
  Future<String> generateFileId() async => 'folder-${++ids}';
  @override
  Future<PublicationFile> getFile(String id) async =>
      folders[id] ?? (throw const PublicationFailure(PublicationIssue.missing));
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
  Future<void> checkPrivate(String id) async {}

  @override
  Future<void> updateFile(
    PublicationFile expected,
    Uint8List bytes, {
    required Map<String, String> properties,
  }) async {
    contents[expected.id] = bytes;
    final digest = sha256.convert(bytes).toString();
    final f = folders[expected.id]!;
    final v = int.tryParse(f.version) ?? 1;
    folders[expected.id] = PublicationFile(
      id: f.id,
      name: f.name,
      mimeType: f.mimeType,
      version: '${v + 1}',
      etag: 'etag-${v + 1}',
      editable: true,
      properties: {...f.properties, ...properties, 'antirknHash': digest},
      downloadUrl: f.downloadUrl,
    );
  }

  @override
  Future<void> updateProperties(
    PublicationFile expected,
    Map<String, String> properties,
  ) async {
    final f = folders[expected.id]!;
    folders[expected.id] = PublicationFile(
      id: f.id,
      name: f.name,
      mimeType: f.mimeType,
      version: f.version,
      etag: f.etag,
      editable: true,
      properties: {...f.properties, ...properties},
      downloadUrl: f.downloadUrl,
    );
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
}
