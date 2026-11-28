import 'dart:async';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_strings.dart';
import '../l10n/app_localizations.dart';
import 'client_traffic_controller.dart';

String _protocolName(String protocol) => switch (protocol) {
  'vless' => 'VLESS',
  'awg' => 'AmneziaWG',
  _ => 'TrustTunnel',
};

/// "November", or "December 2025" outside the current year.
String trafficMonthName(AppLocalizations l, String month, DateTime now) {
  final year = int.parse(month.substring(0, 4));
  final name = DateFormat.LLLL(
    l.localeName,
  ).format(DateTime(year, int.parse(month.substring(5))));
  final label = name.isEmpty
      ? month
      : name[0].toUpperCase() + name.substring(1);
  return year == now.toUtc().year ? label : '$label $year';
}

/// Why a server's latest read failed, when it is worth saying: a server
/// merely not connected keeps its cached figures without comment.
String? _issueText(AppLocalizations l, String? issue) => switch (issue) {
  null || 'traffic_not_connected' => null,
  'traffic_runner_outdated' => l.trafficIssueOutdated,
  _ => l.trafficIssueFailed,
};

/// Reads the servers again; spins while they are being read.
class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.controller});
  final ClientTrafficController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => IconButton(
      key: const ValueKey('traffic-refresh'),
      tooltip: AppLocalizations.of(context).trafficRefresh,
      onPressed: controller.busy
          ? null
          : () => controller.refresh(connect: true),
      icon: controller.busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
    ),
  );
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({
    required this.title,
    required this.usage,
    required this.color,
    this.selected = false,
    this.onTap,
    super.key,
  });
  final String title;
  final TrafficUsage? usage;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    String value(int? bytes) => bytes == null ? '—' : serverBytes(bytes);
    return Semantics(
      selected: selected,
      child: SummaryCard(
        title: title,
        selected: selected,
        color: color,
        onTap: onTap,
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.south_west, color: colors.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    value(usage?.down),
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Icon(Icons.north_east, size: 18, color: colors.tertiary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    value(usage?.up),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Two cards side by side, stacked when narrow or with large text.
class _CardPair extends StatelessWidget {
  const _CardPair({required this.first, required this.second});
  final Widget first, second;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final stacked =
          size.maxWidth < 340 ||
          MediaQuery.textScalerOf(context).scale(14) > 21;
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            first,
            const SizedBox(height: AppLayout.smallGap),
            second,
          ],
        );
      }
      // Both cards hold the same lines, so they are of one height.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: AppLayout.smallGap),
          Expanded(child: second),
        ],
      );
    },
  );
}

/// This month and all the time, in the client's card; either card opens
/// the details in place, under the cards. Opening the card reads the
/// already connected servers again in the background once it has slid in.
class ClientTrafficCards extends StatefulWidget {
  const ClientTrafficCards({
    required this.controller,
    required this.userId,
    required this.userName,
    required this.serverName,
    this.motion = MotionPreference.system,
    super.key,
  });
  final ClientTrafficController controller;
  final String userId, userName;
  final String Function(String) serverName;
  final MotionPreference motion;

  /// Counters read this recently are not read again on opening.
  static const freshFor = Duration(minutes: 1);

  @override
  State<ClientTrafficCards> createState() => _ClientTrafficCardsState();
}

class _ClientTrafficCardsState extends State<ClientTrafficCards> {
  Animation<double>? _route;

  /// The details are open, starting from this period; null: all the time.
  bool _open = false;
  String? _month;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    // Reading over SSH while the sheet slides in makes the slide stutter.
    _route = ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation;
    if (_route!.isCompleted) {
      _refresh();
    } else {
      _route!.addStatusListener(_routeStatus);
    }
  }

  @override
  void didUpdateWidget(ClientTrafficCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another client in the same place starts folded.
    if (oldWidget.userId != widget.userId) _open = false;
  }

  void _routeStatus(AnimationStatus status) {
    if (!status.isCompleted) return;
    _route?.removeStatusListener(_routeStatus);
    if (mounted) _refresh();
  }

  void _refresh() =>
      unawaited(widget.controller.refresh(maxAge: ClientTrafficCards.freshFor));

  @override
  void dispose() {
    _route?.removeStatusListener(_routeStatus);
    super.dispose();
  }

  void _details(String? month) => setState(() {
    _open = true;
    _month = month;
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, l = AppLocalizations.of(context);
      if (c.servers().isEmpty) return const SizedBox.shrink();
      final summary = c.summary(widget.userId);
      final now = DateTime.now();
      final month = trafficMonth(now);
      final known = !summary.isEmpty;
      final color = Theme.of(context).colorScheme.surfaceContainerHighest;
      return Padding(
        key: const ValueKey('client-traffic'),
        padding: const EdgeInsets.only(top: AppLayout.gap),
        child: AppAnimatedSize(
          motion: widget.motion,
          child: _open
              ? ClientTrafficDetails(
                  key: ValueKey('client-traffic-open-${widget.userId}'),
                  controller: c,
                  userId: widget.userId,
                  serverName: widget.serverName,
                  month: _month,
                  color: color,
                  onCollapse: () => setState(() => _open = false),
                )
              : Semantics(
                  expanded: false,
                  child: _CardPair(
                    first: _UsageCard(
                      key: const ValueKey('client-traffic-month'),
                      title: trafficMonthName(l, month, now),
                      usage: known ? summary.usage(month) : null,
                      color: color,
                      onTap: () => _details(month),
                    ),
                    second: _UsageCard(
                      key: const ValueKey('client-traffic-all'),
                      title: l.trafficAllTime,
                      usage: known ? summary.usage(null) : null,
                      color: color,
                      onTap: () => _details(null),
                    ),
                  ),
                ),
        ),
      );
    },
  );
}

