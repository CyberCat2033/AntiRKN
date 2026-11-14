import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    GithubComponentReleaseSource.clearCache();
  });

  test('checks dynamic upstream releases including Mihomo when requested', () async {
    final queried = <String>[];
    final source = GithubComponentReleaseSource(
      metadata: (path) async {
        queried.add(path);
        if (path.endsWith('/tags')) {
          return [
            {'name': 'v3.1.20260828'},
            {'name': 'v3.1.20260812'},
          ];
        }
        if (path.contains('mihomo')) {
          return {
            'tag_name': 'v1.19.30',
            'draft': false,
            'prerelease': false,
          };
        }
        return {
          'tag_name': path.contains('Xray-core') ? 'v26.9.9' : 'v3.8.0',
          'draft': false,
          'prerelease': false,
        };
      },
    );

    final result = await source.check(true);
    expect(result.keys.toSet(), {
      'panel',
      'xray',
      'trusttunnel',
      'amneziawgTools',
      'amneziawg',
      'mihomo',
    });
    expect(result['mihomo'], '1.19.30');
    expect(result['xray'], '26.9.9');
    expect(queried, contains('MetaCubeX/mihomo/releases/latest'));
  });

  test('rejects prerelease, alpha, beta and draft releases', () async {
    final source = GithubComponentReleaseSource(
      metadata: (path) async {
        if (path.contains('Xray-core')) {
          return {
            'tag_name': 'v26.10.0-beta1',
            'draft': false,
            'prerelease': true,
          };
        }
        return {
          'tag_name': 'v3.8.0',
          'draft': false,
          'prerelease': false,
        };
      },
    );

    await expectLater(source.check(), throwsFormatException);
  });

  test('resolves release assets dynamically for host architectures (x86_64 vs aarch64)', () async {
    final source = GithubComponentReleaseSource(
      metadata: (path) async {
        if (path.contains('Xray-core/releases/tags/v26.9.9')) {
          return {
            'tag_name': 'v26.9.9',
            'draft': false,
            'prerelease': false,
            'assets': [
              {
                'name': 'Xray-linux-64.zip',
                'browser_download_url': 'https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-linux-64.zip',
                'size': 21356337,
                'digest': '1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df',
              },
              {
                'name': 'Xray-linux-arm64-v8a.zip',
                'browser_download_url': 'https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-linux-arm64-v8a.zip',
                'size': 19800000,
                'digest': '2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b',
              },
            ],
          };
        }
        return null;
      },
    );

    final assetX64 = await source.resolveAsset(
      component: 'xray',
      version: '26.9.9',
      architecture: 'x86_64',
    );
    expect(assetX64, isNotNull);
    expect(assetX64!['assetName'], 'Xray-linux-64.zip');
    expect(assetX64['sha256'], '1eb9175d0f0a8f8149c9230a7fc5ae66ce332ed20a53155ce61fe62e3f58b7df');

    final assetArm64 = await source.resolveAsset(
      component: 'xray',
      version: '26.9.9',
      architecture: 'aarch64',
    );
    expect(assetArm64, isNotNull);
    expect(assetArm64!['assetName'], 'Xray-linux-arm64-v8a.zip');
  });
}
