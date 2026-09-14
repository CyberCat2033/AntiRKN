import 'dart:convert';
import 'dart:typed_data';
import 'package:antirkn_ssh_transport/src/panel_api.dart';
import 'package:test/test.dart';

void main() {
  Uint8List bytes(String value) => Uint8List.fromList(latin1.encode(value));
  test('HTTP length and session cookies are preserved', () {
    final response = parsePanelHttp(
      bytes(
        'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nSet-Cookie: session=fixture; HttpOnly\r\n\r\n{}',
      ),
    );
    expect(utf8.decode(response.body), '{}');
    expect(response.cookies, ['session=fixture; HttpOnly']);
  });
  test('chunked JSON is assembled', () {
    final response = parsePanelHttp(
      bytes(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n1\r\n}\r\n0\r\n\r\n',
      ),
    );
    expect(utf8.decode(response.body), '{}');
  });
  test('redirect, truncation and ambiguous framing are rejected', () {
    for (final value in [
      'HTTP/1.1 302 Found\r\nLocation: https://example.invalid\r\n\r\n',
      'HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}',
      'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n{}',
      'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n8\r\n{}',
    ]) {
      expect(() => parsePanelHttp(bytes(value)), throwsFormatException);
    }
  });
}
