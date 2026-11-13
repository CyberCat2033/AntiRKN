import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The child handles exactly one private request and is gone before returning.
final class NativeWorker {
  NativeWorker({this.path});
  final String? path;
  static const channel = MethodChannel('org.antirkn/mihomo');
  Future<Map<String, dynamic>> invoke(
    Map<String, Object?> request,
    CancellationToken token,
  ) async {
    Process? process;
    Directory? directory;
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    try {
      token.check();
      if (Platform.isAndroid) {
        directory = await (await getTemporaryDirectory()).createTemp('mihomo-');
        final input = File('${directory.path}/request.json');
        await input.writeAsString(jsonEncode(request), flush: true);
        final result = await token.bind(
          channel
              .invokeMapMethod<String, dynamic>('validate', {
                'id': id,
                'path': input.path,
              })
              .timeout(const Duration(seconds: 18)),
        );
        if (result == null) throw const FormatException('worker_result');
        return result;
      }
      if (!Platform.isLinux && !Platform.isWindows) {
        throw UnsupportedError('platform');
      }
      directory = await Directory.systemTemp.createTemp('antirkn-mihomo-');
      final executable =
          path ??
          '${File(Platform.resolvedExecutable).parent.path}'
              '${Platform.isWindows ? '/antirkn-mihomo.exe' : '/lib/antirkn-mihomo'}';
      process = await Process.start(
        executable,
        [directory.path],
        workingDirectory: directory.path,
        includeParentEnvironment: false,
        environment: {
          'GOMEMLIMIT': '192MiB',
          if (Platform.isWindows)
            'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
        },
      );
      final child = process;
      final output = readLimited(child.stdout, 16384);
      final errors = child.stderr.drain<void>();
      final work = () async {
        child.stdin.add(utf8.encode(jsonEncode(request)));
        await child.stdin.close();
        final bytes = await output;
        final code = await child.exitCode;
        await errors;
        if (code != 0) throw const FormatException('worker_failed');
        return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      }();
      return await token.bind(work.timeout(const Duration(seconds: 18)));
    } finally {
      if (process != null) {
        process.kill(ProcessSignal.sigkill);
        // Safely reap exit code to prevent defunct/zombie process in OS table
        unawaited(process.exitCode.catchError((_) => -1));
      }
      if (Platform.isAndroid) {
        try {
          await channel.invokeMethod<void>('cancel', {'id': id});
        } catch (_) {}
      }
      try {
        await directory?.delete(recursive: true);
      } catch (_) {}
    }
  }
}

Future<Uint8List> readLimited(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  await for (final part in stream) {
    if (bytes.length + part.length > limit) {
      throw const FormatException('output_limit');
    }
    bytes.add(part);
  }
  return bytes.takeBytes();
}
