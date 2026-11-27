import 'dart:async';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../runner/panel_login_view.dart';
import '../runner/runner_controller.dart';
import '../runner/runner_panel.dart';
import '../ssh/client_egress_card.dart';
import 'secret_link_box.dart';

/// A VLESS inbound of the connected 3x-ui panel that may leave the server
/// directly, past the client egress (relay class).
class RelayTarget {
  const RelayTarget({
    required this.inboundId,
    required this.title,
    required this.linkName,
    required this.row,
    this.resource,
    this.clientFacing = false,
    this.makeInternal,
  });

  /// The 3x-ui inbound ID.
  final int inboundId;

  /// The inbound as the list names it.
  final String title;

  /// The link name: "server · inbound".
  final String linkName;

  /// The panel discovery row: listen, port, enabled.
  final Map row;

  /// The managed or adopted resource, if any.
  final VlessInbound? resource;

  /// Given to catalog clients: the runner refuses the relay class.
  final bool clientFacing;

  /// Switches a [clientFacing] inbound to "Internal use" and applies it on
  /// the server; true when that succeeded. Null when the inbound cannot be
  /// switched from here.
  final Future<bool> Function()? makeInternal;
}

/// Why the direct exit cannot be turned on now; null when it can, and always
/// null while it is on (turning it off is always allowed).
String? relayBlockedReason(AppLocalizations l, RelayTarget target, bool on) =>
    on
    ? null
    : target.clientFacing && target.makeInternal == null
    ? l.relayClientFacing
    : target.row['enabled'] != true
    ? l.relayInboundDisabled
    : null;

/// Marks a relay inbound in its row.
class RelayInboundBadge extends StatelessWidget {
  const RelayInboundBadge({required this.stale, super.key});
  final bool stale;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return StatusChip(
      label: stale ? l.relayStaleBadge : l.relayBadge,
      icon: stale ? Icons.warning_amber_outlined : Icons.call_split,
      error: stale,
    );
  }
}

/// Opens the direct exit settings of [target].
class RelayInboundButton extends StatelessWidget {
  const RelayInboundButton({
    required this.controller,
    required this.target,
    required this.sshHost,
    super.key,
  });
  final RunnerController controller;
  final RelayTarget target;
  final String sshHost;
  @override
  Widget build(BuildContext context) => IconButton(
    key: ValueKey('relay-inbound-${target.inboundId}'),
    tooltip: AppLocalizations.of(context).relayTitle,
    icon: const Icon(Icons.call_split),
    onPressed: () => showRelayInbound(
      context,
      controller: controller,
      target: target,
      sshHost: sshHost,
    ),
  );
}

Future<void> showRelayInbound(
  BuildContext context, {
  required RunnerController controller,
  required RelayTarget target,
  required String sshHost,
}) => showAppDetails(
  context,
  title: target.title,
  children: [
    RelayInboundSection(
      controller: controller,
      target: target,
      sshHost: sshHost,
    ),
  ],
);

/// The direct exit switch of one inbound, its state and its link.
class RelayInboundSection extends StatefulWidget {
  const RelayInboundSection({
    required this.controller,
    required this.target,
    required this.sshHost,
    this.refreshOnOpen = true,
    super.key,
  });
  final RunnerController controller;
  final RelayTarget target;
  final String sshHost;

  /// Reads the server state once when shown: a panel edit may have changed
  /// the inbound tag since (stale).
  final bool refreshOnOpen;
  @override
  State<RelayInboundSection> createState() => _RelayInboundSectionState();
}

class _RelayInboundSectionState extends State<RelayInboundSection> {
  bool working = false;
  String? issue;

  /// The job this sheet submitted: only its outcome is shown here.
  String? startedJob;

  RunnerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    if (widget.refreshOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && c.canRequestAction) unawaited(c.refreshRelay());
      });
    }
  }

  Future<void> apply(bool enabled) async {
    setState(() {
      working = true;
      issue = null;
    });
    try {
      if (!await showPanelLogin(context, c) || !mounted) return;
      final internal = widget.target.makeInternal;
      if (enabled && widget.target.clientFacing && internal != null) {
        // Clients lose this inbound: the switch is confirmed, then applied
        // before the runner is asked (it refuses client inbounds).
        final l = AppLocalizations.of(context);
        final confirmed = await confirmAppDanger(
          context,
          title: l.relayMakeInternalTitle,
          message: l.relayMakeInternalHelp,
          confirmLabel: l.relayMakeInternalConfirm,
          cancelLabel: l.sshCancel,
          confirmKey: const ValueKey('relay-make-internal-confirm'),
        );
        if (!confirmed || !mounted) return;
        if (!await internal()) {
          if (mounted) issue = 'relay_client_inbound';
          return;
        }
        if (!mounted) return;
      }
      final ok = await c.applyRelay(
        inboundId: widget.target.inboundId,
        enabled: enabled,
      );
      if (!mounted) return;
      // An uncertain reply keeps the request; it is sent again, not lost.
      if (ok || c.pending?.json['kind'] == 'relay_apply') {
        startedJob = c.selected?.id ?? c.pending?.id;
      } else {
        issue = c.responseCode ?? 'relay_failed';
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> openLink() async {
    if (!await showPanelLogin(context, c) || !mounted) return;
    final target = widget.target;
    final destination = clientEgressDestination(
      row: target.row,
      sshHost: widget.sshHost,
      resource: target.resource,
    );
    await showAppDetails(
      context,
      title: AppLocalizations.of(context).relayLinkTitle,
      children: [
        RelayLinkView(
          controller: c,
          inboundId: target.inboundId,
          endpoint: destination.host,
          externalPort: destination.port,
          name: target.linkName,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final l = AppLocalizations.of(context), target = widget.target;
      final entry = c.relayEntry(target.inboundId);
      final on = entry != null, stale = entry?['stale'] == true;
      final job = [
        c.selected,
        ...c.jobs,
      ].where((j) => j?.kind == 'relay_apply').firstOrNull;
      final running =
          job?.terminal == false || c.pending?.json['kind'] == 'relay_apply';
      final busy = working || c.busy || c.actionPending || running;
      final blocked = relayBlockedReason(l, target, on);
      final canChange = !busy && c.canRequestAction && blocked == null;
      final own = job != null && job.id == startedJob;
      final failure = issue != null
          ? runnerCodeLabel(l, issue!)
          : job != null && own && job.terminal && job.status != 'succeeded'
          ? job.events.isNotEmpty
                ? runnerEventLabel(l, job.events.last.code)
                : l.relayFailed
          : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDisabledReason(
            reason: blocked,
            child: SwitchListTile(
              key: const ValueKey('relay-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(l.relayTitle),
              subtitle: Text(l.relayHelp),
              value: on,
              onChanged: canChange ? apply : null,
            ),
          ),
          if (blocked != null)
            AppNotice(
              key: const ValueKey('relay-blocked'),
              message: blocked,
              margin: const EdgeInsets.only(top: 8),
            )
          else if (!on && target.clientFacing)
            AppNotice(
              key: const ValueKey('relay-make-internal'),
              icon: Icons.warning_amber_outlined,
              message: l.relayMakeInternalNotice,
              margin: const EdgeInsets.only(top: 8),
            )
          else if (c.egress != null && c.egress!['enabled'] != true)
            AppNotice(
              key: const ValueKey('relay-egress-off'),
              message: l.relayEgressOff,
              margin: const EdgeInsets.only(top: 8),
            ),
          if (stale)
            AppNotice(
              key: const ValueKey('relay-stale'),
              icon: Icons.warning_amber_outlined,
              message: l.relayStale,
              margin: const EdgeInsets.only(top: 8),
              action: FilledButton.tonal(
                key: const ValueKey('relay-apply-again'),
                onPressed: !busy && c.canRequestAction
                    ? () => apply(true)
                    : null,
                child: Text(l.relayApplyAgain),
              ),
            ),
          if (job != null && (running || own))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                job.events.isNotEmpty && job.status != 'succeeded'
                    ? runnerEventLabel(l, job.events.last.code)
                    : runnerStateLabel(l, job.status),
              ),
            ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          if (failure != null)
            AppNotice(
              key: const ValueKey('relay-issue'),
              message: failure,
              error: true,
              margin: const EdgeInsets.only(top: 8),
            ),
          if (c.relayStateIssue != null)
            AppNotice(
              key: const ValueKey('relay-state-issue'),
              message: l.relayStateFailed,
              error: true,
              margin: const EdgeInsets.only(top: 8),
            ),
          if (on && !stale)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('relay-link'),
                  onPressed: busy ? null : openLink,
                  icon: const Icon(Icons.qr_code_2),
                  label: Text(l.relayLink),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// The service link of a relay inbound: read on open, hidden until shown,
/// kept only while this view is open.
class RelayLinkView extends StatefulWidget {
  const RelayLinkView({
    required this.controller,
    required this.inboundId,
    required this.endpoint,
    required this.externalPort,
    required this.name,
    super.key,
  });
  final RunnerController controller;
  final int inboundId;
  final String endpoint, name;
  final int externalPort;
  @override
  State<RelayLinkView> createState() => _RelayLinkViewState();
}

class _RelayLinkViewState extends State<RelayLinkView> {
  bool loading = true;
  String? uri, issue;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    final c = widget.controller;
    final link = await c.relayLink(
      inboundId: widget.inboundId,
      endpoint: widget.endpoint,
      externalPort: widget.externalPort,
      label: widget.name,
    );
    if (!mounted) return;
    setState(() {
      loading = false;
      uri = link;
      issue = link == null ? c.responseCode ?? 'relay_failed' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // The same view as the service mode test link, QR code included.
    return AccessLinkView(
      help: l.relayLinkHelp,
      keyPrefix: 'relay-link',
      link: uri,
      loading: loading,
      notice: issue == null ? null : runnerCodeLabel(l, issue!),
      noticeError: true,
    );
  }
}
