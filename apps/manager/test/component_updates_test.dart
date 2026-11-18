import 'dart:async';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/runner/component_updates_controller.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

class Source implements ComponentReleaseSource {
  int calls = 0;
  Completer<Map<String, String>>? gate;
  bool fail = false;
  @override
  Future<Map<String, String>> check() async {
    calls++;
    if (fail) throw const FormatException('offline');
    return gate?.future ??
        {
          'panel': '3.7.0',
          'xray': '26.7.28',
          'trusttunnel': '1.1.0',
          'amneziawg': '3.1.20260828',
          'amneziawgTools': '3.1.20260812',
        };
  }

  @override
  Future<List<ComponentRelease>> releases(String component) async => const [];

  @override
  Future<Map<String, Object?>?> resolveInstallerRelease({
    required String component,
    required String version,
  }) async => null;

  @override
  Future<Map<String, Object?>?> resolveAsset({
    required String component,
    required String version,
    String? architecture,
  }) async => null;
}

class Settings implements SettingsStore {
  final values = <String, String>{};
  @override
  Future<String?> readSetting(String key) async => values[key];
  @override
  Future<void> writeSetting(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  test(
    'diagnostics pause prevents automatic and manual release traffic',
    () async {
      final source = Source();
      final controller = ComponentUpdatesController(source: source)
        ..diagnosticsPaused = true;
      controller.maybeCheck();
      await controller.check();
      expect(source.calls, 0);
      controller.diagnosticsPaused = false;
      await controller.check();
      expect(source.calls, 1);
      controller.dispose();
    },
  );
  test(
    'numeric version comparison handles dates and rejects unknown labels',
    () {
      expect(componentIsNewer('v3.1.20260828', '3.1.20260812'), isTrue);
      expect(componentIsNewer('1.1.0', '1.1.0'), isFalse);
      expect(componentIsNewer('1.1.0', '2.0.0'), isFalse);
      expect(componentIsNewer('1.1.0-rc1', '1.0.0'), isNull);
      expect(componentIsNewer('1.1.0', 'unknown'), isNull);
      expect(
        componentIsNewer('1.3.0-beta.2', '1.1.0', allowPreview: true),
        isTrue,
      );
      expect(
        componentIsNewer('1.3.0', '1.3.0-beta.2', allowPreview: true),
        isTrue,
      );
      expect(
        componentIsNewer('1.3.0-beta.2', '1.3.0-beta.1', allowPreview: true),
        isTrue,
      );
      expect(
        componentIsNewer(
          '26.11.9',
          'Xray 26.7.28 (Xray, Penetrates Everything.)',
        ),
        isTrue,
      );
      expect(componentIsNewer('v26.11.9', '26.11.9'), isFalse);
      expect(componentIsNewer('26.11.9', ' 26.7.28\n'), isTrue);
    },
  );
  test(
    'preferences persist independently; manual check works with auto off',
    () async {
      final settings = Settings();
      settings.values['componentUpdatesAutomatic'] = 'false';
      final source = Source();
      var c = ComponentUpdatesController(source: source, settings: settings);
      await c.load();
      c.maybeCheck();
      expect(source.calls, 0);
      await c.setPreference(suggestions: false);
      await c.check();
      expect(source.calls, 1);
      expect(c.checkedAt, isNotNull);
      c.dispose();
      c = ComponentUpdatesController(source: source, settings: settings);
      await c.load();
      expect(c.automatic, isFalse);
      expect(c.suggestions, isFalse);
      expect(c.latest['trusttunnel'], '1.1.0');
      expect(source.calls, 1);
      c.dispose();
    },
  );
  test(
    'concurrent check, navigation refresh and retry are throttled',
    () async {
      final source = Source()..gate = Completer();
      final c = ComponentUpdatesController(source: source);
      final first = c.check();
      await c.check();
      c.maybeCheck();
      expect(source.calls, 1);
      source.gate!.complete({'trusttunnel': '1.1.0'});
      await first;
      await c.check();
      expect(source.calls, 1);
      c.dispose();
    },
  );
  test('offline preserves last success and exposes failure', () async {
    final c = ComponentUpdatesController(source: Source()..fail = true);
    c.latest = {'trusttunnel': '1.0.33'};
    final before = DateTime.utc(2026, 1, 1);
    c.checkedAt = before;
    await c.check();
    expect(c.failed, isTrue);
    expect(c.latest['trusttunnel'], '1.0.33');
    expect(c.checkedAt, before);
    c.dispose();
  });
  test(
    'component preview is read only; stale plan cannot install runner',
    () async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store);
      final c = RunnerController(
        serverId: 'fixture',
        transport: () => remote,
        identity: () => 'fixture|key',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
      await c.prepareComponent('trusttunnel');
      expect(c.canApplyComponent, isTrue);
      expect(remote.installs, 0);
      expect(remote.submissions, 0);
      remote.panelFingerprint = 'e' * 64;
      await c.applyComponent();
      expect(c.error, RunnerIssue.conflict);
      expect(remote.installs, 0);
      expect(remote.submissions, 0);
      c.dispose();
    },
  );
  test(
    'component lost submit response recovers same persisted identity',
    () async {
      final store = MemoryRunnerJournal();
      final remote = FakeRunnerTransport(store)..loseSubmitResponse = true;
      RunnerController create() => RunnerController(
        serverId: 'fixture',
        transport: () => remote,
        identity: () => 'fixture|key',
        password: () => null,
        accessFailure: (_) {},
        store: store,
      );
      var c = create();
      await c.prepareComponent('amneziawg');
      await c.applyComponent();
      expect(remote.submitWithoutPersistence, isFalse);
      final id = c.pending!.id;
      c.dispose();
      c = create();
      await c.refresh();
      expect(c.selected!.id, id);
      expect(c.selected!.kind, 'component_install');
      expect(remote.submissions, 1);
      c.dispose();
    },
  );
}
