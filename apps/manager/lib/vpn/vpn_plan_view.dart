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
                          '${serverName(vpnServerId(p.serverId))}${isAwgTarget(p.serverId)
                              ? ' · AmneziaWG'
                              : isTtTarget(p.serverId)
                              ? ' · TrustTunnel'
                              : ''}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (isAwgTarget(p.serverId)) Text(l.awgNetworkPlan),
                        if (isTtTarget(p.serverId)) Text(l.ttRestartPlan),
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
                                  isTtTarget(p.serverId)
                                      ? '${(r as Map)['name']} · ${r['domain']}\n${r['listen']}:${r['port']} → ${r['endpoint']}:${r['externalPort']}\n${r['outbound'] == 'socks5' ? 'SOCKS5 ${r['socksAddress']}' : l.ttDirect}'
                                      : isAwgTarget(p.serverId)
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
    final job = c.currentJob(serverId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.observesOperation(serverId)) ...[
          Text(l.operationObserving),
          if (c.observedJobs.containsKey(serverId) && job == null)
            Text(l.operationMissing),
          if (c.observationErrors[serverId] case final String error)
            Text(vpnMessage(l, error)),
          if (job == null)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: ValueKey('operation-takeover-$serverId'),
                onPressed: c.busy ? null : () => c.takeOver(serverId),
                child: Text(l.operationTakeOver),
              ),
            ),
        ],
        if (c.needsRestoreReview(serverId)) ...[
          Text(l.backupOperationReview),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: c.busy ? null : () => c.reviewRestored(serverId),
              child: Text(l.backupReviewServer),
            ),
          ),
        ],
        if (record['error'] case final String error) Text(vpnMessage(l, error)),
        if (job != null) ...[
          if (job.status != 'succeeded') ...[
            Text(runnerStateLabel(l, job.status)),
            if (job.events.isNotEmpty &&
                vpnMessage(l, job.events.last.code) !=
                    runnerStateLabel(l, job.status))
              Text(vpnMessage(l, job.events.last.code)),
            if (!job.terminal) ...[
              LinearProgressIndicator(
                value: job.count > 0 ? job.checkpoint / job.count : null,
              ),
              Text('${job.checkpoint} / ${job.count}'),
            ],
          ],
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
              if ((record['paused'] == true || c.observesOperation(serverId)) &&
                  (job?.status == 'failed' ||
                      job?.status == 'partially_applied'))
                OutlinedButton(
                  onPressed: c.busy ? null : () => c.resume(serverId),
                  child: Text(l.runnerRetry),
                ),
            ],
          ),
        if (record['verifiedAt'] case final String at)
          ExpansionTile(
            key: PageStorageKey('vpn-snapshot-$serverId'),
            tilePadding: EdgeInsets.zero,
            title: Text(
              l.vpnSnapshot,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text('${DateTime.tryParse(at)?.toLocal() ?? at}'),
              ),
              if (job?.status == 'succeeded')
                Text(runnerStateLabel(l, job!.status)),
            ],
          ),
      ],
    );
  }
}
