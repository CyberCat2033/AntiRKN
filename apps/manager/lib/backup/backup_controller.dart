import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/foundation.dart';

class BackupController extends ChangeNotifier {
  BackupController({required this.store, required this.files});
  final WorkspaceBackupStore store;
  final BackupFileStore files;
  WorkspaceRestorePlan? _plan;
  BackupSummary? get summary => _plan?.summary;
  bool busy = false, completed = false;
  BackupIssue? error;
  bool _disposed = false;

  Future<void> _run(Future<void> Function() action) async {
    if (busy || _disposed || completed) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } on BackupFailure catch (e) {
      error = e.issue;
    } catch (_) {
      error = BackupIssue.storage;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> export(String password) => _run(() async {
    final bytes = await store.createBackup(password);
    try {
      if (!_disposed) completed = await files.save(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  });

  Future<void> prepare(String password) => _run(() async {
    final bytes = await files.pick();
    if (bytes == null) return;
    try {
      if (_disposed) return;
      final plan = await store.prepareRestore(bytes, password);
      if (_disposed) {
        plan.dispose();
      } else {
        _plan?.dispose();
        _plan = plan;
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  });

  Future<void> restore() => _run(() async {
    final plan = _plan;
    if (plan == null) return;
    try {
      await store.restoreBackup(plan);
      completed = true;
    } finally {
      plan.dispose();
      _plan = null;
    }
  });

  @override
  void dispose() {
    _disposed = true;
    _plan?.dispose();
    _plan = null;
    super.dispose();
  }
}
