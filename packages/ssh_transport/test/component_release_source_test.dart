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
}
