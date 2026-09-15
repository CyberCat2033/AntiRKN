import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';

final class DriveHttpResponse {
  const DriveHttpResponse(this.status, this.headers, this.bytes);
  final int status;
  final Map<String, String> headers;
  final Uint8List bytes;
}

abstract interface class DriveHttp {
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  });
}

/// No redirects, TLS bypasses, logging or unbounded response buffering.
final class NativeDriveHttp implements DriveHttp {
  NativeDriveHttp({this.timeout = const Duration(seconds: 45)});
  final Duration timeout;
  @override
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await (() async {
        final request = await client.openUrl(method, uri);
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        if (body != null) {
          request.contentLength = body.length;
          request.add(body);
        }
        final response = await request.close();
        if (response.contentLength > responseLimit) {
          throw const SyncTransportFailure(SyncTransportIssue.limit);
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (builder.length + chunk.length > responseLimit) {
            throw const SyncTransportFailure(SyncTransportIssue.limit);
          }
          builder.add(chunk);
        }
        final responseHeaders = <String, String>{};
        response.headers.forEach(
          (name, values) =>
              responseHeaders[name.toLowerCase()] = values.join(','),
        );
        return DriveHttpResponse(
          response.statusCode,
          responseHeaders,
          builder.takeBytes(),
        );
      })().timeout(timeout);
    } on SyncTransportFailure {
      rethrow;
    } catch (_) {
      throw const SyncTransportFailure(SyncTransportIssue.network);
    } finally {
      client.close(force: true);
    }
  }
}
