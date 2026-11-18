import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';
import 'package:test/test.dart';

void main() {
  test(
    'installer releases: TrustTunnel by asset digest, AmneziaWG by tag commit',
    () async {
      final commit = 'a' * 40;
      String? downloaded;
      final source = GithubComponentReleaseSource(
        metadata: (path) async => switch (path) {
          'TrustTunnel/TrustTunnel/releases/tags/v1.2.0' => {
            'draft': false,
            'assets': [
              {
                'name': 'trusttunnel-v1.2.0-linux-x86_64.tar.gz',
                'size': 10,
                'digest': 'sha256:${'b' * 64}',
              },
            ],
          },
          'amnezia-vpn/amneziawg-go/tags' => [
            {
              'name': 'v3.1.20261116',
              'commit': {'sha': commit},
            },
          ],
          _ => throw StateError(path),
        },
        download: (url) async {
          downloaded = url;
          return [1, 2, 3];
        },
        sha256Hex: (bytes) => 'c' * 64,
      );
      final tt = await source.resolveInstallerRelease(
        component: 'trusttunnel',
        version: '1.2.0',
      );
      expect((tt!['archive'] as Map)['sha256'], 'b' * 64);
      expect((tt['archive'] as Map)['bytes'], 10);
      final awg = await source.resolveInstallerRelease(
        component: 'amneziawg',
        version: '3.1.20261116',
      );
      expect(awg!['commit'], commit);
      expect(
        downloaded,
        'https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/$commit',
      );
      expect(awg['archive'], {
        'url': downloaded,
        'bytes': 3,
        'sha256': 'c' * 64,
      });
      expect(
        await const GithubComponentReleaseSource().resolveInstallerRelease(
          component: 'amneziawg',
          version: '3.1.20261116',
        ),
        isNull,
        reason: 'without a hash function the source archive cannot be pinned',
      );
    },
  );

  test('lists recent releases with previews marked, drafts dropped', () async {
    final source = GithubComponentReleaseSource(
      metadata: (path) async {
        if (path == 'amnezia-vpn/amneziawg-go/tags') {
          return [
            {'name': 'v3.1.20260828'},
            {'name': 'v3.1.20261116'},
            {'name': 'v3.1.20261116-rc1'},
          ];
        }
        expect(path, 'XTLS/Xray-core/releases');
        return [
          {'tag_name': 'v26.12.1', 'draft': true, 'prerelease': false},
          {
            'tag_name': 'v26.12.0-beta1',
            'draft': false,
            'prerelease': true,
            'published_at': '2026-11-17T10:00:00Z',
          },
          {
            'tag_name': 'v26.11.9',
            'draft': false,
            'prerelease': false,
            'published_at': '2026-11-09T10:00:00Z',
          },
          {'tag_name': 'nightly', 'draft': false, 'prerelease': true},
        ];
      },
    );
    final releases = await source.releases('xray');
    expect(releases.map((r) => r.version), ['26.12.0-beta1', '26.11.9']);
    expect(releases.map((r) => r.preview), [true, false]);
    expect(releases.last.published, DateTime.utc(2026, 11, 9, 10));
    // AmneziaWG Go has tags only: stable ones, newest first.
    expect((await source.releases('amneziawg')).map((r) => r.version), [
      '3.1.20261116',
      '3.1.20260828',
    ]);
    expect(await source.releases('mihomo'), isEmpty);
  });
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
  test(
    'offers the latest stable trusttunnel and still resolves an explicitly chosen preview',
    () async {
      final source = GithubComponentReleaseSource(
        metadata: (path) async {
          if (path == 'TrustTunnel/TrustTunnel/releases') {
            return [
              {'tag_name': 'v1.3.0-beta.2', 'draft': false, 'prerelease': true},
              {'tag_name': 'v1.1.0', 'draft': false, 'prerelease': false},
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
                  'browser_download_url':
                      'https://example.com/trusttunnel.tar.gz',
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
      // Previews are never offered as "the latest"; they stay selectable explicitly.
      expect(result['trusttunnel'], '1.1.0');

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
    },
  );

  test(
    'ReleaseAssetSelector strictly discriminates x86_64 from aarch64 even with 64 in version',
    () {
      final assets = [
        {
          'name': 'trusttunnel-v1.3.0-beta.2-linux-aarch64-dbgsym.tar.gz',
          'url': 'https://aarch64-dbg',
        },
        {
          'name': 'trusttunnel-v1.3.0-beta.2-linux-aarch64.tar.gz',
          'url': 'https://aarch64',
        },
        {
          'name': 'trusttunnel-v1.3.0-beta.2-linux-x86_64-dbgsym.tar.gz',
          'url': 'https://x86_64-dbg',
        },
        {
          'name': 'trusttunnel-v1.3.0-beta.2-linux-x86_64.tar.gz',
          'url': 'https://x86_64',
        },
        {
          'name': 'trusttunnel-v1.3.0-beta.2-macos-universal.tar.gz',
          'url': 'https://macos',
        },
      ];

      final x86Candidate = ReleaseAssetSelector.selectAsset(
        assets: assets,
        targetOs: 'linux',
        targetArch: 'x86_64',
      );
      expect(x86Candidate, isNotNull);
      expect(
        x86Candidate!['name'],
        'trusttunnel-v1.3.0-beta.2-linux-x86_64.tar.gz',
      );
      expect(x86Candidate['url'], 'https://x86_64');

      final armCandidate = ReleaseAssetSelector.selectAsset(
        assets: assets,
        targetOs: 'linux',
        targetArch: 'aarch64',
      );
      expect(armCandidate, isNotNull);
      expect(
        armCandidate!['name'],
        'trusttunnel-v1.3.0-beta.2-linux-aarch64.tar.gz',
      );
      expect(armCandidate['url'], 'https://aarch64');
    },
  );

  test(
    'normalizeSha256 strips sha256: prefix, lowercases and validates 64-hex',
    () {
      const hex =
          '496a27ff72014b883438efab55ffd237183b5ff95d9c341cc0de9d18342a9b11';
      expect(GithubComponentReleaseSource.normalizeSha256(null), '');
      expect(GithubComponentReleaseSource.normalizeSha256(''), '');
      expect(GithubComponentReleaseSource.normalizeSha256('   '), '');
      expect(GithubComponentReleaseSource.normalizeSha256(hex), hex);
      expect(GithubComponentReleaseSource.normalizeSha256('sha256:$hex'), hex);
      expect(
        GithubComponentReleaseSource.normalizeSha256(
          'SHA256:${hex.toUpperCase()}',
        ),
        hex,
      );
      expect(
        GithubComponentReleaseSource.normalizeSha256('  sha256:$hex  '),
        hex,
      );
      expect(
        GithubComponentReleaseSource.normalizeSha256('invalid-length'),
        '',
      );
      expect(GithubComponentReleaseSource.normalizeSha256('${hex}extra'), '');
      expect(GithubComponentReleaseSource.normalizeSha256('z' * 64), '');
    },
  );
}
