// Uses only public, deliberately non-operational compiler fixtures.
import 'dart:convert';
import 'dart:io';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:yaml/yaml.dart';
import '../packages/profile_compiler/test/support/fixtures.dart';

Future<void> main(List<String> args) async {
  final worker = File('build/mihomo/linux/antirkn-mihomo').absolute.path;
  final base = File('base.yml').readAsStringSync();
  final resources = <String, String>{};
  if (args.contains('--download')) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      for (final entry
          in ((loadYaml(base) as Map)['rule-providers'] as Map).entries) {
        final request = await client.getUrl(
          Uri.parse(entry.value['url'] as String),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        if (response.statusCode != 200) throw StateError('fixture_dependency');
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 10),
        )) {
          if (bytes.length + chunk.length > 4 * 1024 * 1024) {
            throw StateError('fixture_limit');
          }
          bytes.addAll(chunk);
        }
        resources[entry.key as String] = base64Encode(bytes);
      }
    } finally {
      client.close(force: true);
    }
  }
  Future<Map<String, dynamic>> invoke(
    String yaml,
    Map<String, String> data,
  ) async {
    final dir = await Directory.systemTemp.createTemp('antirkn-core-fixture-');
    try {
      final process = await Process.start(worker, [
        dir.path,
      ], includeParentEnvironment: false);
      final stdout = utf8.decoder.bind(process.stdout).join();
      final stderr = utf8.decoder.bind(process.stderr).join();
      process.stdin.write(jsonEncode({'yaml': yaml, 'resources': data}));
      await process.stdin.close();
      final result = jsonDecode(await stdout) as Map<String, dynamic>;
      if (await process.exitCode != 0 || (await stderr).isNotEmpty) {
        throw StateError('worker_output');
      }
      return result;
    } finally {
      await dir.delete(recursive: true);
    }
  }

  final checks = <String, Object?>{};
  for (final entry in fixtureVariants().entries) {
    final profile = const ProfileCompiler().compile(
      template: base,
      userId: 'user-a',
      accesses: entry.value,
    );
    if (profile.hasBlockingErrors || profile.yaml == null) {
      throw StateError('compiler_fixture');
    }
    final result = await invoke(profile.yaml!, resources);
    if (result['hash'] != profile.sha256Hash ||
        result['status'] != (resources.isEmpty ? 'incomplete' : 'valid')) {
      throw StateError(
        'fixture_${entry.key}_${result['status']}_${result['code']}',
      );
    }
    checks[entry.key] = result;
  }
  const yaml =
      'rule-providers: {p: {type: http, path: ./p.yaml, url: "https://example.com/p.yaml", behavior: classical}}\nrules: ["RULE-SET,p,DIRECT"]';
  final good = await invoke(yaml, {
    'p': base64Encode(utf8.encode('payload:\n  - DOMAIN,example.com\n')),
  });
  final bad = await invoke(yaml, {
    'p': base64Encode(utf8.encode('payload: [')),
  });
  if (good['status'] != 'valid' || bad['status'] != 'invalid') {
    throw StateError('provider_fixture');
  }
  checks['provider_valid'] = good;
  checks['provider_invalid'] = bad;
  final file = File('docs/evidence/mihomo-config-checks.json');
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({'downloadedRuleSnapshots': resources.length, 'checks': checks})}\n',
  );
  stdout.writeln('${checks.length} native compiler/provider checks passed');
}
