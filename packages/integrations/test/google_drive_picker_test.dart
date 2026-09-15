import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'package:test/test.dart';
import 'google_drive_publisher_test.dart' as f;

const key = 'public-picker-fixture-key', appId = '123456';
Future<int> post(
  HttpClient http,
  Uri page,
  Map<String, Object?> value, {
  String? origin,
}) async {
  final request = await http.postUrl(page.replace(path: '${page.path}/result'));
  request.headers.contentType = ContentType.json;
  request.headers.set('Origin', origin ?? page.origin);
  request.write(jsonEncode(value));
  final response = await request.close();
  await response.drain<void>();
  return response.statusCode;
}

void main() {
  test(
    'loopback picker grants one selected ID, keeps OAuth out of URLs and closes its endpoint',
    () async {
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      late Uri endpoint;
      final picker = GoogleDrivePicker(
        tokens: f.Tokens(),
        openBrowser: (uri) async {
          endpoint = uri;
          expect(uri.host, '127.0.0.1');
          expect(uri.hasQuery, isFalse);
          expect(uri.toString(), isNot(contains('private-fixture-token')));
          final response = await (await http.getUrl(uri)).close();
          expect(response.headers.value('cache-control'), 'no-store');
          final page = await utf8.decoder.bind(response).join();
          expect(page, contains('setOAuthToken("private-fixture-token")'));
          expect(page, contains('setAppId("123456")'));
          expect(page, contains('https://apis.google.com/js/api.js'));
          expect(
            await post(http, uri, {
              'action': 'picked',
              'id': 'fixture',
              'resourceKey': 'key-fixture',
            }, origin: 'https://untrusted.example'),
            404,
          );
          expect(
            await post(http, uri, {
              'action': 'picked',
              'id': 'fixture',
              'resourceKey': 'key-fixture',
            }),
            200,
          );
          return true;
        },
      );
      final target = await picker.pick(apiKey: key, appId: appId);
      expect(target?.fileId, 'fixture');
      expect(target?.resourceKey, 'key-fixture');
      await expectLater(
        () async => (await http.getUrl(endpoint)).close(),
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
      );
    },
  );
  test(
    'cancel, browser failure and account change end without a selected file',
    () async {
      final tokens = f.Tokens();
      late GoogleDrivePicker picker;
      picker = GoogleDrivePicker(
        tokens: tokens,
        openBrowser: (_) async {
          picker.cancel();
          return true;
        },
      );
      expect(await picker.pick(apiKey: key, appId: appId), isNull);
      picker = GoogleDrivePicker(
        tokens: tokens,
        openBrowser: (_) async => false,
      );
      await expectLater(
        picker.pick(apiKey: key, appId: appId),
        throwsA(isA<GoogleAccountFailure>()),
      );
      picker = GoogleDrivePicker(
        tokens: tokens,
        openBrowser: (_) async {
          tokens.accountKey = 'changed';
          return true;
        },
      );
      await expectLater(
        picker.pick(apiKey: key, appId: appId),
        throwsA(f.issue(PublicationIssue.accountChanged)),
      );
    },
  );
  test(
    'malformed callback cannot finish selection; timeout closes session',
    () async {
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final picker = GoogleDrivePicker(
        tokens: f.Tokens(),
        timeout: const Duration(milliseconds: 100),
        openBrowser: (uri) async {
          expect(
            await post(http, uri, {'action': 'picked', 'id': '../file'}),
            400,
          );
          return true;
        },
      );
      // Invalid ID is an explicit invalid result; hostile path and origin never select anything.
      await expectLater(
        picker.pick(apiKey: key, appId: appId),
        throwsA(f.issue(PublicationIssue.invalid)),
      );
      final waiting = GoogleDrivePicker(
        tokens: f.Tokens(),
        timeout: const Duration(milliseconds: 10),
        openBrowser: (_) async => true,
      );
      await expectLater(
        waiting.pick(apiKey: key, appId: appId),
        throwsA(f.issue(PublicationIssue.network)),
      );
    },
  );
  test(
    'Drive URL parser accepts view/download/resource keys and rejects arbitrary URLs',
    () {
      expect(PublicationTarget.parse('legacy-ID').fileId, 'legacy-ID');
      expect(
        PublicationTarget.parse(
          'https://drive.google.com/file/d/legacy-ID/view?resourcekey=abc',
        ).resourceKey,
        'abc',
      );
      expect(
        PublicationTarget.parse(
          'https://drive.google.com/uc?export=download&id=legacy-ID',
        ).fileId,
        'legacy-ID',
      );
      expect(
        PublicationTarget.parse(
          'https://drive.usercontent.google.com/download?id=legacy-ID&resourcekey=abc',
        ).fileId,
        'legacy-ID',
      );
      for (final value in [
        'http://drive.google.com/uc?id=file',
        'https://drive.google.com.evil/uc?id=file',
        'https://user@drive.google.com/uc?id=file',
        'https://docs.google.com/document/d/file/edit',
        'https://drive.google.com/drive/folders/file',
        'https://drive.google.com/uc?id=a&id=b',
        'https://drive.google.com/uc?id=file&resourcekey=a%0d%0ab',
        '../file',
      ]) {
        expect(
          () => PublicationTarget.parse(value),
          throwsA(isA<PublicationFailure>()),
          reason: value,
        );
      }
    },
  );
  test(
    'resource key accompanies API requests but never public readback',
    () async {
      final http = f.Http()..reply = (_) async => f.response(200, 'profile');
      final drive = GoogleDrivePublisher(tokens: f.Tokens(), http: http);
      drive.useResourceKey(
        PublicationTarget('fixture', resourceKey: 'resource-key'),
      );
      await drive.download('fixture');
      expect(
        http.requests.last.headers['X-Goog-Drive-Resource-Keys'],
        'fixture/resource-key',
      );
      await drive.verifyPublicLink(
        'https://drive.google.com/uc?id=fixture&resourcekey=resource-key',
        Uint8List.fromList(utf8.encode('profile')),
      );
      expect(http.requests.last.headers, isEmpty);
    },
  );
}