/// The month card, the all-time card and the chart's bars are one choice
/// of period; the server list follows it.
class ClientTrafficDetails extends StatefulWidget {
  const ClientTrafficDetails({
    required this.controller,
    required this.userId,
    required this.serverName,
    this.month,
    this.color,
    this.onCollapse,
    super.key,
  });
  final ClientTrafficController controller;
  final String userId;
  final String Function(String) serverName;

  /// The month first shown; null: all the time.
  final String? month;

  /// The cards' colour; `surfaceContainerHigh` when not given.
  final Color? color;

  /// Folds the details back into the two cards; tapping the chosen card
  /// again does the same.
  final VoidCallback? onCollapse;
  @override
  State<ClientTrafficDetails> createState() => _ClientTrafficDetailsState();
}

class _ClientTrafficDetailsState extends State<ClientTrafficDetails> {
  late String? selected = widget.month;
  late String lastMonth = widget.month ?? trafficMonth(DateTime.now());

  void _select(String? month) => setState(() {
    selected = month;
    if (month != null) lastMonth = month;
  });

  /// A card picks its period; the one already picked folds the details.
  void _card(String? month) {
    final current = month == null ? selected == null : selected != null;
    if (current && widget.onCollapse != null) return widget.onCollapse!();
    _select(month);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, l = AppLocalizations.of(context);
      final theme = Theme.of(context), colors = theme.colorScheme;
      final now = DateTime.now();
      final summary = c.summary(widget.userId);
      final months = trafficMonths(now);
      final known = !summary.isEmpty;
      final period = selected == null
          ? l.trafficAllTime
          : trafficMonthName(l, selected!, now);
      final color = widget.color ?? colors.surfaceContainerHigh;
      return Column(
        key: const ValueKey('client-traffic-details-sheet'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: widget.onCollapse == null ? null : true,
            child: _CardPair(
              first: _UsageCard(
                key: const ValueKey('traffic-details-month'),
                title: trafficMonthName(l, lastMonth, now),
                usage: known ? summary.usage(lastMonth) : null,
                color: color,
                selected: selected != null,
                onTap: () => _card(lastMonth),
              ),
              second: _UsageCard(
                key: const ValueKey('traffic-details-all'),
                title: l.trafficAllTime,
                usage: known ? summary.usage(null) : null,
                color: color,
                selected: selected == null,
                onTap: () => _card(null),
              ),
            ),
          ),
          const SizedBox(height: AppLayout.gap),
          Row(
            children: [
              Expanded(
                child: Text(
                  l.trafficByMonth,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (widget.onCollapse != null) _RefreshButton(controller: c),
            ],
          ),
          Text(
            l.trafficChartHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppLayout.smallGap),
          TrafficChart(
            months: months,
            usage: {for (final m in months) m: summary.usage(m)},
            selected: selected,
            label: (m) => trafficMonthName(l, m, now),
            onSelect: _select,
          ),
          const SizedBox(height: AppLayout.smallGap),
          Wrap(
            spacing: AppLayout.gap,
            children: [
              _Legend(color: colors.primary, label: l.trafficDownloaded),
              _Legend(color: colors.tertiary, label: l.trafficUploaded),
            ],
          ),
          const SizedBox(height: AppLayout.gap),
          Text(
            '${l.trafficByServer} · $period',
            style: theme.textTheme.titleSmall,
          ),
          for (final server in summary.servers)
            _ServerRow(
              key: ValueKey('traffic-server-${server.serverId}'),
              server: server,
              name: widget.serverName(server.serverId),
              month: selected,
              issue: _issueText(l, c.issues[server.serverId]),
            ),
          const SizedBox(height: AppLayout.gap),
          Text(
            l.trafficPrivacy,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (widget.onCollapse case final collapse?)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: const ValueKey('client-traffic-collapse'),
                onPressed: collapse,
                icon: const Icon(Icons.expand_less),
                label: Text(l.trafficCollapse),
              ),
            ),
        ],
      );
    },
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

/// Downloaded and uploaded bytes on one line, with the arrows of the
/// traffic cards.
class TrafficUsageText extends StatelessWidget {
  const TrafficUsageText(this.usage, {this.style, super.key});
  final TrafficUsage usage;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(Icons.south_west, size: 16, color: colors.primary),
          ),
          TextSpan(text: ' ${serverBytes(usage.down)}  '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(Icons.north_east, size: 16, color: colors.tertiary),
          ),
          TextSpan(text: ' ${serverBytes(usage.up)}'),
        ],
      ),
      style: style,
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.server,
    required this.name,
    required this.month,
    this.issue,
    super.key,
  });
  final ServerClientTraffic server;
  final String name;
  final String? month;

  /// Why this server could not be read now; its cached figures stay.
  final String? issue;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final several = server.protocols.length > 1;
    String? note(ProtocolTraffic p) => switch (p.state) {
      TrafficSourceState.off => l.trafficStateOff,
      TrafficSourceState.unavailable => l.trafficStateUnavailable,
      _ => null,
    };
    bool counts(ProtocolTraffic p) => p.state != TrafficSourceState.off;
    return LayoutBuilder(
      builder: (context, size) {
        // Sums beside the name, as on a wide row; under it when they would
        // not fit a narrow screen with large text.
        final stacked =
            size.maxWidth < 360 ||
            MediaQuery.textScalerOf(context).scale(14) > 21;
        Widget line(Widget start, Widget? end) => stacked || end == null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [start, ?end],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: start),
                  const SizedBox(width: AppLayout.gap),
                  end,
                ],
              );
        final total = server.protocols.any(counts)
            ? TrafficUsageText(
                server.usage(month),
                style: theme.textTheme.bodyMedium,
              )
            : Text('—', style: theme.textTheme.bodyMedium);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppLayout.smallGap),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                issue == null ? Icons.dns_outlined : Icons.cloud_off_outlined,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: AppLayout.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    line(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: theme.textTheme.titleMedium),
                          if (issue != null)
                            Text(
                              issue!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.error,
                              ),
                            ),
                        ],
                      ),
                      total,
                    ),
                    for (final p in server.protocols)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: line(
                          Wrap(
                            spacing: AppLayout.smallGap,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              AppBadge(label: _protocolName(p.protocol)),
                              if (note(p) case final text?)
                                Text(text, style: muted),
                            ],
                          ),
                          several && counts(p)
                              ? TrafficUsageText(p.usage(month), style: muted)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Twelve monthly bars, downloads below uploads; each bar picks its month,
