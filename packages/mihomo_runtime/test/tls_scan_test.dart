import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_mihomo_runtime/antirkn_mihomo_runtime.dart';
import 'package:antirkn_mihomo_runtime/src/tls_scan_result.dart';
import 'package:flutter_test/flutter_test.dart';

const revision = 'ac017cdd246ce8bd547653d927e7bf77d7ee73d5';

Map<String, dynamic> probe({
  String ip = '8.8.8.8',
  String sni = 'dns.google',
  Map<String, Object?> extra = const {},
}) => {
  'ip': ip,
  'port': 443,
  'sni': sni,
  'reach': 'ok',
  'tls': 'ok',
  'tcpMs': 21,
  'tlsMs': 48,
  'version': '1.3',
  'alpn': 'h2',
  'group': 'X25519MLKEM768',
  'dns': 'match',
  'certificate': {
    'names': ['dns.google', '*.dns.google.com'],
    'namesTotal': 12,
    'commonName': 'dns.google',
    'issuer': 'Google Trust Services',
    'notBefore': 1760000000,
    'notAfter': 1770000000,
    'verify': 'valid',
  },
  ...extra,
};

Map<String, dynamic> answer(List<Object?> probes) => {
  'status': 'ok',
  'code': 'scanned',
  'probes': probes,
  'version': mihomoVersion,
  'revision': revision,
};

