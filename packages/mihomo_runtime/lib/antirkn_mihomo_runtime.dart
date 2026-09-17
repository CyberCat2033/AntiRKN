import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

const mihomoVersion = '1.19.30';
const _revision = 'ac017cdd246ce8bd547653d927e7bf77d7ee73d5';

/// A worker handles one request, then exits. No user config is ever executed.
final class MihomoConfigValidator implements CoreConfigValidator {
  MihomoConfigValidator({this.workerPath});
  final String? workerPath;
  static const _channel = MethodChannel('org.antirkn/mihomo');
  final _cache = <String, ({Uint8List bytes, DateTime at})>{};
  bool _busy = false;

  @override
  Future<CoreConfigCheck> validate(
    String yaml,
    CancellationToken cancellation,
  ) async {
    final hash = sha256.convert(utf8.encode(yaml)).toString();
    CoreConfigCheck outcome(CoreConfigStatus status, String code) =>
        CoreConfigCheck(
          status: status,
          code: code,
          profileHash: hash,
          checkedAt: DateTime.now().toUtc(),
        );
    if (_busy) return outcome(CoreConfigStatus.unavailable, 'busy');
    if (utf8.encode(yaml).length > 4 * 1024 * 1024) {
      return outcome(CoreConfigStatus.incomplete, 'input_limit');
    }
    _busy = true;
    Process? process;
    Directory? directory;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final deadline = Timer(const Duration(seconds: 35), cancellation.cancel);
    try {
      cancellation.check();
      // The native parser first checks the exact YAML. Fetch dependencies only
      // when it explicitly reports valid provider definitions with missing data.
      Future<Map<String, dynamic>> invoke(Map<String, Object?> request) async {
        cancellation.check();
        if (Platform.isAndroid) {
          directory ??= await (await getTemporaryDirectory()).createTemp(
            'mihomo-',
          );
          final input = File('${directory!.path}/request.json');
          await input.writeAsString(jsonEncode(request), flush: true);
          final result = await cancellation.bind(
            _channel.invokeMapMethod<String, dynamic>('validate', {
              'id': id,
              'path': input.path,
            }),
          );
          if (result == null) throw const FormatException('worker_result');
          return result;
        }
        if (!Platform.isLinux && !Platform.isWindows) {
          throw UnsupportedError('platform');
        }
        directory ??= await Directory.systemTemp.createTemp('antirkn-mihomo-');
        final exe =
            workerPath ??
            '${File(Platform.resolvedExecutable).parent.path}'
                '${Platform.isWindows ? '/antirkn-mihomo.exe' : '/lib/antirkn-mihomo'}';
        process = await Process.start(
          exe,
          [directory!.path],
          workingDirectory: directory!.path,
          includeParentEnvironment: false,
          environment: {
            'GOMEMLIMIT': '192MiB',
            if (Platform.isWindows)
              'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
          },
        );
        final output = _limited(process!.stdout, 16384);
        // Drain without retaining potentially sensitive upstream diagnostics.
        final errors = process!.stderr.drain<void>();
        final work = () async {
          process!.stdin.add(utf8.encode(jsonEncode(request)));
          await process!.stdin.close();
          final bytes = await output;
          final exit = await process!.exitCode;
          await errors;
          if (exit != 0) throw const FormatException('worker_failed');
          return Map<String, dynamic>.from(
            jsonDecode(utf8.decode(bytes)) as Map,
          );
        }();
        try {
          return await cancellation.bind(work);
        } finally {
          process?.kill(ProcessSignal.sigkill);
        }
      }

      var response = await invoke({'yaml': yaml});
      if (response['code'] == 'provider_content' && !cancellation.isCancelled) {
        final resources = await cancellation.bind(
          _resources(yaml, http, cancellation),
        );
        if (resources.isNotEmpty) {
          response = await invoke({'yaml': yaml, 'resources': resources});
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
      process?.kill(ProcessSignal.sigkill);
      if (Platform.isAndroid) {
        try {
          await _channel.invokeMethod<void>('cancel', {'id': id});
        } catch (_) {
          /* Host may be gone. */
        }
      }
      try {
        await directory?.delete(recursive: true);
      } catch (_) {
        /* App cache cleanup on next host start. */
      }
      _busy = false;
    }
  }

  Future<Map<String, String>> _resources(
    String source,
    HttpClient client,
    CancellationToken token,
  ) async {
    final result = <String, String>{};
    final root = loadYaml(source);
    if (root is! Map || root['rule-providers'] is! Map) return result;
    var bytes = 0;
    final providers = (root['rule-providers'] as Map).entries.take(16);
    for (final entry in providers) {
      token.check();
      final value = entry.value;
      // Local files, authenticated sources and proxy-routed resources require
      // their original environment; never invent an empty replacement.
      if (entry.key is! String ||
          value is! Map ||
          value['type'] != 'http' ||
          value['header'] != null ||
          value['proxy'] != null) {
        continue;
      }
      final url = value['url'];
      if (url is! String) continue;
      var uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        continue;
      }
      try {
        final old = _cache[url];
        Uint8List data;
        if (old != null &&
            DateTime.now().difference(old.at) < const Duration(minutes: 5)) {
          data = old.bytes;
        } else {
          HttpClientResponse? response;
          for (var redirect = 0; redirect < 4; redirect++) {
            final request = await token.bind(client.getUrl(uri!));
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
            _limited(
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
        result[entry.key as String] = base64Encode(data);
      } catch (_) {
        token.check(); /* The worker reports missing content. */
      }
    }
    return result;
  }
}

Future<Uint8List> _limited(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final part in stream) {
    if (bytes.length + part.length > limit) {
      throw const FormatException('output_limit');
    }
    bytes.add(part);
  }
  return bytes.takeBytes();
}
