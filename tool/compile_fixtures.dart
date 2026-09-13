import 'dart:convert';
import 'dart:io';

import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import '../packages/profile_compiler/test/support/fixtures.dart';

/// Generates only public, non-operational P0 fixtures. No runtime server access.
void main(List<String> args) {
  if (args.length != 1) {
    throw ArgumentError(
      'Usage: dart run tool/compile_fixtures.dart OUTPUT_DIRECTORY',
    );
  }
  final output = Directory(args.single)..createSync(recursive: true);
  final source = File('base.yml').readAsStringSync();
  final report = <String, Object?>{};
  for (final entry in fixtureVariants().entries) {
    final result = const ProfileCompiler().compile(
      template: source,
      userId: 'user-a',
      accesses: entry.value,
    );
    if (result.yaml == null) {
      throw StateError('Fixture compilation failed: ${entry.key}');
    }
    File('${output.path}/${entry.key}.yml').writeAsStringSync(result.yaml!);
    report[entry.key] = {
      'sha256': result.sha256Hash,
      'policyBlocked': result.hasBlockingErrors,
      'groups': {
        for (final g in result.groups)
          g.name: {
            'members': g.members,
            'fallback': g.fallback,
            'complete': g.complete,
          },
      },
      'diagnostics': result.diagnostics
          .map((d) => {'code': d.code, 'subject': d.subject})
          .toList(),
    };
  }
  File('${output.path}/groups.json').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(
    'Generated ${report.length} public test fixtures. No network connections tested.',
  );
}
