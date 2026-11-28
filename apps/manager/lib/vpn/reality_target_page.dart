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
  RealityReason.redirectNotChecked => l.realityReasonRedirectNotChecked,
  RealityReason.notTls13 => l.realityReasonNotTls13,
  RealityReason.noH2 => l.realityReasonNoH2,
  RealityReason.unsupportedGroup => l.realityReasonUnsupportedGroup,
  RealityReason.certificateInvalid => l.realityReasonCertificateInvalid,
  RealityReason.handshakeFailed => l.realityReasonHandshakeFailed,
  RealityReason.knownCdn => l.realityReasonKnownCdn,
  RealityReason.expiresSoon => l.realityReasonExpiresSoon,
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

  @override
  void initState() {
    super.initState();
    c.ready.then((_) => c.checkNetwork());
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
            : showAppDetails(
                context,
                title: candidate.target.sni,
                children: [_details(l, candidate, sheet: true)],
              ),
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
                  if (candidate.level == RealityLevel.serverChecked)
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
    final theme = Theme.of(context);
    final p = candidate.confirmation, cert = p.certificate;
    final local = MaterialLocalizations.of(context);
    final facts = <(String, String)>[
      (l.vpnTarget, realityChoice(candidate).target),
      (l.vpnSni, candidate.target.sni),
      ('TLS', p.version),
      ('ALPN', p.alpn),
      (l.realityKeyExchange, p.group),
      (
        l.realitySearchDns,
        switch (p.dns) {
          TlsDnsCheck.match => l.realityReasonDnsMatch,
          TlsDnsCheck.mismatch => l.realityReasonDnsMismatch,
          _ => l.realityReasonDnsUnresolved,
        },
      ),
      (l.realityLatency, '${p.tls.inMilliseconds}'),
      if (candidate.fromServer?.latency case final latency?)
        (l.realitySearchServerLatency, '${latency.inMilliseconds}'),
      if (cert != null) ...[
        (l.realityCertificate, cert.issuer),
        (l.realityCertificateExpiry, local.formatMediumDate(cert.notAfter)),
        (l.realitySearchNames, cert.names.join(', ')),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in facts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelLarge),
                SelectableText(
                  value.isEmpty ? '—' : value,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        Text(l.realitySearchWhy, style: theme.textTheme.labelLarge),
        for (final r in candidate.reasons)
          Text(
            '• ${realityReasonText(l, r)}',
            style: theme.textTheme.bodyMedium,
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
        if (candidate.suitable) ...[
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              if (sheet) Navigator.of(context).pop();
              _use(candidate);
            },
            child: Text(l.realitySearchUse),
          ),
        ],
      ],
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
                    final wide = box.maxWidth >= AppLayout.expanded;
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
