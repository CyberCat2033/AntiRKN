import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import 'ip_diagnostics_controller.dart';

String diagnosticStageLabel(AppLocalizations l, String stage) =>
    switch (stage) {
      'baseline' => l.diagBaseline,
      'target' => l.diagTarget,
      'controls' => l.diagControls,
      'recovery' => l.diagRecovery,
      'complete' => l.diagComplete,
      'cancelled' => l.diagCancelled,
      'networkChanged' => l.diagNetworkChanged,
      'insufficient' => l.diagInsufficient,
      'degraded' => l.diagDegraded,
      _ => l.diagFailed,
    };

class IpDiagnosticsPage extends StatelessWidget {
  const IpDiagnosticsPage({
    required this.controller,
    this.servers = const [],
    super.key,
  });
  final IpDiagnosticsController controller;
  final List<SavedServer> servers;
  Future<void> start(BuildContext context) async {
    final l = AppLocalizations.of(context);
    List<IpProbeTarget> targets;
    try {
      targets = controller.parse();
    } catch (_) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.diagInvalid)));
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AppFormDialog(
        title: Text(l.diagTitle),
        content: Text(l.diagConsent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.sshCancel),
          ),
          FilledButton(
            key: const ValueKey('diagnostics-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.diagStart),
          ),
        ],
      ),
    );
    if (approved == true && context.mounted) await controller.start(targets);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, l = AppLocalizations.of(context), run = c.current;
      return ListView(
        padding: AppLayout.screenPadding(context),
        children: [
          AppPageIntro(l.diagIntro),
          AppSettingsSection(
            title: l.diagTitle,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (servers.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: c.busy
                          ? null
                          : () async {
                              final server = await showAppChoice<String>(
                                context,
                                title: l.server,
                                value: '',
                                options: [
                                  for (final server in servers)
                                    (server.id, server.profile.displayName),
                                ],
                              );
                              final chosen = servers
                                  .where((s) => s.id == server)
                                  .firstOrNull;
                              if (chosen != null) {
                                final ips = {
                                  if (IpAddress.tryParse(chosen.profile.host) !=
                                      null)
                                    chosen.profile.host,
                                  ...?chosen.profile.lastInfo?.publicAddresses
                                      ?.map((ip) => ip.canonical),
                                };
                                c.seed(
                                  ips.join('\n'),
                                  serverPort: chosen.profile.port,
                                );
                              }
                            },
                      icon: const Icon(Icons.dns_outlined),
                      label: Text(l.diagChooseServer),
                    ),
                  TextField(
                    key: const ValueKey('diagnostics-addresses'),
                    controller: c.addresses,
                    enabled: !c.busy,
                    minLines: 2,
                    maxLines: 5,
                    maxLength: 3000,
                    decoration: InputDecoration(labelText: l.diagAddresses),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: c.port,
                    enabled: !c.busy,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l.diagPort),
                  ),
                  const SizedBox(height: 12),
                  AppSelectField<IpProbeKind>(
                    label: l.diagProtocol,
                    value: c.kind,
                    options: [
                      (IpProbeKind.tcp, 'TCP'),
                      (IpProbeKind.ssh, 'SSH'),
                      (IpProbeKind.tls, 'TLS'),
                    ],
                    onChanged: c.busy ? null : c.setKind,
                  ),
                  if (c.kind == IpProbeKind.tls) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: c.host,
                      enabled: !c.busy,
                      decoration: InputDecoration(labelText: l.diagSni),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('diagnostics-start'),
                    onPressed: c.busy ? null : () => start(context),
                    icon: const Icon(Icons.network_check),
                    label: Text(l.diagStart),
                  ),
                  if (c.busy) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: c.stop,
                      icon: const Icon(Icons.stop),
                      label: Text(l.diagStop),
                    ),
                  ],
                  if (c.issue != null)
                    Text(c.issue == 'busy' ? l.diagBusy : l.diagFailed),
                  if (c.historyError) Text(l.diagHistoryError),
                ],
              ),
            ),
          ),
          if (run != null)
            AppSettingsSection(
              title: diagnosticStageLabel(l, run.stage.name),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (c.busy) const LinearProgressIndicator(),
                    Text(
                      '${run.completed}/${run.targets.length} · ${run.currentIp ?? ''}',
                    ),
                    if (run.network != null)
                      Text(
                        '${l.diagNetwork}: ${networkLabel(l, run.network!.kind)}${run.network!.vpn ? ' · VPN' : ''}',
                      ),
                    if (run.controlsTotal > 0)
                      Text(
                        l.diagControlCount(
                          run.controlsReachable,
                          run.controlsTotal,
                        ),
                      ),
                    if (run.suspectedStrong)
                      Text(
                        l.diagStrong,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (run.regionalLoss) Text(l.diagRegional),
                    if (run.recoveredAt != null)
                      Text(
                        l.diagRecovered(
                          run.recoveredAt!.difference(run.lossAt!).inSeconds,
                        ),
                      ),
                    if (run.stage == IpDiagnosticStage.degraded &&
                        run.recoveredAt == null)
                      Text(l.diagNotRecovered),
                    for (final sample in run.samples.where(
                      (s) => s.phase == 'target',
                    ))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          sample.result.reachable
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                        ),
                        title: Text(probeEndpoint(sample.target)),
                        subtitle: Text(
                          '${probeLabel(l, sample.result.status)} · ${sample.result.milliseconds} ms',
                        ),
                      ),
                    Text(l.diagLimits),
                  ],
                ),
              ),
            ),
          AppSettingsSection(
            title: l.diagControlList,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l.diagControlHelp),
                ),
                for (final control in c.engine.controls)
                  ListTile(
                    dense: true,
                    title: Text(control.name),
                    subtitle: Text(
                      '${probeEndpoint(control.target)} · ${regionLabel(l, control.region)}',
                    ),
                  ),
              ],
            ),
          ),
          AppSettingsSection(
            title: l.diagHistory,
            child: Column(
              children: [
                for (final entry in c.history)
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(_historyTitle(l, entry)),
                    subtitle: Text(
                      '${entry['completed']}/${entry['total']} · ${networkLabel(l, entry['network'] as String? ?? 'system')}',
                    ),
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (context) => AppFormDialog(
                        title: Text(l.diagHistory),
                        content: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(_historyTitle(l, entry)),
                              Text(
                                l.diagControlCount(
                                  entry['controlsReachable'] as int? ?? 0,
                                  entry['controlsTotal'] as int? ?? 0,
                                ),
                              ),
                              if (entry['suspectedStrong'] == true)
                                Text(l.diagStrong),
                              if (entry['regionalLoss'] == true)
                                Text(l.diagRegional),
                              for (final sample
                                  in (entry['samples'] as List? ?? const [])
                                      .whereType<Map>()
                                      .where(
                                        (sample) => sample['phase'] == 'target',
                                      ))
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: SelectableText(
                                    '${sample['ip']} · ${sample['port']}',
                                  ),
                                  subtitle: Text(
                                    probeLabel(
                                      l,
                                      IpProbeStatus.values
                                              .where(
                                                (s) =>
                                                    s.name == sample['status'],
                                              )
                                              .firstOrNull ??
                                          IpProbeStatus.unavailable,
                                    ),
                                  ),
                                ),
                              Text(l.diagLimits),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: jsonEncode(entry)),
                              );
                            },
                            child: Text(l.diagCopyReport),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(l.uiBack),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (c.history.isNotEmpty)
                  TextButton(
                    onPressed: c.busy ? null : c.clearHistory,
                    child: Text(l.diagClearHistory),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
  String _historyTitle(AppLocalizations l, Map<String, dynamic> entry) {
    final at = DateTime.tryParse(entry['startedAt'] as String? ?? '');
    final stage = entry['stage'] as String? ?? 'failed';
    final interrupted =
        !controller.busy &&
        ['baseline', 'target', 'controls', 'recovery'].contains(stage);
    return '${at == null ? '' : DateFormat.yMd(l.localeName).add_Hm().format(at.toLocal())} · ${interrupted ? l.diagInterrupted : diagnosticStageLabel(l, stage)}';
  }
}

String probeLabel(AppLocalizations l, IpProbeStatus value) => switch (value) {
  IpProbeStatus.reachable => l.diagReachable,
  IpProbeStatus.refused => l.diagRefused,
  IpProbeStatus.tlsError => l.diagTlsError,
  IpProbeStatus.protocolError => l.diagProtocolError,
  IpProbeStatus.timeout || IpProbeStatus.unavailable => l.diagUnreachable,
};

String networkLabel(AppLocalizations l, String value) => switch (value) {
  'wifi' => l.diagWifi,
  'mobile' => l.diagMobile,
  'ethernet' => 'Ethernet',
  'vpn' => 'VPN',
  _ => l.diagSystem,
};
String regionLabel(AppLocalizations l, String value) => switch (value) {
  'foreign' => l.diagForeign,
  'ru' => l.diagRussia,
  _ => l.diagAnycast,
};

String probeEndpoint(IpProbeTarget target) =>
    target.address.family == IpFamily.ipv6
    ? '[${target.address.canonical}]:${target.port}'
    : '${target.address.canonical}:${target.port}';
