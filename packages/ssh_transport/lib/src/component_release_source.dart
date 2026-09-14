import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';

/// Device-side metadata only. No SSH, APT, executable download or execution.
final class GithubComponentReleaseSource implements ComponentReleaseSource {
  const GithubComponentReleaseSource();
  Future<dynamic> _read(HttpClient client, String path) async {
    final request = await client.getUrl(
      Uri.https('api.github.com', '/repos/$path'),
    );
    request.followRedirects = false;
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('User-Agent', 'AntiRKN');
    final response = await request.close();
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
    return jsonDecode(utf8.decode(bytes));
  }

  @override
  Future<Map<String, String>> check() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final result = <String, String>{};
        for (final entry in {
          'trusttunnel': 'TrustTunnel/TrustTunnel',
          'amneziawgTools': 'amnezia-vpn/amneziawg-tools',
        }.entries) {
          final data =
              await _read(client, '${entry.value}/releases/latest') as Map;
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
}
