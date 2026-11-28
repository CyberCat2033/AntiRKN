import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';
import 'src/native_worker.dart';
import 'src/tls_scan_result.dart';

export 'src/worker_gate.dart' show MihomoWorkerGate;

const mihomoVersion = '1.19.34';
const _revision = 'ac017cdd246ce8bd547653d927e7bf77d7ee73d5';

/// A worker handles one request, then exits. No user config is ever executed.
final class MihomoConfigValidator implements CoreConfigValidator {
  MihomoConfigValidator({this.workerPath});
  final String? workerPath;
  final _cache = <String, ({Uint8List bytes, DateTime at})>{};
  static const int _maxConcurrentValidations = 4;
  int _activeCount = 0;
  final _waitQueue = <Completer<void>>[];

  @override
  Future<CoreConfigCheck> validate(
    String yaml,
    CancellationToken cancellation,
  ) async {
    final hash = yaml.length > 65536
        ? await Isolate.run(() => sha256.convert(utf8.encode(yaml)).toString())
        : sha256.convert(utf8.encode(yaml)).toString();
    CoreConfigCheck outcome(CoreConfigStatus status, String code) =>
        CoreConfigCheck(
          status: status,
          code: code,
          profileHash: hash,
          checkedAt: DateTime.now().toUtc(),
        );
    if (cancellation.isCancelled) {
      return outcome(CoreConfigStatus.cancelled, 'cancelled');
    }
    if (utf8.encode(yaml).length > 4 * 1024 * 1024) {
      return outcome(CoreConfigStatus.incomplete, 'input_limit');
    }
    if (_activeCount >= _maxConcurrentValidations) {
      if (_waitQueue.length >= 32) {
        return outcome(CoreConfigStatus.unavailable, 'busy');
      }
      final completer = Completer<void>();
      _waitQueue.add(completer);
      try {
        await cancellation.bind(
          completer.future.timeout(const Duration(seconds: 30)),
        );
      } on TimeoutException {
        _waitQueue.remove(completer);
        return outcome(CoreConfigStatus.unavailable, 'busy');
      } catch (_) {
        _waitQueue.remove(completer);
        return outcome(CoreConfigStatus.cancelled, 'cancelled');
      }
    }
    _activeCount++;
    final worker = NativeWorker(path: workerPath);
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final deadline = Timer(const Duration(seconds: 35), cancellation.cancel);
    try {
      cancellation.check();
      var response = await worker.invoke({'yaml': yaml}, cancellation);
      if (response['code'] == 'provider_content' && !cancellation.isCancelled) {
        final resources = await cancellation.bind(
          _resources(yaml, http, cancellation),
        );
        if (resources.isNotEmpty) {
          response = await worker.invoke({
            'yaml': yaml,
            'resources': resources,
          }, cancellation);
        }
      }
      cancellation.check();
      if (response['hash'] != hash ||
          response['version'] != mihomoVersion ||
          response['revision'] != _revision) {
        throw const FormatException('worker_result');
      }
      final status = switch (response['status']) {
        'valid' => CoreConfigStatus.valid,
        'invalid' => CoreConfigStatus.invalid,
        'incomplete' => CoreConfigStatus.incomplete,
        _ => throw const FormatException('worker_result'),
      };
      const codes = {
        'valid',
        'invalid_yaml',
        'unsupported_yaml',
        'input_limit',
        'core_failure',
        'isolation_unavailable',
        'external_dependency',
        'core_rejected',
        'provider_content',
        'provider_rejected',
      };
      final code = response['code'];
      if (code is! String || !codes.contains(code)) {
        throw const FormatException('worker_result');
      }
      final path = response['path'];
      return CoreConfigCheck(
        status: status,
        code: code,
        profileHash: hash,
        checkedAt: DateTime.now().toUtc(),
        version: mihomoVersion,
        resourcesHash: response['resourcesHash'] as String? ?? '',
        path:
            path is String &&
                RegExp(
                  r'^(proxies|proxy-groups|rules|listeners)(\[\d{1,5}\])?$|^(rule-providers|proxy-providers|providers|tls)$',
                ).hasMatch(path)
            ? path
            : null,
      );
    } catch (_) {
      return outcome(
        cancellation.isCancelled
            ? CoreConfigStatus.cancelled
            : CoreConfigStatus.unavailable,
        cancellation.isCancelled ? 'cancelled' : 'runtime_unavailable',
      );
    } finally {
      deadline.cancel();
      http.close(force: true);
      _activeCount--;
      if (_waitQueue.isNotEmpty) {
        _waitQueue.removeAt(0).complete();
      }
    }
  }

  Future<Map<String, String>> _resources(
    String source,
    HttpClient client,
    CancellationToken token,
  ) async {
    final result = <String, String>{};
    final candidates = await Isolate.run(() => _parseHttpRuleProviders(source));
    token.check();
    var bytes = 0;
    for (final entry in candidates.entries) {
      token.check();
      final url = entry.value;
      var uri = Uri.parse(url);
      try {
        final old = _cache[url];
        Uint8List data;
        if (old != null &&
            DateTime.now().difference(old.at) < const Duration(minutes: 5)) {
          data = old.bytes;
        } else {
          HttpClientResponse? response;
          for (var redirect = 0; redirect < 4; redirect++) {
            final request = await token.bind(client.getUrl(uri));
            request.followRedirects = false;
            request.headers.set(
              HttpHeaders.userAgentHeader,
              'AntiRKN config-check',
            );
            response = await token.bind(
              request.close().timeout(const Duration(seconds: 8)),
            );
            if (!response!.isRedirect) break;
            final location = response.headers.value(HttpHeaders.locationHeader);
            await response.drain<void>();
            if (location == null) {
              throw const FormatException('resource_redirect');
            }
            uri = uri.resolve(location);
            if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
              throw const FormatException('resource_redirect');
            }
          }
          if (response?.statusCode != 200) {
            throw const FormatException('resource_http');
          }
          data = await token.bind(
            readLimited(
              response!,
              4 * 1024 * 1024,
            ).timeout(const Duration(seconds: 8)),
          );
          final cachedBytes = _cache.values.fold<int>(
            0,
            (a, b) => a + b.bytes.length,
          );
          if (cachedBytes + data.length > 8 * 1024 * 1024) _cache.clear();
          _cache[url] = (bytes: data, at: DateTime.now());
        }
        if (bytes + data.length > 8 * 1024 * 1024) break;
        bytes += data.length;
        result[entry.key] = base64Encode(data);
      } catch (_) {
        token.check(); /* The worker reports missing content. */
      }
    }
    return result;
  }
}

