import 'package:antirkn_mihomo_runtime/antirkn_mihomo_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final gate = MihomoWorkerGate.instance;
  tearDown(gate.resume);

  test('quiesce waits for active runs and blocks new ones', () async {
    gate.enter();
    var done = false;
    final waiting = gate.quiesce(const Duration(seconds: 5)).then((ok) {
      done = true;
      return ok;
    });
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    expect(gate.enter, throwsFormatException);
    gate.leave();
    expect(await waiting, isTrue);
    expect(gate.active, 0);
    gate.resume();
    gate.enter();
    gate.leave();
  });

  test('a run that does not finish reopens the gate', () async {
    gate.enter();
    expect(await gate.quiesce(const Duration(milliseconds: 20)), isFalse);
    expect(gate.closed, isFalse);
    gate.leave();
  });
}
