import 'dart:convert';
import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';

// Private fixture input/output paths; never prints profiles or credentials.
Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--xhttp-defaults') {
    stdout.writeln(jsonEncode(xhttpFormDefaults()));
    return;
  }
  final input = jsonDecode(await File(args[0]).readAsString()) as Map;
  final workspace = VpnWorkspace.decode(jsonEncode(input['workspace']));
  final user = input['userId'] as String;
  final resource = input['resourceId'] as String;
  final selected = workspace.copy(
    inbounds: workspace.inbounds.where((r) => r.id == resource).toList(),
  );
  final result = const ProfileCompiler().compile(
    template: jsonEncode(input['template']),
    userId: user,
    accesses: vlessUserAccesses(selected, user),
  );
  if (result.hasBlockingErrors || result.yaml == null) {
    stderr.writeln(result.diagnostics.map((e) => e.code).join(','));
    exitCode = 1;
    return;
  }
  await File(args[1]).writeAsString(result.yaml!, flush: true);
  stdout.writeln('Compiled personal VLESS fixture with production compiler.');
}
