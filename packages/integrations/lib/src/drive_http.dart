import 'dart:async';
import 'dart:io';
import 'dart:math';
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
  NativeDriveHttp({
    this.timeout = const Duration(seconds: 20),
    this.maxDuration = const Duration(minutes: 10),
    HttpClient? client,
  }) : _client = client;

  /// Longest wait without progress: connecting, sending one body chunk,
  /// waiting for the response or receiving one response chunk. A large body
  /// on a slow link keeps going while it moves.
  final Duration timeout;

  /// Upper bound for one request even while it keeps progressing.
  final Duration maxDuration;
  final HttpClient? _client;
  static const _chunk = 64 * 1024;

  static HttpClient? _defaultClient;
  static HttpClient _getOrCreateDefault(Duration timeout) =>
      _defaultClient ??= HttpClient()
        ..connectionTimeout = timeout
        ..idleTimeout = const Duration(seconds: 15);

  /// A broken connection may leave stale pooled sockets (e.g. after a network
  /// change), so new requests get a fresh client. The old one is closed
  /// without force: requests still running on it finish normally.
  static void resetDefaultClient() {
    _defaultClient?.close();
    _defaultClient = null;
  }

  HttpClient get _httpClient => _client ?? _getOrCreateDefault(timeout);

  @override
  Future<DriveHttpResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    Uint8List? body,
    required int responseLimit,
  }) async {
    final client = _httpClient;
    HttpClientRequest? request;
    try {
      return await (() async {
        final opened = request = await client
            .openUrl(method, uri)
            .timeout(timeout);
        opened.followRedirects = false;
        headers.forEach(opened.headers.set);
        if (body != null) {
          opened.contentLength = body.length;
          for (var offset = 0; offset < body.length; offset += _chunk) {
            opened.add(
              Uint8List.sublistView(
                body,
                offset,
                min(offset + _chunk, body.length),
              ),
            );
            await opened.flush().timeout(timeout);
          }
        }
        final response = await opened.close().timeout(timeout);
        if (response.contentLength > responseLimit) {
          throw const SyncTransportFailure(SyncTransportIssue.limit);
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(timeout)) {
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
      })().timeout(maxDuration);
    } on SyncTransportFailure {
      request?.abort();
      rethrow;
    } catch (_) {
      request?.abort();
      if (_client == null) resetDefaultClient();
      throw const SyncTransportFailure(SyncTransportIssue.network);
    }
  }
}
