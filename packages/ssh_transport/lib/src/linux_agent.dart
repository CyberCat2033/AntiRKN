import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:dartssh2/dartssh2.dart';

bool get linuxSshAgentAvailable =>
    Platform.isLinux &&
    (Platform.environment['SSH_AUTH_SOCK']?.isNotEmpty ?? false);

/// Local agent protocol only: list public identities and request a signature.
/// Never forwards the agent to the VPS, exports keys, adds or removes identities.
Future<List<SSHIdentity>> linuxAgentIdentities(
  CancellationToken cancellation,
) async {
  if (!linuxSshAgentAvailable) {
    throw const SshFailure(SshIssue.agentUnavailable);
  }
  final path = Platform.environment['SSH_AUTH_SOCK']!;
  final reply = _Reader(
    await _request(path, Uint8List.fromList([11]), cancellation),
  );
  if (reply.byte() != 12) throw const SshFailure(SshIssue.agentUnavailable);
  final count = reply.uint32();
  if (count > 32) throw const SshFailure(SshIssue.agentUnavailable);
  final identities = <SSHIdentity>[];
  for (var i = 0; i < count; i++) {
    final publicKey = reply.string();
    reply.string(); // Comments are not needed and are never logged.
    final publicType = SSHHostKey.getType(publicKey);
    if (!const {
      'ssh-ed25519',
      'ssh-rsa',
      'ecdsa-sha2-nistp256',
      'ecdsa-sha2-nistp384',
      'ecdsa-sha2-nistp521',
    }.contains(publicType)) {
      continue;
    }
    final signatureType = publicType == 'ssh-rsa' ? 'rsa-sha2-512' : publicType;
    identities.add(
      SSHIdentity.custom(
        type: signatureType,
        publicKey: SSHRawHostKey(publicKey),
        shouldProbe: true,
        signer: (data) async {
          final packet = BytesBuilder(copy: false)
            ..addByte(13)
            ..add(_string(publicKey))
            ..add(_string(data))
            ..add(_uint32(publicType == 'ssh-rsa' ? 4 : 0));
          final response = _Reader(
            await _request(path, packet.takeBytes(), cancellation),
          );
          if (response.byte() != 14) {
            throw const SshFailure(SshIssue.authentication);
          }
          final signature = response.string();
          if (!response.ended ||
              SSHSignature.getType(signature) != signatureType) {
            throw const SshFailure(SshIssue.authentication);
          }
          return SSHRawSignature(signature);
        },
      ),
    );
  }
  if (!reply.ended || identities.isEmpty) {
    throw const SshFailure(SshIssue.agentUnavailable);
  }
  return identities;
}

Uint8List _uint32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
Uint8List _string(Uint8List value) =>
    (BytesBuilder(copy: false)
          ..add(_uint32(value.length))
          ..add(value))
        .takeBytes();

Future<Uint8List> _request(
  String path,
  Uint8List packet,
  CancellationToken cancellation,
) async {
  Socket? socket;
  ConnectionTask<Socket>? task;
  StreamIterator<Uint8List>? input;
  try {
    cancellation.check();
    task = await Socket.startConnect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    socket = await cancellation.bind(
      task.socket.timeout(const Duration(seconds: 5)),
    );
    socket!.add(_string(packet));
    input = StreamIterator(socket);
    final bytes = BytesBuilder(copy: false);
    final watch = Stopwatch()..start();
    int? length;
    while (true) {
      final remaining = const Duration(seconds: 30) - watch.elapsed;
      if (remaining.isNegative) throw const SshFailure(SshIssue.timeout);
      if (!await cancellation.bind(input.moveNext().timeout(remaining))) {
        throw const SshFailure(SshIssue.agentUnavailable);
      }
      if (bytes.length + input.current.length > 262148) {
        throw const SshFailure(SshIssue.agentUnavailable);
      }
      bytes.add(input.current);
      if (length == null && bytes.length >= 4) {
        length = ByteData.sublistView(bytes.toBytes(), 0, 4).getUint32(0);
      }
      if (length != null) {
        if (length == 0 || length > 262144 || bytes.length > length + 4) {
          throw const SshFailure(SshIssue.agentUnavailable);
        }
        if (bytes.length == length + 4) {
          return Uint8List.sublistView(bytes.takeBytes(), 4);
        }
      }
    }
  } on SshFailure {
    rethrow;
  } catch (_) {
    throw const SshFailure(SshIssue.agentUnavailable);
  } finally {
    socket?.destroy();
    task?.cancel();
    await input?.cancel();
  }
}

final class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  bool get ended => offset == bytes.length;
  int byte() {
    if (offset >= bytes.length) {
      throw const SshFailure(SshIssue.agentUnavailable);
    }
    return bytes[offset++];
  }

  int uint32() {
    if (offset + 4 > bytes.length) {
      throw const SshFailure(SshIssue.agentUnavailable);
    }
    final value = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    offset += 4;
    return value;
  }

  Uint8List string() {
    final length = uint32();
    if (offset + length > bytes.length) {
      throw const SshFailure(SshIssue.agentUnavailable);
    }
    final value = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return value;
  }
}
