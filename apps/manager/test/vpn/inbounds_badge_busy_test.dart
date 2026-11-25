import 'package:flutter_test/flutter_test.dart';
import '../vpn_controller_test.dart' as f;

void main() {
  test(
    'connections.busy does not trigger foregroundBusy or workspaceBusy',
    () async {
      final vpn = f.controller(f.MemoryVpn(), {});
      addTearDown(vpn.dispose);
      await vpn.load();

      expect(vpn.busy, isFalse);
      expect(vpn.foregroundBusy, isFalse);
      expect(vpn.workspaceBusy, isFalse);

      // Simulate active background proxy connection check on inbound-1
      vpn.connections.current = (target: 'server-1', resource: 'inbound-1');

      expect(vpn.connections.busy, isTrue);
      expect(vpn.busy, isTrue);
      // Crucial invariant: ping / connection checks must NOT trigger page-level foreground progress
      expect(vpn.foregroundBusy, isFalse);
      expect(vpn.workspaceBusy, isFalse);

      vpn.connections.current = null;
      expect(vpn.connections.busy, isFalse);
      expect(vpn.busy, isFalse);
      expect(vpn.foregroundBusy, isFalse);
      expect(vpn.workspaceBusy, isFalse);
    },
  );
}
