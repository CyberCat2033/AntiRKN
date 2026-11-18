import 'package:antirkn_manager/vpn/vpn_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every protocol shape of a resource the server no longer has', () {
    // VLESS state.
    expect(observationGone({'deleted': true}), isTrue);
    expect(observationGone({'exists': false}), isTrue);
    // AmneziaWG / TrustTunnel state: the confirmed deletion lives in spec.
    expect(
      observationGone({
        'confirmed': true,
        'spec': {'deleted': true, 'enabled': false},
      }),
      isTrue,
    );
    expect(
      observationGone({
        'confirmed': true,
        'spec': {'deleted': false, 'enabled': true},
      }),
      isFalse,
    );
    expect(observationGone({'exists': true, 'deleted': false}), isFalse);
  });
}
