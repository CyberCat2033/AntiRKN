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
      final hasValidExt =
          lowerName.endsWith('.tar.gz') ||
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
  const GithubComponentReleaseSource({
    this.metadata,
    this.download,
    this.sha256Hex,
  });
  final Future<dynamic> Function(String path)? metadata;

  /// SHA-256 of downloaded bytes, provided by the app (this package has no
  /// hashing dependency). Without it AmneziaWG source releases are not offered.
  final String Function(List<int> bytes)? sha256Hex;

  /// Fetches a source archive (tests replace it).
  final Future<List<int>?> Function(String url)? download;

  static final Map<String, ({String? etag, dynamic body})> _cache = {};

  static void clearCache() => _cache.clear();

  Future<dynamic> _read(
    HttpClient client,
    String path, {
    int limit = 512 * 1024,
  }) async {
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
      if (bytes.length > limit) {
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
                  // Only stable releases are offered as "the latest";
                  // previews (rc/beta) stay available through explicit choice.
                  if (m['draft'] == false &&
                      m['prerelease'] == false &&
                      t != null &&
                      componentVersion(t) != null) {
                    data = m;
                    break;
                  }
                }
              }
            } catch (_) {}
          }
          data ??= await _read(client, '${entry.value}/releases/latest') as Map;
          final tag = data['tag_name'] as String;
          if (data['draft'] != false ||
              data['prerelease'] != false ||
              componentVersion(tag) == null) {
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

  static const _releaseRepos = {
    'panel': 'MHSanaei/3x-ui',
    'xray': 'XTLS/Xray-core',
    'trusttunnel': 'TrustTunnel/TrustTunnel',
  };

  @override
  Future<List<ComponentRelease>> releases(String component) async {
    if (component == 'amneziawg') return _awgReleases();
    final repo = _releaseRepos[component];
    if (repo == null) return const [];
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      // Release notes are long; the list of the last 30 can exceed the
      // single-release limit.
      final list =
          await _read(
                client,
                '$repo/releases',
                limit: 8 * 1024 * 1024,
              ).timeout(const Duration(seconds: 60))
              as List;
      final out = <ComponentRelease>[];
      for (final item in list) {
        if (item is! Map || item['draft'] != false) continue;
        final tag = item['tag_name'];
        if (tag is! String) continue;
        final preview = item['prerelease'] == true;
        if (componentVersion(tag, allowPreview: preview) == null) continue;
        out.add(
          ComponentRelease(
            tag.replaceFirst(RegExp(r'^v'), ''),
            preview: preview,
            published: DateTime.tryParse('${item['published_at']}'),
          ),
        );
      }
      return out;
    } finally {
      client.close(force: true);
    }
  }

  /// AmneziaWG Go has tags, no releases or binaries: it is built from source.
  Future<List<ComponentRelease>> _awgReleases() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final tags =
          await _read(
                client,
                'amnezia-vpn/amneziawg-go/tags',
              ).timeout(const Duration(seconds: 60))
              as List;
      final out = <ComponentRelease>[
        for (final item in tags)
          if (item is Map &&
              item['name'] is String &&
              componentVersion(item['name'] as String) != null)
            ComponentRelease(
              (item['name'] as String).replaceFirst(RegExp(r'^v'), ''),
            ),
      ];
      out.sort(
        (a, b) => componentIsNewer(a.version, b.version) == true ? -1 : 1,
      );
      return out;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<Map<String, Object?>?> resolveInstallerRelease({
    required String component,
    required String version,
  }) async {
    if (componentVersion(version) == null) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      if (component == 'trusttunnel') {
        final release =
            await _read(
                  client,
                  'TrustTunnel/TrustTunnel/releases/tags/v$version',
                )
                as Map;
        final name = 'trusttunnel-v$version-linux-x86_64.tar.gz';
        final asset = ((release['assets'] as List?) ?? const [])
            .whereType<Map>()
            .where((a) => a['name'] == name)
            .firstOrNull;
        final sha = normalizeSha256(asset?['digest'] as String?);
        if (release['draft'] != false ||
            asset == null ||
            sha.isEmpty ||
            asset['size'] is! int) {
          return null;
        }
        return {
          'version': version,
          'archive': {
            'url':
                'https://github.com/TrustTunnel/TrustTunnel/releases/download/v$version/$name',
            'bytes': asset['size'],
            'sha256': sha,
          },
        };
      }
      if (component == 'amneziawg' && sha256Hex != null) {
        final tags =
            await _read(client, 'amnezia-vpn/amneziawg-go/tags') as List;
        final commit = tags
            .whereType<Map>()
            .where((t) => t['name'] == 'v$version' || t['name'] == version)
            .map((t) => (t['commit'] as Map?)?['sha'])
            .whereType<String>()
            .firstOrNull;
        if (commit == null || !RegExp(r'^[a-f0-9]{40}$').hasMatch(commit)) {
          return null;
        }
        // GitHub publishes no checksum for source archives: take the
        // archive once over HTTPS and pin its size and SHA-256, so the server
        // builds exactly these bytes.
        final url =
            'https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/$commit';
        final bytes = await (download ?? _download)(url);
        if (bytes == null || bytes.isEmpty) return null;
        return {
          'version': version,
          'commit': commit,
          'archive': {
            'url': url,
            'bytes': bytes.length,
            'sha256': sha256Hex!(bytes),
          },
        };
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<int>?> _download(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = true;
      request.headers.set('User-Agent', 'AntiRKN');
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if (response.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final part in response.timeout(const Duration(seconds: 60))) {
        bytes.addAll(part);
        if (bytes.length > 20 * 1024 * 1024) return null;
      }
      return bytes;
    } catch (_) {
      return null;
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
        release = await _read(client, '$repo/releases/tags/v$version') as Map?;
      } catch (_) {}
      if (release == null) {
        try {
          release = await _read(client, '$repo/releases/tags/$version') as Map?;
        } catch (_) {}
      }
      if (release == null) return null;
      // Previews are never offered as "the latest" (see check), but an
      // explicitly chosen one is installed like any other release.
      if (release['draft'] == true) return null;

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
                final val =
                    res['content'] ??
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
          final downloadUrl =
              checksumAsset['browser_download_url'] as String? ??
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

      final rawCandidate =
          parsedSha256 ??
          (matchedAsset['digest'] as String?) ??
          (matchedAsset['sha256'] as String?) ??
          '';
      final resolvedSha256 = normalizeSha256(rawCandidate);

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

  static final RegExp _sha256Regex = RegExp(r'^[0-9a-f]{64}$');

  /// Normalizes digest string (strips 'sha256:' prefix, trims, lowercases).
  /// Returns empty string if raw is empty or not a valid 64-hex SHA-256.
  static String normalizeSha256(String? raw) {
    if (raw == null) return '';
    var cleaned = raw.trim().toLowerCase();
    if (cleaned.startsWith('sha256:')) {
      cleaned = cleaned.substring(7).trim();
    }
    return _sha256Regex.hasMatch(cleaned) ? cleaned : '';
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
          final normalized = normalizeSha256(match.group(0));
          return normalized.isNotEmpty ? normalized : null;
        }
      }
    }

    if (isDedicated) {
      for (final line in lines) {
        if (line.toUpperCase().contains('256')) {
          final match = hexRegex.firstMatch(line);
          if (match != null) {
            final normalized = normalizeSha256(match.group(0));
            return normalized.isNotEmpty ? normalized : null;
          }
        }
      }
      for (final line in lines) {
        final match = hexRegex.firstMatch(line);
        if (match != null) {
          final normalized = normalizeSha256(match.group(0));
          return normalized.isNotEmpty ? normalized : null;
        }
      }
    }

    return null;
  }
}
