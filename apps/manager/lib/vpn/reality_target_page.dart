import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import 'reality_search_controller.dart';

/// Opens the search above the REALITY form; the form keeps its draft and
/// receives the chosen target and SNI.
Future<RealityTargetChoice?> showRealityTargetSearch(
  BuildContext context, {
  required RealitySearchController controller,
  required String serverAddress,
  required MotionPreference motion,
}) => pushAppPage<RealityTargetChoice>(
  context,
  motion: motion,
  builder: (_) =>
      RealityTargetPage(controller: controller, serverAddress: serverAddress),
);

enum _Source { neighbors, own }

String realityReasonText(AppLocalizations l, RealityReason r) => switch (r) {
  RealityReason.sameNetwork => l.realityReasonSameNetwork,
  RealityReason.nearbyNetwork => l.realityReasonNearbyNetwork,
  RealityReason.farNetwork => l.realityReasonFarNetwork,
  RealityReason.dnsMatch => l.realityReasonDnsMatch,
  RealityReason.dnsMismatch => l.realityReasonDnsMismatch,
  RealityReason.dnsUnresolved => l.realityReasonDnsUnresolved,
  RealityReason.modernKeyExchange => l.realityReasonModernKeyExchange,
  RealityReason.stable => l.realityReasonStable,
  RealityReason.unstable => l.realityReasonUnstable,
  RealityReason.stabilityNotChecked => l.realityReasonStabilityNotChecked,
  RealityReason.serverNotChecked => l.realityReasonServerNotChecked,
  RealityReason.serverChecked => l.realityReasonServerChecked,
  RealityReason.serverRejected => l.realityReasonServerRejected,
  RealityReason.mihomoWorking => l.realityReasonMihomoWorking,
  RealityReason.mihomoFailed => l.realityReasonMihomoFailed,
  RealityReason.mihomoInconclusive => l.realityReasonMihomoInconclusive,
  RealityReason.redirectNotChecked => l.realityReasonRedirectNotChecked,
  RealityReason.notTls13 => l.realityReasonNotTls13,
  RealityReason.noH2 => l.realityReasonNoH2,
  RealityReason.unsupportedGroup => l.realityReasonUnsupportedGroup,
  RealityReason.certificateInvalid => l.realityReasonCertificateInvalid,
  RealityReason.handshakeFailed => l.realityReasonHandshakeFailed,
  RealityReason.knownCdn => l.realityReasonKnownCdn,
  RealityReason.expiresSoon => l.realityReasonExpiresSoon,
};

/// Measured strengths and problems shown as chips in the details.
const _goodReasons = {
  RealityReason.mihomoWorking,
  RealityReason.serverChecked,
  RealityReason.sameNetwork,
  RealityReason.nearbyNetwork,
  RealityReason.dnsMatch,
  RealityReason.stable,
  RealityReason.modernKeyExchange,
};
const _badReasons = {
  RealityReason.mihomoFailed,
  RealityReason.mihomoInconclusive,
  RealityReason.serverRejected,
  RealityReason.knownCdn,
  RealityReason.notTls13,
  RealityReason.noH2,
  RealityReason.unsupportedGroup,
  RealityReason.certificateInvalid,
  RealityReason.handshakeFailed,
  RealityReason.dnsMismatch,
  RealityReason.unstable,
  RealityReason.expiresSoon,
  RealityReason.farNetwork,
};

/// The short "why" of a card: what helps, then what holds it back.
const _cardReasons = [
  RealityReason.sameNetwork,
  RealityReason.nearbyNetwork,
  RealityReason.modernKeyExchange,
  RealityReason.dnsMatch,
  RealityReason.stable,
  RealityReason.expiresSoon,
  RealityReason.dnsMismatch,
  RealityReason.unstable,
  RealityReason.notTls13,
  RealityReason.noH2,
  RealityReason.unsupportedGroup,
  RealityReason.certificateInvalid,
  RealityReason.handshakeFailed,
  RealityReason.knownCdn,
  RealityReason.serverRejected,
  RealityReason.mihomoFailed,
];

