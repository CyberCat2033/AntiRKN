import 'dart:math';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../app_strings.dart';
import '../l10n/app_localizations.dart';
import '../runner/runner_controller.dart';
import '../runner/runner_panel.dart';

/// What a server job did, from its kind: "subject · action". Product
/// names stay untranslated; the job carries no further detail (component,
/// protocol, client), so none is guessed.
String runnerJobTitle(AppLocalizations l, String kind) => switch (kind) {
  'vless_apply' => 'VLESS · ${l.activityApply}',
  'inbound_update' => 'VLESS · ${l.activityEditInbound}',
  'inbound_remove' => 'VLESS · ${l.activityRemoveInbound}',
  'awg_apply' => 'AmneziaWG · ${l.activityApply}',
  'awg_external_edit' => 'AmneziaWG · ${l.activityEditExisting}',
  'tt_apply' => 'TrustTunnel · ${l.activityApply}',
  'tt_external_edit' => 'TrustTunnel · ${l.activityEditExisting}',
  'tt_certificate' => 'TrustTunnel · ${l.activityCertificate}',
  'panel_install' => '3x-ui · ${l.activityInstall}',
  'panel_update' => '3x-ui · ${l.activityUpdate}',
  'component_install' => '${l.activityComponents} · ${l.activityInstall}',
  'component_upgrade_apply' => '${l.activityComponents} · ${l.activityUpdate}',
  'protocol_remove' => l.uiRemoveProtocol,
  'egress_apply' => '${l.egressTitle} · ${l.activityApply}',
  'egress_access' => '${l.egressTitle} · ${l.activityServerAccess}',
  'relay_apply' => '${l.relayTitle} · ${l.activityApply}',
  'apt_update' => '${l.aptTitle} · ${l.activityCheck}',
  'apt_upgrade' => '${l.aptTitle} · ${l.activityInstall}',
  'server_reboot' => l.serverReboot,
  'ssh_harden' => l.activitySshHarden,
  'diagnostic' => l.activityDiagnostic,
  _ => l.uiServerChanges,
};

/// When the job last changed: its last event (the runner lists each job
/// with only that one).
DateTime? runnerJobTime(RunnerJob job) =>
    job.events.lastOrNull?.timestamp.toLocal();

/// Newest first by their last event; jobs without one keep their order at
/// the end.
List<RunnerJob> runnerJobsByTime(List<RunnerJob> jobs) {
  final ordered = jobs.indexed.toList()
    ..sort((a, b) {
      final at = runnerJobTime(a.$2), bt = runnerJobTime(b.$2);
      if (at == null || bt == null) {
        return at != null
            ? -1
            : bt != null
            ? 1
            : a.$1.compareTo(b.$1);
      }
      final order = bt.compareTo(at);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
  return [for (final (_, job) in ordered) job];
}

/// The reason under the state: the last event when it says more than the
/// state itself (a failure code, an awaited confirmation).
String? runnerJobReason(AppLocalizations l, RunnerJob job) {
  final code = job.events.lastOrNull?.code;
  if (code == null ||
      const {
        'planned',
        'running',
        'sample',
        'succeeded',
        'failed',
        'cancelled',
      }.contains(code)) {
    return null;
  }
  final label = runnerEventLabel(l, code);
  return label == runnerStateLabel(l, job.status) ? null : label;
}

/// "HH:mm · state · reason" (or the step of a running job). Without
/// [sameDay] a time outside today also names its date.
String runnerJobSummary(
  AppLocalizations l,
  RunnerJob job, {
  bool sameDay = false,
}) {
  final at = runnerJobTime(job);
  final now = DateTime.now();
  final today =
      at != null &&
      at.year == now.year &&
      at.month == now.month &&
      at.day == now.day;
  return [
    if (at != null)
      sameDay || today
          ? DateFormat.Hm(l.localeName).format(at)
          : l.formatDateTime(at),
    runnerStateLabel(l, job.status),
    if (job.status == 'running')
      l.uiActivityStep(min(job.checkpoint + 1, job.count), job.count)
    else
      ?runnerJobReason(l, job),
  ].join(' · ');
}

/// The day group of the full list: today, yesterday or the local date.
String runnerJobDay(AppLocalizations l, DateTime? at, DateTime now) {
  if (at == null) return l.uiActivityEarlier;
  final day = DateTime(at.year, at.month, at.day);
  if (day == DateTime(now.year, now.month, now.day)) return l.uiActivityToday;
  if (day == DateTime(now.year, now.month, now.day - 1)) {
    return l.uiActivityYesterday;
  }
  return DateFormat.yMMMMd(l.localeName).format(at);
}

/// The state as an icon; the row's text says it too, so it is decorative.
class RunnerJobIcon extends StatelessWidget {
  const RunnerJobIcon({required this.job, super.key});
  final RunnerJob job;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 24,
        child: switch (job.status) {
          'succeeded' => Icon(
            Icons.check_circle_outline,
            color: colors.primary,
          ),
          'failed' ||
          'partially_applied' ||
          'needs_attention' => Icon(Icons.error_outline, color: colors.error),
          'cancelled' => Icon(
            Icons.cancel_outlined,
            color: colors.onSurfaceVariant,
          ),
          // Determinate, with a visible start: never an empty ring.
          'running' => Padding(
            padding: const EdgeInsets.all(2),
            child: CircularProgressIndicator(
              strokeWidth: 3,
              value: max(job.checkpoint / job.count, .08),
            ),
          ),
          _ => Icon(Icons.schedule, color: colors.onSurfaceVariant),
        },
      ),
    );
  }
}

