import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:dartssh2/dartssh2.dart';

/// Bounded HTTP/1.1 over direct-tcpip, with no listening port on the device.
/// Every channel targets the panel's loopback address inside the existing SSH.
final class SshPanelApi {
  SshPanelApi(this.client, this.access, this.cancellation);
  final SSHClient client;
  final PanelAccess access;
  final CancellationToken cancellation;
  final Map<String, String> _cookies = {};
  String? _csrf;

  Future<Object?> call(String path, [Map<String, Object?>? data]) async {
    cancellation.check();
    SSHForwardChannel? opened;
    var accepting = true;
    try {
      final socket = await cancellation.bind(
        client
            .forwardLocal('127.0.0.1', access.port)
            .then((channel) {
              if (accepting) {
                opened = channel;
              } else {
                channel.destroy();
              }
              return channel;
            })
            .timeout(const Duration(seconds: 30)),
      );
      final body = data == null ? <int>[] : utf8.encode(jsonEncode(data));
      final request = StringBuffer()
        ..write('${data == null ? 'GET' : 'POST'} $path HTTP/1.1\r\n')
        ..write('Host: 127.0.0.1:${access.port}\r\n')
        ..write('Origin: http://127.0.0.1:${access.port}\r\n')
        ..write('Connection: close\r\nAccept: application/json\r\n')
        ..write('Content-Length: ${body.length}\r\n');
      if (data != null) request.write('Content-Type: application/json\r\n');
      if (_csrf != null) request.write('X-CSRF-Token: $_csrf\r\n');
      if (_cookies.isNotEmpty) {
        request.write(
          'Cookie: ${_cookies.entries.map((e) => '${e.key}=${e.value}').join('; ')}\r\n',
        );
      }
      request.write('\r\n');
      final received = BytesBuilder(copy: false);
      final future = socket.stream.forEach((chunk) {
        if (received.length + chunk.length > 512 * 1024) {
          throw const FormatException('panel_size');
        }
        received.add(chunk);
      });
      socket.sink.add([...utf8.encode(request.toString()), ...body]);
      // The channel upload loop drains sink.add itself. Flushing the shared
      // native socket concurrently with SSH packet writes breaks dart:io's sink.
      await cancellation.bind(future.timeout(const Duration(seconds: 30)));
      final result = parsePanelHttp(received.takeBytes());
      for (final cookie in result.cookies) {
        final pair = cookie.split(';').first;
        final index = pair.indexOf('=');
        if (index > 0) {
          _cookies[pair.substring(0, index)] = pair.substring(index + 1);
        }
      }
      final json = jsonDecode(utf8.decode(result.body)) as Map;
      if (json['success'] != true) throw const FormatException('panel_api');
      return json['obj'];
    } finally {
      accepting = false;
      opened?.destroy();
    }
  }

  Future<void> verify() async {
    _csrf = await call('/csrf-token') as String;
    await call('/login', {
      'username': access.username,
      'password': access.password,
    });
    _csrf = await call('/csrf-token') as String;
    final settings = await call('/panel/api/setting/all', {}) as Map;
    final inbounds = await call('/panel/api/inbounds/list');
    final status = await call('/panel/api/server/status') as Map;
    if (settings['webListen'] != '127.0.0.1' ||
        settings['webPort'] != access.port ||
        settings['subEnable'] != false ||
        inbounds is! List ||
        status['panelVersion'] != access.panelVersion ||
        (status['xray'] as Map?)?['state'] != 'running' ||
        (status['xray'] as Map?)?['version'] != access.xrayVersion) {
      throw const FormatException('panel_state');
    }
  }
}

({Uint8List body, List<String> cookies}) parsePanelHttp(Uint8List raw) {
  final source = latin1.decode(raw);
  final split = source.indexOf('\r\n\r\n');
  if (split < 0 || split > 16384) throw const FormatException('panel_headers');
  final lines = source.substring(0, split).split('\r\n');
  if (!RegExp(r'^HTTP/1\.[01] 200(?: |$)').hasMatch(lines.first)) {
    throw const FormatException('panel_status');
  }
  final headers = <String, List<String>>{};
  for (final line in lines.skip(1)) {
    final index = line.indexOf(':');
    if (index <= 0) throw const FormatException('panel_header');
    headers
        .putIfAbsent(line.substring(0, index).toLowerCase(), () => [])
        .add(line.substring(index + 1).trim());
  }
  final transfer = headers['transfer-encoding'];
  final lengths = headers['content-length'];
  var body = Uint8List.sublistView(raw, split + 4);
  if (transfer != null) {
    if (transfer.length != 1 ||
        transfer.single.toLowerCase() != 'chunked' ||
        lengths != null) {
      throw const FormatException('panel_encoding');
    }
    final output = BytesBuilder(copy: false);
    var offset = 0;
    final chunks = latin1.decode(body);
    while (true) {
      final end = chunks.indexOf('\r\n', offset);
      if (end < 0) throw const FormatException('panel_chunk');
      final size = int.tryParse(
        chunks.substring(offset, end).split(';').first,
        radix: 16,
      );
      if (size == null || size < 0) throw const FormatException('panel_chunk');
      offset = end + 2;
      if (size == 0) {
        if (chunks.substring(offset) != '\r\n') {
          throw const FormatException('panel_chunk_end');
        }
        break;
      }
      if (offset + size + 2 > body.length ||
          chunks.substring(offset + size, offset + size + 2) != '\r\n') {
        throw const FormatException('panel_chunk');
      }
      output.add(Uint8List.sublistView(body, offset, offset + size));
      offset += size + 2;
    }
    body = output.takeBytes();
  } else if (lengths != null &&
      (lengths.length != 1 || int.tryParse(lengths.single) != body.length)) {
    throw const FormatException('panel_length');
  }
  return (body: body, cookies: headers['set-cookie'] ?? []);
}
