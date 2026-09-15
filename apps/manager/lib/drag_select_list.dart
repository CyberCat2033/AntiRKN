import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'catalog_selection.dart';

typedef SelectableItem = Widget Function(String id, Widget child);

/// Long press starts a reversible range; the same gesture scrolls at either edge.
class DragSelectList extends StatefulWidget {
  const DragSelectList({
    required this.selection,
    required this.ids,
    required this.builder,
    this.enabled = true,
    super.key,
  });
  final CatalogSelection selection;
  final List<String> ids;
  final bool enabled;
  final Widget Function(ScrollController scroll, SelectableItem item) builder;
  @override
  State<DragSelectList> createState() => _DragSelectListState();
}

class _DragSelectListState extends State<DragSelectList> {
  final scroll = ScrollController();
  final bounds = GlobalKey();
  final keys = <String, GlobalKey>{};
  Timer? timer;
  Offset? pointer;
  int? anchor;
  Set<String> before = {};

  @override
  void didUpdateWidget(DragSelectList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        !listEquals(widget.ids, oldWidget.ids) ||
        widget.selection != oldWidget.selection ||
        !widget.selection.active) {
      _finish();
    }
    keys.removeWhere((id, _) => !widget.ids.contains(id));
  }

  Rect? _rect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
  }

  int? _indexAt(Offset position, {bool nearest = false}) {
    final viewport = _rect(bounds);
    if (viewport == null) return null;
    int? candidate;
    var distance = double.infinity;
    for (var i = 0; i < widget.ids.length; i++) {
      final key = keys[widget.ids[i]];
      final rect = key == null ? null : _rect(key);
      if (rect == null || !rect.overlaps(viewport)) continue;
      if (rect.contains(position)) return i;
      if (nearest) {
        final delta = (rect.center.dy - position.dy).abs();
        if (delta < distance) {
          candidate = i;
          distance = delta;
        }
      }
    }
    return candidate;
  }

  void _start(LongPressStartDetails details) {
    if (!widget.enabled) return;
    final index = _indexAt(details.globalPosition);
    if (index == null) return;
    before = widget.selection.active ? Set.of(widget.selection.ids) : {};
    if (!widget.selection.active) widget.selection.start(feedback: false);
    anchor = index;
    pointer = details.globalPosition;
    _range(index);
    timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _scroll());
  }

  void _range(int end) {
    final start = anchor;
    if (start == null) return;
    final lo = start < end ? start : end, hi = start > end ? start : end;
    widget.selection.replace({...before, ...widget.ids.sublist(lo, hi + 1)});
  }

  void _move(LongPressMoveUpdateDetails details) {
    if (anchor == null) return;
    pointer = details.globalPosition;
    final index = _indexAt(pointer!, nearest: true);
    if (index != null) _range(index);
  }

  void _scroll() {
    if (!mounted ||
        !widget.enabled ||
        !widget.selection.active ||
        pointer == null ||
        anchor == null) {
      _finish();
      return;
    }
    final viewport = _rect(bounds);
    if (viewport == null || !scroll.hasClients) return;
    final edge = (viewport.height / 4).clamp(24.0, 64.0);
    final y = pointer!.dy;
    final factor = y < viewport.top + edge
        ? -((viewport.top + edge - y) / edge).clamp(0.0, 1.0)
        : y > viewport.bottom - edge
        ? ((y - viewport.bottom + edge) / edge).clamp(0.0, 1.0)
        : 0.0;
    if (factor == 0) return;
    final next = (scroll.offset + factor * 12).clamp(
      scroll.position.minScrollExtent,
      scroll.position.maxScrollExtent,
    );
    if (next == scroll.offset) return;
    scroll.jumpTo(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || pointer == null || anchor == null) return;
      final index = _indexAt(pointer!, nearest: true);
      if (index != null) _range(index);
    });
  }

  void _finish() {
    timer?.cancel();
    timer = null;
    anchor = null;
    pointer = null;
    before = {};
  }

  @override
  void dispose() {
    _finish();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: bounds,
    behavior: HitTestBehavior.translucent,
    onLongPressStart: widget.enabled ? _start : null,
    onLongPressMoveUpdate: widget.enabled ? _move : null,
    onLongPressEnd: (_) => _finish(),
    onLongPressCancel: _finish,
    child: widget.builder(
      scroll,
      (id, child) => KeyedSubtree(
        key: keys.putIfAbsent(id, () => GlobalKey()),
        child: child,
      ),
    ),
  );
}
