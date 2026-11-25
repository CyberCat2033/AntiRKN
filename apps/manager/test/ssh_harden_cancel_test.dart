// UI-14: the preparing stage of SSH hardening can be cancelled.
import 'package:antirkn_manager/ssh/ssh_harden_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ssh_harden_controller_test.dart' as harden;

void main() {
  test('cancelling preparation returns to input without an error', () async {
    final session = harden.HardenSession()..current = harden.original();
    final flow = SshHardenController(session, pollAutomatically: false);
    addTearDown(() {
      flow.dispose();
      session.dispose();
      session.network.dispose();
    });
    final start = flow.start(
      username: 'fixture',
      port: 2222,
      password: 'new-fixture-password',
    );
    expect(flow.stage, SshHardenStage.preparing);
    expect(flow.canCancelPreparation, isTrue);
    flow.cancelPreparation();
    expect(flow.canCancelPreparation, isFalse);
    await start;
    expect(flow.stage, SshHardenStage.input);
    expect(flow.errorCode, isNull);
    expect(session.calls, isNot(contains('ssh_harden')));
  });
}
