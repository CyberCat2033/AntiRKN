/// Stable numeric upstream versions; opaque/preview labels remain unknown.
List<int>? componentVersion(String value) {
  final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(value);
  return match == null
      ? null
      : [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
}

bool? componentIsNewer(String candidate, String installed) {
  final next = componentVersion(candidate), old = componentVersion(installed);
  if (next == null || old == null) return null;
  for (var i = 0; i < next.length; i++) {
    if (next[i] != old[i]) return next[i] > old[i];
  }
  return false;
}

abstract interface class ComponentReleaseSource {
  Future<Map<String, String>> check();
}
