import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../runner/runner_panel.dart';
import 'vpn_controller.dart';
import 'vpn_strings.dart';

String inboundSummary(Map s) =>
    '${s['name']} · VLESS ${s['transport']} / ${s['security']}\n${s['listen']}:${s['port']} → ${s['endpoint']}:${s['externalPort']}\nSNI: ${s['sni']}${s['security'] == 'reality' ? ' · target: ${s['target']}' : ''}${s['transport'] == 'xhttp' ? '\n${s['path']} · ${s['mode']} · Host: ${s['host']}' : ''}';

class VpnPlanView extends StatelessWidget {
  const VpnPlanView({
    required this.controller,
    required this.serverName,
    super.key,
  });
  final VpnController controller;
  final String Function(String) serverName;
  @override
  Widget build(BuildContext context) {
    final c = controller, l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.busy) const LinearProgressIndicator(),
        if (c.error case final error?)
          Semantics(liveRegion: true, child: Text(vpnMessage(l, error))),
        if (c.plans.isNotEmpty)
          SectionCard(
            title: l.vpnPlan,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.vpnPlanHelp),
                for (final p in c.plans)
                  Padding(
                    padding: const EdgeInsets.only(top: AppLayout.gap),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${serverName(vpnServerId(p.serverId))}${isAwgTarget(p.serverId) ? ' · AmneziaWG' : ''}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (isAwgTarget(p.serverId)) Text(l.awgNetworkPlan),
                        if (p.preview == null) Text(l.vpnOfflinePlan),
                        Text(
                          '${l.vpnUsers}: ${(p.payload['users'] as List).length}',
                        ),
                        for (final user in c.workspace.users)
                          Text(
                            '${user.name} (${user.login}): ${user.enabled ? l.vpnEnabled : l.vpnDisabled}',
                          ),
                        for (final r in p.payload['resources'] as List)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: AppLayout.smallGap,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  isAwgTarget(p.serverId)
                                      ? '${(r as Map)['name']} · UDP ${r['port']} → ${r['endpoint']}:${r['externalPort']}\n${r['pool']} · MTU ${r['mtu']}'
                                      : inboundSummary(r as Map),
                                ),
                                if (r['security'] == 'reality' &&
                                    r['realitySeed'] != null)
                                  Text(l.vpnRealityKeyPlan),
                                Text(
                                  r['internal'] == true
                                      ? l.vpnInternalHelp
                                      : l.vpnClientAccess,
                                ),
                                Text(
                                  r['deleted'] == true
                                      ? l.vpnDeleteHelp
                                      : r['enabled'] == true
                                      ? l.vpnEnabled
                                      : l.vpnDisabled,
                                ),
                                if (r['security'] == 'tls')
                                  Text(
                                    '${l.vpnCertificate}: ${r['certificate']}\n${l.vpnCertificateKey}: ${r['certificateKey']}',
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                Wrap(
                  spacing: AppLayout.smallGap,
                  children: [
                    FilledButton(
                      key: const ValueKey('vpn-apply'),
                      onPressed: c.busy ? null : c.apply,
                      child: Text(l.vpnApply),
                    ),
                    TextButton(
                      onPressed: c.busy ? null : c.dismissPlans,
                      child: Text(l.runnerNotNow),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class VpnJobView extends StatelessWidget {
  const VpnJobView({
    required this.controller,
    required this.serverId,
    super.key,
  });
  final VpnController controller;
  final String serverId;
  @override
  Widget build(BuildContext context) {
    final c = controller,
        l = AppLocalizations.of(context),
        record = c.workspace.servers[serverId];
    if (record == null) return const SizedBox.shrink();
    final job = record['job'] == null
        ? null
        : RunnerJob.fromJson(Map<String, dynamic>.from(record['job'] as Map));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (record['error'] case final String error) Text(vpnMessage(l, error)),
        if (job != null) ...[
          Text(runnerStateLabel(l, job.status)),
          if (job.events.isNotEmpty) Text(vpnMessage(l, job.events.last.code)),
          if (!job.terminal)
            LinearProgressIndicator(value: job.checkpoint / job.count),
          Text('${job.checkpoint} / ${job.count}'),
        ],
        if (record['pending'] == null &&
            record['paused'] != true &&
            record['authorizedPayload'] != null &&
            record['authorizedPayload'] != record['appliedPayload'])
          Text(l.vpnOfflinePlan),
        if (record['pending'] != null ||
            (record['paused'] != true &&
                record['authorizedPayload'] != null &&
                record['authorizedPayload'] != record['appliedPayload']))
          Wrap(
            spacing: AppLayout.smallGap,
            children: [
              if (job?.terminal != true)
                TextButton(
                  onPressed: c.busy ? null : () => c.cancel(serverId),
                  child: Text(l.runnerCancel),
                ),
              if (record['paused'] == true &&
                  (job?.status == 'failed' ||
                      job?.status == 'partially_applied'))
                OutlinedButton(
                  onPressed: c.busy ? null : () => c.resume(serverId),
                  child: Text(l.runnerRetry),
                ),
            ],
          ),
        if (record['verifiedAt'] case final String at)
          Text('${l.vpnSnapshot}: ${DateTime.tryParse(at)?.toLocal() ?? at}'),
      ],
    );
  }
}