class RunnerJobTile extends StatelessWidget {
  const RunnerJobTile({
    required this.job,
    required this.runner,
    this.sameDay = false,
    super.key,
  });
  final RunnerJob job;
  final RunnerController runner;
  final bool sameDay;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListTile(
      key: ValueKey('activity-job-${job.id}'),
      leading: RunnerJobIcon(job: job),
      title: Text(runnerJobTitle(l, job.kind)),
      subtitle: Text(runnerJobSummary(l, job, sameDay: sameDay)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showRunnerJobDetails(context, runner, job),
    );
  }
}

/// The latest server jobs on the overview; the full list opens in a sheet.
class ServerActivitySection extends StatelessWidget {
  const ServerActivitySection({
    required this.runner,
    required this.motion,
    super.key,
  });
  final RunnerController runner;
  final MotionPreference motion;
  static const recent = 3;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: runner,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final jobs = runnerJobsByTime(runner.jobs);
      return AppSettingsSection(
        title: l.uiRecentActivity,
        child: AppAnimatedSize(
          motion: motion,
          child: Column(
            children: [
              if (jobs.isEmpty)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(l.uiNoActivity),
                ),
              for (final job in jobs.take(recent))
                RunnerJobTile(job: job, runner: runner),
              if (jobs.length > recent) ...[
                const Divider(height: 1, indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      key: const ValueKey('activity-view-all'),
                      onPressed: () => showAppDetails(
                        context,
                        title: l.uiActivity,
                        children: [_ActivityList(runner: runner)],
                      ),
                      child: Text(l.uiViewAll),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.runner});
  final RunnerController runner;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: runner,
    builder: (context, _) {
      final l = AppLocalizations.of(context), now = DateTime.now();
      final groups = <String, List<RunnerJob>>{};
      for (final job in runnerJobsByTime(runner.jobs)) {
        groups
            .putIfAbsent(runnerJobDay(l, runnerJobTime(job), now), () => [])
            .add(job);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.uiActivityHelp,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (groups.isEmpty)
            AppEmptyState(title: l.uiNoActivity, icon: Icons.history),
          for (final MapEntry(key: day, value: jobs) in groups.entries) ...[
            AppSectionHeading(title: day, subheader: true),
            Card.filled(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final job in jobs)
                    RunnerJobTile(job: job, runner: runner, sameDay: true),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      );
    },
  );
}

/// One job: its state and reason, the step timeline read from the runner
/// and, under technical details, its ID.
Future<void> showRunnerJobDetails(
  BuildContext context,
  RunnerController runner,
  RunnerJob job,
) => showAppDetails(
  context,
  title: runnerJobTitle(AppLocalizations.of(context), job.kind),
  children: [_JobDetails(runner: runner, job: job)],
);

class _JobDetails extends StatefulWidget {
  const _JobDetails({required this.runner, required this.job});
  final RunnerController runner;
  final RunnerJob job;
  @override
  State<_JobDetails> createState() => _JobDetailsState();
}

class _JobDetailsState extends State<_JobDetails> {
  RunnerJob? full;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    widget.runner.readJobHistory(widget.job.id).then((job) {
      if (!mounted) return;
      setState(() {
        full = job;
        loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.runner,
    builder: (context, _) {
      final l = AppLocalizations.of(context),
          theme = Theme.of(context),
          time = DateFormat.Hms(l.localeName);
      // The listed state stays current while the sheet is open; the read
      // timeline adds the steps the list does not carry.
      final listed =
          widget.runner.jobs.where((j) => j.id == widget.job.id).firstOrNull ??
          widget.job;
      // The newer of the two leads: a job's events never pass its sequence.
      final read = full;
      final job = read != null && read.sequence > listed.sequence
          ? read.mergeEvents(listed)
          : listed.mergeEvents(read);
      final at = runnerJobTime(job);
      final reason = runnerJobReason(l, job);
      final failed = const {
        'failed',
        'partially_applied',
        'needs_attention',
      }.contains(job.status);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: RunnerJobIcon(job: job),
            title: Text(
              [
                runnerStateLabel(l, job.status),
                if (job.status == 'running')
                  l.uiActivityStep(
                    min(job.checkpoint + 1, job.count),
                    job.count,
                  ),
              ].join(' · '),
            ),
            subtitle: at == null ? null : Text(l.formatDateTime(at)),
          ),
          if (failed && reason != null) AppNotice(message: reason, error: true),
          if (loading) const LinearProgressIndicator(),
          if (!loading && full == null)
            AppNotice(message: l.uiActivityStepsUnavailable),
          if (job.events.isNotEmpty) ...[
            AppSectionHeading(title: l.uiActivitySteps, subheader: true),
            Card.filled(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final event in job.events)
                    ListTile(
                      title: Text(runnerEventLabel(l, event.code)),
                      subtitle: Text(time.format(event.timestamp.toLocal())),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          AppExpansionTile(
            key: ValueKey('activity-technical-${job.id}'),
            tilePadding: EdgeInsets.zero,
            title: Text(
              l.uiTechnicalDetails,
              style: theme.textTheme.bodyMedium,
            ),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.uiActivityJobId),
                subtitle: SelectableText(job.id),
              ),
            ],
          ),
        ],
      );
    },
  );
}