class RealityTargetPage extends StatefulWidget {
  const RealityTargetPage({
    required this.controller,
    required this.serverAddress,
    super.key,
  });
  final RealitySearchController controller;

  /// Public IPv4 of the server whose neighbours are searched; '' if unknown.
  final String serverAddress;
  @override
  State<RealityTargetPage> createState() => _RealityTargetPageState();
}

class _RealityTargetPageState extends State<RealityTargetPage> {
  RealitySearchController get c => widget.controller;
  late _Source source = _neighborsPossible ? _Source.neighbors : _Source.own;
  int prefix = 24;
  String own = '';
  RealityCandidate? selected;

  bool get _neighborsPossible {
    final ip = IpAddress.tryParse(widget.serverAddress);
    return ip != null &&
        ip.family == IpFamily.ipv4 &&
        ip.category == IpCategory.publicUnicast;
  }

  /// The candidate whose details sheet is open; its result shows there.
  String? _sheetFor;
  bool _wide = false;
  var _seen = 0;

  @override
  void initState() {
    super.initState();
    // Only checks that end from now on are announced.
    _seen = c.finished?.serial ?? 0;
    c.ready.then((_) => c.checkNetwork());
    c.addListener(_finished);
  }

  @override
  void dispose() {
    c.removeListener(_finished);
    super.dispose();
  }

