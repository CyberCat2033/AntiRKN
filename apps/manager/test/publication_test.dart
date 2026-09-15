import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/publication/publication_panel.dart';
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
  @override
  Future<String?> readPublicationDocument(String id) async => docs[id];
  @override
  Future<String?> readPublicationQueue(String id) async => queues[id];
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Remote implements PublicationRemoteStore {
  final folders = <String, PublicationFile>{};
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final locale in ['ru', 'en']) {
    testWidgets(
      '$locale setup recovers lost folder response; received result and failed update retain copy link',
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
                  PublicationSettingsPanel(controller: c),
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
        expect(find.byIcon(Icons.copy), findsOneWidget);
        await c.setEnabled(false);
        expect(c.settings!.enabled, isFalse);
        expect(tester.takeException(), isNull);
        await c.suspend();
      },
    );
  }
}
