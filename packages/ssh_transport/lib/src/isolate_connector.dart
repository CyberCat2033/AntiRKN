import 'dart:async';
import 'dart:isolate';

import 'package:antirkn_domain/antirkn_domain.dart';

import 'ssh_connector.dart';

/// The socket, handshake, signing, rekeying and inventory stay off the UI isolate.
/// Only typed observations and host-key decisions cross this boundary.
final class DartSshConnector implements SshConnector {
  const DartSshConnector({
    this.connectTimeout = const Duration(seconds: 60),
    this.commandTimeout = const Duration(seconds: 60),
  });
  final Duration connectTimeout;
  final Duration commandTimeout;

  @override
  Future<SshConnection> connect(
    SshProfile profile, {
    required Future<bool> Function(TrustedHostKey) verifyHostKey,
    required CancellationToken cancellation,
  }) async {
    cancellation.check();
    if (!profile.valid) throw const SshFailure(SshIssue.invalidSettings);
    final bridge = _WorkerConnection(verifyHostKey);
    try {
      bridge.worker = await Isolate.spawn(
        _runWorker,
        (bridge.events.sendPort, connectTimeout, commandTimeout),
        onError: bridge.events.sendPort,
        onExit: bridge.events.sendPort,
      );
      await cancellation.bind(bridge.ready.future.timeout(connectTimeout));
      await cancellation.bind(bridge.request('connect', profile));
      cancellation.check();
      bridge.verifier = null;
      return bridge;
    } catch (_) {
      bridge.close();
      rethrow;
    }
  }
}

final class _WorkerConnection implements SshConnection {
  _WorkerConnection(this.verifier) {
    events.listen(_receive);
    // Startup can fail before connect begins waiting for ready.
    unawaited(ready.future.then((_) {}, onError: (Object _) {}));
  }
  final events = ReceivePort();
  final ready = Completer<void>();
  final ended = Completer<void>();
  final pending = <int, Completer<Object?>>{};
  Future<bool> Function(TrustedHostKey)? verifier;
  Isolate? worker;
  SendPort? commands;
  int sequence = 0;
  bool closed = false;
  bool connectionEnded = false;

  void _receive(Object? message) {
    switch (message) {
      case ('ready', final SendPort port):
        commands = port;
        if (!ready.isCompleted) ready.complete();
      case ('result', final int id, final Object? value):
        pending.remove(id)?.complete(value);
        if (connectionEnded && pending.isEmpty) close();
      case ('failure', final int id, final SshIssue issue):
        pending.remove(id)?.completeError(SshFailure(issue));
        if (connectionEnded && pending.isEmpty) close();
      case ('ended',):
        connectionEnded = true;
        if (pending.isEmpty) close();
      case ('verify', final TrustedHostKey key):
        unawaited(_verify(key));
      default:
        // Includes unexpected worker errors/exits; no raw exception escapes.
        close();
    }
  }

  Future<void> _verify(TrustedHostKey key) async {
    try {
      final accepted = await verifier!(key);
      if (!closed) commands!.send(('decision', accepted));
    } catch (error) {
      if (!closed) {
        commands!.send((
          'decision',
          error is SshFailure ? error.issue : SshIssue.trustSaveFailed,
        ));
      }
    }
  }

  Future<Object?> request(String operation, Object? payload) {
    if (closed) throw const SshFailure(SshIssue.disconnected);
    final id = sequence++;
    final response = Completer<Object?>();
    pending[id] = response;
    commands!.send((operation, id, payload));
    return response.future;
  }

  @override
  Future<ServerObservation> observe(CancellationToken cancellation) async {
    try {
      cancellation.check();
      return (await cancellation.bind(request('observe', null)))
          as ServerObservation;
    } catch (_) {
      close();
      rethrow;
    }
  }

  @override
  Future<void> get done => ended.future;

  @override
  void close() {
    if (closed) return;
    closed = true;
    verifier = null;
    commands?.send(('close',));
    // A worker doing CPU-heavy crypto must also be interruptible.
    final running = worker;
    Timer(
      const Duration(seconds: 1),
      () => running?.kill(priority: Isolate.immediate),
    );
    events.close();
    const failure = SshFailure(SshIssue.disconnected);
    if (!ready.isCompleted) ready.completeError(failure);
    for (final response in pending.values) {
      response.completeError(failure);
    }
    pending.clear();
    ended.complete();
  }
}

void _runWorker((SendPort, Duration, Duration) input) {
  final (events, connectTimeout, commandTimeout) = input;
  final commands = ReceivePort();
  final cancellation = CancellationToken();
  SshConnection? connection;
  Completer<bool>? decision;
  commands.listen((message) async {
    if (message case ('close',)) {
      cancellation.cancel();
      connection?.close();
      commands.close();
      // Let cancelled connect/observe unwind and destroy their sockets first.
      Timer(const Duration(milliseconds: 100), Isolate.exit);
      return;
    }
    if (message case ('decision', final Object value)) {
      final current = decision;
      if (current != null && !current.isCompleted) {
        if (value is bool) {
          current.complete(value);
        } else {
          current.completeError(SshFailure(value as SshIssue));
        }
      }
      return;
    }
    if (message case (
      final String operation,
      final int id,
      final Object? payload,
    )) {
      try {
        switch (operation) {
          case 'connect':
            connection =
                await DirectSshConnector(
                  connectTimeout: connectTimeout,
                  commandTimeout: commandTimeout,
                ).connect(
                  payload as SshProfile,
                  cancellation: cancellation,
                  verifyHostKey: (key) async {
                    decision = Completer<bool>();
                    events.send(('verify', key));
                    try {
                      return await cancellation.bind(decision!.future);
                    } finally {
                      decision = null;
                    }
                  },
                );
            unawaited(
              connection!.done.then(
                (_) => events.send(('ended',)),
                onError: (Object _) => events.send(('ended',)),
              ),
            );
            events.send(('result', id, null));
          case 'observe':
            final observation = await connection!.observe(cancellation);
            events.send(('result', id, observation));
        }
      } catch (error) {
        events.send((
          'failure',
          id,
          error is SshFailure ? error.issue : SshIssue.network,
        ));
      }
    }
  });
  events.send(('ready', commands.sendPort));
}
