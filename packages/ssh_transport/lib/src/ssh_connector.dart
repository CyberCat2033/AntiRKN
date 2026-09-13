import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_network_inventory/antirkn_network_inventory.dart';
import 'package:dartssh2/dartssh2.dart';
import 'linux_agent.dart';
import 'ubuntu_release.dart';

/// Public API exposes read-only inventory, never a shell or arbitrary command.
final class DartSshConnector implements SshConnector {
  const DartSshConnector({
    this.connectTimeout = const Duration(seconds: 20),
    this.commandTimeout = const Duration(seconds: 20),
  });
  final Duration connectTimeout;
  final Duration commandTimeout;

  @override
  Future<SshConnection> connect(
    SshProfile profile, {
    required Future<bool> Function(TrustedHostKey) verifyHostKey,
    required CancellationToken cancellation,
  }) async {
    if (!profile.valid) throw const SshFailure(SshIssue.invalidSettings);
    Socket? socket;
    SSHClient? client;
    ConnectionTask<Socket>? task;
    Object? verificationFailure;
    final identities = <SSHIdentity>[];
    final password = <String?>[
      profile.authMethod == SshAuthMethod.password
          ? profile.secrets[ServerSecret.sshPassword]
          : null,
    ];
    final trustedKey = profile.hostKey;
    Future<bool> Function(TrustedHostKey)? verifier = verifyHostKey;
    var handedOff = false;
    var finished = false;
    try {
      cancellation.check();
      if (profile.authMethod == SshAuthMethod.privateKey) {
        identities.addAll(
          await _decodeKeys(
            profile.secrets[ServerSecret.privateKey]!,
            profile.secrets[ServerSecret.keyPassphrase],
            cancellation,
          ),
        );
      }
      if (profile.authMethod == SshAuthMethod.agent) {
        identities.addAll(await linuxAgentIdentities(cancellation));
      }
      final starting = Socket.startConnect(profile.host, profile.port);
      unawaited(
        starting.then((lateTask) {
          if (finished) lateTask.cancel();
        }, onError: (Object _) {}),
      );
      final connectingTask = await cancellation.bind(
        starting.timeout(connectTimeout),
      );
      task = connectingTask;
      unawaited(
        connectingTask.socket.then((lateSocket) {
          if (finished && !handedOff) lateSocket.destroy();
        }, onError: (Object _) {}),
      );
      socket = await cancellation.bind(
        connectingTask.socket.timeout(connectTimeout),
      );
      cancellation.check();
      final transportSocket = _NativeSocket(socket!);
      client = SSHClient(
        transportSocket,
        username: profile.username,
        identities: identities,
        onPasswordRequest: profile.authMethod == SshAuthMethod.password
            ? () => cancellation.isCancelled ? null : password.first
            : null,
        onVerifyHostKey: (algorithm, fingerprint) async {
          try {
            cancellation.check();
            final key = TrustedHostKey(algorithm, utf8.decode(fingerprint));
            // Defense in depth: reject replacement before calling any UI code.
            if (trustedKey != null && !trustedKey.matches(key)) {
              throw const SshFailure(SshIssue.hostKeyChanged);
            }
            final accepted = await cancellation.bind(verifier!(key));
            cancellation.check();
            if (!accepted) throw const SshFailure(SshIssue.hostKeyRejected);
            return true;
          } catch (error) {
            verificationFailure = error is SshFailure
                ? error
                : const SshFailure(SshIssue.trustSaveFailed);
            return false;
          }
        },
        // Handshake includes a user fingerprint prompt; allow time to inspect it.
        handshakeTimeout: const Duration(minutes: 2),
        authTimeout: connectTimeout,
        keepAliveInterval: const Duration(seconds: 15),
      );
      await cancellation.bind(client.authenticated);
      cancellation.check();
      // Authenticated sessions do not need to retain parsed private keys.
      identities.clear();
      password[0] = null;
      final connection = _Connection(client, transportSocket, commandTimeout);
      handedOff = true;
      return connection;
    } catch (error) {
      if (cancellation.isCancelled) throw const SshFailure(SshIssue.cancelled);
      if (verificationFailure != null) throw verificationFailure!;
      throw _safeFailure(error);
    } finally {
      finished = true;
      verifier = null;
      if (!handedOff) {
        task?.cancel();
        socket?.destroy();
        if (client != null) unawaited(client.close().catchError((Object _) {}));
      }
      identities.clear();
      password[0] = null;
    }
  }
}

Future<List<SSHKeyPair>> _decodeKeys(
  String pem,
  String? passphrase,
  CancellationToken cancellation,
) async {
  final receiver = ReceivePort();
  Isolate? worker;
  try {
    worker = await Isolate.spawn(_keyWorker, (
      receiver.sendPort,
      pem,
      passphrase,
    ));
    final result = await cancellation.bind(
      receiver.first.timeout(const Duration(seconds: 30)),
    );
    if (result is! List<SSHKeyPair> || result.isEmpty) {
      throw const SshFailure(SshIssue.invalidKey);
    }
    return result;
  } finally {
    worker?.kill(priority: Isolate.immediate);
    receiver.close();
  }
}

void _keyWorker((SendPort, String, String?) input) {
  try {
    input.$1.send(
      SSHKeyPair.fromPem(
        input.$2,
        SSHKeyPair.isEncryptedPem(input.$2) ? input.$3 : null,
      ),
    );
  } catch (_) {
    input.$1.send(null);
  }
}

