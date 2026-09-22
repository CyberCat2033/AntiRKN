import 'dart:convert';

import 'package:antirkn_ssh_transport/src/runner_bundle.g.dart';
import 'package:test/test.dart';

void main() {
  test('runner install payload formats valid JSON containing bundle and fingerprint', () {
    const fingerprint = 'test-runner-fingerprint-12345';
    final payload = '{"fingerprint":${jsonEncode(fingerprint)},"bundle":$runnerBundle}';

    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    expect(decoded['fingerprint'], equals(fingerprint));
    expect(decoded['bundle'], isA<Map<String, dynamic>>());

    final bundle = decoded['bundle'] as Map<String, dynamic>;
    expect(bundle['release'], equals(runnerRelease));
    expect(bundle['files'], isA<Map<String, dynamic>>());
    expect(bundle['hashes'], isA<Map<String, dynamic>>());
    expect((bundle['files'] as Map).keys, contains('antirkn-runner.service'));
  });
}
