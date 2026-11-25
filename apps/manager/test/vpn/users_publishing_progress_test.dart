import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/catalog_selection.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/publication/publication_controller.dart';
import 'package:antirkn_manager/vpn/users_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../vpn_controller_test.dart' as f;
import '../publication_test.dart' as p;

class _Export implements ProfileExporter {
  @override
  Future<bool> save(String name, String source) async => true;
}

void main() {
  test(
    'PublicationController tracks in-flight, completed, and failed user progress',
    () async {
      final account = p.Account()..publicationAuthorized = true;
      final repo = p.Repository();
      final remote = p.Remote();
      final vpn = f.controller(f.MemoryVpn(), {});
      addTearDown(vpn.dispose);
      final c = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );
      addTearDown(c.dispose);
      await c.ready;

      expect(c.activeSyncTotal, 0);
      expect(c.activeSyncCompleted, 0);
      expect(c.inFlightUserIds, isEmpty);
      expect(c.completedUserIds, isEmpty);
      expect(c.failedUserIds, isEmpty);
      expect(c.hasActiveSync, isFalse);
      expect(c.isUserInFlight(f.alice), isFalse);
      expect(c.isUserCompleted(f.alice), isFalse);
      expect(c.isUserFailed(f.alice), isFalse);

      // Simulate progress
      c.simulateUserProgress(inFlight: {f.alice}, completed: {f.bob}, total: 2);
      expect(c.activeSyncTotal, 2);
      expect(c.activeSyncCompleted, 1);
      expect(c.hasActiveSync, isTrue);
      expect(c.isUserInFlight(f.alice), isTrue);
      expect(c.isUserCompleted(f.bob), isTrue);

      // Test mutual exclusivity when passing inFlight
      c.simulateUserProgress(inFlight: {f.bob});
      expect(c.isUserInFlight(f.bob), isTrue);
      expect(c.isUserCompleted(f.bob), isFalse);

      c.resetSyncProgress();
      expect(c.activeSyncTotal, 0);
      expect(c.activeSyncCompleted, 0);
      expect(c.hasActiveSync, isFalse);
      expect(c.inFlightUserIds, isEmpty);
      expect(c.completedUserIds, isEmpty);
      expect(c.failedUserIds, isEmpty);
    },
  );

  testWidgets(
    'UserTile transitions reactively through ListenableBuilder via pump() without re-pumpWidget',
    (tester) async {
      final account = p.Account()..publicationAuthorized = true;
      final repo = p.Repository();
      final remote = p.Remote();
      final vpn = f.controller(f.MemoryVpn(), {});
      addTearDown(vpn.dispose);
      final pub = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );
      addTearDown(pub.dispose);

      final userAlice = VpnUser(id: f.alice, login: 'alice', name: 'Alice');
      final selection = CatalogSelection();
      addTearDown(selection.dispose);

      // Mount tile once with isSyncing: true
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: UserTile(
              user: userAlice,
              isFirst: true,
              controller: vpn,
              selection: selection,
              publications: pub,
              protocolSummary: 'VLESS',
              motion: MotionPreference.off,
              onProfile: (_, profileUser) {},
              isSyncing: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // 1. Idle state: Shows QR code icon
      expect(find.byIcon(Icons.qr_code_2), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsNothing);

      // 2. Alice in-flight: triggers ListenableBuilder notification, rebuilds with single pump()
      pub.simulateUserProgress(inFlight: {f.alice}, total: 1);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.qr_code_2), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsNothing);

      // 3. Alice completed: switches to checkmark
      pub.simulateUserProgress(completed: {f.alice}, total: 1);
      await tester.pump();
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.qr_code_2), findsNothing);

      // 4. Alice failed: switches to error outline
      pub.simulateUserProgress(failed: {f.alice}, total: 1);
      await tester.pump();
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);

      // 5. Cleared: reverts cleanly back to QR code icon
      pub.resetSyncProgress();
      await tester.pump();
      expect(find.byIcon(Icons.qr_code_2), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    'UsersPage reactive sync state: disabled button, no inner spinner, and determinate progress',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final account = p.Account()..publicationAuthorized = true;
      final repo = p.Repository();
      final remote = p.Remote();
      final vpn = f.controller(f.MemoryVpn(), {});
      addTearDown(vpn.dispose);
      final pub = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );
      addTearDown(pub.dispose);

      final userAlice = VpnUser(id: f.alice, login: 'alice', name: 'Alice');
      final userBob = VpnUser(id: f.bob, login: 'bob', name: 'Bob');
      await tester.runAsync(() async {
        await vpn.load();
        await vpn.saveUser(userAlice);
        await vpn.saveUser(userBob);
      });

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: UsersPage(
              controller: vpn,
              publications: pub,
              serverName: (id) => 'Server $id',
              exporter: _Export(),
              motion: MotionPreference.off,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Initial idle state: button enabled, no progress bar, tiles have QR icons
      final syncButton = find.widgetWithIcon(FilledButton, Icons.cloud_sync);
      expect(syncButton, findsOneWidget);
      expect(tester.widget<FilledButton>(syncButton).onPressed, isNotNull);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.qr_code_2), findsNWidgets(2));

      // Check switches and QR buttons initially enabled
      final aliceSwitchFinder = find.byKey(
        ValueKey('client-toggle-${f.alice}'),
      );
      expect(tester.widget<Switch>(aliceSwitchFinder).onChanged, isNotNull);
      final aliceQrButtonFinder = find.byKey(ValueKey('client-qr-${f.alice}'));
      expect(
        tester.widget<IconButton>(aliceQrButtonFinder).onPressed,
        isNotNull,
      );

      // Trigger active sync via simulateUserProgress
      pub.simulateUserProgress(
        inFlight: {f.alice},
        completed: {f.bob},
        total: 2,
      );
      await tester.pump();

      // Button disabled, NO inner spinner inside button
      expect(tester.widget<FilledButton>(syncButton).onPressed, isNull);
      final buttonDescendants = find.descendant(
        of: syncButton,
        matching: find.byType(CircularProgressIndicator),
      );
      expect(buttonDescendants, findsNothing);

      // Determinate LinearProgressIndicator with value 0.5 (1 of 2 completed)
      final progressFinder = find.byType(LinearProgressIndicator);
      expect(progressFinder, findsOneWidget);
      final indicator = tester.widget<LinearProgressIndicator>(progressFinder);
      expect(indicator.value, closeTo(0.5, 0.01));

      // Even if vpn.foregroundBusy is simultaneously active, NO duplicate progress bars appear
      vpn.upgradeBusy = true;
      await tester.pump();
      expect(vpn.foregroundBusy, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      vpn.upgradeBusy = false;
      await tester.pump();

      // Switches and QR buttons disabled during sync
      expect(tester.widget<Switch>(aliceSwitchFinder).onChanged, isNull);
      expect(tester.widget<IconButton>(aliceQrButtonFinder).onPressed, isNull);

      // Per-client trailing icons: Alice has spinner, Bob has checkmark
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      // Full recovery after sync reset
      pub.resetSyncProgress();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(syncButton).onPressed, isNotNull);
      expect(tester.widget<Switch>(aliceSwitchFinder).onChanged, isNotNull);
      expect(
        tester.widget<IconButton>(aliceQrButtonFinder).onPressed,
        isNotNull,
      );
      expect(find.byIcon(Icons.qr_code_2), findsNWidgets(2));
    },
  );

  test(
    'PublicationController tracks real publication progress and clears it when the run ends',
    () async {
      final account = p.Account()..publicationAuthorized = true;
      final repo = p.Repository();
      final remote = p.Remote();
      final vpn = f.controller(f.MemoryVpn(), {});
      addTearDown(vpn.dispose);
      await vpn.load();
      await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      await vpn.saveUser(VpnUser(id: f.bob, login: 'bob', name: 'Bob'));

      const settings = PublicationSettings(
        accountKey: 'account',
        folderId: 'test-folder',
        folderName: 'Folder',
        access: PublicationAccess.link,
        enabled: true,
        folderReady: true,
      );
      repo.docs['settings'] = canonicalJson(settings.toJson());

      final c = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );
      addTearDown(c.dispose);
      await c.ready;

      final profileAlice = vpn.workspace.profiles[f.alice]!;
      repo.drafts[f.alice] = PublicationDraft(
        workspaceId: vpn.workspace.id,
        deviceId: 'b' * 32,
        userId: f.alice,
        name: 'Alice',
        headId: 'head-${f.alice}',
        hash: profileAlice['hash'] as String,
        stamp: 'stamp-${f.alice}',
        bytes: Uint8List.fromList(utf8.encode(profileAlice['yaml'] as String)),
        ancestors: {},
      );
      final profileBob = vpn.workspace.profiles[f.bob]!;
      repo.drafts[f.bob] = PublicationDraft(
        workspaceId: vpn.workspace.id,
        deviceId: 'b' * 32,
        userId: f.bob,
        name: 'Bob',
        headId: 'head-${f.bob}',
        hash: profileBob['hash'] as String,
        stamp: 'stamp-${f.bob}',
        bytes: Uint8List.fromList(utf8.encode(profileBob['yaml'] as String)),
        ancestors: {},
      );

      remote.folders['test-folder'] = PublicationFile(
        id: 'test-folder',
        name: 'Folder',
        mimeType: 'application/vnd.google-apps.folder',
        version: '1',
        etag: 'etag-f',
        editable: true,
        properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
      );
      final regBytes = Uint8List.fromList(
        utf8.encode(
          canonicalJson({
            'version': 2,
            'workspaceId': vpn.workspace.id,
            'users': <String, dynamic>{},
          }),
        ),
      );
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

      final recordedTotals = <int>[];
      final recordedCompleted = <int>[];
      // Per-client progress is reported through [changes] (UI-30), not by a
      // controller notification per client.
      c.changes.addListener(() {
        recordedTotals.add(c.activeSyncTotal);
        recordedCompleted.add(c.activeSyncCompleted);
      });

      final result = await c.forcePublishAll(force: true);
      expect(result.failed, 0);
      expect(result.uploaded, 2);
      expect(recordedTotals, contains(2));
      expect(recordedCompleted, contains(1));

      expect(recordedCompleted, contains(2));

      // The batch result carries the outcome: progress clears as soon as the
      // run ends, without an artificial 600 ms pause (UI-74).
      expect(c.hasActiveSync, isFalse);
      expect(c.activeSyncTotal, 0);
      expect(c.activeSyncCompleted, 0);
      expect(c.inFlightUserIds, isEmpty);
      expect(c.completedUserIds, isEmpty);
      expect(c.failedUserIds, isEmpty);
    },
  );

  test(
    'back-to-back publishes each clear their progress when they end',
    () async {
      final account = p.Account()..publicationAuthorized = true;
      final repo = p.Repository();
      final remote = p.Remote();
      final vpn = f.controller(f.MemoryVpn(), {});
      addTearDown(vpn.dispose);
      await vpn.load();
      await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));

      const settings = PublicationSettings(
        accountKey: 'account',
        folderId: 'test-folder',
        folderName: 'Folder',
        access: PublicationAccess.link,
        enabled: true,
        folderReady: true,
      );
      repo.docs['settings'] = canonicalJson(settings.toJson());

      final c = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );
      addTearDown(c.dispose);
      await c.ready;

      final profileAlice = vpn.workspace.profiles[f.alice]!;
      repo.drafts[f.alice] = PublicationDraft(
        workspaceId: vpn.workspace.id,
        deviceId: 'b' * 32,
        userId: f.alice,
        name: 'Alice',
        headId: 'head-${f.alice}',
        hash: profileAlice['hash'] as String,
        stamp: 'stamp-${f.alice}',
        bytes: Uint8List.fromList(utf8.encode(profileAlice['yaml'] as String)),
        ancestors: {},
      );
      remote.folders['test-folder'] = PublicationFile(
        id: 'test-folder',
        name: 'Folder',
        mimeType: 'application/vnd.google-apps.folder',
        version: '1',
        etag: 'etag-f',
        editable: true,
        properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
      );
      final regBytes = Uint8List.fromList(
        utf8.encode(
          canonicalJson({
            'version': 2,
            'workspaceId': vpn.workspace.id,
            'users': <String, dynamic>{},
          }),
        ),
      );
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

      await c.forcePublishAll(force: true);
      expect(c.hasActiveSync, isFalse);

      final result = await c.forcePublishAll(force: true);
      expect(result.failed, 0);
      expect(c.hasActiveSync, isFalse);
      expect(c.activeSyncTotal, 0);
    },
  );

  test('dispose() after a finished publish leaves no progress', () async {
    final account = p.Account()..publicationAuthorized = true;
    final repo = p.Repository();
    final remote = p.Remote();
    final vpn = f.controller(f.MemoryVpn(), {});
    addTearDown(vpn.dispose);
    await vpn.load();
    await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));

    const settings = PublicationSettings(
      accountKey: 'account',
      folderId: 'test-folder',
      folderName: 'Folder',
      access: PublicationAccess.link,
      enabled: true,
      folderReady: true,
    );
    repo.docs['settings'] = canonicalJson(settings.toJson());

    final c = PublicationController(
      repository: repo,
      account: account,
      remote: () => remote,
      vpn: vpn,
    );
    await c.ready;

    final profileAlice = vpn.workspace.profiles[f.alice]!;
    repo.drafts[f.alice] = PublicationDraft(
      workspaceId: vpn.workspace.id,
      deviceId: 'b' * 32,
      userId: f.alice,
      name: 'Alice',
      headId: 'head-${f.alice}',
      hash: profileAlice['hash'] as String,
      stamp: 'stamp-${f.alice}',
      bytes: Uint8List.fromList(utf8.encode(profileAlice['yaml'] as String)),
      ancestors: {},
    );
    remote.folders['test-folder'] = PublicationFile(
      id: 'test-folder',
      name: 'Folder',
      mimeType: 'application/vnd.google-apps.folder',
      version: '1',
      etag: 'etag-f',
      editable: true,
      properties: {'antirknRegistry.${vpn.workspace.id}': 'ready:registry-1'},
    );
    final regBytes = Uint8List.fromList(
      utf8.encode(
        canonicalJson({
          'version': 2,
          'workspaceId': vpn.workspace.id,
          'users': <String, dynamic>{},
        }),
      ),
    );
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

    await c.forcePublishAll(force: true);
    expect(c.hasActiveSync, isFalse);

    c.dispose();
    expect(c.hasActiveSync, isFalse);
    expect(c.activeSyncTotal, 0);
  });

  test(
    'suspend() during publication cancels without polluting _failedUserIds',
    () async {
      final account = p.Account()..publicationAuthorized = true;
      final repo = p.Repository();
      final remote = p.Remote();
      final vpn = f.controller(f.MemoryVpn(), {});
      addTearDown(vpn.dispose);
      await vpn.load();
      await vpn.saveUser(VpnUser(id: f.alice, login: 'alice', name: 'Alice'));
      await vpn.saveUser(VpnUser(id: f.bob, login: 'bob', name: 'Bob'));

      const settings = PublicationSettings(
        accountKey: 'account',
        folderId: 'test-folder',
        folderName: 'Folder',
        access: PublicationAccess.link,
        enabled: true,
        folderReady: true,
      );
      repo.docs['settings'] = canonicalJson(settings.toJson());

      final c = PublicationController(
        repository: repo,
        account: account,
        remote: () => remote,
        vpn: vpn,
      );
      addTearDown(c.dispose);
      await c.ready;

      // Start publication and immediately suspend
      final publishFuture = c.forcePublishAll(force: true);
      await c.suspend();
      await publishFuture;

      // After suspension, _failedUserIds must NOT be polluted
      expect(c.failedUserIds, isEmpty);
      expect(c.inFlightUserIds, isEmpty);
      expect(c.completedUserIds, isEmpty);
      expect(c.hasActiveSync, isFalse);
      expect(c.activeSyncTotal, 0);
    },
  );
}
