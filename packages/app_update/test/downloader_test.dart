import 'dart:async';
import 'dart:io';

import 'package:antirkn_app_update/antirkn_app_update.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Serves [body] for every request; the test edits behaviour per case.
final class Server {
  late HttpServer server;
  List<int> body = 'test'.codeUnits;
  int status = 200;
  String? redirect;
  bool honourRange = true;
  int? declaredLength;
  final ranges = <String?>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      if (redirect != null) {
        response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, redirect!);
        return response.close();
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      var bytes = body;
      response.statusCode = status;
      if (range != null && honourRange && status == 200) {
        final start = int.parse(range.substring(6, range.length - 1));
        bytes = body.sublist(start);
        response
          ..statusCode = 206
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${body.length - 1}/${body.length}',
          );
      }
      response.contentLength = declaredLength ?? bytes.length;
      response.add(bytes);
      try {
        await response.close();
      } catch (_) {}
    });
  }

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');
}

bool loopback(Uri uri, {required bool redirected}) =>
    uri.scheme == 'http' && uri.host == '127.0.0.1';

void main() {
  late Server server;
  late Directory cache;
  late GithubArtifactDownloader downloader;

  setUp(() async {
    server = Server();
    await server.start();
    cache = await Directory.systemTemp.createTemp('antirkn-update-test-');
    downloader = GithubArtifactDownloader(
      cacheDirectory: '${cache.path}/updates',
      http: ReleaseHttp(policy: loopback),
      progressStep: 1,
    );
  });

  tearDown(() async {
    await server.server.close(force: true);
    await cache.delete(recursive: true);
  });

  AppUpdateArtifact local({int size = 4, String? sha}) {
    final base = artifact(AppUpdateKind.linuxTarball, 'x64', size: size);
    return AppUpdateArtifact(
      kind: base.kind,
      arch: base.arch,
      fileName: base.fileName,
      url: '${server.base}/${base.fileName}',
      size: size,
      sha256: sha ?? base.sha256,
    );
  }

  Future<String> code(Future<Object?> work) async {
    try {
      await work;
    } on AppUpdateFailure catch (error) {
      return error.code;
    }
    return 'ok';
  }

  test('url policy allows only the repository and GitHub release CDN', () {
    bool allowed(String url, {bool redirected = false}) =>
        appUpdateUriAllowed(Uri.parse(url), redirected: redirected);
    expect(
      allowed(
        'https://github.com/CyberCat2033/AntiRKN/releases/download/v1.2.3/a',
      ),
      isTrue,
    );
    expect(
      allowed('http://github.com/CyberCat2033/AntiRKN/releases/x'),
      isFalse,
    );
    expect(allowed('https://github.com/Other/AntiRKN/releases/x'), isFalse);
    expect(
      allowed('https://u:p@github.com/CyberCat2033/AntiRKN/releases/x'),
      isFalse,
    );
    expect(
      allowed('https://github.com:8443/CyberCat2033/AntiRKN/releases/x'),
      isFalse,
    );
    expect(allowed('https://release-assets.githubusercontent.com/x'), isFalse);
    expect(
      allowed(
        'https://release-assets.githubusercontent.com/x',
        redirected: true,
      ),
      isTrue,
    );
    expect(
      allowed('https://objects.githubusercontent.com/x', redirected: true),
      isTrue,
    );
    expect(allowed('https://evil.example/x', redirected: true), isFalse);
  });

  test('downloads, verifies and reuses a cached artifact', () async {
    final progress = <int>[];
    final path = await downloader.download(
      local(),
      onProgress: (received, _) => progress.add(received),
      token: CancellationToken(),
    );
    expect(await File(path).readAsString(), 'test');
    expect(path, startsWith(cache.path));
    expect(progress.last, 4);
    server.body = 'XXXX'.codeUnits; // the cache is re-hashed, not refetched
    final again = await downloader.download(
      local(),
      onProgress: (_, _) {},
      token: CancellationToken(),
    );
    expect(await File(again).readAsString(), 'test');
    expect(server.ranges, hasLength(1));
  });

  test('a checksum mismatch leaves nothing behind', () async {
    server.body = 'tesT'.codeUnits;
    expect(
      await code(
        downloader.download(
          local(),
          onProgress: (_, _) {},
          token: CancellationToken(),
        ),
      ),
      AppUpdateCode.checksum,
    );
    expect(Directory('${cache.path}/updates').listSync(), isEmpty);
  });

  test('more bytes than the signed size are refused', () async {
    server.body = 'test-and-more'.codeUnits;
    expect(
      await code(
        downloader.download(
          local(),
          onProgress: (_, _) {},
          token: CancellationToken(),
        ),
      ),
      AppUpdateCode.size,
    );
  });

  test('a redirect to another host is refused', () async {
    server.redirect = 'https://evil.example/file';
    expect(
      await code(
        downloader.download(
          local(),
          onProgress: (_, _) {},
          token: CancellationToken(),
        ),
      ),
      AppUpdateCode.redirect,
    );
  });

  test('HTTP errors are codes', () async {
    server.status = 404;
    expect(
      await code(
        downloader.download(
          local(),
          onProgress: (_, _) {},
          token: CancellationToken(),
        ),
      ),
      AppUpdateCode.http,
    );
  });

  test('resumes a partial download with a range request', () async {
    final a = local();
    await Directory('${cache.path}/updates').create();
    await File('${cache.path}/updates/${a.fileName}.part').writeAsString('te');
    final path = await downloader.download(
      a,
      onProgress: (_, _) {},
      token: CancellationToken(),
    );
    expect(await File(path).readAsString(), 'test');
    expect(server.ranges.single, 'bytes=2-');
  });

  test('a server ignoring the range restarts from zero', () async {
    final a = local();
    server.honourRange = false;
    await Directory('${cache.path}/updates').create();
    await File('${cache.path}/updates/${a.fileName}.part').writeAsString('xx');
    final path = await downloader.download(
      a,
      onProgress: (_, _) {},
      token: CancellationToken(),
    );
    expect(await File(path).readAsString(), 'test');
  });

  test('old release files are removed from the cache', () async {
    await Directory('${cache.path}/updates').create();
    final stale = File('${cache.path}/updates/AntiRKN-v1.0.0-linux-x64.tar.gz');
    await stale.writeAsString('old');
    final unrelated = File('${cache.path}/updates/keep.txt');
    await unrelated.writeAsString('keep');
    await downloader.download(
      local(),
      onProgress: (_, _) {},
      token: CancellationToken(),
    );
    expect(stale.existsSync(), isFalse);
    expect(unrelated.existsSync(), isTrue);
  });

  test('the feed caps the manifest size', () async {
    server.body = List.filled(appUpdateManifestMaxBytes + 1, 0x20);
    final feed = GithubUpdateFeed(
      http: ReleaseHttp(policy: loopback),
      manifestUrl: '${server.base}/app-update-{channel}.json',
    );
    expect(
      await code(feed.fetch('stable', CancellationToken())),
      AppUpdateCode.size,
    );
    expect(
      await code(Future.sync(() => feed.fetch('nightly', CancellationToken()))),
      AppUpdateCode.channelMismatch,
    );
  });
}