  /// A check that ended while its details were closed is announced once.
  void _finished() {
    final done = c.finished;
    if (!mounted || done == null || done.serial == _seen) return;
    _seen = done.serial;
    final shown = _wide
        ? (selected?.target.key ?? c.recommended.firstOrNull?.target.key)
        : _sheetFor;
    if (done.key == shown || done.outcome == RealityConnectOutcome.cancelled) {
      return;
    }
    final l = AppLocalizations.of(context);
    final candidate = c.candidates
        .where((x) => x.target.key == done.key)
        .firstOrNull;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (done.outcome) {
          RealityConnectOutcome.works => l.realityConnectSnackWorks(done.sni),
          RealityConnectOutcome.fails => l.realityConnectSnackFails(done.sni),
          RealityConnectOutcome.cleanupPending => l.realityConnectCleanup,
          _ => l.realityConnectSnackUnknown(done.sni),
        }),
        action: candidate != null && candidate.suitable
            ? SnackBarAction(
                label: l.realitySearchUse,
                onPressed: () => _use(candidate),
              )
            : null,
      ),
    );
  }

  Future<void> _openSheet(
    AppLocalizations l,
    RealityCandidate candidate,
  ) async {
    final key = candidate.target.key;
    _sheetFor = key;
    await showAppDetails(
      context,
      title: candidate.target.sni,
      children: [
        // Live: the check runs and ends while the sheet is open.
        ListenableBuilder(
          listenable: c,
          builder: (_, _) => _details(
            l,
            c.candidates.where((x) => x.target.key == key).firstOrNull ??
                candidate,
            sheet: true,
          ),
        ),
      ],
    );
    if (_sheetFor == key) _sheetFor = null;
  }

  RealitySearchPlan? get plan {
    try {
      return switch (source) {
        _Source.neighbors => RealitySearchPlan.neighbors(
          widget.serverAddress,
          prefix: prefix,
          limit: RealitySearchPlan.hardLimit,
        ),
        _Source.own => RealitySearchPlan.explicit(
          own.split(RegExp(r'[\s,;]+')).where((s) => s.isNotEmpty),
          server: _neighborsPossible ? widget.serverAddress : '',
        ),
      };
    } on FormatException {
      return null;
    }
  }

  void _use(RealityCandidate candidate) =>
      Navigator.of(context).pop(realityChoice(candidate));

  Future<void> _copy(String text) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: text));
      messenger.showSnackBar(SnackBar(content: Text(l.realitySearchCopied)));
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.realitySearchCopyFailed)),
      );
    }
  }

  Future<void> _editSource() async {
    final l = AppLocalizations.of(context);
    var nextSource = source, nextPrefix = prefix;
    final text = TextEditingController(text: own);
    final applied = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AppFormDialog(
          title: Text(l.realitySearchSource),
          content: AppFormFields(
            children: [
              SegmentedButton<_Source>(
                segments: [
                  ButtonSegment(
                    value: _Source.neighbors,
                    label: Text(l.realitySearchNeighbors),
                    enabled: _neighborsPossible,
                  ),
                  ButtonSegment(
                    value: _Source.own,
                    label: Text(l.realitySearchOwn),
                  ),
                ],
                selected: {nextSource},
                onSelectionChanged: (s) =>
                    setDialog(() => nextSource = s.single),
              ),
              if (nextSource == _Source.neighbors)
                AppSelectField<int>(
                  value: nextPrefix,
                  label: l.realitySearchRange,
                  options: [
                    for (final p in [24, 23, 22, 25, 26])
                      (p, l.realitySearchPrefix(p, (1 << (32 - p)) - 2)),
                  ],
                  onChanged: (v) => setDialog(() => nextPrefix = v),
                )
              else ...[
                TextField(
                  key: const ValueKey('reality-search-own'),
                  controller: text,
                  minLines: 3,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    labelText: l.realitySearchOwnAddresses,
                    helperText: l.realitySearchOwnHelp,
                    helperMaxLines: 3,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.uiApply),
            ),
          ],
        ),
      ),
    );
    final value = text.text;
    text.dispose();
    if (applied != true || !mounted) return;
    setState(() {
      source = nextSource;
      prefix = nextPrefix;
      own = value;
    });
  }

  String _phase(AppLocalizations l, RealitySearchState s) => switch (s.phase) {
    RealitySearchPhase.discovery => l.realitySearchDiscovery,
    RealitySearchPhase.confirmation => l.realitySearchConfirmation,
    RealitySearchPhase.stability => l.realitySearchStability,
    RealitySearchPhase.done => l.realitySearchDone,
    RealitySearchPhase.cancelled => l.realitySearchCancelled,
    RealitySearchPhase.failed => l.realitySearchFailed,
    RealitySearchPhase.networkChanged => l.realitySearchNetworkChanged,
  };

  Widget _sourceCard(AppLocalizations l) {
    final p = plan;
    final subtitle = p == null
        ? l.realitySearchNoAddresses
        : [
            if (source == _Source.neighbors)
              '${p.server!.canonical}/$prefix'.replaceFirst(
                RegExp(r'\.\d+/'),
                '.0/',
              ),
            l.realitySearchAddresses(p.addresses.length),
            l.realitySearchAbout(
              realitySearchEstimate(
                p.addresses.length,
                c.search.limits,
              ).inSeconds,
            ),
          ].join(' · ');
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const ValueKey('reality-search-source'),
        leading: const Icon(Icons.hub_outlined),
        title: Text(
          source == _Source.neighbors
              ? l.realitySearchNeighbors
              : l.realitySearchOwn,
        ),
        subtitle: Text(subtitle),
        trailing: TextButton(
          onPressed: c.running ? null : _editSource,
          child: Text(l.realitySearchChange),
        ),
      ),
    );
  }

  List<Widget> _notices(AppLocalizations l) {
    final net = c.state?.network;
    return [
      if (!_neighborsPossible)
        AppNotice(message: l.realitySearchNoServerAddress),
      if (net != null && !net.measuresDevice)
        AppNotice(message: l.realitySearchVpn, icon: Icons.vpn_lock_outlined),
      if (c.otherNetwork)
        AppNotice(message: l.realitySearchOtherNetwork, icon: Icons.history),
      if (c.storeFailed) AppNotice(message: l.realitySearchStoreFailed),
      if (c.serverUnavailable)
        AppNotice(
          message: l.realitySearchServerUnavailable,
          icon: Icons.cloud_off_outlined,
        ),
    ];
  }

  Widget _progress(AppLocalizations l) {
    final s = c.state;
    final start = FilledButton.icon(
      key: const ValueKey('reality-search-start'),
      onPressed: c.running || plan == null ? null : () => c.start(plan!),
      icon: const Icon(Icons.travel_explore),
      label: Text(s == null ? l.realitySearchStart : l.realitySearchRestart),
    );
    if (s == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AppActionRow(children: [start]),
      );
    }
    final total = s.total;
    final status = l.realitySearchFound(s.tlsFound, c.recommended.length);
    if (!c.running && c.connecting.isNotEmpty) {
      return AppProgressCard(
        title: l.realitySearchConnecting,
        icon: Icons.network_check,
        status: l.realitySearchConnectingHelp,
      );
    }
    if (!c.running && c.checking.isNotEmpty) {
      return AppProgressCard(
        title: l.realitySearchServerChecking,
        icon: Icons.dns_outlined,
        status: status,
      );
    }
    if (!c.running) {
      // A stopped or finished search has no running indicator.
      final theme = Theme.of(context);
      return Card.filled(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_phase(l, s), style: theme.textTheme.titleMedium),
              Text(status, style: theme.textTheme.bodyMedium),
              if (s.phase == RealitySearchPhase.failed)
                Text(
                  l.realitySearchFailedCode(s.code),
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (c.resumable)
                    FilledButton(
                      key: const ValueKey('reality-search-resume'),
                      onPressed: c.resume,
                      child: Text(l.realitySearchResume),
                    ),
                  start,
                ],
              ),
            ],
          ),
        ),
      );
    }
    return AppProgressCard(
      title: _phase(l, s),
      icon: Icons.travel_explore,
      value: total > 0 ? s.processed / total : null,
      step: total > 0 ? '${s.processed}/$total' : null,
      status: status,
      actions: [
        OutlinedButton(
          key: const ValueKey('reality-search-stop'),
          onPressed: c.stop,
          child: Text(l.realitySearchStop),
        ),
      ],
    );
  }

  Widget _card(AppLocalizations l, RealityCandidate candidate, bool wide) {
    final theme = Theme.of(context);
    final reasons = [
      for (final r in _cardReasons)
        if (candidate.reasons.contains(r)) realityReasonText(l, r),
    ].take(3).join(' · ');
    final isSelected = wide && selected?.target == candidate.target;
    return Card.filled(
      key: ValueKey('reality-candidate-${candidate.target.key}'),
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      color: isSelected ? theme.colorScheme.secondaryContainer : null,
      child: InkWell(
        onTap: () => wide
            ? setState(() => selected = candidate)
            : _openSheet(l, candidate),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      candidate.target.sni,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (candidate.suitable)
                    Semantics(
                      label: l.realitySearchScore(candidate.score),
                      child: ExcludeSemantics(
                        child: Text(
                          '${candidate.score}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (reasons.isNotEmpty)
                Text(reasons, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusChip(
                    label: l.realityLevelTls,
                    icon: Icons.lock_outline,
                  ),
                  if (candidate.level.index >= RealityLevel.confirmed.index)
                    StatusChip(
                      label: l.realityLevelPair,
                      icon: Icons.verified_outlined,
                    ),
                  if (candidate.suitable)
                    StatusChip(
                      label: l.realityLevelCriteria,
                      icon: Icons.task_alt,
                    ),
                  if (candidate.level == RealityLevel.mihomoChecked)
                    StatusChip(
                      label: l.realityLevelMihomo,
                      icon: Icons.check_circle_outline,
                    ),
                  if (candidate.fromMihomo?.status ==
                      RealityMihomoStatus.failed)
                    StatusChip(
                      label: l.realityLevelMihomoFailed,
                      icon: Icons.error_outline,
                      error: true,
                    ),
                  if (candidate.fromServer?.feasible == true)
                    StatusChip(
                      label: switch (candidate.fromServer?.latency) {
                        final latency? => l.realityLevelServerTime(
                          latency.inMilliseconds,
                        ),
                        null => l.realityLevelServer,
                      },
                      icon: Icons.dns_outlined,
                    ),
                ],
              ),
              if (candidate.suitable) ...[
                const SizedBox(height: 8),
                FilledButton.tonal(
                  key: ValueKey('reality-use-${candidate.target.key}'),
                  onPressed: () => _use(candidate),
                  child: Text(l.realitySearchUse),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _details(
    AppLocalizations l,
    RealityCandidate candidate, {
    bool sheet = false,
  }) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final p = candidate.confirmation, cert = p.certificate;
    final local = MaterialLocalizations.of(context);
    final server = candidate.fromServer?.latency?.inMilliseconds;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
    // Only what was measured: "not checked" reasons stay out of the way.
    final good = [
      for (final r in candidate.reasons)
        if (_goodReasons.contains(r)) r,
    ];
    final bad = [
      for (final r in candidate.reasons)
        if (_badReasons.contains(r)) r,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(l.vpnTarget, realityChoice(candidate).target),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final value in ['TLS ${p.version}', p.alpn, p.group])
                if (value.trim().isNotEmpty && value != 'TLS ')
                  StatusChip(label: value, icon: Icons.lock_outline),
            ],
          ),
        ),
        row(
          l.realityDetailsLatency,
          server == null
              ? l.realityDetailsLatencyDevice(p.tls.inMilliseconds)
              : l.realityDetailsLatencyBoth(p.tls.inMilliseconds, server),
        ),
        if (cert != null)
          row(
            l.realityCertificate,
            l.realityDetailsCertificate(
              cert.issuer.isEmpty ? '—' : cert.issuer,
              local.formatMediumDate(cert.notAfter),
            ),
          ),
        if (good.isNotEmpty || bad.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(l.realitySearchWhy, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in bad)
                StatusChip(
                  label: realityReasonText(l, r),
                  icon: Icons.error_outline,
                  error: true,
                ),
              for (final r in good)
                StatusChip(label: realityReasonText(l, r), icon: Icons.check),
            ],
          ),
        ],
        AppExpansionTile(
          key: ValueKey('reality-more-${candidate.target.key}'),
          title: Text(l.realityDetailsMore),
          tilePadding: EdgeInsets.zero,
          // Clear of the rounded clip and the divider under the last line.
          childrenPadding: const EdgeInsets.only(bottom: AppLayout.gap),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(
              l.realitySearchVerifiedAddress,
              realityVerifiedAddress(candidate),
            ),
            row(l.vpnSni, candidate.target.sni),
            row(l.realitySearchDns, switch (p.dns) {
              TlsDnsCheck.match => l.realityReasonDnsMatch,
              TlsDnsCheck.mismatch => l.realityReasonDnsMismatch,
              _ => l.realityReasonDnsUnresolved,
            }),
            if (cert != null) row(l.realitySearchNames, cert.names.join(', ')),
            for (final r in candidate.reasons)
              if (!_goodReasons.contains(r) && !_badReasons.contains(r))
                Text(
                  realityReasonText(l, r),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
          ],
        ),
        if (candidate.suitable &&
            candidate.fromServer == null &&
            c.checkFromServer != null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: ValueKey('reality-server-${candidate.target.key}'),
            onPressed: c.running || c.checking.contains(candidate.target.key)
                ? null
                : () => c.checkOnServer(candidate),
            icon: const Icon(Icons.dns_outlined),
            label: Text(l.realitySearchServerCheck),
          ),
        ],
        if ((candidate.suitable || candidate.suitableBeforeConnection) &&
            c.checkConnection != null) ...[
          const SizedBox(height: 16),
          _connection(l, candidate),
        ],
        if (candidate.suitable) ...[
          const SizedBox(height: 16),
          FilledButton(
            key: ValueKey('reality-details-use-${candidate.target.key}'),
            onPressed: () {
              if (sheet) Navigator.of(context).pop();
              _use(candidate);
            },
            child: Text(l.realitySearchUse),
          ),
        ] else if (candidate.suitableBeforeConnection) ...[
          const SizedBox(height: 16),
          FilledButton.tonal(
            key: ValueKey('reality-details-use-${candidate.target.key}'),
            onPressed: () {
              if (sheet) Navigator.of(context).pop();
              _use(candidate);
            },
            child: Text(l.realitySearchUseAnyway),
          ),
        ],
      ],
    );
  }

  /// The connection check in place of its button: steps while it runs,
  /// then its result and "Check again".
  Widget _connection(AppLocalizations l, RealityCandidate candidate) {
    final theme = Theme.of(context), key = candidate.target.key;
    final stage = c.connecting[key];
    Widget start(String label) => OutlinedButton.icon(
      key: ValueKey('reality-connect-$key'),
      onPressed: c.running || c.connecting.isNotEmpty
          ? null
          : () => c.checkWithMihomo(candidate),
      icon: const Icon(Icons.network_check),
      label: Text(label),
    );
    final outcome =
        c.outcomes[key] ??
        switch (candidate.fromMihomo?.status) {
          RealityMihomoStatus.working => RealityConnectOutcome.works,
          RealityMihomoStatus.failed => RealityConnectOutcome.fails,
          RealityMihomoStatus.inconclusive => RealityConnectOutcome.unknown,
          null => null,
        };
    final Widget child;
    if (stage != null) {
      final cancelling = c.cancelling.contains(key);
      child = AppOperationStatus(
        key: const ValueKey('running'),
        tone: AppOperationTone.running,
        title: l.realitySearchConnecting,
        step: stage,
        steps: [
          stage > 0 ? l.realityConnectStepCreated : l.realityConnectStepCreate,
          stage > 1
              ? l.realityConnectStepDownloaded
              : l.realityConnectStepDownload,
          l.realityConnectStepRemove,
        ],
        actions: [
          TextButton(
            key: ValueKey('reality-connect-cancel-$key'),
            onPressed: cancelling ? null : () => c.cancelConnection(key),
            child: Text(
              cancelling ? l.realityConnectCancelling : l.realityConnectCancel,
            ),
          ),
        ],
      );
    } else if (outcome == null) {
      child = Column(
        key: const ValueKey('idle'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          start(l.realitySearchConnect),
          Text(l.realitySearchConnectHelp, style: theme.textTheme.bodySmall),
        ],
      );
    } else {
      final took = candidate.fromMihomo?.duration;
      final seconds = took == null
          ? null
          : (took.inMilliseconds / 1000)
                .toStringAsFixed(1)
                .replaceAll(
                  '.',
                  Localizations.localeOf(context).languageCode == 'ru'
                      ? ','
                      : '.',
                );
      final (tone, title, message) = switch (outcome) {
        RealityConnectOutcome.works => (
          AppOperationTone.success,
          l.realityConnectWorks,
          seconds == null
              ? l.realityConnectWorksHelp
              : l.realityConnectWorksTime(seconds),
        ),
        RealityConnectOutcome.fails => (
          AppOperationTone.failure,
          l.realityConnectFails,
          l.realityConnectFailsHelp,
        ),
        RealityConnectOutcome.unknown => (
          AppOperationTone.neutral,
          l.realityConnectUnknown,
          l.realityConnectUnknownHelp,
        ),
        RealityConnectOutcome.cancelled => (
          AppOperationTone.neutral,
          l.realityConnectCancelled,
          l.realityConnectCancelledHelp,
        ),
        RealityConnectOutcome.cleanupPending => (
          AppOperationTone.failure,
          l.realityConnectCleanup,
          l.realityConnectCleanupHelp,
        ),
      };
      child = Column(
        key: ValueKey('result-${outcome.name}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppOperationStatus(tone: tone, title: title, message: message),
          const SizedBox(height: 8),
          start(l.realityConnectAgain),
        ],
      );
    }
    final duration = AppMotion.duration(context, MotionPreference.system);
    return _Reveal(
      state: '${stage ?? outcome?.name ?? 'idle'}',
      child: AppAnimatedSize(
        motion: MotionPreference.system,
        child: duration == Duration.zero
            ? child
            : AnimatedSwitcher(duration: duration, child: child),
      ),
    );
  }

  List<Widget> _results(AppLocalizations l, bool wide) {
    final s = c.state;
    if (s == null) return const [];
    // One list per build: candidates are recomputed on every read.
    final all = c.candidates;
    final best = all.where((x) => x.suitable).take(3).toList();
    final rest = all.where((x) => !best.contains(x)).toList();
    return [
      if (best.isNotEmpty) ...[
        AppSectionHeading(title: l.realitySearchRecommended),
        for (final x in best) _card(l, x, wide),
      ] else if (s.phase == RealitySearchPhase.done)
        AppEmptyState(
          title: l.realitySearchNothing,
          message: l.realitySearchNothingHelp,
          icon: Icons.search_off,
        ),
      if (rest.isNotEmpty) ...[
        AppSectionHeading(title: l.realitySearchOthers, count: rest.length),
        for (final x in rest) _card(l, x, wide),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => Column(
            children: [
              AppPageHeader(
                leading: IconButton(
                  tooltip: l.uiBack,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back),
                ),
                title: Text(l.realitySearchTitle),
                actions: [
                  if (c.candidates.isNotEmpty)
                    AppMoreMenu(
                      tooltip: l.realitySearchExport,
                      children: [
                        AppMenuItem(
                          label: l.realitySearchCopyJson,
                          icon: Icons.data_object,
                          onPressed: () => _copy(c.exportJson()),
                        ),
                        AppMenuItem(
                          label: l.realitySearchCopyCsv,
                          icon: Icons.table_chart_outlined,
                          onPressed: () => _copy(c.exportCsv()),
                        ),
                      ],
                    ),
                ],
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final wide = _wide = box.maxWidth >= AppLayout.expanded;
                    final pad = AppLayout.screenPadding(context);
                    final list = ListView(
                      padding: pad,
                      children: [
                        _sourceCard(l),
                        ..._notices(l),
                        _progress(l),
                        ..._results(l, wide),
                      ],
                    );
                    if (!wide) return list;
                    final shown =
                        selected != null &&
                            c.candidates.any(
                              (x) => x.target == selected!.target,
                            )
                        ? c.candidates.firstWhere(
                            (x) => x.target == selected!.target,
                          )
                        : c.recommended.firstOrNull;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: list),
                        Expanded(
                          child: ListView(
                            padding: pad,
                            children: [
                              if (shown != null) ...[
                                AppSectionHeading(title: shown.target.sni),
                                _details(l, shown),
                              ] else
                                AppEmptyState(
                                  title: l.realitySearchPick,
                                  icon: Icons.touch_app_outlined,
                                ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Scrolls its child fully into view when [state] changes, so a block that
/// grows at the bottom of a sheet or pane stays visible.
class _Reveal extends StatefulWidget {
  const _Reveal({required this.state, required this.child});
  final String state;
  final Widget child;
  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> {
  @override
  void didUpdateWidget(_Reveal old) {
    super.didUpdateWidget(old);
    if (old.state == widget.state) return;
    // After the size animation, so the whole block is measured.
    final wait = AppMotion.duration(context, MotionPreference.system);
    Future<void>.delayed(wait, () {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 1,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: wait,
        curve: AppMotion.curve,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
