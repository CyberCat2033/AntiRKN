import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class Keys implements VaultKeyStore {
  final data = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String id) async => data[id];
  @override
  Future<void> write(String id, String value) async {
    if (fail) throw StateError('fixture');
    data[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    if (fail) throw StateError('fixture');
    data.remove(id);
  }
}

class Bridge
    implements GoogleAuthorizationBridge, PublicationGoogleAuthorizationBridge {
  int publications = 0;
  @override
  Future<String?> authorizePublications({
    required bool interactive,
    String? email,
  }) async {
    publications++;
    return authorize(interactive: interactive, email: email);
  }

  String? token = 'PRIVATE-ANDROID-TOKEN-FIXTURE';
  final calls = <bool>[];
  String? email;
  int cleared = 0;
  @override
  Future<String?> authorize({required bool interactive, String? email}) async {
    calls.add(interactive);
    this.email = email;
    return token;
  }

  @override
  Future<void> clearToken() async {
    cleared++;
  }
}

class Http implements DriveHttp {
  int status = 200;
  String id = '123456';
  int requests = 0;
  @override
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  }) async {
    requests++;
    expect(method, 'GET');
    expect(uri.path, '/drive/v3/about');
    expect(headers['Authorization'], 'Bearer PRIVATE-ANDROID-TOKEN-FIXTURE');
    return DriveHttpResponse(
      status,
      {},
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'user': {
              'permissionId': id,
              'emailAddress': 'fixture@example.com',
              'displayName': 'Fixture User',
            },
          }),
        ),
      ),
    );
  }
}

Matcher issue(GoogleAccountIssue issue) =>
    isA<GoogleAccountFailure>().having((e) => e.issue, 'issue', issue);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Keys keys;
  late Bridge bridge;
  late Http http;
  AndroidGoogleAccountService service({String project = 'fixture-project'}) =>
      AndroidGoogleAccountService(
        projectId: project,
        keys: keys,
        bridge: bridge,
        http: http,
        supported: true,
      );
  setUp(() {
    keys = Keys();
    bridge = Bridge();
    http = Http();
  });
  test(
    'real account readback before secure save; tokens never persist and restore is local',
    () async {
      final auth = service();
      expect(await auth.restore(), isNull);
      final account = await auth.signIn();
      expect(account!.email, 'fixture@example.com');
      expect(
        keys.data.values.single,
        isNot(contains('PRIVATE-ANDROID-TOKEN-FIXTURE')),
      );
      final requests = http.requests;
      final next = service();
      expect((await next.restore())!.permissionId, account.permissionId);
      expect(http.requests, requests);
      expect(next.accountKey, auth.accountKey);
      expect(await next.accessToken(), 'PRIVATE-ANDROID-TOKEN-FIXTURE');
      expect(bridge.calls, [true, false]);
      expect(bridge.email, account.email);
    },
  );
  test(
    'cancel, network failure and storage failure preserve previous connected account',
    () async {
      final auth = service();
      await auth.signIn();
      final previous = keys.data.values.single;
      bridge.token = null;
      expect(await auth.signIn(), isNull);
      expect(keys.data.values.single, previous);
      bridge.token = 'PRIVATE-ANDROID-TOKEN-FIXTURE';
      http.status = 503;
      await expectLater(
        auth.signIn(),
        throwsA(issue(GoogleAccountIssue.network)),
      );
      expect(keys.data.values.single, previous);
      http.status = 200;
      keys.fail = true;
      await expectLater(
        auth.signIn(),
        throwsA(issue(GoogleAccountIssue.storage)),
      );
      expect(keys.data.values.single, previous);
    },
  );
  test(
    'logout removes account; other project cannot reuse identity; silent switch is refused',
    () async {
      final auth = service();
      await auth.signIn();
      expect(await service(project: 'other-project').restore(), isNull);
      http.id = 'different';
      await expectLater(
        auth.accessToken(),
        throwsA(issue(GoogleAccountIssue.reauthorize)),
      );
      await auth.signOut();
      expect(keys.data, isEmpty);
      expect(bridge.cleared, 1);
      expect(() => auth.accountKey, throwsA(isA<SyncTransportFailure>()));
      expect(await service().restore(), isNull);
    },
  );
  test(
    'publication consent survives restore; silent renewal requests both scopes',
    () async {
      final first = service();
      await first.signIn();
      final binding = first.accountKey;
      expect(first.publicationAuthorized, isFalse);
      await first.authorizePublications();
      expect(first.publicationAuthorized, isTrue);
      expect(first.accountKey, binding);
      final restored = service();
      await restored.restore();
      expect(restored.publicationAuthorized, isTrue);
      await restored.accessToken();
      expect(bridge.publications, 2);
      expect(bridge.calls.last, isFalse);
      await restored.signOut();
      expect(restored.publicationAuthorized, isFalse);
    },
  );
  test('publication method channel explicitly requests extra scope', () async {
    const channel = MethodChannel('org.antirkn/google_authorization');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments, {
        'interactive': true,
        'email': null,
        'publications': true,
      });
      return 'fixture';
    });
    expect(
      await const MethodChannelGoogleAuthorization().authorizePublications(
        interactive: true,
      ),
      'fixture',
    );
  });
  test('unconfigured build fails before native authorization', () async {
    await expectLater(
      service(project: '').signIn(),
      throwsA(issue(GoogleAccountIssue.configuration)),
    );
    expect(bridge.calls, isEmpty);
    expect(http.requests, 0);
  });
  test(
    'method channel requests authorization and maps errors without exposing provider text',
    () async {
      const channel = MethodChannel('org.antirkn/google_authorization');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'authorize');
        expect(call.arguments, {'interactive': true, 'email': null});
        throw PlatformException(
          code: 'google_configuration',
          message: 'PRIVATE-PROVIDER-DETAIL',
        );
      });
      const native = MethodChannelGoogleAuthorization();
      try {
        await native.authorize(interactive: true);
        fail('expected');
      } on GoogleAccountFailure catch (e) {
        expect(e.issue, GoogleAccountIssue.configuration);
        expect(e.toString(), isNot(contains('PRIVATE-PROVIDER-DETAIL')));
      }
    },
  );
}
