import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

final class SystemProfileExporter implements ProfileExporter {
  @override
  Future<bool> save(String name, String source) async {
    if (!RegExp(r'^[a-f0-9]{32}\.yml$').hasMatch(name)) {
      throw const FormatException('profile_name');
    }
    final bytes = Uint8List.fromList(utf8.encode(source));
    try {
      if (Platform.isAndroid) {
        return await const MethodChannel(
              'org.antirkn/template_picker',
            ).invokeMethod<bool>('saveProfile', {
              'name': name,
              'bytes': bytes,
            }) ??
            false;
      }
      final destination = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: [
          const XTypeGroup(label: 'YAML', extensions: ['yml', 'yaml']),
        ],
      );
      if (destination == null) return false;
      await XFile.fromData(
        bytes,
        mimeType: 'application/yaml',
        name: name,
      ).saveTo(destination.path);
      return true;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }
}
