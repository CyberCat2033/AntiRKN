import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_integrations/antirkn_integrations.dart';

final class FixtureTokens implements SyncAccessTokenProvider {
  @override
  String accountKey = 'public-fixture-account';
  @override
  Future<String> accessToken() async => 'public-fixture-token';
}

/// A loopback HTTP implementation of the subset under test, not real Google.
final class DriveFixture implements DriveHttp {
  late HttpServer server;
  final files = <String, Map<String, dynamic>>{};
  final contents = <String, Uint8List>{};
  final log = <Map<String, dynamic>>[];
  final sessions = <String, Map<String, dynamic>>{};
  final paths = <String>[];
  int generated = 0, creates = 0, puts = 0, conditionalPuts = 0, clock = 0;
  int pageSize = 100;
  bool loseUploadResponse = false, denyDownload = false;
  Future<void> Function()? duringFirstList;
  Future<void> Function()? beforeDownload;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await _handle(request);
      } catch (_) {
        request.response.statusCode = 500;
        await request.response.close();
      }
    });
  }

  Future<void> close() => server.close(force: true);
  @override
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  }) {
    if (uri.scheme != 'https' || uri.host != 'www.googleapis.com') {
      throw StateError('unexpected_origin');
    }
    return NativeDriveHttp().send(
      method,
      uri.replace(scheme: 'http', host: '127.0.0.1', port: server.port),
      headers: headers,
      body: body,
      responseLimit: responseLimit,
    );
  }

  void insert(String id, String name, Uint8List bytes) {
    final version = '${log.length + 1}';
    final metadata = <String, dynamic>{
      'id': id,
      'name': name,
      'mimeType': 'application/octet-stream',
      'spaces': ['appDataFolder'],
      'size': '${bytes.length}',
      'version': version,
      'trashed': false,
      'createdTime':
          files[id]?['createdTime'] ??
          DateTime.utc(2026).add(Duration(seconds: ++clock)).toIso8601String(),
      'etag': '"etag-$id-$version"',
    };
    files[id] = metadata;
    contents[id] = bytes;
    log.add({'fileId': id, 'removed': false, 'file': metadata});
  }

  Future<void> _handle(HttpRequest request) async {
    paths.add('${request.method} ${request.uri.path}');
    final response = request.response;
    Future<void> json(Object value, [int status = 200]) async {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(value));
      await response.close();
    }

    if (request.headers.value('authorization') !=
        'Bearer public-fixture-token') {
      return json({}, 401);
    }
    final path = request.uri.path;
    final query = request.uri.queryParameters;
    if (path == '/drive/v3/files/generateIds') {
      if (query['space'] != 'appDataFolder') return json({}, 400);
      return json({
        'ids': ['fixture_${++generated}'],
        'space': 'appDataFolder',
      });
    }
    if (path == '/upload/drive/v3/files' && request.method == 'POST') {
      creates++;
      final metadata =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      if (metadata['parents'].single != 'appDataFolder') return json({}, 400);
      if (files.containsKey(metadata['id'])) return json({}, 409);
      final sessionId = 'session_$creates';
      sessions[sessionId] = metadata;
      response.headers.set(
        'location',
        'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=$sessionId',
      );
      return json({});
    }
    if (path == '/upload/drive/v3/files' && request.method == 'PUT') {
      puts++;
      final metadata = sessions[query['upload_id']]!;
      final builder = BytesBuilder();
      await for (final chunk in request) {
        builder.add(chunk);
      }
      insert(
        metadata['id'] as String,
        metadata['name'] as String,
        builder.takeBytes(),
      );
      if (loseUploadResponse) {
        loseUploadResponse = false;
        return json({}, 503);
      }
      return json({'id': metadata['id']});
    }
    if (path.startsWith('/upload/drive/v3/files/') &&
        request.method == 'PATCH' &&
        query['uploadType'] == 'media') {
      final id = path.split('/').last;
      if (!files.containsKey(id)) return json({}, 404);
      final builder = BytesBuilder();
      await for (final chunk in request) {
        builder.add(chunk);
      }
      insert(id, files[id]!['name'] as String, builder.takeBytes());
      return json({'id': id});
    }
    if (path.startsWith('/upload/drive/v2/files/') &&
        request.method == 'PUT' &&
        query['uploadType'] == 'media') {
      conditionalPuts++;
      final id = path.split('/').last;
      final builder = BytesBuilder();
      await for (final chunk in request) {
        builder.add(chunk);
      }
      if (!files.containsKey(id)) return json({}, 404);
      if (request.headers.value('if-match') != files[id]!['etag']) {
        return json({}, 412);
      }
      insert(id, files[id]!['name'] as String, builder.takeBytes());
      return json({
        'id': id,
        'version': files[id]!['version'],
        'etag': files[id]!['etag'],
      });
    }
    if (path == '/drive/v2/files' && request.method == 'GET') {
      if (query['spaces'] != 'appDataFolder') return json({}, 400);
      final title = RegExp(
        r"title = '([^']+)'",
      ).firstMatch(query['q'] ?? '')?.group(1);
      final matching = files.values
          .where((file) => file['name'] == title && file['trashed'] != true)
          .toList();
      final size = int.tryParse(query['maxResults'] ?? '') ?? 100;
      final start = int.tryParse(query['pageToken'] ?? '0') ?? -1;
      if (start < 0) return json({}, 400);
      final page = matching.skip(start).take(min(size, pageSize)).toList();
      final hook = duringFirstList;
      duringFirstList = null;
      if (hook != null) await hook();
      return json({
        'incompleteSearch': false,
        'items': [
          for (final file in page)
            {
              'id': file['id'],
              'title': file['name'],
              'fileSize': file['size'],
              'version': file['version'],
              'etag': file['etag'],
              'createdDate': file['createdTime'],
              'labels': {'trashed': file['trashed']},
            },
        ],
        if (start + page.length < matching.length)
          'nextPageToken': '${start + page.length}',
      });
    }
    if (path.startsWith('/drive/v3/files/')) {
      final id = path.split('/').last;
      if (query['alt'] == 'media') {
        final hook = beforeDownload;
        beforeDownload = null;
        if (hook != null) await hook();
        if (denyDownload) return json({}, 503);
        if (!contents.containsKey(id)) return json({}, 404);
        response.add(contents[id]!);
        return response.close();
      }
      if (!files.containsKey(id)) return json({}, 404);
      return json(files[id]!);
    }
    return json({}, 404);
  }
}
