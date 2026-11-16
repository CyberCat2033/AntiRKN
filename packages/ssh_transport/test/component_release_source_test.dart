import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'checks stable releases of every component including panel and Xray',
    () async {
      final paths = <String>[];
      final source = GithubComponentReleaseSource(
        metadata: (path) async {
          paths.add(path);
          if (path.endsWith('/tags')) {
            return [
              {'name': 'v3.1.20260828'},
              {'name': 'v3.1.20260812'},
            ];
          }
          return {
            'tag_name': path.contains('Xray-core') ? 'v26.7.28' : 'v3.7.0',
            'draft': false,
            'prerelease': false,
          };
        },
      );
      final result = await source.check();
      expect(result.keys.toSet(), {
        'panel',
        'xray',
        'trusttunnel',
        'amneziawgTools',
        'amneziawg',
      });
      expect(result['xray'], '26.7.28');
      expect(result['amneziawg'], '3.1.20260828');
      expect(paths, contains('MHSanaei/3x-ui/releases/latest'));
      expect(paths, contains('XTLS/Xray-core/releases/latest'));
    },
  );
  test(
    'a failed component cannot masquerade as an all-components success',
    () async {
      final source = GithubComponentReleaseSource(
        metadata: (path) async => {
          'tag_name': 'v3.7.0-rc1',
          'draft': false,
          'prerelease': true,
        },
      );
      await expectLater(source.check(), throwsFormatException);
    },
  );
  test('discovers trusttunnel candidate release from releases list and resolves clean asset', () async {
    final source = GithubComponentReleaseSource(
      metadata: (path) async {
        if (path == 'TrustTunnel/TrustTunnel/releases') {
          return [
            {
              'tag_name': 'v1.3.0-beta.2',
              'draft': false,
              'prerelease': true,
            },
            {
              'tag_name': 'v1.1.0',
              'draft': false,
              'prerelease': false,
            },
          ];
        }
        if (path.contains('TrustTunnel/releases/tags')) {
          return {
            'tag_name': 'v1.3.0-beta.2',
            'draft': false,
            'prerelease': true,
            'assets': [
              {
                'name': 'trusttunnel-linux-amd64-dbgsym.tar.gz',
                'browser_download_url': 'https://example.com/dbgsym.tar.gz',
                'size': 1234567,
              },
              {
                'name': 'trusttunnel-linux-amd64.tar.gz',
                'browser_download_url': 'https://example.com/trusttunnel.tar.gz',
                'size': 765432,
              },
            ],
          };
        }
        if (path.endsWith('/tags')) {
          return [
            {'name': 'v3.1.20260828'},
            {'name': 'v3.1.20260812'},
          ];
        }
        return {
          'tag_name': path.contains('Xray-core') ? 'v26.7.28' : 'v3.7.0',
          'draft': false,
          'prerelease': false,
        };
      },
    );
    final result = await source.check();
    expect(result['trusttunnel'], '1.3.0-beta.2');

    // Verify componentIsNewer
    expect(
      componentIsNewer('v1.3.0-beta.2', '1.1.0', allowPreview: true),
      isTrue,
    );

    // Verify resolveAsset filters dbgsym
    final asset = await source.resolveAsset(
      component: 'trusttunnel',
      version: '1.3.0-beta.2',
      architecture: 'x86_64',
    );
    expect(asset, isNotNull);
    expect(asset!['assetName'], 'trusttunnel-linux-amd64.tar.gz');
    expect(asset['url'], 'https://example.com/trusttunnel.tar.gz');
  });

  test('ReleaseAssetSelector strictly discriminates x86_64 from aarch64 even with 64 in version', () {
    final assets = [
      {'name': 'trusttunnel-v1.3.0-beta.2-linux-aarch64-dbgsym.tar.gz', 'url': 'https://aarch64-dbg'},
      {'name': 'trusttunnel-v1.3.0-beta.2-linux-aarch64.tar.gz', 'url': 'https://aarch64'},
      {'name': 'trusttunnel-v1.3.0-beta.2-linux-x86_64-dbgsym.tar.gz', 'url': 'https://x86_64-dbg'},
      {'name': 'trusttunnel-v1.3.0-beta.2-linux-x86_64.tar.gz', 'url': 'https://x86_64'},
      {'name': 'trusttunnel-v1.3.0-beta.2-macos-universal.tar.gz', 'url': 'https://macos'},
    ];

    final x86Candidate = ReleaseAssetSelector.selectAsset(
      assets: assets,
      targetOs: 'linux',
      targetArch: 'x86_64',
    );
    expect(x86Candidate, isNotNull);
    expect(x86Candidate!['name'], 'trusttunnel-v1.3.0-beta.2-linux-x86_64.tar.gz');
    expect(x86Candidate['url'], 'https://x86_64');

    final armCandidate = ReleaseAssetSelector.selectAsset(
      assets: assets,
      targetOs: 'linux',
      targetArch: 'aarch64',
    );
    expect(armCandidate, isNotNull);
    expect(armCandidate!['name'], 'trusttunnel-v1.3.0-beta.2-linux-aarch64.tar.gz');
    expect(armCandidate['url'], 'https://aarch64');
  });

  test('normalizeSha256 strips sha256: prefix, lowercases and validates 64-hex', () {
    const hex = '496a27ff72014b883438efab55ffd237183b5ff95d9c341cc0de9d18342a9b11';
    expect(GithubComponentReleaseSource.normalizeSha256(null), '');
    expect(GithubComponentReleaseSource.normalizeSha256(''), '');
    expect(GithubComponentReleaseSource.normalizeSha256('   '), '');
    expect(GithubComponentReleaseSource.normalizeSha256(hex), hex);
    expect(GithubComponentReleaseSource.normalizeSha256('sha256:$hex'), hex);
    expect(GithubComponentReleaseSource.normalizeSha256('SHA256:${hex.toUpperCase()}'), hex);
    expect(GithubComponentReleaseSource.normalizeSha256('  sha256:$hex  '), hex);
    expect(GithubComponentReleaseSource.normalizeSha256('invalid-length'), '');
    expect(GithubComponentReleaseSource.normalizeSha256('${hex}extra'), '');
    expect(GithubComponentReleaseSource.normalizeSha256('z' * 64), '');
  });
}
