import 'package:antirkn_domain/antirkn_domain.dart';

typedef SyncEntityKey = (ChangeEntityKind, String);
SyncEntityKey syncEntityKey(LocalChange change) =>
    (change.header.entityKind, change.header.entityId);

/// Pure causal graph: device clocks and transport arrival order are irrelevant.
/// Callers admit complete transaction groups and validate entity payloads.
final class CausalGraph {
  CausalGraph(Iterable<LocalChange> input) {
    final branchSets = <SyncEntityKey, Set<String>>{};
    final deviceSequences = <(String, int), String>{};
    for (final event in input) {
      final h = event.header;
      if (events.containsKey(h.changeId) ||
          deviceSequences.containsKey((h.deviceId, h.sequence))) {
        throw const SyncMergeFailure(SyncMergeIssue.invalid);
      }
      events[h.changeId] = event;
      deviceSequences[(h.deviceId, h.sequence)] = h.changeId;
      branchSets.putIfAbsent(syncEntityKey(event), () => {}).add(h.changeId);
    }
    for (final event in events.values) {
      final h = event.header;
      for (final id in h.parents) {
        final parent = events[id];
        if (parent == null ||
            syncEntityKey(parent) != syncEntityKey(event) ||
            parent.header.workspaceId != h.workspaceId ||
            parent.header.revision >= h.revision ||
            (id == h.baseChangeId &&
                parent.header.revision != h.baseRevision)) {
          throw const SyncMergeFailure(SyncMergeIssue.invalid);
        }
        if (parent.header.deleted && !h.deleted && h.mergeParents.isEmpty) {
          throw const SyncMergeFailure(SyncMergeIssue.invalid);
        }
        branchSets[syncEntityKey(event)]!.remove(id);
      }
    }
    for (final entry in branchSets.entries) {
      if (entry.value.length > 65) {
        throw const SyncMergeFailure(SyncMergeIssue.limit);
      }
      tips[entry.key] = entry.value.toList()..sort();
    }
  }
  final events = <String, LocalChange>{};
  final tips = <SyncEntityKey, List<String>>{};

  Set<String> ancestors(String id) {
    final result = <String>{}, pending = <String>[id];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (result.add(current)) pending.addAll(events[current]!.header.parents);
    }
    return result;
  }

  LocalChange? commonAncestor(List<String> ids) {
    if (ids.isEmpty) return null;
    var common = ancestors(ids.first);
    for (final id in ids.skip(1)) {
      common = common.intersection(ancestors(id));
    }
    final candidates = common.map((id) => events[id]!).toList()
      ..sort((a, b) {
        final revision = b.header.revision.compareTo(a.header.revision);
        return revision == 0
            ? a.header.changeId.compareTo(b.header.changeId)
            : revision;
      });
    return candidates.firstOrNull;
  }

  bool equivalent(List<String> ids) {
    final first = events[ids.first]!;
    return ids.every(
      (id) =>
          events[id]!.source == first.source &&
          events[id]!.header.deleted == first.header.deleted,
    );
  }
}
