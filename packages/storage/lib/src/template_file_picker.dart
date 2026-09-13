import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// Reads a bounded copy. No retained external path, URI permission or writes.
final class SystemTemplateFilePicker implements TemplateFilePicker {
  @override
  Future<ImportedTemplate?> pick() async {
    if (Platform.isAndroid) return _pickAndroid();
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'YAML', extensions: ['yml', 'yaml']),
      ],
    );
    if (file == null) return null;
    final extension = file.name.split('.').last.toLowerCase();
    if (!{'yml', 'yaml'}.contains(extension)) {
      throw const FormatException('invalid_template_extension');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > 262144) {
        throw const FormatException('template_size_limit');
      }
      bytes.add(chunk);
    }
    final source = utf8.decode(bytes.takeBytes());
    return ImportedTemplate(name: file.name, source: source);
  }

  // The Android file_selector implementation copies documents to disk first.
  // This narrow native adapter bounds the URI stream without a temporary file.
  Future<ImportedTemplate?> _pickAndroid() async {
    try {
      final data = await const MethodChannel(
        'org.antirkn/template_picker',
      ).invokeMapMethod<String, Object?>('pick');
      if (data == null) return null;
      return ImportedTemplate(
        name: data['name']! as String,
        source: utf8.decode(data['bytes']! as Uint8List),
      );
    } on PlatformException catch (e) {
      throw FormatException(e.code);
    }
  }
}
