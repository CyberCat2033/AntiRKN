import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

final class SystemPrivateKeyFilePicker implements PrivateKeyFilePicker {
  static const maxBytes = 256 * 1024;
  @override
  Future<void> cancel() async {
    if (Platform.isAndroid) {
      await const MethodChannel(
        'org.antirkn/template_picker',
      ).invokeMethod<void>('cancelKey');
    }
  }

  @override
  Future<ImportedPrivateKey?> pick() async {
    try {
      if (Platform.isAndroid) {
        final data = await const MethodChannel(
          'org.antirkn/template_picker',
        ).invokeMapMethod<String, Object?>('pickKey');
        if (data == null) return null;
        return ImportedPrivateKey(
          name: data['name']! as String,
          bytes: data['bytes']! as Uint8List,
        );
      }
      // OpenSSH private keys commonly have no extension.
      final home = Platform.environment['HOME'];
      final sshDirectory = Platform.isLinux && home != null
          ? Directory('$home/.ssh')
          : null;
      final file = await openFile(
        initialDirectory: sshDirectory != null && await sshDirectory.exists()
            ? sshDirectory.path
            : null,
      );
      if (file == null) return null;
      final buffer = Uint8List(maxBytes);
      var length = 0;
      try {
        await for (final chunk in file.openRead()) {
          if (length + chunk.length > maxBytes) {
            throw const SshFailure(SshIssue.invalidKey);
          }
          buffer.setRange(length, length + chunk.length, chunk);
          length += chunk.length;
        }
        return ImportedPrivateKey(
          name: file.name,
          bytes: Uint8List.sublistView(buffer, 0, length),
        );
      } finally {
        buffer.fillRange(0, buffer.length, 0);
      }
    } catch (_) {
      throw const SshFailure(SshIssue.invalidKey);
    }
  }
}