/// Uses the packaged worker's direct adapter API: no config activation or TUN.
final class MihomoOutboundProbe implements CoreProbeTransport {
  MihomoOutboundProbe({this.workerPath});
  final String? workerPath;
  @override
  Future<CoreTrafficCheck> probe(
    Map<String, Object?>? proxy,
    CancellationToken token, {
    required bool udp,
    String directInterface = '',
  }) async {
    try {
      final source = jsonEncode(proxy ?? <String, Object?>{});
      final hash = sha256.convert(utf8.encode(source)).toString();
      final result = await NativeWorker(path: workerPath).invoke({
        'mode': proxy == null ? 'control' : 'probe',
        'yaml': source,
        'udp': udp,
        if (directInterface.isNotEmpty) 'interface': directInterface,
      }, token);
      if (result['hash'] != hash ||
          result['version'] != mihomoVersion ||
          result['revision'] != _revision) {
        throw const FormatException('worker_result');
      }
      const codes = {
        'connected',
        'connection_failed',
        'udp_unsupported',
        'unsupported',
        'unsupported_route',
        'invalid_proxy',
        'input_limit',
        'timeout',
      };
      final code = result['code'];
      if (code is! String || !codes.contains(code)) {
        throw const FormatException('worker_result');
      }
      return CoreTrafficCheck(
        status: switch (result['status']) {
          'success' => CoreTrafficStatus.success,
          'failed' => CoreTrafficStatus.failed,
          'not_tested' => CoreTrafficStatus.notTested,
          _ => throw const FormatException('worker_result'),
        },
        code: code,
        tcp: result['tcp'] == true,
        udp: result['udp'] == true,
        udpTested: result['udpTested'] == true,
        milliseconds: (result['milliseconds'] as int? ?? 0).clamp(0, 60000),
        endpoint: switch (result['endpoint']) {
          final String value
              when const {
                'reachable',
                'refused',
                'timeout',
                'unreachable',
                'unresolved',
              }.contains(value) =>
            value,
          _ => '',
        },
      );
    } catch (_) {
      return CoreTrafficCheck(
        status: token.isCancelled
            ? CoreTrafficStatus.cancelled
            : CoreTrafficStatus.notTested,
        code: token.isCancelled ? 'cancelled' : 'runtime_unavailable',
      );
    }
  }
}

/// FR-SNI engine: one packaged worker run per batch on Windows, Linux and
/// Android. A cancelled run is killed; its observations are discarded.
final class MihomoTlsScanner implements TlsScanTransport {
  MihomoTlsScanner({this.workerPath});
  final String? workerPath;
  @override
  Future<TlsScanBatch> scan(
    List<TlsScanTarget> targets,
    CancellationToken token, {
    TlsScanLimits limits = const TlsScanLimits(),
    bool resolve = true,
    String directInterface = '',
  }) async {
    if (targets.isEmpty ||
        targets.length > limits.batchSize ||
        targets.toSet().length != targets.length) {
      return TlsScanBatch(status: TlsScanStatus.notTested, code: 'input_limit');
    }
    try {
      var result = await NativeWorker(path: workerPath).invoke(
        {
          'mode': 'tls_scan',
          'targets': [for (final t in targets) t.toJson()],
          'concurrency': limits.concurrency,
          'connectMs': limits.connect.inMilliseconds,
          'handshakeMs': limits.handshake.inMilliseconds,
          'resolve': resolve,
          if (directInterface.isNotEmpty) 'interface': directInterface,
        },
        token,
        outputLimit: 65536,
      );
      if (result['version'] != mihomoVersion ||
          result['revision'] != _revision) {
        throw const FormatException('worker_result');
      }
      // The Android bridge passes the observations as JSON text.
      if (result['probes'] case final String text) {
        result = {...result, 'probes': jsonDecode(text)};
      }
      return parseTlsScan(result, targets);
    } catch (_) {
      return TlsScanBatch(
        status: token.isCancelled
            ? TlsScanStatus.cancelled
            : TlsScanStatus.notTested,
        code: token.isCancelled ? 'cancelled' : 'runtime_unavailable',
      );
    }
  }
}

Map<String, String> _parseHttpRuleProviders(String source) {
  final result = <String, String>{};
  final root = loadYaml(source);
  if (root is! Map || root['rule-providers'] is! Map) return result;
  final providers = (root['rule-providers'] as Map).entries.take(16);
  for (final entry in providers) {
    final value = entry.value;
    if (entry.key is! String ||
        value is! Map ||
        value['type'] != 'http' ||
        value['header'] != null ||
        value['proxy'] != null) {
      continue;
    }
    final url = value['url'];
    if (url is! String) continue;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      continue;
    }
    result[entry.key as String] = url;
  }
  return result;
}
