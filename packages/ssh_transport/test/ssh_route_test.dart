import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:test/test.dart';

SshProfile server(String id, [String? jump]) => SshProfile(
  id: id,
  host: '$id.example',
  port: 22,
  username: 'test',
  authMethod: SshAuthMethod.password,
  jumpServerId: jump,
  secrets: const {ServerSecret.sshPassword: 'fixture-only'},
);
void main() {
  test('routes preserve hop order and direct connections', () {
    final a = server('a'), b = server('b', 'a'), c = server('c', 'b');
    expect(resolveSshRoute(c, [b, a, c]).map((p) => p.id), ['a', 'b', 'c']);
    expect(resolveSshRoute(a, []), [a]);
    expect(
      c.withHostKey(const TrustedHostKey('test', 'fixture')).jumpServerId,
      'b',
    );
  });
  test('missing, self and indirect cycles never fall back to direct', () {
    for (final (target, catalog) in [
      (server('a', 'missing'), <SshProfile>[]),
      (server('a', 'a'), [server('a')]),
      (server('a', 'b'), [server('b', 'a')]),
    ]) {
      expect(
        () => resolveSshRoute(target, catalog),
        throwsA(
          isA<SshFailure>().having(
            (e) => e.issue,
            'issue',
            SshIssue.invalidJumpRoute,
          ),
        ),
      );
    }
  });
  test('changing the jump changes connection settings', () {
    expect(server('a').hasSameConnectionSettings(server('a', 'b')), isFalse);
    expect(
      server('a', 'b').hasSameConnectionSettings(server('a', 'b')),
      isTrue,
    );
  });
}
