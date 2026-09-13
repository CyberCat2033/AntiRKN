import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';

/// The distribution determines support; VERSION_ID is display metadata only.
String ubuntuNameFromOsRelease(String source) {
  final values = <String, String>{};
  final assignment = RegExp(
    r'''^([A-Z_]+)=(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([A-Za-z0-9_.-]+))$''',
  );
  for (final line in const LineSplitter().convert(source)) {
    final match = assignment.firstMatch(line);
    if (match == null) continue;
    final key = match[1]!;
    if (values.containsKey(key)) {
      throw const SshFailure(SshIssue.unsupportedOs);
    }
    values[key] = match[2] ?? match[3] ?? match[4]!;
  }
  if (values['ID'] != 'ubuntu') {
    throw const SshFailure(SshIssue.unsupportedOs);
  }
  final version = values['VERSION_ID'];
  if (version == null ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$').hasMatch(version)) {
    return 'Ubuntu';
  }
  return 'Ubuntu $version';
}
