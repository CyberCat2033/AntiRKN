import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';

class ReleaseAssetSelector {
  /// Strict asset selection matching target OS and target architecture.
  /// Eliminates accidental matching of AArch64 assets on x86_64 and filters debug symbols/signatures.
  static Map? selectAsset({
    required List assets,
    required String targetOs,
    required String targetArch,
    String? component,
  }) {
    final arch = targetArch.toLowerCase();
    final isArm = arch == 'aarch64' || arch == 'arm64';
    final osPattern = RegExp(targetOs, caseSensitive: false);

    // Strict architecture tokens bounded by separators
    final x86Pattern = RegExp(
      r'(?:^|[-_.])(?:amd64|x86_64|x64|64)(?:[-_.]|$)',
      caseSensitive: false,
    );
    final armPattern = RegExp(
      r'(?:^|[-_.])(?:arm64|aarch64)(?:[-_.]|$)',
      caseSensitive: false,
    );

    for (final a in assets) {
      if (a is! Map) continue;
      final name = (a['name'] as String?) ?? '';
      final lowerName = name.toLowerCase();

      // Check OS
      if (!osPattern.hasMatch(lowerName)) continue;

      // Exclude packaging formats, signatures, debug symbols, checksums, and SBOMs
      if (lowerName.endsWith('.deb') ||
          lowerName.endsWith('.rpm') ||
          lowerName.endsWith('.sig') ||
          lowerName.endsWith('.sha256') ||
          lowerName.endsWith('.sha256sum') ||
          lowerName.endsWith('.txt') ||
          lowerName.endsWith('.sbom') ||
          lowerName.contains('dbgsym')) {
        continue;
      }

      // Valid archive or binary extensions
      final hasValidExt = lowerName.endsWith('.tar.gz') ||
          lowerName.endsWith('.tgz') ||
          lowerName.endsWith('.zip') ||
          lowerName.endsWith('.tar.xz') ||
          !lowerName.contains('.');
      if (!hasValidExt) continue;

      if (isArm) {
        if (armPattern.hasMatch(lowerName)) {
          return a;
        }
      } else {
        // x86_64 / amd64: MUST NOT match any arm or aarch64
        if (lowerName.contains('arm') || lowerName.contains('aarch')) {
          continue;
        }
        if (x86Pattern.hasMatch(lowerName)) {
          return a;
        }
      }
    }

    return null;
  }
}

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

      Map? release;
      try {
        release =
            await _read(client, '$repo/releases/tags/v$version') as Map?;
      } catch (_) {}
      if (release == null) {
        try {
          release =
              await _read(client, '$repo/releases/tags/$version') as Map?;
        } catch (_) {}
      }
      if (release == null) return null;
      if (release['draft'] == true ||
          (release['prerelease'] == true && component != 'trusttunnel')) {
        return null;
      }

      final assets = (release['assets'] as List?) ?? [];
      final matchedAsset = ReleaseAssetSelector.selectAsset(
        assets: assets,
        targetOs: 'linux',
        targetArch: arch,
        component: component,
      );
      if (matchedAsset == null) {
        return null;
      }

      final targetName = matchedAsset['name'] as String;
      Map? checksumAsset;
      bool isDedicated = false;

      final dedicatedCandidates = [
        '$targetName.sha256',
        '$targetName.sha256sum',
        '$targetName.dgst',
        '$targetName.digest',
        '$targetName.sha256.txt',
      ];
      for (final a in assets) {
        if (a is! Map) continue;
        final name = (a['name'] as String?)?.toLowerCase();
        if (name == null) continue;
        for (final candidate in dedicatedCandidates) {
          if (name == candidate.toLowerCase()) {
            checksumAsset = a;
            isDedicated = true;
            break;
          }
        }
        if (checksumAsset != null) break;
      }

      if (checksumAsset == null) {
        final multiCandidates = [
          'sha256sums',
          'sha256sums.txt',
          'checksums.txt',
          'checksums_sha256.txt',
          'checksums',
        ];
        for (final a in assets) {
          if (a is! Map) continue;
          final name = (a['name'] as String?)?.toLowerCase();
          if (name == null) continue;
          if (multiCandidates.contains(name)) {
            checksumAsset = a;
            isDedicated = false;
            break;
          }
        }
      }

      String? parsedSha256;
      if (checksumAsset != null) {
        String? checksumContent;
        if (checksumAsset['content'] is String &&
            (checksumAsset['content'] as String).isNotEmpty) {
          checksumContent = checksumAsset['content'] as String;
        } else if (checksumAsset['text'] is String &&
            (checksumAsset['text'] as String).isNotEmpty) {
          checksumContent = checksumAsset['text'] as String;
        }

        if (checksumContent == null && metadata != null) {
          final candidatePaths = [
            checksumAsset['browser_download_url'] as String?,
            checksumAsset['name'] as String?,
            '$repo/releases/download/v$version/${checksumAsset['name']}',
            '$repo/releases/download/$version/${checksumAsset['name']}',
            '$repo/${checksumAsset['name']}',
          ].whereType<String>();

          for (final p in candidatePaths) {
            try {
              final res = await metadata!(p);
              if (res is String && res.isNotEmpty) {
                checksumContent = res;
                break;
              } else if (res is List<int> && res.isNotEmpty) {
                checksumContent = utf8.decode(res);
                break;
              } else if (res is Map) {
                final val = res['content'] ??
                    res['digest'] ??
                    res['sha256'] ??
                    res['text'];
                if (val is String && val.isNotEmpty) {
                  checksumContent = val;
                  break;
                }
              }
            } catch (_) {}
          }
        }

        if (checksumContent == null && metadata == null) {
          final downloadUrl = checksumAsset['browser_download_url'] as String? ??
              checksumAsset['url'] as String?;
          if (downloadUrl != null) {
            try {
              final req = await client.getUrl(Uri.parse(downloadUrl));
              req.followRedirects = true;
              req.maxRedirects = 5;
              req.headers.set('User-Agent', 'AntiRKN');
              final resp = await req.close();
              if (resp.statusCode == 200) {
                final bytes = <int>[];
                await for (final chunk in resp) {
                  bytes.addAll(chunk);
                  if (bytes.length > 512 * 1024) break;
                }
                checksumContent = utf8.decode(bytes);
              }
            } catch (_) {}
          }
        }

        if (checksumContent != null && checksumContent.isNotEmpty) {
          parsedSha256 = _parseSha256(
            checksumContent,
            targetName,
            isDedicated: isDedicated,
          );
        }
      }

      final resolvedSha256 = parsedSha256 ??
          (matchedAsset['digest'] as String?) ??
          (matchedAsset['sha256'] as String?) ??
          '';

      return {
        'component': component,
        'version': version,
        'architecture': arch,
        'assetName': matchedAsset['name'],
        'url': matchedAsset['browser_download_url'],
        'bytes': matchedAsset['size'],
        'sha256': resolvedSha256,
      };
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static String? _parseSha256(
    String content,
    String assetName, {
    required bool isDedicated,
  }) {
    final hexRegex = RegExp(r'\b[0-9a-fA-F]{64}\b');
    final lines = const LineSplitter()
        .convert(content)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty);

    for (final line in lines) {
      if (line.contains(assetName)) {
        final match = hexRegex.firstMatch(line);
        if (match != null) {
          return match.group(0)!.toLowerCase();
        }
      }
    }

    if (isDedicated) {
      for (final line in lines) {
        if (line.toUpperCase().contains('256')) {
          final match = hexRegex.firstMatch(line);
          if (match != null) {
            return match.group(0)!.toLowerCase();
          }
        }
      }
      for (final line in lines) {
        final match = hexRegex.firstMatch(line);
        if (match != null) {
          return match.group(0)!.toLowerCase();
        }
      }
    }

    return null;
  }
}
