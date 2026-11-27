import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';

import 'ed25519.dart';

/// Only HTTPS to the repository's release paths on github.com, and redirects
/// from there to GitHub's release asset CDN. Credentials, other ports and
/// every other host are refused.
bool appUpdateUriAllowed(Uri uri, {required bool redirected}) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (uri.hasPort && uri.port != 443)) {
    return false;
  }
  if (uri.host == 'github.com') {
    return uri.path.startsWith(appUpdateRepositoryPath) &&
        !uri.path.contains('/../') &&
        !uri.path.contains('/./');
  }
  return redirected && appUpdateRedirectHosts.contains(uri.host);
}

typedef AppUpdateUriPolicy = bool Function(Uri uri, {required bool redirected});

/// One bounded GET with manual, policy-checked redirects. A new client per
/// request, closed (aborting the transfer) on cancellation.
final class ReleaseHttp {
  ReleaseHttp({
    this.policy = appUpdateUriAllowed,
    HttpClient Function()? client,
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  }) : _client = client ?? HttpClient.new;

  final AppUpdateUriPolicy policy;
  final HttpClient Function() _client;
  final Duration connectTimeout;
  final Duration idleTimeout;
  static const maxRedirects = 5;

  /// Calls [use] with the final response; the client is closed afterwards.
  Future<T> get<T>(
    Uri uri,
    CancellationToken token,
    Future<T> Function(HttpClientResponse response) use, {
    int? rangeStart,
  }) async {
    final client = _client()
      ..connectionTimeout = connectTimeout
      ..idleTimeout = idleTimeout
      ..autoUncompress = false
      ..findProxy = null;
    final done = Completer<void>();
    unawaited(
      token.bind(done.future).catchError((_) => client.close(force: true)),
    );
    try {
      for (var hop = 0; hop <= maxRedirects; hop++) {
        token.check();
        if (!policy(uri, redirected: hop > 0)) {
          throw const AppUpdateFailure(AppUpdateCode.redirect);
        }
        final request = await client.getUrl(uri).timeout(connectTimeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'AntiRKN-updater');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (rangeStart != null && rangeStart > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$rangeStart-');
        }
        final response = await request.close().timeout(idleTimeout);
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.drain<void>().catchError((_) {});
          final next = location == null ? null : Uri.tryParse(location);
          if (next == null) {
            throw const AppUpdateFailure(AppUpdateCode.redirect);
          }
          uri = uri.resolveUri(next);
          continue;
        }
        return await use(response);
      }
      throw const AppUpdateFailure(AppUpdateCode.redirect);
    } on AppUpdateFailure {
      rethrow;
    } catch (_) {
      token.check();
      throw const AppUpdateFailure(AppUpdateCode.network);
    } finally {
      if (!done.isCompleted) done.complete();
      client.close(force: true);
    }
  }
}

/// The channel's latest manifest from GitHub Releases.
final class GithubUpdateFeed implements AppUpdateFeed {
  GithubUpdateFeed({ReleaseHttp? http, String? manifestUrl})
    : _http = http ?? ReleaseHttp(),
      _url = manifestUrl ?? appUpdateManifestUrl;
  final ReleaseHttp _http;
  final String _url;

  @override
  Future<Uint8List> fetch(String channel, CancellationToken token) {
    if (!appUpdateChannels.contains(channel)) {
      throw const AppUpdateFailure(AppUpdateCode.channelMismatch);
    }
    return _http.get(Uri.parse(_url.replaceAll('{channel}', channel)), token, (
      response,
    ) async {
      if (response.statusCode != 200) {
        throw const AppUpdateFailure(AppUpdateCode.http);
      }
      if (response.contentLength > appUpdateManifestMaxBytes) {
        throw const AppUpdateFailure(AppUpdateCode.size);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_http.idleTimeout)) {
        token.check();
        if (bytes.length + chunk.length > appUpdateManifestMaxBytes) {
          throw const AppUpdateFailure(AppUpdateCode.size);
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    });
  }
}

/// SHA-256 of a file, lower-case hex.
Future<String> sha256OfFile(String path) async {
  final hash = Sha256Stream();
  await for (final chunk in File(path).openRead()) {
    hash.add(chunk);
  }
  return hash.close();
}

final _cacheFile = RegExp(r'^AntiRKN-v[0-9.]+-[A-Za-z0-9_.-]+$');

/// Streams an artifact into [cacheDirectory] (a temporary or cache
/// directory, never the app's data directory) as `<name>.part`, hashing on
/// the fly, resuming an interrupted `.part` with a Range request, and
/// renames it to its final name only when size and SHA-256 match.
final class GithubArtifactDownloader implements AppUpdateDownloader {
  GithubArtifactDownloader({
    required this.cacheDirectory,
    ReleaseHttp? http,
    this.progressStep = 256 * 1024,
  }) : _http = http ?? ReleaseHttp();

