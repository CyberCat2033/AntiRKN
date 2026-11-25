import 'dart:convert';
import 'dart:io';

import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/runner_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'runner_support.dart';

void main() {
  final id = 'c' * 32;

  test(
    'a refused system update does not upgrade on a later index refresh',
    () async {
      final store = MemoryRunnerJournal();
      final remote = ScriptedTransport(store)
        ..installed = true
        ..submitCode = 'busy';
      final c = fixtureRunner(remote, store);
      addTearDown(c.dispose);
      await c.refresh();
      await c.updateSystem();
      expect(c.pending, isNull);
      expect(c.selected, isNull);
      // Another device refreshes the indexes later.
      remote.submitCode = null;
      remote.job = runnerJob(
        id,
        kind: 'apt_update',
        status: 'succeeded',
        count: 2,
        interval: 1,
      );
      await c.selectJob(id);
      expect(
        remote.requests.where((r) => r.json['action'] == 'apt_plan'),
        isEmpty,
      );
      expect(remote.submissions, 0);
    },
  );

  group('labels', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final ru = lookupAppLocalizations(const Locale('ru'));

    test('upgrade failures are failures with their own text', () {
      for (final l in [en, ru]) {
        final expected = {
          'upgrade_disk_full': l.runnerUpgradeDiskFull,
          'upgrade_memory_low': l.runnerUpgradeMemoryLow,
          'upgrade_not_installed': l.runnerUpgradeNotInstalled,
          'upgrade_invalid_component': l.runnerUpgradeInvalidComponent,
          'upgrade_binary_not_found': l.runnerUpgradeBinaryNotFound,
          'upgrade_architecture_mismatch': l.runnerUpgradeArchitectureMismatch,
          'upgrade_rollback_failed': l.runnerUpgradeRollbackFailed,
          'upgrade_rolled_back': l.runnerUpgradeRolledBack,
          'upgrade_conflict': l.runnerUpgradeConflict,
          'upgrade_connectivity_failed': l.runnerUpgradeConnectivityFailed,
          'upgrade_failed': l.runnerUpgradeFailedGeneric,
        };
        for (final MapEntry(:key, :value) in expected.entries) {
          expect(runnerEventLabel(l, key), value, reason: key);
          expect(runnerCodeLabel(l, key), value, reason: key);
        }
        expect(
          runnerEventLabel(l, 'upgrade_downloading'),
          l.runnerUpgradeDownloading,
        );
        // Unknown codes: progress in the job log, a failure as a response.
        expect(
          runnerEventLabel(l, 'upgrade_future_step'),
          l.runnerUpgradeInProgressGeneric,
        );
        expect(
          runnerCodeLabel(l, 'upgrade_future_step'),
          l.runnerUpgradeFailedGeneric,
        );
      }
      // Every upgrade response code of the schema is an outcome, and so is
      // the event-only upgrade_rollback_failed: none reads as progress.
      final schema =
          jsonDecode(File('../../schemas/runner-v1.json').readAsStringSync())
              as Map<String, dynamic>;
      final outcomes = [
        for (final code in (schema['codes'] as List).cast<String>())
          if (code.startsWith('upgrade_')) code,
        'upgrade_rollback_failed',
      ];
      expect(outcomes, hasLength(greaterThan(10)));
      for (final code in outcomes) {
        expect(upgradeOutcomeLabel(en, code), isNotNull, reason: code);
        expect(
          runnerEventLabel(en, code),
          isNot(en.runnerUpgradeInProgressGeneric),
          reason: code,
        );
      }
    });

    test('APT codes have specific texts', () {
      for (final l in [en, ru]) {
        final expected = {
          'apt_disk_full': l.aptDiskFull,
          'apt_memory_low': l.aptMemoryLow,
          'apt_lock_busy': l.aptLockBusy,
          'apt_failed': l.aptFailed,
          'apt_dpkg_interrupted': l.aptDpkgInterrupted,
          'apt_interrupted': l.aptInterrupted,
        };
        for (final MapEntry(:key, :value) in expected.entries) {
          expect(runnerCodeLabel(l, key), value, reason: key);
          expect(runnerEventLabel(l, key), value, reason: key);
        }
      }
    });
  });
}
