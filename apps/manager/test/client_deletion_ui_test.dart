import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/vpn/profile_share_sheet.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'publication_test.dart' as p;
import 'vpn_controller_test.dart' as f;
import 'vpn_widgets_test.dart' show Export;

class TrashRemote extends p.Remote {
  int trashes = 0;
  bool loseTrashReply = false;
  @override
  Future<void> trashFile(PublicationFile expected, String deletionId) async {
    trashes++;
    folders[expected.id] = PublicationFile(
      id: expected.id,
      name: expected.name,
      mimeType: expected.mimeType,
      version: '2',
      etag: 'new-etag',
      editable: true,
      trashed: true,
      properties: {...expected.properties, 'antirknDeleted': deletionId},
    );
    if (loseTrashReply) {
      loseTrashReply = false;
      throw const PublicationFailure(PublicationIssue.network);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'file deletion recovers lost reply and refuses a changed binding or foreign file',
    () async {
      final vpn = f.controller(f.MemoryVpn(), {});
      final repo = p.Repository(),
          remote = TrashRemote()..loseTrashReply = true;
      final account = p.Account()..publicationAuthorized = true;
      final c = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
        canPublish: () => false,
      );
      addTearDown(c.dispose);
      addTearDown(vpn.dispose);
      await c.ready;
      await vpn.load();
      await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      repo.docs['result/${f.alice}'] = jsonEncode({'fileId': 'bound-file'});
      PublicationFile file(String owner) => PublicationFile(
        id: 'bound-file',
        name: 'alice.yml',
        mimeType: 'application/yaml',
        version: '1',
        etag: 'etag',
        editable: true,
        properties: {
          'antirknWorkspace': vpn.workspace.id,
          'antirknUser': owner,
        },
      );
      remote.folders['bound-file'] = file(f.bob);
      vpn.deletePublishedFile = c.deleteClientFile;
      await vpn.deleteUser(
        vpn.workspace.users.single,
        file: {
          'fileId': 'bound-file',
          'registryId': 'registry',
          'accountKey': 'account',
          'folderId': 'folder',
        },
      );
      expect(remote.trashes, 0);
      expect(vpn.workspace.users.single.deletion!['file']['error'], 'conflict');
      remote.folders['bound-file'] = file(f.alice);
      repo.docs['result/${f.alice}'] = jsonEncode({'fileId': 'other-file'});
      await vpn.retryDeletion(f.alice);
      expect(remote.trashes, 0);
      repo.docs['result/${f.alice}'] = jsonEncode({'fileId': 'bound-file'});
      await vpn.retryDeletion(f.alice);
      expect(remote.trashes, 1);
      expect(vpn.workspace.users.single.deletionComplete, false);
      await vpn.retryDeletion(f.alice);
      expect(remote.trashes, 1);
      expect(vpn.workspace.users.single.deletionComplete, true);
    },
  );

