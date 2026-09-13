import 'dart:async';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';
import 'package:test/test.dart';

Matcher issue(SshIssue issue) =>
    isA<SshFailure>().having((e) => e.issue, 'issue', issue);
SshProfile profile(int port) => SshProfile(
  host: '127.0.0.1',
  port: port,
  username: 'test',
  authMethod: SshAuthMethod.password,
  secrets: {ServerSecret.sshPassword: 'unused-test-password'},
);

void main() {
  test(
    'invalid settings reject before transport or host trust callback',
    () async {
      var verified = false;
      await expectLater(
        const DartSshConnector().connect(
          profile(0),
          verifyHostKey: (_) async {
            verified = true;
            return true;
          },
          cancellation: CancellationToken(),
        ),
        throwsA(issue(SshIssue.invalidSettings)),
      );
      expect(verified, isFalse);
    },
  );

  test(
    'cancelled handshake closes a real socket without sending password',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = Completer<Socket>();
      final listener = server.listen(accepted.complete);
      addTearDown(listener.cancel);
      final cancellation = CancellationToken();
      final connecting = const DartSshConnector().connect(
        profile(server.port),
        verifyHostKey: (_) async => throw StateError('no handshake completed'),
        cancellation: cancellation,
      );
      final expectation = expectLater(
        connecting,
        throwsA(issue(SshIssue.cancelled)),
      );
      final socket = await accepted.future;
      addTearDown(socket.destroy);
      final bytes = socket.expand((chunk) => chunk).toList();
      cancellation.cancel();
      await expectation;
      final received = String.fromCharCodes(
        await bytes.timeout(const Duration(seconds: 2)),
      );
      expect(received.contains('unused-test-password'), isFalse);
    },
  );

  test('key parse failure exposes only a safe code', () async {
    final bad = SshProfile(
      host: '127.0.0.1',
      port: 22,
      username: 'test',
      authMethod: SshAuthMethod.privateKey,
      secrets: {
        ServerSecret.privateKey: 'invalid-private-material',
        ServerSecret.keyPassphrase: 'unused-test-passphrase',
      },
    );
    await expectLater(
      const DartSshConnector().connect(
        bad,
        verifyHostKey: (_) async => true,
        cancellation: CancellationToken(),
      ),
      throwsA(issue(SshIssue.invalidKey)),
    );
  });

  test(
    'cancellation observes late failures without leaking uncaught errors',
    () async {
      final token = CancellationToken()..cancel();
      final work = Completer<int>();
      await expectLater(
        token.bind(work.future),
        throwsA(issue(SshIssue.cancelled)),
      );
      work.completeError(StateError('late failure'));
      await Future<void>.delayed(Duration.zero);
    },
  );
}
