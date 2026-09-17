import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_mihomo_runtime/antirkn_mihomo_runtime.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final worker = File('../../build/mihomo/linux/antirkn-mihomo').absolute.path;
  Future<CoreConfigCheck> check(String yaml) => MihomoConfigValidator(
    workerPath: worker,
  ).validate(yaml, CancellationToken());
  for (final entry in <String, (String, CoreConfigStatus)>{
    'minimal': ('proxies: []\nrules: ["MATCH,DIRECT"]', CoreConfigStatus.valid),
    'enabled TUN and ports are parsed without applying them': (
      'mixed-port: 10993\ntun: {enable: true, auto-route: true}\nrules: ["MATCH,DIRECT"]',
      CoreConfigStatus.valid,
    ),
    'malformed YAML': ('proxies: [', CoreConfigStatus.invalid),
    'duplicate key': ('mode: rule\nmode: global', CoreConfigStatus.invalid),
    'aliases': ('proxies: &p []\nrules: *p', CoreConfigStatus.invalid),
    'bad rule': (
      'rules: ["SECRET-TEST-ONLY,credential,DIRECT"]',
      CoreConfigStatus.invalid,
    ),
    'unknown destination': (
      'rules: ["MATCH,MISSING"]',
      CoreConfigStatus.invalid,
    ),
    'missing provider file': (
      'rule-providers: {p: {type: file, path: ./missing.yaml, behavior: domain}}\nrules: ["RULE-SET,p,DIRECT"]',
      CoreConfigStatus.incomplete,
    ),
    'absolute provider path': (
      'rule-providers: {p: {type: file, path: /etc/passwd, behavior: domain}}',
      CoreConfigStatus.incomplete,
    ),
    'certificate path': (
      'tls: {certificate: /etc/passwd, private-key: /etc/passwd}',
      CoreConfigStatus.incomplete,
    ),
    'vless': (
      'proxies: [{name: test, type: vless, server: 192.0.2.1, port: 443, uuid: 00000000-0000-4000-8000-000000000001, tls: true}]',
      CoreConfigStatus.valid,
    ),
    'trusttunnel': (
      'proxies: [{name: test, type: trusttunnel, server: 192.0.2.1, port: 443, username: test, password: test-only}]',
      CoreConfigStatus.valid,
    ),
  }.entries) {
    test(entry.key, () async {
      final result = await check(entry.value.$1);
      expect(result.status, entry.value.$2, reason: result.toString());
      expect(
        result.profileHash,
        sha256.convert(utf8.encode(entry.value.$1)).toString(),
      );
      expect(result.toString(), isNot(contains('SECRET-TEST-ONLY')));
      expect(result.version, mihomoVersion);
    });
  }
  test('pre-cancelled request does not launch a missing worker', () async {
    final token = CancellationToken()..cancel();
    final result = await MihomoConfigValidator(
      workerPath: '/missing',
    ).validate('proxies: []', token);
    expect(result.status, CoreConfigStatus.cancelled);
  });
  test('missing runtime is a separate status', () async {
    final result = await MihomoConfigValidator(
      workerPath: '/missing',
    ).validate('proxies: []', CancellationToken());
    expect(result.status, CoreConfigStatus.unavailable);
  });
  test(
    'cancelling a hung worker terminates it and removes its private home',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'antirkn-worker-fixture-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final executable = File('${dir.path}/worker');
      final marker = File('${dir.path}/pid');
      await executable.writeAsString(
        '#!/bin/sh\nprintf "%s\\n%s\\n" "\$\$" "\$1" > "${marker.path}"\nexec /bin/sleep 30\n',
      );
      await Process.run('chmod', ['700', executable.path]);
      final token = CancellationToken();
      final work = MihomoConfigValidator(
        workerPath: executable.path,
      ).validate('proxies: []', token);
      for (var i = 0; i < 100 && !await marker.exists(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final lines = await marker.readAsLines();
      token.cancel();
      final result = await work.timeout(const Duration(seconds: 2));
      expect(result.status, CoreConfigStatus.cancelled);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await Directory('/proc/${lines.first}').exists(), isFalse);
      expect(await Directory(lines[1]).exists(), isFalse);
    },
  );
}
