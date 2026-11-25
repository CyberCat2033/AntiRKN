/// Local data changed under a pending effect: a stale editor, journal writer
/// or publication draft. The caller reloads and tries again.
enum SyncMergeIssue { changed }

final class SyncMergeFailure implements Exception {
  const SyncMergeFailure(this.issue);
  final SyncMergeIssue issue;
  @override
  String toString() => 'SyncMergeFailure(${issue.name})';
}