  final String cacheDirectory;
  final ReleaseHttp _http;
  final int progressStep;

  @override
  Future<String> download(
    AppUpdateArtifact artifact, {
    required void Function(int received, int total) onProgress,
    required CancellationToken token,
  }) async {
    final directory = await _directory();
    final target = File('${directory.path}/${artifact.fileName}');
    final part = File('${target.path}.part');
    try {
      await _removeOthers(directory, {
        artifact.fileName,
        '${artifact.fileName}.part',
      });
      if (await _isFile(target)) {
        if (await target.length() == artifact.size &&
            await sha256OfFile(target.path) == artifact.sha256) {
          onProgress(artifact.size, artifact.size);
          return target.path;
        }
        await target.delete();
      }
      await _removeLink(part);
      var offset = await _isFile(part) ? await part.length() : 0;
      if (offset >= artifact.size) {
        await part.delete();
        offset = 0;
      }
      var hash = Sha256Stream();
      if (offset > 0) {
        await for (final chunk in part.openRead(0, offset)) {
          hash.add(chunk);
        }
      }
      await _http.get(Uri.parse(artifact.url), token, rangeStart: offset, (
        response,
      ) async {
        final range = response.headers.value(HttpHeaders.contentRangeHeader);
        if (offset > 0 &&
            response.statusCode == 206 &&
            range == 'bytes $offset-${artifact.size - 1}/${artifact.size}') {
          // Resumed.
        } else if (response.statusCode == 200) {
          offset = 0;
          hash = Sha256Stream();
        } else {
          await response.drain<void>().catchError((_) {});
          throw const AppUpdateFailure(AppUpdateCode.http);
        }
        if (response.contentLength >= 0 &&
            offset + response.contentLength != artifact.size) {
          throw const AppUpdateFailure(AppUpdateCode.size);
        }
        final file = await part.open(
          mode: offset == 0 ? FileMode.write : FileMode.append,
        );
        var received = offset;
        var reported = received;
        try {
          onProgress(received, artifact.size);
          await for (final chunk in response.timeout(_http.idleTimeout)) {
            token.check();
            if (received + chunk.length > artifact.size) {
              await file.close();
              await part.delete();
              throw const AppUpdateFailure(AppUpdateCode.size);
            }
            hash.add(chunk);
            await file.writeFrom(chunk);
            received += chunk.length;
            if (received - reported >= progressStep) {
              reported = received;
              onProgress(received, artifact.size);
            }
          }
          await file.flush();
        } finally {
          try {
            await file.close();
          } catch (_) {}
        }
        if (received != artifact.size) {
          throw const AppUpdateFailure(AppUpdateCode.network);
        }
        onProgress(received, artifact.size);
      });
      if (hash.close() != artifact.sha256) {
        await part.delete();
        throw const AppUpdateFailure(AppUpdateCode.checksum);
      }
      await part.rename(target.path);
      return target.path;
    } on AppUpdateFailure {
      rethrow;
    } on FileSystemException {
      throw const AppUpdateFailure(AppUpdateCode.storage);
    }
  }

  Future<Directory> _directory() async {
    final directory = Directory(cacheDirectory);
    try {
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        await directory.create(recursive: true);
      } else if (type != FileSystemEntityType.directory) {
        throw const AppUpdateFailure(AppUpdateCode.storage);
      }
      return directory;
    } on FileSystemException {
      throw const AppUpdateFailure(AppUpdateCode.storage);
    }
  }

  /// Old release files only: the cache holds one artifact at a time.
  static Future<void> _removeOthers(
    Directory directory,
    Set<String> keep,
  ) async {
    await for (final entry in directory.list(followLinks: false)) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (!keep.contains(name) && _cacheFile.hasMatch(name) && entry is File) {
        try {
          await entry.delete();
        } on FileSystemException {
          // Retried on the next download.
        }
      }
    }
  }

  static Future<bool> _isFile(File file) async =>
      await FileSystemEntity.type(file.path, followLinks: false) ==
      FileSystemEntityType.file;

  static Future<void> _removeLink(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link) await Link(file.path).delete();
    if (type == FileSystemEntityType.directory) {
      throw const AppUpdateFailure(AppUpdateCode.storage);
    }
  }
}
