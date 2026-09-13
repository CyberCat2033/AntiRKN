import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/src/ubuntu_release.dart';
import 'package:test/test.dart';

void main() {
  for (final version in [
    '20.04',
    '22.04',
    '24.04',
    '25.10',
    '26.04',
    'rolling',
  ]) {
    test('Ubuntu $version is accepted and reports its actual version', () {
      expect(
        ubuntuNameFromOsRelease('ID=ubuntu\nVERSION_ID="$version"\n'),
        'Ubuntu $version',
      );
    });
  }

  test('Ubuntu does not require version metadata', () {
    for (final version in ['', 'VERSION_ID=""', 'VERSION_ID="invalid value"']) {
      expect(ubuntuNameFromOsRelease('ID=ubuntu\n$version\n'), 'Ubuntu');
    }
  });

  test('quoted distribution identifiers are accepted', () {
    for (final id in ['"ubuntu"', "'ubuntu'"]) {
      expect(ubuntuNameFromOsRelease('ID=$id\n'), 'Ubuntu');
    }
  });

  test('other distributions and ambiguous identifiers are rejected', () {
    for (final source in [
      'ID=debian\nVERSION_ID=24.04',
      'ID=linuxmint\nID_LIKE=ubuntu',
      'NAME=Ubuntu\nVERSION_ID=24.04',
      'ID=ubuntu\nID=debian',
      '',
    ]) {
      expect(
        () => ubuntuNameFromOsRelease(source),
        throwsA(
          isA<SshFailure>().having(
            (error) => error.issue,
            'issue',
            SshIssue.unsupportedOs,
          ),
        ),
      );
    }
  });
}
