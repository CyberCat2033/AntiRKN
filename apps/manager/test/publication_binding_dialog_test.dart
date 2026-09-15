import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/publication_binding_dialog.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/publication/publication_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'publication_test.dart' as f;
import 'vpn_controller_test.dart' as v;

class Controller extends PublicationController {
  Controller()
    : super(
        repository: f.Repository(),
        account: f.Account()..publicationAuthorized = true,
        remote: f.Remote.new,
        vpn: v.controller(v.MemoryVpn(), {}),
      ) {
    foreground(false);
  }
  int inspected = 0, accepted = 0, picked = 0;
  @override
  bool get pickerReady => true;
  @override
  Future<PublicationTarget?> pickFile() async {
    picked++;
    return PublicationTarget('existing-file');
  }

  @override
  Future<PublicationBindingPreview> inspectFile(
    String userId,
    PublicationTarget target,
  ) async {
    inspected++;
    return PublicationBindingPreview(
      file: PublicationFile(
        id: target.fileId,
        name: 'legacy.yml',
        mimeType: 'application/yaml',
        version: '1',
        etag: 'etag',
        editable: true,
        properties: {},
      ),
      content: 'old: content',
      hash: 'old-hash',
      draft: PublicationDraft(
        workspaceId: 'a' * 32,
        deviceId: 'b' * 32,
        userId: userId,
        name: 'Fixture',
        headId: 'head',
        hash: 'hash',
        stamp: 'stamp',
        bytes: Uint8List.fromList(utf8.encode('new: profile')),
        ancestors: {},
      ),
      settingsSource: '',
      intentSource: null,
      registryId: null,
      entry: null,
    );
  }

  @override
  Future<void> bindFile(PublicationBindingPreview preview) async {
    accepted++;
  }

  @override
  void dispose() {
    vpn.dispose();
    super.dispose();
  }
}

void main() {
  test(
    'pending target failure retains old QR; a failed active target hides it',
    () async {
      final c = Controller();
      addTearDown(c.dispose);
      await c.ready;
      final user = VpnUser(id: 'c' * 32, login: 'fixture', name: 'Fixture');
      c.vpn.workspace = c.vpn.workspace.copy(users: [user]);
      c.settings = const PublicationSettings(
        accountKey: 'account',
        folderId: 'folder',
        folderName: 'Folder',
        access: PublicationAccess.link,
      );
      c.results[user.id] = {
        'fileId': 'old',
        'url': 'https://drive.google.com/uc?id=old',
        'access': 'link',
      };
      c.bindings[user.id] = {'id': 'new-operation', 'fileId': 'new'};
      c.queues[user.id] = {'status': 'error', 'issue': 'linkUnavailable'};
      expect(c.verifiedLinkFor(user.id), 'https://drive.google.com/uc?id=old');
      c.results[user.id]!['binding'] = 'new-operation';
      expect(c.verifiedLinkFor(user.id), isNull);
    },
  );

  for (final locale in ['ru', 'en']) {
    testWidgets(
      'existing link requires reviewed confirmation in $locale at phone width',
      (tester) async {
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = Controller();
        addTearDown(c.dispose);
        await c.ready;
        c.settings = const PublicationSettings(
          accountKey: 'account',
          folderId: 'folder',
          folderName: 'Folder',
          access: PublicationAccess.link,
        );
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => PublicationBindingDialog(
                      controller: c,
                      user: VpnUser(
                        id: 'c' * 32,
                        login: 'fixture',
                        name: 'Fixture',
                      ),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final confirm = find.byKey(const ValueKey('publication-bind-confirm'));
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tester.enterText(
          find.byKey(const ValueKey('publication-file-link')),
          'https://drive.google.com/uc?id=existing-file',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('publication-pick-file')),
        );
        await tester.tap(find.byKey(const ValueKey('publication-pick-file')));
        await tester.pumpAndSettle();
        expect(c.picked, 1);
        expect(c.inspected, 1);
        expect(c.accepted, 0);
        expect(find.text('legacy.yml'), findsOneWidget);
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(c.accepted, 1);
        expect(find.byType(PublicationBindingDialog), findsNothing);
      },
    );
  }
  testWidgets('picker configuration can be saved and is validated', (
    tester,
  ) async {
    final c = Controller();
    addTearDown(c.dispose);
    await c.ready;
    c.settings = const PublicationSettings(
      accountKey: 'account',
      folderId: 'folder',
      folderName: 'Folder',
      access: PublicationAccess.link,
    );
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: PublicationSettingsPanel(controller: c),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('publication-picker-settings')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('picker-api-key')),
      'public-picker-fixture-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('picker-project-number')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey('picker-settings-save')));
    await tester.pumpAndSettle();
    expect(c.pickerApiKey, 'public-picker-fixture-key');
    expect(c.pickerAppId, '123456');
    expect(tester.takeException(), isNull);
  });
}
