import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../integrations/test/fixtures/drive_fixture.dart';

final client = GoogleDesktopClient.parse(
  jsonEncode({
    'installed': {
      'project_id': 'public-project',
      'client_id': '123-desktop.apps.googleusercontent.com',
      'client_secret': 'public-client-secret',
      'auth_uri': 'https://accounts.google.com/o/oauth2/auth',
      'token_uri': 'https://oauth2.googleapis.com/token',
    },
  }),
);

class OAuth implements GoogleDesktopOAuth, GooglePublicationOAuth {
  int publications = 0;
  @override
  Future<GoogleOAuthTokens?> authorizePublications(
    GoogleDesktopClient client,
    GoogleOAuthCancellation cancellation,
  ) {
    publications++;
    return authorize(client, cancellation);
  }

  GoogleOAuthTokens? tokens = const GoogleOAuthTokens(
    'public-fixture-token',
    'public-refresh-token',
    Duration(hours: 1),
  );
  GoogleAccountIssue? error;
  int authorizations = 0, refreshes = 0;
  Future<void> Function(GoogleOAuthCancellation)? waiting;
  final refreshArguments = <String>[];
  @override
  Future<GoogleOAuthTokens?> authorize(
    GoogleDesktopClient client,
    GoogleOAuthCancellation cancellation,
  ) async {
    authorizations++;
    await waiting?.call(cancellation);
    if (error != null) throw GoogleAccountFailure(error!);
    return tokens;
  }

  @override
  Future<GoogleOAuthTokens> refresh(
    GoogleDesktopClient client,
    String token,
  ) async {
    refreshes++;
    refreshArguments.add(token);
    if (error != null) throw GoogleAccountFailure(error!);
    return tokens!;
  }
}

class Http implements DriveHttp {
  String id = 'public-account';
  bool offline = false, reject = false;
  DriveHttp? drive;
  int identities = 0;
  @override
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  }) async {
    if (offline) throw const SyncTransportFailure(SyncTransportIssue.network);
    if (uri.path == '/drive/v3/about') {
      identities++;
      expect(headers['Authorization'], 'Bearer public-fixture-token');
      return DriveHttpResponse(
        200,
        {},
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'user': {
                'permissionId': id,
                'emailAddress': 'fixture@example.com',
                'displayName': 'Fixture',
              },
            }),
          ),
        ),
      );
    }
    if (reject) {
      return DriveHttpResponse(401, {}, Uint8List.fromList(utf8.encode('{}')));
    }
    return drive!.send(
      method,
      uri,
      headers: headers,
      body: body,
      responseLimit: responseLimit,
    );
  }
}

class Keys implements VaultKeyStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

class AndroidBridge implements GoogleAuthorizationBridge {
  @override
  Future<String?> authorize({required bool interactive, String? email}) async =>
      'public-fixture-token';
  @override
  Future<void> clearToken() async {}
}

class Store implements GoogleSessionStore {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? expected, String? next) async {
    if (fail || expected != value) throw StateError('private-storage-error');
    value = next;
  }
}

Matcher issue(GoogleAccountIssue value) =>
    isA<GoogleAccountFailure>().having((e) => e.issue, 'issue', value);

