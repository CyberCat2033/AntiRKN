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
import 'server_inventory_reader.dart';
import 'parallel_reads.dart';
import 'command_executor.dart';
import 'privilege_runner.dart';
import 'inventory_probes.dart';

/// Public API exposes read-only inventory, never a shell or arbitrary command.
final class DirectSshConnector implements SshConnector {
  const DirectSshConnector({
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
    List<SshProfile> jumpHosts = const [],
    Future<bool> Function(SshProfile, TrustedHostKey)? verifyJumpHostKey,
  }) async {
    final route = resolveSshRoute(profile, jumpHosts);
    if (route.length != jumpHosts.length + 1 ||
        List.generate(
          jumpHosts.length,
          (i) => route[i].id != jumpHosts[i].id,
        ).any((different) => different)) {
      throw const SshFailure(SshIssue.invalidJumpRoute);
    }
    if (jumpHosts.isNotEmpty &&
        (verifyJumpHostKey == null ||
            {profile.id, ...jumpHosts.map((p) => p.id)}.length !=
                jumpHosts.length + 1)) {
      throw const SshFailure(SshIssue.invalidJumpRoute);
    }
    final hops = <_Connection>[];
    SSHSocket? forwarded;
    try {
      for (var index = 0; index < jumpHosts.length; index++) {
        final jump = jumpHosts[index];
        late final _Connection hop;
        try {
          hop = await _connectOne(
            jump,
            verifyHostKey: (key) => verifyJumpHostKey!(jump, key),
            cancellation: cancellation,
            forwarded: forwarded,
          );
        } on SshFailure catch (error) {
          if (error.issue == SshIssue.hostKeyChanged) {
            throw const SshFailure(SshIssue.jumpHostKeyChanged);
          }
          rethrow;
        }
        hops.add(hop);
        final next = index + 1 < jumpHosts.length
            ? jumpHosts[index + 1]
            : profile;
        var accepting = true;
        try {
          forwarded = await cancellation.bind(
            hop.client
                .forwardLocal(next.host, next.port)
                .then((channel) {
                  if (!accepting) channel.destroy();
                  return channel;
                })
                .timeout(connectTimeout),
          );
        } finally {
          accepting = false;
        }
      }
      final target = await _connectOne(
        profile,
        verifyHostKey: verifyHostKey,
        cancellation: cancellation,
        forwarded: forwarded,
      );
      target.hops.addAll(hops);
      return target;
    } catch (error) {
      forwarded?.destroy();
      for (final hop in hops.reversed) {
        hop.close();
      }
      throw cancellation.isCancelled
          ? const SshFailure(SshIssue.cancelled)
          : _safeFailure(error);
    }
  }

  Future<_Connection> _connectOne(
    SshProfile profile, {
    required Future<bool> Function(TrustedHostKey) verifyHostKey,
    required CancellationToken cancellation,
    SSHSocket? forwarded,
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
      if (forwarded == null) {
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
      }
      cancellation.check();
      final transportSocket = forwarded ?? _NativeSocket(socket!);
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
      final connection = _Connection(
        client,
        transportSocket,
        commandTimeout,
        profile.id,
        socket == null
            ? IpAddress.tryParse(profile.host)
            : IpAddress.parse(socket.remoteAddress.address),
      );
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
        forwarded?.destroy();
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
  _Connection(
    this.client,
    this.socket,
    this.commandTimeout,
    this.serverId,
    this.peer,
  );
  final IpAddress? peer;
  final hops = <_Connection>[];
  final String serverId;
  final SSHClient client;
  final SSHSocket socket;
  final Duration commandTimeout;
  late final _executor = SshCommandExecutor(client, commandTimeout);
  bool _closed = false;
  bool _observing = false;
  @override
  Future<void> get done => client.done;

  @override
  Future<ServerObservation> observe(
    CancellationToken cancellation, {
    bool useSudo = false,
    String? sudoPassword,
  }) async {
    if (_closed) throw const SshFailure(SshIssue.disconnected);
    if (_observing) throw const SshFailure(SshIssue.commandFailed);
    _observing = true;
    try {
      final privileges = PrivilegeRunner(
        _executor,
        cancellation,
        password: sudoPassword,
      );
      if (useSudo && !validSudoPassword(sudoPassword)) {
        throw const SshFailure(SshIssue.invalidSudoPassword);
      }
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
      final outputs = Map.fromEntries(
        await parallelReads(
          IpCommandOutputs.commands.entries,
          (entry) async => MapEntry(
            entry.key,
            await _read(entry.value.join(' '), cancellation),
          ),
        ),
      );
      final network = const IpInventoryParser().parse(
        outputs: IpCommandOutputs(
          addresses: outputs[InventoryDocument.addresses]!,
          routesV4: outputs[InventoryDocument.routesV4]!,
          routesV6: outputs[InventoryDocument.routesV6]!,
          rulesV4: outputs[InventoryDocument.rulesV4]!,
          rulesV6: outputs[InventoryDocument.rulesV6]!,
        ),
        serverId: serverId,
        observedAt: observedAt,
        source: NetworkSource.iproute2,
        sshPeer: peer,
      );
      return ServerObservation(
        os: os,
        architecture: architecture,
        network: network,
        software: await ServerInventoryReader((command) async {
          final raw = await _read(command, cancellation, limit: 65536);
          if (useSudo &&
              raw.trim() == '@denied' &&
              InventoryProbes.canElevate(command)) {
            return privileges.read(command);
          }
          return raw;
        }).read(cancellation),
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

  @override
  Future<PrivilegeCheck> checkPrivileges(
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    if (_closed) throw const SshFailure(SshIssue.disconnected);
    try {
      return await PrivilegeRunner(
        _executor,
        cancellation,
        password: sudoPassword,
      ).check();
    } catch (error) {
      throw cancellation.isCancelled
          ? const SshFailure(SshIssue.cancelled)
          : _safeFailure(error);
    }
  }

  Future<String> _read(
    String command,
    CancellationToken cancellation, {
    int limit = 1024 * 1024,
    Duration? timeout,
  }) async {
    final result = await _executor.execute(
      command,
      cancellation,
      limit: limit,
      timeout: timeout,
    );
    if (!result.succeeded) throw const SshFailure(SshIssue.commandFailed);
    return result.output;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    socket.destroy();
    for (final hop in hops.reversed) {
      hop.close();
    }
    hops.clear();
    unawaited(client.close().catchError((Object _) {}));
  }
}
