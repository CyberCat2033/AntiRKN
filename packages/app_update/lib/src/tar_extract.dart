import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';

const _block = 512;
const _unsafe = AppUpdateFailure(AppUpdateCode.archiveUnsafe);

/// Extracts a `.tar.gz` into the new directory [destination]. Only regular
/// files and directories are accepted: links, devices, FIFOs, absolute
/// paths, `..`, duplicates and oversized archives are refused with
/// [AppUpdateCode.archiveUnsafe] before anything outside [destination] can
/// be touched (no link is ever created, so no path can escape it). Returns
/// the relative paths that carry an executable bit.
Future<List<String>> extractTarGz(
  String archive,
  String destination, {
  int maxBytes = 1024 * 1024 * 1024,
  int maxEntries = 20000,
}) async {
  final root = Directory(destination);
  if (await FileSystemEntity.type(destination, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw _unsafe;
  }
  await root.create(recursive: true);
  final reader = _Reader(File(archive).openRead().transform(gzip.decoder));
  final seen = <String>{};
  final executables = <String>[];
  var total = 0;
  var entries = 0;
  String? longName;
  String? paxPath;
  try {
    while (true) {
      final header = await reader.read(_block);
      if (header == null) throw _unsafe;
      if (header.every((b) => b == 0)) break;
      if (++entries > maxEntries) throw _unsafe;
      _checksum(header);
      final type = header[156];
      final size = _octal(header, 124, 12);
      final padded = (size + _block - 1) ~/ _block * _block;
      switch (type) {
        case 0x4c: // 'L' GNU long name
        case 0x78: // 'x' pax extended header
          if (size > 65536) throw _unsafe;
          final data = await reader.read(padded);
          if (data == null) throw _unsafe;
          final text = data.sublist(0, size);
          if (type == 0x4c) {
            longName = _cString(text);
          } else {
            paxPath = _paxPath(text) ?? paxPath;
          }
          continue;
        case 0x67: // 'g' global pax header: no path information we use
          if (!await reader.skip(padded)) throw _unsafe;
          continue;
      }
      final name =
          paxPath ??
          longName ??
          _joinUstar(
            _cString(header.sublist(345, 500)),
            _cString(header.sublist(0, 100)),
          );
      longName = null;
      paxPath = null;
      final relative = _safePath(name);
      final isDirectory = type == 0x35;
      final isFile = type == 0x30 || type == 0;
      if (!isDirectory && !isFile) throw _unsafe;
      if (relative == null) {
        if (isDirectory) continue; // "./"
        throw _unsafe;
      }
      if (!seen.add(relative)) throw _unsafe;
      final path = '$destination/$relative';
      if (isDirectory) {
        if (size != 0) throw _unsafe;
        await Directory(path).create(recursive: true);
        continue;
      }
      total += size;
      if (total > maxBytes) throw _unsafe;
      await Directory(
        path.substring(0, path.lastIndexOf('/')),
      ).create(recursive: true);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw _unsafe;
      }
      final file = await File(path).open(mode: FileMode.writeOnly);
      try {
        var left = size;
        while (left > 0) {
          final chunk = await reader.read(left < 65536 ? left : 65536);
          if (chunk == null) throw _unsafe;
          await file.writeFrom(chunk);
          left -= chunk.length;
        }
        await file.flush();
      } finally {
        await file.close();
      }
      if (!await reader.skip(padded - size)) throw _unsafe;
      if (_octal(header, 100, 8) & 0x49 != 0) executables.add(relative);
    }
  } on FormatException {
    throw _unsafe;
  } finally {
    await reader.cancel();
  }
  return executables;
}

void _checksum(Uint8List header) {
  var sum = 0;
  for (var i = 0; i < _block; i++) {
    sum += i >= 148 && i < 156 ? 0x20 : header[i];
  }
  if (sum != _octal(header, 148, 8)) throw _unsafe;
}

int _octal(Uint8List bytes, int offset, int length) {
  if (bytes[offset] & 0x80 != 0) throw _unsafe; // base-256: too large
  final text = ascii
      .decode(bytes.sublist(offset, offset + length), allowInvalid: false)
      .replaceAll('\u0000', ' ')
      .trim();
  if (text.isEmpty) return 0;
  if (!RegExp(r'^[0-7]{1,12}$').hasMatch(text)) throw _unsafe;
  return int.parse(text, radix: 8);
}

String _cString(List<int> bytes) {
  final end = bytes.indexOf(0);
  return utf8.decode(end < 0 ? bytes : bytes.sublist(0, end));
}

String _joinUstar(String prefix, String name) =>
    prefix.isEmpty ? name : '$prefix/$name';

String? _paxPath(List<int> data) {
  final text = utf8.decode(data);
  var offset = 0;
  String? path;
  while (offset < text.length) {
    final space = text.indexOf(' ', offset);
    if (space < 0) throw _unsafe;
    final length = int.tryParse(text.substring(offset, space));
    if (length == null || length <= 0 || offset + length > text.length) {
      throw _unsafe;
    }
    final record = text.substring(space + 1, offset + length - 1);
    final equals = record.indexOf('=');
    if (equals < 0) throw _unsafe;
    final key = record.substring(0, equals);
    if (key == 'path') path = record.substring(equals + 1);
    if (key == 'linkpath') throw _unsafe;
    offset += length;
  }
  return path;
}

/// A relative path inside the destination, null for the archive root.
String? _safePath(String name) {
  if (name.isEmpty ||
      name.length > 4096 ||
      name.startsWith('/') ||
      name.contains('\\') ||
      name.contains('\u0000')) {
    throw _unsafe;
  }
  final parts = name.split('/').where((p) => p.isNotEmpty && p != '.').toList();
  if (parts.isEmpty) return null;
  if (parts.any((p) => p == '..' || p.length > 255)) throw _unsafe;
  return parts.join('/');
}

/// Exact-length reads over a byte stream.
final class _Reader {
  _Reader(Stream<List<int>> stream) : _input = StreamIterator(stream);
  final StreamIterator<List<int>> _input;
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;

  Future<bool> _fill() async {
    if (_offset < _buffer.length) return true;
    if (!await _input.moveNext()) return false;
    final chunk = _input.current;
    _buffer = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    _offset = 0;
    return true;
  }

  /// Exactly [count] bytes, or null at the end of the stream.
  Future<Uint8List?> read(int count) async {
    final result = BytesBuilder(copy: false);
    while (result.length < count) {
      if (!await _fill()) return null;
      final take = (count - result.length).clamp(0, _buffer.length - _offset);
      result.add(Uint8List.sublistView(_buffer, _offset, _offset + take));
      _offset += take;
    }
    return result.takeBytes();
  }

  Future<bool> skip(int count) async {
    var left = count;
    while (left > 0) {
      if (!await _fill()) return false;
      final take = left.clamp(0, _buffer.length - _offset);
      _offset += take;
      left -= take;
    }
    return true;
  }

  Future<void> cancel() => _input.cancel();
}
