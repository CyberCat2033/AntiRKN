import 'app_update_contract.g.dart';

final _semVer = RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$');
final _released = RegExp(
  r'^##\s+\[v?([0-9]+\.[0-9]+\.[0-9]+)\]\s+-\s+([0-9]{4}-[0-9]{2}-[0-9]{2})\s*$',
);
final _secondLevel = RegExp(r'^##(\s|$)');
final _linkDefinition = RegExp(r'^\[[^\]]+\]:\s*\S+\s*$');

/// Compares `X.Y.Z` versions; malformed versions sort below every valid one.
int compareAppVersions(String a, String b) {
  List<int>? parts(String value) =>
      _semVer.hasMatch(value) ? value.split('.').map(int.parse).toList() : null;
  final left = parts(a);
  final right = parts(b);
  if (left == null || right == null) {
    return (left == null ? 0 : 1) - (right == null ? 0 : 1);
  }
  for (var i = 0; i < 3; i++) {
    if (left[i] != right[i]) return left[i].compareTo(right[i]);
  }
  return 0;
}

/// Released sections of a Keep a Changelog file, in file order. The
/// `[Unreleased]` section and text before the first release are skipped.
/// Bullets are normalized to `- `, blank runs collapse, link reference
/// definitions are dropped.
List<AppUpdateChangelogEntry> parseKeepAChangelog(String markdown) {
  final result = <AppUpdateChangelogEntry>[];
  String? version;
  String? date;
  final body = <String>[];
  void flush() {
    if (version != null) {
      result.add(
        AppUpdateChangelogEntry(
          version: version,
          date: date!,
          markdown: _normalize(body),
        ),
      );
    }
    body.clear();
  }

  for (final raw in markdown.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trimRight();
    if (_secondLevel.hasMatch(line)) {
      flush();
      final match = _released.firstMatch(line);
      version = match?.group(1);
      date = match?.group(2);
      continue;
    }
    if (version != null) body.add(line);
  }
  flush();
  return result;
}

String _normalize(List<String> lines) => lines
    .where((line) => !_linkDefinition.hasMatch(line.trim()))
    .map((line) {
      final trimmed = line.trimLeft();
      final indent = line.substring(0, line.length - trimmed.length);
      return trimmed.startsWith('* ')
          ? '$indent- ${trimmed.substring(2)}'
          : line;
    })
    .join('\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

/// The signed `changelog` of release [version]: the newest released
/// sections up to [version] from both files, newest first. Throws
/// `FormatException('changelog_missing')` when the release section is
/// missing or empty in either language, `changelog_invalid` on duplicates.
Map<String, List<AppUpdateChangelogEntry>> appUpdateChangelogForRelease({
  required String version,
  required Map<String, String> files,
}) {
  final result = <String, List<AppUpdateChangelogEntry>>{};
  for (final language in appUpdateChangelogLanguages) {
    final source = files[language];
    if (source == null) throw const FormatException('changelog_missing');
    final entries = parseKeepAChangelog(source);
    final versions = entries.map((e) => e.version).toSet();
    if (versions.length != entries.length) {
      throw const FormatException('changelog_invalid');
    }
    final selected =
        entries
            .where(
              (e) =>
                  e.markdown.isNotEmpty &&
                  compareAppVersions(e.version, version) <= 0,
            )
            .toList()
          ..sort((a, b) => compareAppVersions(b.version, a.version));
    if (selected.isEmpty || selected.first.version != version) {
      throw const FormatException('changelog_missing');
    }
    result[language] = List.unmodifiable(
      selected.take(appUpdateChangelogMaxItems),
    );
  }
  return Map.unmodifiable(result);
}

/// Payload rule: per language, strictly newest first, none newer than the
/// release, and the release itself first.
bool appUpdateChangelogValid(
  Map<String, List<AppUpdateChangelogEntry>> changelog,
  String version,
) {
  for (final entries in changelog.values) {
    if (entries.isEmpty || entries.first.version != version) return false;
    for (var i = 1; i < entries.length; i++) {
      if (compareAppVersions(entries[i - 1].version, entries[i].version) <= 0) {
        return false;
      }
    }
  }
  return true;
}

/// What is new for the installed [installedVersion], newest first, in
/// [languageCode] with a per-version fallback to English.
List<AppUpdateChangelogEntry> appUpdateChangesSince(
  Map<String, List<AppUpdateChangelogEntry>> changelog, {
  required String installedVersion,
  required String languageCode,
}) {
  final english = changelog['en'] ?? const [];
  final local = languageCode == 'en'
      ? const <AppUpdateChangelogEntry>[]
      : changelog[languageCode] ?? const [];
  final byVersion = {for (final e in local) e.version: e};
  final versions = {
    for (final e in [...english, ...local])
      if (compareAppVersions(e.version, installedVersion) > 0) e.version,
  }.toList()..sort((a, b) => compareAppVersions(b, a));
  return [
    for (final v in versions)
      byVersion[v] ?? english.firstWhere((e) => e.version == v),
  ];
}

/// The GitHub release body: the release's section in English, then Russian.
String appUpdateReleaseNotes(
  Map<String, List<AppUpdateChangelogEntry>> changelog,
  String version,
) {
  String section(String language) => changelog[language]!
      .firstWhere(
        (e) => e.version == version,
        orElse: () => throw const FormatException('changelog_missing'),
      )
      .markdown;
  return '## English\n\n${section('en')}\n\n## Русский\n\n${section('ru')}\n';
}
