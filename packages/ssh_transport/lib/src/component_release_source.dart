import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';

/// Device-side metadata only. No SSH, APT, executable download or execution.
final class GithubComponentReleaseSource implements ComponentReleaseSource {
  const GithubComponentReleaseSource({this.metadata});
  final Future<dynamic> Function(String path)? metadata;

  static final Map<String, ({String? etag, dynamic body})> _cache = {};

  static void clearCache() => _cache.clear();

  Future<dynamic> _read(HttpClient client, String path) async {
    if (metadata != null) return metadata!(path);
    final request = await client.getUrl(
      Uri.https('api.github.com', '/repos/$path'),
    );
    request.followRedirects = false;
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('User-Agent', 'AntiRKN');
    if (_cache.containsKey(path) && _cache[path]!.etag != null) {
      request.headers.set('If-None-Match', _cache[path]!.etag!);
    }
    final response = await request.close();
    if (response.statusCode == 304 && _cache.containsKey(path)) {
      return _cache[path]!.body;
    }
    if (response.statusCode != 200) {
      throw const FormatException('release_source');
    }
    final bytes = <int>[];
    await for (final part in response) {
      bytes.addAll(part);
      if (bytes.length > 512 * 1024) {
        throw const FormatException('release_size');
      }
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    final etag = response.headers.value('etag');
    _cache[path] = (etag: etag, body: decoded);
    return decoded;
  }

  @override
  Future<Map<String, String>> check([bool includeMihomo = false]) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final result = <String, String>{};
        final repos = <String, String>{
          'panel': 'MHSanaei/3x-ui',
          'xray': 'XTLS/Xray-core',
          'trusttunnel': 'TrustTunnel/TrustTunnel',
          'amneziawgTools': 'amnezia-vpn/amneziawg-tools',
        };
        if (includeMihomo) {
          repos['mihomo'] = 'MetaCubeX/mihomo';
        }
        for (final entry in repos.entries) {
          Map? data;
          if (entry.key == 'trusttunnel') {
            try {
              final list =
                  await _read(client, '${entry.value}/releases') as List?;
              if (list != null && list.isNotEmpty) {
                for (final item in list) {
                  final m = item as Map;
                  final t = m['tag_name'] as String?;
                  if (m['draft'] == false &&
                      t != null &&
                      componentVersion(t, allowPreview: true) != null) {
                    data = m;
                    break;
                  }
                }
              }
            } catch (_) {}
          }
          data ??=
              await _read(client, '${entry.value}/releases/latest') as Map;
          final tag = data['tag_name'] as String;
          if (data['draft'] != false ||
              (entry.key != 'trusttunnel' && data['prerelease'] != false) ||
              componentVersion(tag, allowPreview: entry.key == 'trusttunnel') == null) {
            throw const FormatException('release_version');
          }
          result[entry.key] = tag.replaceFirst(RegExp(r'^v'), '');
        }
        final tags =
            await _read(client, 'amnezia-vpn/amneziawg-go/tags') as List;
        String? newest;
        for (final item in tags) {
          final tag = (item as Map)['name'] as String;
          if (componentVersion(tag) != null &&
              (newest == null || componentIsNewer(tag, newest) == true)) {
            newest = tag;
          }
        }
        if (newest == null) throw const FormatException('release_tags');
        result['amneziawg'] = newest.replaceFirst(RegExp(r'^v'), '');
        return result;
      })().timeout(const Duration(seconds: 60));
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<Map<String, Object?>?> resolveAsset({
    required String component,
    required String version,
    String? architecture,
  }) async {
    final arch = (architecture ?? 'x86_64').toLowerCase();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final repo = switch (component) {
        'panel' => 'MHSanaei/3x-ui',
        'xray' => 'XTLS/Xray-core',
        'trusttunnel' => 'TrustTunnel/TrustTunnel',
        'amneziawgTools' => 'amnezia-vpn/amneziawg-tools',
        'mihomo' => 'MetaCubeX/mihomo',
        _ => null,
      };
      if (repo == null) return null;

      final release =
          await _read(client, '$repo/releases/tags/v$version') as Map?;
      if (release == null) return null;
      if (release['draft'] == true ||
          (release['prerelease'] == true && component != 'trusttunnel')) {
        return null;
      }

      final assets = (release['assets'] as List?) ?? [];
      final archToken = (arch == 'aarch64' || arch == 'arm64')
          ? RegExp(r'arm64|aarch64', caseSensitive: false)
          : RegExp(r'amd64|x86_64|64', caseSensitive: false);

      Map? matchedAsset;
      for (final a in assets) {
        final name = (a as Map)['name'] as String;
        if (name.contains('linux') && archToken.hasMatch(name)) {
          if (!name.endsWith('.deb') &&
              !name.endsWith('.rpm') &&
              !name.contains('dbgsym')) {
            matchedAsset = a;
            break;
          }
        }
      }
      if (matchedAsset == null && assets.isNotEmpty) {
        matchedAsset = assets.first as Map;
      }
      if (matchedAsset == null) return null;

      return {
        'component': component,
        'version': version,
        'architecture': arch,
        'assetName': matchedAsset['name'],
        'url': matchedAsset['browser_download_url'],
        'bytes': matchedAsset['size'],
        'sha256': matchedAsset['digest'] ?? '',
      };
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
