part of 'workspace_database.dart';

final class _VpnProfilePatch {
  const _VpnProfilePatch(this.userId, this.profile);
  final String userId;
  final Map<String, dynamic> profile;
}

/// Owns one SQLite connection for the VPN write path. The caller still orders
/// this worker with its other repository operations through _serial.
final class _VpnWriteWorker {
  _VpnWriteWorker(this._isolate, this._commands, this._exit, this._exited);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _exit;
  final Completer<void> _exited;
  bool _closed = false;

  bool get terminated => _exited.isCompleted;

  static Future<_VpnWriteWorker> start(String path, SecretKeyData key) async {
    final bytes = Uint8List.fromList(await key.extractBytes());
    final ready = ReceivePort();
    final exit = ReceivePort();
    final exited = Completer<void>();
    exit.listen((_) {
      if (!exited.isCompleted) exited.complete();
    });
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _vpnWriteWorkerMain,
        (path, bytes, ready.sendPort),
        onExit: exit.sendPort,
        onError: exit.sendPort,
      );
      final result = await Future.any<dynamic>([
        ready.first,
        exited.future.then<dynamic>(
          (_) => throw const VaultFailure(VaultIssue.unavailable),
        ),
      ]);
      if (result is! SendPort) {
        if (result is VaultFailure) throw result;
        throw const VaultFailure(VaultIssue.unavailable);
      }
      return _VpnWriteWorker(isolate, result, exit, exited);
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      exit.close();
      rethrow;
    } finally {
      ready.close();
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<int> write(Object input, int expectedRevision) async {
    if (_closed || terminated) {
      throw const VaultFailure(VaultIssue.unavailable);
    }
    final response = ReceivePort();
    try {
      _commands.send((input, expectedRevision, response.sendPort));
      final result = await Future.any<dynamic>([
        response.first,
        _exited.future.then<dynamic>(
          (_) => throw const VaultFailure(VaultIssue.unavailable),
        ),
      ]);
      if (result case (true, final int revision)) return revision;
      if (result case (false, final Object error)) throw error;
      throw const VaultFailure(VaultIssue.unavailable);
    } finally {
      response.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!terminated) _commands.send(null);
    try {
      await _exited.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
    } finally {
      _exit.close();
    }
  }
}

Future<void> _vpnWriteWorkerMain((String, Uint8List, SendPort) start) async {
  final requests = ReceivePort();
  WorkspaceDatabase? store;
  var announced = false;
  try {
    store = WorkspaceDatabase.open(
      start.$1,
      key: SecretKeyData(start.$2, overwriteWhenDestroyed: true),
    );
    start.$3.send(requests.sendPort);
    announced = true;
    await for (final message in requests) {
      if (message == null) break;
      final (input, expectedRevision, reply) =
          message as (Object, int, SendPort);
      try {
        final revision = input is VpnUser
            ? await store.upsertVpnUser(
                input,
                expectedRevision: expectedRevision,
              )
            : input is _VpnProfilePatch
            ? await store.upsertVpnProfile(
                input.userId,
                input.profile,
                expectedRevision: expectedRevision,
              )
            : await store.writeVpn(
                input is VpnWorkspace ? input.encode() : input as String,
                expectedRevision: expectedRevision,
              );
        reply.send((true, revision));
      } on VaultFailure catch (error) {
        reply.send((false, error));
      } on SyncMergeFailure catch (error) {
        reply.send((false, error));
      } on FormatException catch (error) {
        reply.send((false, error));
      } catch (_) {
        reply.send((false, const VaultFailure(VaultIssue.writeFailed)));
      }
    }
  } catch (_) {
    if (!announced) {
      start.$3.send(const VaultFailure(VaultIssue.unavailable));
    }
  } finally {
    requests.close();
    await store?.close();
  }
}