void main() {
  late OAuth oauth;
  late Http http;
  late Store store;
  var now = DateTime.utc(2026, 9, 15);
  DesktopGoogleAccountService service({GoogleSessionStore? secrets}) =>
      DesktopGoogleAccountService(
        store: secrets ?? store,
        oauth: oauth,
        loadClient: () async => client,
        http: http,
        now: () => now,
      );
  setUp(() {
    oauth = OAuth();
    http = Http();
    store = Store();
    now = DateTime.utc(2026, 9, 15);
  });

  test(
    'publication consent is retained across restart and refresh; denial preserves session',
    () async {
      final first = service();
      await first.signIn();
      final binding = first.accountKey;
      expect(first.publicationAuthorized, isFalse);
      oauth.error = GoogleAccountIssue.denied;
      await expectLater(
        first.authorizePublications(),
        throwsA(issue(GoogleAccountIssue.denied)),
      );
      expect(first.accountKey, binding);
      expect(first.publicationAuthorized, isFalse);
      oauth.error = null;
      await first.authorizePublications();
      expect(first.publicationAuthorized, isTrue);
      final restored = service();
      await restored.restore();
      expect(restored.publicationAuthorized, isTrue);
      expect(restored.accountKey, binding);
      now = now.add(const Duration(hours: 2));
      await restored.accessToken();
      expect(restored.publicationAuthorized, isTrue);
      final again = service();
      await again.restore();
      expect(again.publicationAuthorized, isTrue);
      await again.signOut();
      expect(again.publicationAuthorized, isFalse);
    },
  );
  test(
    'local restore, cached access, expiry refresh and rotation keep provider identity and binding',
    () async {
      final first = service();
      expect(await first.restore(), isNull);
      final account = await first.signIn();
      final binding = first.accountKey;
      expect(account!.permissionId, 'public-account');
      expect(store.value, isNot(contains('public-fixture-token')));
      await first.accessToken();
      await first.accessToken();
      expect(oauth.refreshes, 0);
      await first.close();
      final second = service();
      final count = http.identities;
      await second.restore();
      expect(http.identities, count);
      expect(second.accountKey, binding);
      expect(await second.accessToken(), 'public-fixture-token');
      expect(oauth.refreshes, 1);
      now = now.add(const Duration(hours: 2));
      oauth.tokens = const GoogleOAuthTokens(
        'public-fixture-token',
        'rotated-refresh',
        Duration(hours: 1),
      );
      await second.accessToken();
      expect(store.value, contains('rotated-refresh'));
      now = now.add(const Duration(hours: 2));
      oauth.tokens = const GoogleOAuthTokens(
        'public-fixture-token',
        null,
        Duration(hours: 1),
      );
      await second.accessToken();
      expect(oauth.refreshArguments.last, 'rotated-refresh');
      expect(store.value, contains('rotated-refresh'));
      expect(second.accountKey, binding);
      await second.close();
    },
  );

  test(
    'cancel, denied login, failed readback and failed save preserve previous account',
    () async {
      final auth = service();
      await auth.signIn();
      final previous = store.value, binding = auth.accountKey;
      oauth.tokens = null;
      expect(await auth.signIn(), isNull);
      oauth.error = GoogleAccountIssue.denied;
      await expectLater(
        auth.signIn(),
        throwsA(issue(GoogleAccountIssue.denied)),
      );
      oauth.error = null;
      oauth.tokens = const GoogleOAuthTokens(
        'public-fixture-token',
        'new-refresh',
        Duration(hours: 1),
      );
      http.offline = true;
      await expectLater(
        auth.signIn(),
        throwsA(issue(GoogleAccountIssue.network)),
      );
      http.offline = false;
      http.id = 'other-account';
      store.fail = true;
      await expectLater(
        auth.signIn(),
        throwsA(issue(GoogleAccountIssue.storage)),
      );
      expect(store.value, previous);
      expect(auth.accountKey, binding);
      await auth.close();
    },
  );

  test(
    '401 invalidates cached access; revoked refresh persists reauthorization without retry storms',
    () async {
      final auth = service();
      await auth.signIn();
      http.reject = true;
      final remote = GoogleDriveSyncStore(tokens: auth, http: http);
      await expectLater(
        remote.getStartPageToken(),
        throwsA(
          isA<SyncTransportFailure>().having(
            (e) => e.issue,
            'issue',
            SyncTransportIssue.unauthorized,
          ),
        ),
      );
      expect(await auth.accessToken(), 'public-fixture-token');
      expect(oauth.refreshes, 1);
      now = now.add(const Duration(hours: 2));
      oauth.error = GoogleAccountIssue.network;
      final previous = store.value;
      await expectLater(
        auth.accessToken(),
        throwsA(issue(GoogleAccountIssue.network)),
      );
      expect(store.value, previous);
      oauth.error = GoogleAccountIssue.reauthorize;
      await expectLater(
        remote.getStartPageToken(),
        throwsA(issue(GoogleAccountIssue.reauthorize)),
      );
      final requests = oauth.refreshes;
      await auth.close();
      final reopened = service();
      expect(await reopened.restore(), isNotNull);
      await expectLater(
        reopened.accessToken(),
        throwsA(issue(GoogleAccountIssue.reauthorize)),
      );
      expect(oauth.refreshes, requests);
      oauth.error = null;
      await reopened.signIn();
      expect(await reopened.accessToken(), 'public-fixture-token');
      await reopened.close();
    },
  );

  test(
    'refreshed token for another identity never reaches Drive operations',
    () async {
      final auth = service();
      await auth.signIn();
      http.id = 'other';
      now = now.add(const Duration(hours: 2));
      await expectLater(
        auth.accessToken(),
        throwsA(issue(GoogleAccountIssue.reauthorize)),
      );
      expect((await auth.restore())!.permissionId, 'public-account');
      await auth.close();
    },
  );

  test(
    'logout is local, atomic on failure, and invalidates a second process cached session',
    () async {
      final first = service();
      await first.signIn();
      final second = service();
      await second.restore();
      await second.accessToken();
      store.fail = true;
      await expectLater(
        first.signOut(),
        throwsA(issue(GoogleAccountIssue.storage)),
      );
      expect(await first.accessToken(), 'public-fixture-token');
      store.fail = false;
      http.offline = true;
      await first.signOut();
      expect(store.value, isNull);
      await expectLater(
        second.accessToken(),
        throwsA(issue(GoogleAccountIssue.reauthorize)),
      );
      expect(await service().restore(), isNull);
      expect(() => first.accountKey, throwsA(isA<SyncTransportFailure>()));
      http.offline = false;
      await first.signIn();
      await expectLater(
        second.accessToken(),
        throwsA(issue(GoogleAccountIssue.reauthorize)),
        reason:
            'new login has a fresh session ID even for the same refresh token',
      );
      http.id = 'another-account';
      final before = first.accountKey;
      await first.signIn();
      expect(first.accountKey, isNot(before));
      expect((await service().restore())!.permissionId, 'another-account');
      await first.close();
      await second.close();
    },
  );

  test(
    'close cancels pending browser and joins late result without saving credentials',
    () async {
      final auth = service();
      final entered = Completer<void>();
      oauth.waiting = (cancellation) async {
        entered.complete();
        await cancellation.whenCancelled;
      };
      final attempt = auth.signIn();
      await entered.future;
      await expectLater(auth.signIn(), throwsA(issue(GoogleAccountIssue.busy)));
      await auth.close();
      expect(await attempt, isNull);
      expect(store.value, isNull);
      expect(http.identities, 0);
    },
  );

  test(
    'encrypted file: restart, wrong key, corruption, stale writer, and logout tombstone',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'desktop-google-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/session');
      final encrypted = EncryptedGoogleSessionStore(
        file: file,
        key: SecretKeyData(List.filled(32, 1)),
      );
      final auth = service(secrets: encrypted);
      await auth.signIn();
      final bytes = await file.readAsString();
      for (final text in [
        'public-refresh-token',
        'public-client-secret',
        'public-account',
        'fixture@example.com',
      ]) {
        expect(bytes, isNot(contains(text)));
      }
      final wrong = EncryptedGoogleSessionStore(
        file: file,
        key: SecretKeyData(List.filled(32, 2)),
      );
      await expectLater(
        service(secrets: wrong).restore(),
        throwsA(issue(GoogleAccountIssue.storage)),
      );
      final current = await encrypted.read();
      await expectLater(encrypted.replace(null, 'stale'), throwsA(anything));
      expect(await encrypted.read(), current);
      final restarted = service(secrets: encrypted);
      expect(await restarted.restore(), isNotNull);
      await restarted.signOut();
      expect(await encrypted.read(), isNull);
      expect(await file.readAsString(), isNot(bytes));
      await file.writeAsString(bytes.replaceFirst('box', 'damaged'));
      await expectLater(
        restarted.restore(),
        throwsA(issue(GoogleAccountIssue.storage)),
      );
      await auth.close();
      await restarted.close();
    },
  );

  test(
    'desktop and Android accounts share binding; paired databases converge both ways and after restart/offline',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'desktop-android-sync-',
      );
      final drive = DriveFixture();
      await drive.start();
      http.drive = drive;
      final databases = <WorkspaceDatabase>[];
      final sessions = <AutoSyncSession>[];
      WorkspaceDatabase database(String name, int key) {
        final db = WorkspaceDatabase.open(
          '${directory.path}/$name.sqlite',
          key: SecretKeyData(List.filled(32, key)),
        );
        databases.add(db);
        return db;
      }

      addTearDown(() async {
        for (final s in sessions) {
          await s.close();
        }
        for (final d in databases) {
          await d.close();
        }
        await drive.close();
        await directory.delete(recursive: true);
      });
      Future<AutoSyncSession> open(
        WorkspaceDatabase db,
        SyncAccessTokenProvider tokens,
      ) async {
        final s = await db.openAutoSync(tokens, http: http);
        sessions.add(s);
        return s;
      }

      Future<AutoSyncResult> drain(AutoSyncSession s) async {
        for (var i = 0; i < 30; i++) {
          final result = await s.exchange(
            cancellation: SyncCancellation(),
            apply: (receive) async {
              await receive();
              return true;
            },
          );
          if (!result.more) return result;
        }
        throw StateError('exchange did not drain');
      }

      final linux = database('linux', 41);
      var android = database('android', 42);
      await linux.writeDraft('initial template');
      final desktop = service(secrets: linux.googleSessionStore());
      await desktop.signIn();
      final archive = await linux.createBackup('public-backup-password');
      await android.restoreBackup(
        await android.prepareRestore(archive, 'public-backup-password'),
      );
      await android.close();
      android = database('android', 42);
      expect(await android.googleSessionStore().read(), isNull);
      final phone = AndroidGoogleAccountService(
        projectId: client.projectId,
        keys: Keys(),
        bridge: AndroidBridge(),
        http: http,
        supported: true,
      );
      await phone.signIn();
      expect(phone.accountKey, desktop.accountKey);
      final a = await open(linux, desktop);
      var b = await open(android, phone);
      http.reject = true;
      await expectLater(drain(a), throwsA(isA<SyncTransportFailure>()));
      http.reject = false;
      await drain(a);
      expect(
        oauth.refreshes,
        1,
        reason: 'production cycle forwards invalidation to desktop account',
      );
      await drain(b);
      await linux.writeDraft('from desktop');
      await drain(a);
      await drain(b);
      expect(await android.readDraft(), 'from desktop');
      await android.writeDraft('from phone');
      await drain(b);
      await drain(a);
      expect(await linux.readDraft(), 'from phone');
      http.offline = true;
      await android.writeDraft('offline phone edit');
      await expectLater(drain(b), throwsA(anything));
      await b.close();
      await android.close();
      android = database('android', 42);
      b = await open(android, phone);
      http.offline = false;
      await drain(b);
      await drain(a);
      expect(await linux.readDraft(), 'offline phone edit');
      await linux.writeDraft('desktop concurrent');
      await android.writeDraft('phone concurrent');
      await drain(a);
      expect((await drain(b)).conflicts, greaterThan(0));
      expect((await drain(a)).conflicts, greaterThan(0));
      expect(await linux.readDraft(), 'desktop concurrent');
      expect(await android.readDraft(), 'phone concurrent');
      final conflict = (await linux.readSyncMergeStatus()).conflicts.single;
      final chosen = conflict.variants.firstWhere(
        (v) => v.source == 'phone concurrent',
      );
      await linux.resolveSyncConflict(conflict, chosen.header.changeId);
      await drain(a);
      await drain(b);
      expect((await android.readSyncMergeStatus()).conflicts, isEmpty);
      expect(await linux.readDraft(), 'phone concurrent');
      expect(await android.readDraft(), 'phone concurrent');
      // Restore changes workspace data but keeps this installation's Google login.
      await a.close();
      await linux.restoreBackup(
        await linux.prepareRestore(archive, 'public-backup-password'),
      );
      expect(await linux.googleSessionStore().read(), isNotNull);
      await desktop.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
