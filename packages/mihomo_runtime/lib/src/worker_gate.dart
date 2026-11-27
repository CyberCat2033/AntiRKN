import 'dart:async';

import 'package:antirkn_domain/antirkn_domain.dart';

/// Process-wide gate of the bundled Mihomo worker. Every [NativeWorker] run
/// enters it; an app update closes it and waits until no worker process is
/// left, so the worker binary is never replaced while it runs.
final class MihomoWorkerGate implements CoreLifecycle {
  MihomoWorkerGate._();
  static final instance = MihomoWorkerGate._();

  int _active = 0;
  bool _closed = false;
  Completer<void>? _idle;

  int get active => _active;
  bool get closed => _closed;

  /// Enters a run; throws `FormatException('worker_paused')` while closed.
  void enter() {
    if (_closed) throw const FormatException('worker_paused');
    _active++;
  }

  void leave() {
    if (_active > 0) _active--;
    if (_active == 0) _idle?.complete();
    if (_active == 0) _idle = null;
  }

  @override
  Future<bool> quiesce(Duration timeout) async {
    _closed = true;
    if (_active == 0) return true;
    final idle = _idle ??= Completer<void>();
    try {
      await idle.future.timeout(timeout);
      return true;
    } on TimeoutException {
      _closed = false;
      return false;
    }
  }

  @override
  void resume() => _closed = false;
}