  for (final locale in ['ru', 'en']) {
    testWidgets(
      '$locale deletion confirmation at 390px text x2: cancel and opt-in file cleanup',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final vpn = f.controller(f.MemoryVpn(), {});
        final repo = p.Repository(), remote = p.Remote();
        final c = PublicationController(
          repository: repo,
          account: p.Account()..publicationAuthorized = true,
          remote: () => remote,
          vpn: vpn,
          canPublish: () => false,
        );
        addTearDown(c.dispose);
        addTearDown(vpn.dispose);
        await c.ready;
        await tester.runAsync(() async {
          await vpn.load();
          await vpn.saveUser(
            VpnUser(id: f.alice, login: 'alice', name: 'Alice'),
          );
          await c.configure(PublicationAccess.link);
          repo.docs['result/${f.alice}'] = jsonEncode({
            'fileId': 'bound-file',
            'registryId': 'registry',
          });
          await c.reload();
        });
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: AppTheme.create(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: UsersPage(
                controller: vpn,
                publications: c,
                serverName: (id) => id,
                exporter: Export(),
                motion: MotionPreference.off,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('vpn-user-edit')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Alice'));
        await tester.pumpAndSettle();
        Future<void> openDelete() async {
          await tester.tap(
            find.byKey(const ValueKey('vpn-user-delete-selected')),
          );
          await tester.pumpAndSettle();
        }

        await openDelete();
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('client-delete-file')),
              )
              .value,
          false,
        );
        await tester.tap(
          find.widgetWithText(TextButton, locale == 'ru' ? 'Отмена' : 'Cancel'),
        );
        await tester.pumpAndSettle();
        expect(vpn.workspace.users.single.deleted, false);
        await openDelete();
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('client-delete-confirm')));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
        expect(vpn.workspace.users.single.deleted, true);
        expect(vpn.workspace.users.single.deletion!['file'], isNull);
        expect(find.text('Alice'), findsNothing);
        expect(tester.takeException(), isNull);
        await c.suspend();
      },
    );
  }

  testWidgets(
    'UsersPage isolates publication queue updates and summarises server work in one banner',
    (tester) async {
      final store = f.MemoryVpn();
      final remotes = {'srv1': f.Remote(store)};
      final vpn = f.controller(store, remotes);
      final repo = p.Repository(), remote = p.Remote();
      final c = PublicationController(
        repository: repo,
        account: p.Account()..publicationAuthorized = true,
        remote: () => remote,
        vpn: vpn,
        canPublish: () => false,
      );
      addTearDown(c.dispose);
      addTearDown(vpn.dispose);
      await c.ready;
      await tester.runAsync(() async {
        await vpn.load();
        await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
        await c.configure(PublicationAccess.link);
        repo.docs['result/${f.alice}'] = jsonEncode({
          'fileId': 'bound-file',
          'registryId': 'registry',
        });
        await c.reload();
      });

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: UsersPage(
              controller: vpn,
              publications: c,
              serverName: (id) => 'Server $id',
              exporter: Export(),
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('client-avatar-${f.alice}')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('server-operations-banner')),
        findsNothing,
      );

      // Now set publication error in queue for Alice and notify publications
      c.queues[f.alice] = {'status': 'error', 'issue': 'linkUnavailable'};
      c.notifyListeners();
      await tester.pump();
      // Alice tile and the page summary both name the publication error.
      expect(find.textContaining('without Google sign-in'), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('publication-failures')),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await vpn.saveInbound(f.inbound('srv1', '1' * 32));
      });
      vpn.workspace = vpn.workspace.copy(
        servers: {
          'srv1': {'error': 'unreachable'},
        },
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('server-operations-banner')),
        findsOneWidget,
      );
      expect(find.text('Server srv1'), findsOneWidget);

      expect(tester.takeException(), isNull);
      await c.suspend();
    },
  );

  testWidgets(
    'UsersPage opens ProfileShareSheet immediately without blocking when profile is uncompiled',
    (tester) async {
      final vpn = f.controller(f.MemoryVpn(), {});
      final repo = p.Repository(), remote = p.Remote();
      final c = PublicationController(
        repository: repo,
        account: p.Account()..publicationAuthorized = true,
        remote: () => remote,
        vpn: vpn,
        canPublish: () => false,
      );
      addTearDown(c.dispose);
      addTearDown(vpn.dispose);
      await c.ready;
      await tester.runAsync(() async {
        await vpn.load();
        await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      });
      // Ensure profile is uncompiled/missing in workspace.profiles and results
      vpn.workspace = vpn.workspace.copy(profiles: {});
      vpn.results.clear();

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: UsersPage(
              controller: vpn,
              publications: c,
              serverName: (id) => 'Server $id',
              exporter: Export(),
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final qrBtn = find.byKey(ValueKey('client-qr-${f.alice}'));
      expect(qrBtn, findsOneWidget);

      // Tap on QR button: must open dialog immediately without waiting for server sync
      await tester.tap(qrBtn);
      await tester.pump(); // exactly one frame

      // ProfileShareSheet is already mounted in the widget tree on the very next frame
      expect(find.byType(ProfileShareSheet), findsOneWidget);
      expect(find.text('Alice'), findsAtLeastNWidgets(1));

      // Verify that profile-generating-card is displayed while regenerating in background
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const ValueKey('profile-generating-card')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('profile-close')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('profile-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ProfileShareSheet), findsNothing);
      expect(tester.takeException(), isNull);
      await c.suspend();
    },
  );

  testWidgets(
    'UsersPage safely renders client avatar with empty or whitespace name without crashing',
    (tester) async {
      final vpn = f.controller(f.MemoryVpn(), {});
      final repo = p.Repository(), remote = p.Remote();
      final c = PublicationController(
        repository: repo,
        account: p.Account()..publicationAuthorized = true,
        remote: () => remote,
        vpn: vpn,
        canPublish: () => false,
      );
      addTearDown(c.dispose);
      addTearDown(vpn.dispose);
      await c.ready;
      await tester.runAsync(() async {
        await vpn.load();
        await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: '   '));
      });

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: UsersPage(
              controller: vpn,
              publications: c,
              serverName: (id) => 'Server $id',
              exporter: Export(),
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('client-avatar-${f.alice}')), findsOneWidget);
      expect(find.text('?'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await c.suspend();
    },
  );

  for (final (width, scale) in [(390.0, 2.0), (1000.0, 1.0)]) {
    testWidgets('a removal blocked on sign-in asks once with one action at '
        '$width ×$scale', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = f.MemoryVpn();
      final vpn = f.controller(
        store,
        {},
        connectForDeletion: (_) async => true,
        remoteIssue: (_) => 'vpn_panel_login',
      );
      addTearDown(vpn.dispose);
      await tester.runAsync(() async {
        await f.setup(vpn);
        await vpn.deleteUser(
          vpn.workspace.users.singleWhere((u) => u.id == f.alice),
        );
      });
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: UsersPage(
              controller: vpn,
              serverName: (id) => 'Server $id',
              exporter: Export(),
              motion: MotionPreference.off,
              onOpenServer: (id) => opened = id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('server-operations-banner')),
        findsOneWidget,
      );
      expect(
        find.text('Sign in to 3x-ui on this server to continue.'),
        findsOneWidget,
      );
      expect(find.textContaining('Removing Alice'), findsOneWidget);
      expect(find.text('Open server'), findsOneWidget);
      await tester.tap(find.text('Open server'));
      await tester.pumpAndSettle();
      expect(opened, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('work that runs by itself is one quiet line without buttons', (
    tester,
  ) async {
    final store = f.MemoryVpn();
    final vpn = f.controller(
      store,
      {},
      connectForDeletion: (_) async => false,
      remoteIssue: (_) => 'ssh:network',
    );
    await tester.runAsync(() async {
      await f.setup(vpn);
      await vpn.deleteUser(
        vpn.workspace.users.singleWhere((u) => u.id == f.alice),
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: UsersPage(
            controller: vpn,
            serverName: (id) => 'Server $id',
            exporter: Export(),
            motion: MotionPreference.off,
          ),
        ),
      ),
    );
    await tester.pump();
    final banner = find.byKey(const ValueKey('server-operations-banner'));
    expect(banner, findsOneWidget);
    expect(find.text('Removing Alice'), findsOneWidget);
    expect(
      find.descendant(of: banner, matching: find.byType(ButtonStyleButton)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    // Let the controller's quiet retry timers run out with the tree gone.
    await tester.pumpWidget(const SizedBox.shrink());
    vpn.dispose();
    await tester.pump(const Duration(minutes: 1));
  });
}
