/// Small bounded batches hide round-trip latency without exhausting SSH channels.
Future<List<R>> parallelReads<T, R>(
  Iterable<T> input,
  Future<R> Function(T) read,
) async {
  final items = input.toList();
  final results = <int, R>{};
  var next = 0;
  var failed = false;
  Future<void> worker() async {
    while (!failed && next < items.length) {
      final index = next++;
      try {
        results[index] = await read(items[index]);
      } catch (_) {
        failed = true;
        rethrow;
      }
    }
  }

  await Future.wait(
    List.generate(items.length.clamp(0, 3), (_) => worker()),
    eagerError: true,
  );
  return [
    for (var index = 0; index < items.length; index++) results[index] as R,
  ];
}
