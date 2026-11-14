/// Stable numeric upstream versions; preview labels are handled when allowed.
List<int>? componentVersion(String value, {bool allowPreview = false}) {
  if (!allowPreview) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(value);
    return match == null
        ? null
        : [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
  }
  final match = RegExp(
    r'^v?(\d+)\.(\d+)\.(\d+)(?:[-.]?([a-zA-Z]+)?(?:[-.]?(\d+))?)?$',
  ).firstMatch(value);
  if (match == null) return null;
  final major = int.parse(match[1]!);
  final minor = int.parse(match[2]!);
  final patch = int.parse(match[3]!);
  final prereleaseTag = match[4];
  final prereleaseNum = match[5] != null
      ? int.parse(match[5]!)
      : (prereleaseTag != null ? 0 : 9999);
  return [major, minor, patch, prereleaseTag == null ? 1 : 0, prereleaseNum];
}

bool? componentIsNewer(
  String candidate,
  String installed, {
  bool allowPreview = false,
}) {
  final next = componentVersion(candidate, allowPreview: allowPreview);
  final old = componentVersion(installed, allowPreview: allowPreview);
  if (next == null || old == null) return null;
  for (var i = 0; i < next.length; i++) {
    if (next[i] != old[i]) return next[i] > old[i];
  }
  return false;
}

abstract interface class ComponentReleaseSource {
  Future<Map<String, String>> check();
  Future<Map<String, Object?>?> resolveAsset({
    required String component,
    required String version,
    String? architecture,
  });
}
