import 'dart:io';
import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// Only authenticated ciphertext crosses the platform file boundary.
final class SystemBackupFileStore implements BackupFileStore {
  static const _channel = MethodChannel('org.antirkn/template_picker');
  static const _types = [
    XTypeGroup(label: 'AntiRKN', extensions: ['antirkn']),
  ];

  @override
  Future<Uint8List?> pick() async {
    try {
      if (Platform.isAndroid) {
        final data = await _channel.invokeMapMethod<String, Object?>(
          'pickBackup',
        );
        return data?['bytes'] as Uint8List?;
      }
      final file = await openFile(acceptedTypeGroups: _types);
      if (file == null) return null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        if (bytes.length + chunk.length > maxWorkspaceBackupBytes) {
          throw const BackupFailure(BackupIssue.tooLarge);
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } on BackupFailure {
      rethrow;
    } on PlatformException catch (e) {
      throw BackupFailure(
        e.code == 'template_size_limit'
            ? BackupIssue.tooLarge
            : BackupIssue.file,
      );
    } catch (_) {
      throw const BackupFailure(BackupIssue.file);
    }
  }

  @override
  Future<bool> save(Uint8List bytes) async {
    if (bytes.length > maxWorkspaceBackupBytes) {
      throw const BackupFailure(BackupIssue.tooLarge);
    }
    final name =
        'AntiRKN-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.antirkn';
    try {
      if (Platform.isAndroid) {
        return await _channel.invokeMethod<bool>('saveBackup', {
              'name': name,
              'bytes': bytes,
            }) ??
            false;
      }
      final destination = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: _types,
      );
      if (destination == null) return false;
      await writeBackupFile(destination.path, bytes);
      return true;
    } catch (_) {
      throw const BackupFailure(BackupIssue.file);
    }
  }
}

/// Stage encrypted bytes next to the destination, then replace by rename.
/// A failed write never truncates the previously saved backup.
Future<void> writeBackupFile(String path, Uint8List bytes) async {
  final temporary = File('$path.${newVpnId()}.tmp');
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
