import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:dartssh2/dartssh2.dart';

const sudoPrompt = '__ANTIRKN_SUDO_PASSWORD__';

final class RemoteCommandResult {
  const RemoteCommandResult(
    this.output,
    this.error,
    this.exitCode,
    this.signalled,
    this.passwordSent,
  );
  final String output;
  final String error;
  final int? exitCode;
  final bool signalled;
  final bool passwordSent;
  bool get succeeded => exitCode == 0 && !signalled;
  @override
  String toString() => 'RemoteCommandResult(redacted)';
}

final class SshCommandExecutor {
  const SshCommandExecutor(this.client, this.commandTimeout);
  final SSHClient client;
  final Duration commandTimeout;
  Future<RemoteCommandResult> execute(
    String command,
    CancellationToken cancellation, {
    int limit = 1024 * 1024,
    Duration? timeout,
    String? sudoPassword,
  }) async {
    cancellation.check();
    SSHSession? session;
    var acceptingSession = true;
    StreamSubscription<Uint8List>? out;
    StreamSubscription<Uint8List>? err;
    final output = BytesBuilder(copy: false);
    final errors = BytesBuilder(copy: false);
    var passwordSent = false;
    final finished = Completer<RemoteCommandResult>();
    var streamsEnded = 0;
    var exitObserved = false;
    void fail(Object failure) {
      if (!finished.isCompleted) finished.completeError(failure);
    }

    void completeIfReady() {
      if (streamsEnded != 2 || !exitObserved || finished.isCompleted) return;
      try {
        finished.complete(
          RemoteCommandResult(
            utf8.decode(output.takeBytes()),
            utf8.decode(errors.takeBytes(), allowMalformed: true),
            session!.exitCode,
            session!.exitSignal != null,
            passwordSent,
          ),
        );
      } catch (_) {
        fail(const SshFailure(SshIssue.invalidInventory));
      }
    }

    void streamEnded() {
      streamsEnded++;
      completeIfReady();
    }

    try {
      session = await cancellation.bind(
        client
            .execute(command)
            .then((opened) {
              // A channel opened after timeout/cancellation still needs closing.
              if (acceptingSession) {
                session = opened;
              } else {
                opened.close();
              }
              return opened;
            })
            .timeout(timeout ?? commandTimeout),
      );
      // Attach error handling before any stream can complete.
      final result = cancellation.bind(
        finished.future.timeout(timeout ?? commandTimeout),
      );
      unawaited(
        session!.waitForExit().then((_) {
          exitObserved = true;
          completeIfReady();
        }, onError: (Object _) => fail(const SshFailure(SshIssue.network))),
      );
      out = session!.stdout.listen(
        (chunk) {
          if (finished.isCompleted) return;
          if (output.length + chunk.length > limit) {
            fail(const SshFailure(SshIssue.outputLimit));
            return;
          }
          output.add(chunk);
        },
        onError: (Object _) => fail(const SshFailure(SshIssue.network)),
        onDone: streamEnded,
      );
      err = session!.stderr.listen(
        (chunk) {
          if (finished.isCompleted) return;
          if (errors.length + chunk.length > 16384) {
            fail(const SshFailure(SshIssue.outputLimit));
            return;
          }
          errors.add(chunk);
          // No PTY, no echo. Send at most one line, only after sudo requests it.
          // NOPASSWD commands never receive the password on their stdin.
          if (!passwordSent &&
              !cancellation.isCancelled &&
              sudoPassword != null &&
              utf8
                  .decode(errors.toBytes(), allowMalformed: true)
                  .contains(sudoPrompt)) {
            passwordSent = true;
            try {
              session!.stdin.add(utf8.encode('$sudoPassword\n'));
              unawaited(session!.stdin.close().catchError((Object _) {}));
            } catch (_) {
              fail(const SshFailure(SshIssue.disconnected));
            }
          }
        },
        onError: (Object _) => fail(const SshFailure(SshIssue.network)),
        onDone: streamEnded,
      );
      if (sudoPassword == null) {
        unawaited(session!.stdin.close().catchError((Object _) {}));
      }
      return await result;
    } finally {
      acceptingSession = false;
      await out?.cancel();
      await err?.cancel();
      session?.close();
    }
  }
}