void main() {
  final google = TlsScanTarget('8.8.8.8', 443, sni: 'dns.google');

  group('targets and limits', () {
    test('accept one public address with a concrete SNI', () {
      expect(google.toJson(), {
        'ip': '8.8.8.8',
        'port': 443,
        'sni': 'dns.google',
      });
      expect(TlsScanTarget('2606:4700:4700::1111', 443).sni, '');
      expect(TlsScanTarget('8.8.8.8', 443, sni: 'dns.google'), google);
    });
    for (final (ip, port, sni) in [
      ('10.0.0.1', 443, ''),
      ('127.0.0.1', 443, ''),
      ('203.0.113.9', 443, ''),
      ('fe80::1', 443, ''),
      ('dns.google', 443, ''),
      ('8.8.8.8', 0, ''),
      ('8.8.8.8', 443, '*.google'),
      ('8.8.8.8', 443, 'DNS.google'),
      ('8.8.8.8', 443, '8.8.4.4'),
      ('8.8.8.8', 443, 'bad_name.example'),
    ]) {
      test('reject $ip:$port "$sni"', () {
        expect(
          () => TlsScanTarget(ip, port, sni: sni),
          throwsA(isA<FormatException>()),
        );
      });
    }
    test('batch size keeps the worst case inside the worker budget', () {
      expect(const TlsScanLimits().batchSize, 16);
      expect(const TlsScanLimits(concurrency: 4).batchSize, 8);
      expect(
        const TlsScanLimits(
          concurrency: 2,
          connect: Duration(seconds: 3),
          handshake: Duration(seconds: 5),
        ).batchSize,
        2,
      );
      expect(const TlsScanLimits(concurrency: 0).batchSize, 0);
      expect(
        const TlsScanLimits(connect: Duration(milliseconds: 100)).batchSize,
        0,
      );
    });
  });

  group('worker answer', () {
    test('maps a full observation', () {
      final batch = parseTlsScan(answer([probe()]), [google]);
      expect(batch.status, TlsScanStatus.scanned);
      final p = batch.probes.single;
      expect(p.reach, TlsReach.ok);
      expect(p.handshake, TlsHandshake.ok);
      expect(p.tls, const Duration(milliseconds: 48));
      expect((p.version, p.alpn, p.group), ('1.3', 'h2', 'X25519MLKEM768'));
      expect(p.dns, TlsDnsCheck.match);
      expect(p.certificate!.check, TlsCertificateCheck.valid);
      expect(p.certificate!.names, ['dns.google', '*.dns.google.com']);
      expect(p.certificate!.namesTotal, 12);
      expect(p.certificate!.notAfter.isUtc, isTrue);
    });
    test('maps a refused address and a worker refusal', () {
      final refused = parseTlsScan(
        answer([
          probe(
            extra: {
              'reach': 'refused',
              'tls': '',
              'version': '',
              'alpn': '',
              'group': '',
              'certificate': null,
              'dns': 'mismatch',
            },
          ),
        ]),
        [google],
      ).probes.single;
      expect(refused.reach, TlsReach.refused);
      expect(refused.handshake, TlsHandshake.none);
      expect(refused.certificate, isNull);
      expect(refused.dns, TlsDnsCheck.mismatch);
      final denied = parseTlsScan(
        {
          'status': 'not_tested',
          'code': 'private_target',
          'probes': <Object?>[],
        },
        [google],
      );
      expect(denied.status, TlsScanStatus.notTested);
      expect(denied.code, 'private_target');
    });
    for (final (name, json) in [
      ('another target', answer([probe(ip: '8.8.4.4')])),
      ('missing probe', answer([])),
      (
        'unknown reach',
        answer([
          probe(extra: {'reach': 'maybe'}),
        ]),
      ),
      (
        'TLS without TCP',
        answer([
          probe(extra: {'reach': 'timeout'}),
        ]),
      ),
      (
        'version without TLS',
        answer([
          probe(extra: {'tls': 'reset'}),
        ]),
      ),
      (
        'certificate without TLS',
        answer([
          probe(extra: {'tls': 'alert', 'version': ''}),
        ]),
      ),
      (
        'unknown group',
        answer([
          probe(extra: {'group': 'X448'}),
        ]),
      ),
      (
        'negative time',
        answer([
          probe(extra: {'tcpMs': -1}),
        ]),
      ),
      (
        'chain-only with SNI',
        answer([
          probe(
            extra: {
              'certificate': {
                ...probe()['certificate'] as Map,
                'verify': 'chain_only',
              },
            },
          ),
        ]),
      ),
      (
        'too many names',
        answer([
          probe(
            extra: {
              'certificate': {
                ...probe()['certificate'] as Map,
                'names': List.filled(9, 'a.example'),
              },
            },
          ),
        ]),
      ),
      (
        'control character in a hint',
        answer([
          probe(
            extra: {
              'certificate': {
                ...probe()['certificate'] as Map,
                'issuer': 'a\nb',
              },
            },
          ),
        ]),
      ),
      (
        'refusal with probes',
        {
          'status': 'not_tested',
          'code': 'input_limit',
          'probes': [probe()],
        },
      ),
      (
        'unknown refusal',
        {'status': 'not_tested', 'code': 'secret text', 'probes': <Object?>[]},
      ),
    ]) {
      test('rejects $name', () {
        expect(
          () => parseTlsScan(json, [google]),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });

  group('scanner', () {
    late Directory dir;
    setUp(
      () async => dir = await Directory.systemTemp.createTemp('antirkn-tls-'),
    );
    tearDown(() => dir.delete(recursive: true));

    Future<String> fake(String output, {bool hang = false}) async {
      final data = File('${dir.path}/answer.json')..writeAsStringSync(output);
      final script = File('${dir.path}/worker')
        ..writeAsStringSync(
          '#!/bin/sh\ncat > "${dir.path}/request.json"\n'
          '${hang ? 'exec /bin/sleep 30\n' : 'cat "${data.path}"\n'}',
        );
      await Process.run('chmod', ['700', script.path]);
      return script.path;
    }

    test('sends a bounded request and reads the answer', () async {
      final batch = await MihomoTlsScanner(
        workerPath: await fake(jsonEncode(answer([probe()]))),
      ).scan([google], CancellationToken(), directInterface: 'wlan0');
      expect(batch.status, TlsScanStatus.scanned);
      expect(jsonDecode(File('${dir.path}/request.json').readAsStringSync()), {
        'mode': 'tls_scan',
        'targets': [google.toJson()],
        'concurrency': 10,
        'connectMs': 1500,
        'handshakeMs': 3000,
        'resolve': true,
        'interface': 'wlan0',
      });
    });
    test(
      'accepts observations passed as JSON text by the Android bridge',
      () async {
        final json = answer([])..['probes'] = jsonEncode([probe()]);
        final batch = await MihomoTlsScanner(
          workerPath: await fake(jsonEncode(json)),
        ).scan([google], CancellationToken());
        expect(
          batch.probes.single.certificate!.issuer,
          'Google Trust Services',
        );
      },
    );
    test('another core build is unavailable, not a result', () async {
      final batch = await MihomoTlsScanner(
        workerPath: await fake(
          jsonEncode(answer([probe()])..['revision'] = 'x'),
        ),
      ).scan([google], CancellationToken());
      expect(
        (batch.status, batch.code),
        (TlsScanStatus.notTested, 'runtime_unavailable'),
      );
      expect(batch.probes, isEmpty);
    });
    test('an oversized or repeated batch never starts the worker', () async {
      final scanner = MihomoTlsScanner(workerPath: '/missing');
      final many = [
        for (var i = 1; i <= 17; i++) TlsScanTarget('8.8.4.$i', 443),
      ];
      for (final targets in [
        <TlsScanTarget>[],
        many,
        [google, google],
      ]) {
        final batch = await scanner.scan(targets, CancellationToken());
        expect(batch.code, 'input_limit');
      }
    });
    test('cancelling a running batch discards it', () async {
      final token = CancellationToken();
      final work = MihomoTlsScanner(
        workerPath: await fake('', hang: true),
      ).scan([google], token);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      token.cancel();
      final batch = await work.timeout(const Duration(seconds: 2));
      expect(
        (batch.status, batch.code),
        (TlsScanStatus.cancelled, 'cancelled'),
      );
    });
    final worker = File('../../build/mihomo/linux/antirkn-mihomo').absolute;
    test(
      'packaged worker answers with one observation per target',
      () async {
        final targets = [google, TlsScanTarget('1.1.1.1', 443)];
        final batch = await MihomoTlsScanner(
          workerPath: worker.path,
        ).scan(targets, CancellationToken());
        expect(batch.status, TlsScanStatus.scanned);
        expect(batch.probes.map((p) => p.target), targets);
        // Offline sandboxes fail at TCP; online hosts observe TLS 1.3.
        for (final p in batch.probes) {
          expect(p.handshake == TlsHandshake.none, p.reach != TlsReach.ok);
        }
      },
      skip: worker.existsSync() ? false : 'build the Linux worker first',
    );
  });
}
