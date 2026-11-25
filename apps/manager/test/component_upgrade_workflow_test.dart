import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

void main() {
  test(
    'checkComponentUpgrade fetches plan with dynamic upstream resolution',
    () async {
      final journal = MemoryRunnerJournal();
      final transport = FakeRunnerTransport(journal)..installed = true;
      final controller = RunnerController(
        serverId: 'fixture',
        transport: () => transport,
        store: journal,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
      );

      expect(controller.componentUpgradePlan, isNull);

      await controller.checkComponentUpgrade(
        'xray',
        candidate: {
          'component': 'xray',
          'version': '26.9.9',
          'architecture': 'x86_64',
          'sha256': 'a' * 64,
          'url':
              'https://github.com/XTLS/Xray-core/releases/download/v26.9.9/Xray-linux-64.zip',
        },
      );

      final plan = controller.componentUpgradePlan;
      expect(plan, isNotNull);
      expect(plan!['component'], 'xray');
      expect(plan['installed'], isTrue);
      expect(plan['currentVersion'], '26.7.28');
      expect(plan['candidateVersion'], '26.9.9');
      expect(plan['upgradable'], isTrue);
      expect(plan['source'], 'native');

      controller.dispose();
    },
  );

  test(
    'applyComponentUpgrade submits job with fingerprint and tracks checkpoints',
    () async {
      final journal = MemoryRunnerJournal();
      final transport = FakeRunnerTransport(journal)..installed = true;
      final controller = RunnerController(
        serverId: 'fixture',
        transport: () => transport,
        store: journal,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
      );

      final candidate = {
        'component': 'xray',
        'version': '26.9.9',
        'architecture': 'x86_64',
        'sha256': 'a' * 64,
      };

      await controller.checkComponentUpgrade('xray', candidate: candidate);
      final plan = controller.componentUpgradePlan;
      expect(plan, isNotNull);

      // Apply component upgrade
      await controller.applyComponentUpgrade(plan!, candidate);

      expect(transport.submissions, 1);
      final submitReq = transport.requests.firstWhere(
        (r) =>
            r.json['action'] == 'submit' &&
            r.json['kind'] == 'component_upgrade_apply',
      );
      expect(submitReq.json['count'], 6);
      expect(submitReq.json['interval'], 1);
      expect(submitReq.json['fingerprint'], plan['fingerprint']);

      expect(controller.selected, isNotNull);
      expect(controller.selected!.kind, 'component_upgrade_apply');

      controller.dispose();
    },
  );

  test(
    'applyComponentUpgrade handles self-healing rollback on canary failure',
    () async {
      final journal = MemoryRunnerJournal();
      final transport = FakeRunnerTransport(journal)..installed = true;
      final controller = RunnerController(
        serverId: 'fixture',
        transport: () => transport,
        store: journal,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
      );

      final candidate = {
        'component': 'xray',
        'version': '26.9.9',
        'architecture': 'x86_64',
        'sha256': 'a' * 64,
      };

      await controller.checkComponentUpgrade('xray', candidate: candidate);
      final plan = controller.componentUpgradePlan;
      expect(plan, isNotNull);

      await controller.applyComponentUpgrade(plan!, candidate);

      expect(controller.selected, isNotNull);
      final id = controller.selected!.id;

      // Simulate failure during execution: job failed with upgrade_rolled_back
      transport.job = runnerJob(
        id,
        kind: 'component_upgrade_apply',
        status: 'failed',
        progress: 5,
        count: 6,
        interval: 1,
        sequence: 4,
        events: [
          {
            'sequence': 3,
            'timestamp': 1789340001,
            'code': 'upgrade_switched',
            'progress': 5,
            'total': 6,
          },
          {
            'sequence': 4,
            'timestamp': 1789340005,
            'code': 'upgrade_rolled_back',
            'progress': 5,
            'total': 6,
          },
        ],
      );

      await controller.refresh();

      expect(controller.selected, isNotNull);
      expect(controller.selected!.status, 'failed');
      expect(controller.selected!.events.last.code, 'upgrade_rolled_back');

      controller.dispose();
    },
  );

  test(
    'adopted component with custom systemd unit retains source and paths',
    () async {
      final journal = MemoryRunnerJournal();
      final transport = FakeRunnerTransport(journal)
        ..installed = true
        ..componentUpgradePlanData = {
          'component': 'panel',
          'installed': true,
          'source': 'adopted_unit',
          'currentVersion': '3.7.0',
          'candidateVersion': '3.8.0',
          'binaryPath': '/opt/custom-x-ui/x-ui',
          'configPath': '/opt/custom-x-ui/bin/config.json',
          'units': ['custom-x-ui.service'],
          'upgradable': true,
          'arch': 'x86_64',
          'fingerprint': 'e' * 64,
          'ready': true,
        };
      final controller = RunnerController(
        serverId: 'fixture',
        transport: () => transport,
        store: journal,
        identity: () => 'fixture',
        password: () => null,
        accessFailure: (_) {},
      );

      await controller.checkComponentUpgrade(
        'panel',
        candidate: {
          'component': 'panel',
          'version': '3.8.0',
          'architecture': 'x86_64',
          'sha256': 'b' * 64,
        },
      );

      final plan = controller.componentUpgradePlan;
      expect(plan, isNotNull);
      expect(plan!['source'], 'adopted_unit');
      expect(plan['binaryPath'], '/opt/custom-x-ui/x-ui');
      expect(plan['units'], contains('custom-x-ui.service'));

      controller.dispose();
    },
  );
}
