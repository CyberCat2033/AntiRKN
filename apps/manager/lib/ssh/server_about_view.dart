import 'server_reboot_view.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../busy_reason.dart';
import '../l10n/app_localizations.dart';
import '../network/ip_diagnostics_controller.dart';
import '../network/server_ip_diagnostics.dart';
import '../vpn/vpn_controller.dart';
import 'ssh_controller.dart';
import 'client_egress_card.dart';
import '../app_strings.dart';
import 'server_service_mode_view.dart';

class ServerAboutView extends StatelessWidget {
  const ServerAboutView({
    required this.controller,
    this.diagnostics,
    this.vpn,
    this.clientEgress,
    this.motion = MotionPreference.system,
    super.key,
  });
  final SshController controller;
  final IpDiagnosticsController? diagnostics;
  final VpnController? vpn;
  final Widget? clientEgress;
  final MotionPreference motion;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, controller.runner, diagnostics]),
    builder: (context, _) {
      final c = controller, l = AppLocalizations.of(context);
      final inventory = c.observation?.network;
      final publicAddresses = inventory == null
          ? c.lastInfo?.publicAddresses
          : inventory.addresses
                .where(
                  (address) => address.addressClass == AddressClass.external,
                )
                .map((address) => address.address);
      final addresses = <String, IpFamily>{
        for (final address in publicAddresses ?? <IpAddress>[])
          address.canonical: address.family,
      };
      final server = c.profile == null
          ? null
          : ServerIpDiagnostics(
              c.profile!,
              addresses.keys.map(IpAddress.parse),
            );
      final running =
          diagnostics?.busy == true && diagnostics?.serverKey == server?.key;
      final canDiagnose =
          server != null &&
          server.addresses.isNotEmpty &&
          server.addresses.length <= 64;
      final traffic = c.trafficBytes;
      final facts = c.software?.facts;
      final free = int.tryParse(facts?[ServerFact.freeDiskKiB]?.value ?? '');
      final total = int.tryParse(facts?[ServerFact.totalDiskKiB]?.value ?? '');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          clientEgress ??
              ClientEgressCard(controller: c.runner, vpn: vpn, motion: motion),
          if (vpn case final vpn?)
            ServerServiceModeSection(
              vpn: vpn,
              serverId: c.serverId,
              serverName: c.displayName,
              relay: c.runner.relayInbounds.isNotEmpty,
              motion: motion,
            ),
          AppSettingsSection(
            title: l.uiPublicAddresses,
            // Diagnostics check these addresses and show the result under
            // each of them, so the action sits on this section.
            action: diagnostics == null
                ? null
                : TextButton.icon(
                    key: const ValueKey('server-ip-diagnostics'),
                    onPressed: running
                        ? diagnostics!.stop
                        : !canDiagnose || diagnostics!.busy
                        ? null
                        : () => showServerIpDiagnostics(
                            context,
                            diagnostics!,
                            server,
                          ),
                    icon: Icon(running ? Icons.stop : Icons.network_check),
                    label: Text(
                      running
                          ? '${l.diagStop} · ${diagnostics!.current?.completed ?? 0}/${diagnostics!.current?.targets.length ?? 0}'
                          : l.diagTitle,
                    ),
                  ),
            child: Column(
              children: [
                if (addresses.isEmpty)
                  ListTile(
                    title: Text(
                      publicAddresses == null
                          ? l.uiServerDataNotCached
                          : l.uiNoPublicAddresses,
                    ),
                  ),
                for (final entry in addresses.entries)
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(entry.value == IpFamily.ipv4 ? 'v4' : 'v6'),
                    ),
                    title: SelectableText(entry.key),
                    subtitle: server == null
                        ? null
                        : _result(context, server, entry.key),
                    trailing: IconButton(
                      tooltip: l.uiCopyAddress,
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: entry.key));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l.uiAddressCopied)),
                          );
                        }
                      },
                    ),
                  ),
                // Shown where the diagnostics action is, not at the page top.
                if (diagnostics != null && !canDiagnose && addresses.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(l.diagNoIpv4),
                  ),
              ],
            ),
          ),
          AppSettingsSection(
            title: l.uiTraffic,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 28,
                    runSpacing: 16,
                    children: [
                      _Metric(
                        icon: Icons.south_west,
                        title: l.uiTrafficReceived,
                        value: traffic == null ? '—' : serverBytes(traffic.$1),
                      ),
                      _Metric(
                        icon: Icons.north_east,
                        title: l.uiTrafficSent,
                        value: traffic == null ? '—' : serverBytes(traffic.$2),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    c.trafficResetAt == null
                        ? l.uiTrafficSinceBoot
                        : l.uiTrafficSince(
                            DateFormat.yMd(
                              l.localeName,
                            ).add_Hm().format(c.trafficResetAt!.toLocal()),
                          ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (c.trafficStorageFailed)
                    AppNotice(
                      message: l.settingsSaveError,
                      error: true,
                      margin: const EdgeInsets.only(top: 8),
                    ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AppDisabledReason(
                      reason: busyReason(
                        l,
                        runner: c.runner,
                        ssh: c,
                        needsConnection: true,
                      ),
                      child: TextButton.icon(
                        key: const ValueKey('server-traffic-reset'),
                        onPressed:
                            c.stage == SshStage.connected &&
                                !c.busy &&
                                !c.runner.busy &&
                                !c.resettingTraffic &&
                                c.canResetTraffic &&
                                c.trafficSample != null
                            ? () async {
                                await c.resetTraffic();
                              }
                            : null,
                        icon: const Icon(Icons.restart_alt),
                        label: Text(l.uiTrafficReset),
                      ),
                    ),
                  ),
                  Text(
                    l.uiTrafficResetHelp,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          AppSettingsSection(
            title: l.uiDiskSpace,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Metric(
                    icon: Icons.storage_outlined,
                    title: l.uiDiskFree,
                    value: free == null ? '—' : serverBytes(free * 1024),
                  ),
                  if (free != null && total != null && total > 0) ...[
                    const SizedBox(height: 18),
                    LinearProgressIndicator(
                      value: (1 - free / total).clamp(0, 1),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    const SizedBox(height: 8),
                    Text(l.uiDiskTotal(serverBytes(total * 1024))),
                  ],
                ],
              ),
            ),
          ),
          // The heaviest action of the tab goes last.
          ServerRebootView(controller: c),
        ],
      );
    },
  );

  Widget? _result(BuildContext context, ServerIpDiagnostics server, String ip) {
    final result = diagnostics?.resultFor(server, ip);
    if (result == null) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        diagnosticAddressLabel(AppLocalizations.of(context), result),
        key: ValueKey('diagnostic-result-$ip'),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.title, required this.value});
  final IconData icon;
  final String title, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(title)],
      ),
      const SizedBox(height: 8),
      Text(value, style: Theme.of(context).textTheme.headlineSmall),
    ],
  );
}
