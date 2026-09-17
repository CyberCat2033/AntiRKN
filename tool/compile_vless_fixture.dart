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
    ttEndpoints: workspace.ttEndpoints.where((r) => r.id == resource).toList(),
    inbounds: workspace.inbounds.where((r) => r.id == resource).toList(),
    awgInterfaces: workspace.awgInterfaces
        .where((r) => r.id == resource)
        .toList(),
  );
  final accesses = [
    ...vlessUserAccesses(selected, user),
    ...awgUserAccesses(selected, user),
    ...ttUserAccesses(selected, user),
  ];
  if (args.contains('--probe')) {
    final proxy = accesses.singleWhere((p) => p.identity.id == resource);
    await File(args[1]).writeAsString(jsonEncode(proxy.fields), flush: true);
    return;
  }
  final result = const ProfileCompiler().compile(
    template: jsonEncode(input['template']),
    userId: user,
    accesses: accesses,
  );
  if (result.hasBlockingErrors || result.yaml == null) {
    stderr.writeln(result.diagnostics.map((e) => e.code).join(','));
    exitCode = 1;
    return;
  }
  await File(args[1]).writeAsString(result.yaml!, flush: true);
  stdout.writeln('Compiled personal VPN fixture with production compiler.');
}