/// a drag across the chart picks the month under the finger.
class TrafficChart extends StatelessWidget {
  const TrafficChart({
    required this.months,
    required this.usage,
    required this.selected,
    required this.label,
    required this.onSelect,
    super.key,
  });
  final List<String> months;
  final Map<String, TrafficUsage> usage;

  /// The chosen month; null: all the time, every bar highlighted.
  final String? selected;
  final String Function(String) label;
  final ValueChanged<String> onSelect;

  static const _height = 104.0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), theme = Theme.of(context);
    final colors = theme.colorScheme;
    final peak = usage.values.fold<int>(
      0,
      (a, u) => u.down + u.up > a ? u.down + u.up : a,
    );
    double height(int bytes) => peak == 0 ? 0 : bytes / peak * (_height - 4);
    return LayoutBuilder(
      builder: (context, size) {
        void pick(double dx) {
          final i = (dx / size.maxWidth * months.length).floor();
          final month = months[i.clamp(0, months.length - 1)];
          if (month != selected) onSelect(month);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onHorizontalDragStart: (d) => pick(d.localPosition.dx),
              onHorizontalDragUpdate: (d) => pick(d.localPosition.dx),
              child: SizedBox(
                height: _height,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final m in months)
                      Expanded(
                        child: _Bar(
                          key: ValueKey('traffic-bar-$m'),
                          usage: usage[m] ?? TrafficUsage.zero,
                          on: selected == null || selected == m,
                          selected: selected == m,
                          label: l.trafficBarLabel(
                            label(m),
                            serverBytes((usage[m] ?? TrafficUsage.zero).down),
                            serverBytes((usage[m] ?? TrafficUsage.zero).up),
                          ),
                          downHeight: height(usage[m]?.down ?? 0),
                          upHeight: height(usage[m]?.up ?? 0),
                          onTap: () => onSelect(m),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: Row(
                children: [
                  for (final m in months)
                    Expanded(
                      child: Text(
                        label(m).characters.first,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: selected == m
                              ? colors.onSurface
                              : colors.onSurfaceVariant,
                          fontWeight: selected == m ? FontWeight.bold : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.usage,
    required this.on,
    required this.selected,
    required this.label,
    required this.downHeight,
    required this.upHeight,
    required this.onTap,
    super.key,
  });
  final TrafficUsage usage;
  final bool on, selected;
  final String label;
  final double downHeight, upHeight;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final alpha = on ? 1.0 : .35;
    const radius = BorderRadius.all(Radius.circular(6));
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (upHeight > 0)
                Container(
                  height: upHeight,
                  decoration: BoxDecoration(
                    color: colors.tertiary.withValues(alpha: alpha),
                    borderRadius: radius,
                  ),
                ),
              if (upHeight > 0 && downHeight > 0) const SizedBox(height: 2),
              Container(
                height: downHeight > 0 ? downHeight : 2,
                decoration: BoxDecoration(
                  color:
                      (downHeight > 0 ? colors.primary : colors.outlineVariant)
                          .withValues(alpha: alpha),
                  borderRadius: radius,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
