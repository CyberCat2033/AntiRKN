/// Stable numeric upstream versions; preview labels are handled when allowed.
List<int>? componentVersion(String value, {bool allowPreview = false}) {
  final clean = value.trim();
  if (!allowPreview) {
    final match = RegExp(
      r'(?:^|[^\w])v?(\d+)\.(\d+)\.(\d+)(?:[-.]?([a-zA-Z]+[0-9]*))?(?=[^\w]|$)',
    ).firstMatch(clean);
    if (match == null || match[4] != null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
  }
  final match = RegExp(
    r'(?:^|[^\w])v?(\d+)\.(\d+)\.(\d+)(?:[-.]?([a-zA-Z]+)?(?:[-.]?(\d+))?)?(?=[^\w]|$)',
  ).firstMatch(clean);
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

/// One upstream release offered for an explicit version choice.
final class ComponentRelease {
  const ComponentRelease(this.version, {this.preview = false, this.published});
  final String version;

  /// Marked as a pre-release (rc/beta) upstream.
  final bool preview;
  final DateTime? published;
}

abstract interface class ComponentReleaseSource {
  Future<Map<String, String>> check();

  /// Recent releases, newest first, previews included and marked.
  Future<List<ComponentRelease>> releases(String component);
  /// A newer upstream TrustTunnel/AmneziaWG release for the AntiRKN
  /// installer: `{version, archive: {url, bytes, sha256}[, commit]}`, or null
  /// when it cannot be identified with a checksum.
  Future<Map<String, Object?>?> resolveInstallerRelease({
    required String component,
    required String version,
  });

  Future<Map<String, Object?>?> resolveAsset({
    required String component,
    required String version,
    String? architecture,
  });
}
