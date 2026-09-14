import 'dart:convert';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';

Future<void> main() async {
  final latest = await const GithubComponentReleaseSource().check();
  print(
    jsonEncode({
      'latest': latest,
      'checkedAt': DateTime.now().toUtc().toIso8601String(),
    }),
  );
}
