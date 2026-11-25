import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/src/runner_bundle.g.dart';
import 'package:test/test.dart';

void main() {
  test('upgrade requests the app sends pass the runner contract', () {
    // The confirmation was declared with its fields but missing from the
    // action enum: the server rejected every confirmation as invalid and
    // rolled each successful upgrade back after the window.
    expect(
      RunnerRequest.componentUpgradeConfirm('a' * 32).json['action'],
      'component_upgrade_confirm',
    );
    expect(
      RunnerRequest.componentUpgradeCheck('xray').json['action'],
      'component_upgrade_check',
    );
  });

  test(
    'runner install payload formats valid JSON containing bundle and fingerprint',
    () {
      const fingerprint = 'test-runner-fingerprint-12345';
      final payload =
          '{"fingerprint":${jsonEncode(fingerprint)},"bundle":$runnerBundle}';

      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      expect(decoded['fingerprint'], equals(fingerprint));
      expect(decoded['bundle'], isA<Map<String, dynamic>>());

      final bundle = decoded['bundle'] as Map<String, dynamic>;
      expect(bundle['release'], equals(runnerRelease));
      expect(bundle['files'], isA<Map<String, dynamic>>());
      expect(bundle['hashes'], isA<Map<String, dynamic>>());
      expect((bundle['files'] as Map).keys, contains('antirkn-runner.service'));
    },
  );

  group('decodeRunnerObject sanitization and noise immunity', () {
    test('extracts clean JSON dictionary without noise', () {
      final res = decodeRunnerObject('{"version":51,"code":"ok","alive":true}');
      expect(res['version'], 51);
      expect(res['code'], 'ok');
      expect(res['alive'], isTrue);
    });

    test('extracts JSON when preceded by pam_systemd error', () {
      const noisy =
          'pam_systemd(sshd:session): Failed to release session: Interrupted system call\n'
          '{"version":51,"code":"ok","alive":true,"jobs":[]}';
      final res = decodeRunnerObject(noisy);
      expect(res['code'], 'ok');
      expect(res['version'], 51);
    });

    test('extracts JSON when preceded by sudo password prompt', () {
      const noisy =
          '[sudo] password for user:\n'
          '{"version":51,"code":"ok","alive":false,"jobs":[]}';
      final res = decodeRunnerObject(noisy);
      expect(res['code'], 'ok');
      expect(res['alive'], isFalse);
    });

    test('extracts JSON when preceded by apt warnings and python warnings', () {
      const noisy =
          'Warning: apt-key is deprecated. Manage keyring files in trusted.gpg.d instead.\n'
          'sys:1: ResourceWarning: Implicitly cleaning up <HTTPError 404: Not Found>\n'
          '{"version":51,"code":"ok","alive":true,"jobs":[{"id":"job1","status":"running"}]}';
      final res = decodeRunnerObject(noisy);
      expect(res['code'], 'ok');
      expect(res['jobs'], hasLength(1));
    });

    test(
      'extracts JSON when noise surrounds it with curly braces and ANSI escapes',
      () {
        const noisy =
            '\x1B[0;32mSystem message: {warning: kernel tainted}\x1B[0m\r\n'
            '{"version":51,"code":"ok","alive":true}\r\n'
            'Connection to 127.0.0.1 closed by remote host.\n';
        final res = decodeRunnerObject(noisy);
        expect(res['code'], 'ok');
        expect(res['version'], 51);
      },
    );

    test('throws FormatException on entirely invalid garbage without json', () {
      expect(
        () => decodeRunnerObject('Fatal: kernel panic - not syncing'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