SshFailure _safeFailure(Object error) {
  if (error is SshFailure) return error;
  if (error is TimeoutException) return const SshFailure(SshIssue.timeout);
  if (error is SSHAuthError) return const SshFailure(SshIssue.authentication);
  if (error is SSHKeyDecodeError) return const SshFailure(SshIssue.invalidKey);
  if (error is SSHHostkeyError) {
    return const SshFailure(SshIssue.hostKeyChanged);
  }
  if (error is InventoryDecodeException || error is FormatException) {
    return const SshFailure(SshIssue.invalidInventory);
  }
  return const SshFailure(SshIssue.network);
}

final class _NativeSocket implements SSHSocket {
  _NativeSocket(this.socket);
  final Socket socket;
  @override
  Stream<Uint8List> get stream => socket;
  @override
  StreamSink<List<int>> get sink => socket;
  @override
  Future<void> close() async {
    await socket.close();
  }

  @override
  Future<void> get done => socket.done;
  @override
  void destroy() => socket.destroy();
  @override
  Future<void> flush() => socket.flush();
}

final class _Connection implements SshConnection {
  _Connection(this.client, this.socket, this.commandTimeout);
  final SSHClient client;
  final _NativeSocket socket;
  final Duration commandTimeout;
  bool _closed = false;
  bool _observing = false;
  @override
  Future<void> get done => client.done;

  @override
  Future<ServerObservation> observe(CancellationToken cancellation) async {
    if (_closed) throw const SshFailure(SshIssue.disconnected);
    if (_observing) throw const SshFailure(SshIssue.commandFailed);
    _observing = true;
    try {
      final osRelease = await _read(
        'cat /etc/os-release',
        cancellation,
        limit: 16384,
      );
      final os = ubuntuNameFromOsRelease(osRelease);
      final architecture = (await _read(
        'uname -m',
        cancellation,
        limit: 1024,
      )).trim();
      if (architecture != 'x86_64') {
        throw const SshFailure(SshIssue.unsupportedOs);
      }
      final observedAt = DateTime.now().toUtc();
      final outputs = <InventoryDocument, String>{};
      for (final entry in IpCommandOutputs.commands.entries) {
        outputs[entry.key] = await _read(entry.value.join(' '), cancellation);
      }
      final network = const IpInventoryParser().parse(
        outputs: IpCommandOutputs(
          addresses: outputs[InventoryDocument.addresses]!,
          routesV4: outputs[InventoryDocument.routesV4]!,
          routesV6: outputs[InventoryDocument.routesV6]!,
          rulesV4: outputs[InventoryDocument.rulesV4]!,
          rulesV6: outputs[InventoryDocument.rulesV6]!,
        ),
        serverId: SshProfile.serverId,
        observedAt: observedAt,
        source: NetworkSource.iproute2,
        sshPeer: IpAddress.parse(socket.socket.remoteAddress.address),
      );
      return ServerObservation(
        os: os,
        architecture: architecture,
        network: network,
      );
    } catch (error) {
      // Failed/cancelled command ends the transport, so retries use a new session.
      close();
      throw cancellation.isCancelled
          ? const SshFailure(SshIssue.cancelled)
          : _safeFailure(error);
    } finally {
      _observing = false;
    }
  }

  Future<String> _read(
    String command,
    CancellationToken cancellation, {
    int limit = 1024 * 1024,
  }) async {
    cancellation.check();
    SSHSession? session;
    StreamSubscription<Uint8List>? out;
    StreamSubscription<Uint8List>? err;
    final output = BytesBuilder(copy: false);
    var errorBytes = 0;
    final finished = Completer<String>();
    var streamsEnded = 0;
    var exitObserved = false;
    void fail(Object failure) {
      if (!finished.isCompleted) finished.completeError(failure);
    }

    void completeIfReady() {
      if (streamsEnded != 2 || !exitObserved || finished.isCompleted) return;
      if (session!.exitCode != 0 || session.exitSignal != null) {
        fail(const SshFailure(SshIssue.commandFailed));
      } else {
        try {
          finished.complete(utf8.decode(output.takeBytes()));
        } catch (_) {
          fail(const SshFailure(SshIssue.invalidInventory));
        }
      }
    }

    void streamEnded() {
      streamsEnded++;
      completeIfReady();
    }

    try {
      session = await cancellation.bind(
        client.execute(command).timeout(commandTimeout),
      );
      // Attach error handling before any stream can complete.
      final result = cancellation.bind(finished.future.timeout(commandTimeout));
      unawaited(
        session!.waitForExit().then((_) {
          exitObserved = true;
          completeIfReady();
        }, onError: (Object _) => fail(const SshFailure(SshIssue.network))),
      );
      out = session.stdout.listen(
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
      err = session.stderr.listen(
        (chunk) {
          errorBytes += chunk.length;
          if (errorBytes > 16384) fail(const SshFailure(SshIssue.outputLimit));
        },
        onError: (Object _) => fail(const SshFailure(SshIssue.network)),
        onDone: streamEnded,
      );
      unawaited(session.stdin.close().catchError((Object _) {}));
      return await result;
    } finally {
      await out?.cancel();
      await err?.cancel();
      session?.close();
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    socket.destroy();
    unawaited(client.close().catchError((Object _) {}));
  }
}
