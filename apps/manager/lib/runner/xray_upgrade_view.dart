import 'dart:async';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../vpn/vpn_controller.dart';
import '../vpn/connection_check_view.dart';
import 'panel_login_view.dart';
import 'runner_controller.dart';
import 'component_updates_controller.dart';
import 'xray_upgrade_controller.dart';

class XrayUpgradeView extends StatefulWidget {
  const XrayUpgradeView({
    required this.runner,
    required this.vpn,
    required this.host,
    super.key,
  });
  final RunnerController runner;
  final VpnController vpn;
  final String host;
  @override
  State<XrayUpgradeView> createState() => _XrayUpgradeViewState();
}

class _XrayUpgradeViewState extends State<XrayUpgradeView>
    with WidgetsBindingObserver {
  late final c = XrayUpgradeController(
    runner: widget.runner,
    vpn: widget.vpn,
    host: widget.host,
  );
  Timer? _poll;

  /// A transaction was asked for here: its progress and result stay shown
  /// until dismissed.
  bool _shown = false;
  late final XrayVersionChoice _choice = XrayVersionChoice(
    install: _install,
    update: _update,
    ready: () => c.ready,
    previous: () => c.previousVersion,
  );

  /// A version chosen in the component versions dialog (UI-45).
  Future<void> _install(Map<String, Object?> asset) async {
    if (!mounted || !await showPanelLogin(context, widget.runner) || !mounted) {
      return;
    }
    setState(() => _shown = true);
    await c.install(asset);
  }

  /// The Update action of the 3x-ui / Xray software row when only the core
  /// is behind: exactly the [version] the row shows, through the checked
  /// transaction; the runner's pinned flow when it pins this release.
  Future<void> _update(String version) async {
    if (!mounted || !await showPanelLogin(context, widget.runner) || !mounted) {
      return;
    }
    setState(() => _shown = true);
    if (c.plan == null) await c.inspect();
    if (!mounted) return;
    final updates = ComponentUpdatesScope.of(context);
    final current =
        c.plan?['current'] as String? ?? widget.runner.panelAccess?.xrayVersion;
    final newer =
        current != null &&
        componentIsNewer(version, current, allowPreview: true) == true;
    if (newer &&
        c.available &&
        c.plan?['available'] == true &&
        c.plan?['candidate'] == version) {
      await c.run();
    } else if (newer &&
        c.available &&
        c.plan?['choosable'] == true &&
        updates != null) {
      final asset = await updates.source.resolveAsset(
        component: 'xray',
        version: version,
      );
      if (mounted) await c.install(asset, upgradeOnly: true);
    } else if (c.code.isEmpty) {
      c.phase = 'not_changed';
      c.changed();
    }
  }

  /// The shown move of the core: the running transaction's release, else
  /// the runner's pinned candidate, else a newer upstream release.
  ({String? current, String? candidate, bool newer}) _offer(
    ComponentUpdatesController? updates,
  ) {
    final current =
        c.plan?['current'] as String? ?? widget.runner.panelAccess?.xrayVersion;
    bool newer(String? version) =>
        version != null &&
        current != null &&
        (componentIsNewer(version, current) == true ||
            componentIsNewer(version, current, allowPreview: true) == true);
    final dynamicXray = updates?.latest['xray'];
    final planned = newer(c.plan?['candidate'] as String?);
    final upstream = newer(dynamicXray);
    return (
      current: current,
      candidate:
          c.chosen?['version'] as String? ??
          (planned
              ? c.plan!['candidate'] as String
              : (upstream ? dynamicXray : null)),
      newer: planned || upstream,
    );
  }

  /// Phases of a transaction the server still runs or recovers.
  static const _active = {
    'baseline',
    'preparing',
    'replacing',
    'comparison',
    'awaiting_checks',
    'recovery_required',
    'recovery_pending',
    'rolling_back',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.runner.xrayVersionChoice = _choice;
    unawaited(c.inspect());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted &&
          !c.busy &&
          widget.runner.connected &&
          widget.runner.panelAccess != null &&
          ((c.plan == null && c.code.isEmpty) ||
              // Another path (component upgrade, version choice) changed
              // the core: the shown "current → candidate" is stale.
              (c.plan?['current'] != null &&
                  widget.runner.panelAccess?.xrayVersion != null &&
                  c.plan!['current'] !=
                      widget.runner.panelAccess!.xrayVersion) ||
              c.operation != null &&
                  !XrayUpgradeController.terminal.contains(
                    c.operation!['phase'],
                  ))) {
        unawaited(c.inspect());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      c.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(widget.runner.xrayVersionChoice, _choice)) {
      widget.runner.xrayVersionChoice = null;
    }
    _poll?.cancel();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c, widget.runner, widget.vpn]),
    builder: (context, _) {
      // Shown under the 3x-ui / Xray software row like a component install:
      // nothing until a transaction runs here or the server reports one.
      if (!_shown && !c.running && !_active.contains(c.phase)) {
        return const SizedBox.shrink();
      }
      final l = AppLocalizations.of(context);
      final offer = _offer(ComponentUpdatesScope.of(context));
      final message = switch (c.phase) {
        'baseline' => l.xrayUpgradeBaseline,
        'preparing' || 'replacing' => l.xrayUpgradePreparing,
        'comparison' || 'awaiting_checks' => l.xrayUpgradeComparison,
        'committed' => l.xrayUpgradeCommitted,
        'rolled_back' => l.xrayUpgradeRestored,
        'not_changed' => l.xrayUpgradeUnchanged,
        'recovery_required' => l.xrayUpgradeAttention,
        'recovery_pending' || 'rolling_back' => l.xrayUpgradePending,
        _ => '',
      };
      final problem = switch (c.code) {
        'xray_check_coverage' => l.xrayUpgradeCoverage,
        'xray_check_layout' => offer.newer ? '' : l.xrayUpgradeLayout,
        'xray_check_changed' => l.xrayUpgradeConflict,
        'xray_check_rollback' => l.xrayUpgradeAttention,
        'xray_check_panel_api' => l.xrayUpgradePanelApi,
        'xray_release_missing' => l.versionsAssetMissing,
        'xray_check_digest' => l.xrayUpgradeDigest,
        'xray_check_config' => l.xrayUpgradeConfig,
        'xray_check_timeout' ||
        'xray_check_watchdog' ||
        'xray_check_late' => l.xrayUpgradeTimeout,
        'xray_check_restart' => l.xrayUpgradeRestart,
        'xray_check_busy' => l.xrayUpgradeBusy,
        'vpn_pending_readback' => l.xrayUpgradeProblemAfter(
          l.vpnPendingReadback,
        ),
        'vpn_pending' => l.xrayUpgradeProblemAfter(l.vpnPending),
        'vpn_conflict' => l.xrayUpgradeProblemAfter(l.vpnConflict),
        '' ||
        'committed' ||
        'preparing' ||
        'replacing' ||
        'awaiting_checks' => '',
        _ => l.xrayUpgradeProblem,
      };
      String check(ConnectionCheck? result) => result == null
          ? l.xrayUpgradeNotTested
          : connectionCheckMessage(l, result);
      final title = offer.candidate != null && offer.current != null
          ? 'Xray ${offer.current} → ${offer.candidate}'
          : l.xrayUpgradeTitle;
      // Before/after of each inbound: technical, so in the details sheet.
      final details = [
        // The exact reason for support: hidden from the main view.
        if (c.code.isNotEmpty && c.code != 'committed')
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SelectableText(l.xrayUpgradeCode(c.code)),
          ),
        for (final row in c.rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name.isEmpty ? 'VLESS · ${row.id}' : row.name,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (!row.enabled) Text(l.xrayUpgradeDisabled),
                if (row.enabled) ...[
                  Text('${l.xrayUpgradeBefore}: ${check(row.before)}'),
                  Text('${l.xrayUpgradeAfter}: ${check(row.after)}'),
                  if (c.phase == 'rolled_back' || row.restored != null)
                    Text('${l.xrayUpgradeRecovery}: ${check(row.restored)}'),
                ],
              ],
            ),
          ),
      ];
      final inProgress =
          c.running ||
          c.busy ||
          (_active.contains(c.phase) && c.phase != 'recovery_required');
      if (inProgress) {
        return Padding(
          key: const ValueKey('xray-upgrade'),
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  // A new run starts with the baseline check; the previous
                  // run's outcome must not show while it is in progress.
                  '$title · ${_active.contains(c.phase) ? message : l.xrayUpgradeBaseline}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: 6),
              const LinearProgressIndicator(),
              if (c.running)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  // Stopping aborts the upgrade and rolls the core back on
                  // the server: confirm in error colours (UI-55).
                  child: TextButton(
                    key: const ValueKey('xray-stop'),
                    onPressed: () async {
                      final stop = await confirmAppDanger(
                        context,
                        title: l.xrayUpgradeStopTitle,
                        message: l.xrayUpgradeStopHelp,
                        confirmLabel: l.connectionStop,
                        cancelLabel: l.runnerNotNow,
                        confirmKey: const ValueKey('xray-stop-confirm'),
                      );
                      if (stop && c.running) c.cancel();
                    },
                    child: Text(l.connectionStop),
                  ),
                ),
            ],
          ),
        );
      }
      final text = [
        if (message.isNotEmpty) message,
        if (problem.isNotEmpty) problem,
        if (c.plan != null && offer.candidate == null) l.xrayUpgradeNoStable,
      ];
      return AppNotice(
        key: const ValueKey('xray-upgrade'),
        title: title,
        message: text.isEmpty ? l.xrayUpgradeTitle : text.join('\n'),
        error: problem.isNotEmpty || c.phase == 'recovery_required',
        icon: c.phase == 'committed'
            ? Icons.check_circle_outline
            : Icons.info_outline,
        liveRegion: true,
        action: Wrap(
          spacing: 8,
          children: [
            if (details.isNotEmpty)
              TextButton(
                key: const ValueKey('xray-upgrade-details'),
                onPressed: () =>
                    showAppDetails(context, title: title, children: details),
                child: Text(l.componentsDetails),
              ),
            // A transaction the server still has to recover stays shown.
            if (c.phase != 'recovery_required')
              TextButton(
                key: const ValueKey('xray-upgrade-close'),
                onPressed: () => setState(() => _shown = false),
                child: Text(l.networkClose),
              ),
          ],
        ),
      );
    },
  );
}
