import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_sync/antirkn_sync.dart';
import 'package:test/test.dart';

LocalChange event(
  String id, {
  String? parent,
  int revision = 1,
  String source = 'value',
  bool deleted = false,
  List<String> others = const [],
  String entity = 'default',
}) => LocalChange(
  header: ChangeHeader(
    workspaceId: 'f' * 32,
    deviceId: id * 32,
    changeId: id * 32,
    sequence: 1,
    transactionId: id * 32,
    transactionIndex: 0,
    transactionSize: 1,
    entityKind: ChangeEntityKind.template,
    entityId: entity,
    baseChangeId: parent == null ? null : parent * 32,
    baseRevision: revision - 1,
    revision: revision,
    deleted: deleted,
    schemaVersion: others.isEmpty ? 1 : 2,
    mergeParents: others.map((e) => e * 32).toList(),
  ),
  source: deleted ? null : source,
);
void main() {
  test('ordering follows ancestors and merging acknowledges both branches', () {
    final root = event('a'),
        left = event('b', parent: 'a', revision: 2, source: 'left'),
        right = event('c', parent: 'a', revision: 2, source: 'right'),
        merge = event('d', parent: 'b', revision: 3, others: ['c']);
    final before = CausalGraph([right, root, left]);
    expect(before.tips.values.single, ['b' * 32, 'c' * 32]);
    expect(
      before.commonAncestor(before.tips.values.single)!.header.changeId,
      'a' * 32,
    );
    for (final events in [
      [merge, right, root, left],
      [root, left, right, merge],
    ]) {
      expect(CausalGraph(events).tips.values.single, ['d' * 32]);
    }
  });
  test(
    'missing parent, unrelated parent, duplicate device sequence and ordinary resurrection reject',
    () {
      for (final events in [
        [event('b', parent: 'a', revision: 2)],
        [event('a', entity: 'other'), event('b', parent: 'a', revision: 2)],
        [event('a'), event('a')],
        [event('a', deleted: true), event('b', parent: 'a', revision: 2)],
      ]) {
        expect(() => CausalGraph(events), throwsA(isA<SyncMergeFailure>()));
      }
    },
  );
  test(
    'future revision cannot be named as a merge parent and parent list is owned',
    () {
      expect(
        () => CausalGraph([
          event('a'),
          event('b', parent: 'a', revision: 2),
          event('c', parent: 'b', revision: 3),
          event('d', parent: 'a', revision: 2, others: ['c']),
        ]),
        throwsA(isA<SyncMergeFailure>()),
      );
      final h = event('d', parent: 'a', revision: 2, others: ['b']).header;
      expect(() => h.mergeParents.add('e' * 32), throwsUnsupportedError);
      expect(ChangeHeader.fromJson(h.toJson()).parents, h.parents);
      expect(
        ChangeHeader.fromJson(event('a').header.toJson()).schemaVersion,
        1,
      );
    },
  );
}
