import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import 'ssh_controller.dart';

String serverBytes(int value) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var amount = value.toDouble(), unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit++;
  }
  return '${amount.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

class ServerAboutView extends StatelessWidget {
  const ServerAboutView({required this.controller, super.key});
  final SshController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, l = AppLocalizations.of(context);
      final inventory = c.network.inventory;
      final addresses = <String, IpFamily>{
        for (final address in inventory?.addresses ?? <ServerAddress>[])
          if (address.addressClass == AddressClass.external)
            address.address.canonical: address.address.family,
      };
      final traffic = c.trafficBytes;
      final facts = c.observation?.software?.facts;
      final free = int.tryParse(facts?[ServerFact.freeDiskKiB]?.value ?? '');
      final total = int.tryParse(facts?[ServerFact.totalDiskKiB]?.value ?? '');
      final at = c.observation?.network.observedAt;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  c.stage == SshStage.connected
                      ? l.uiServerAboutHelp
                      : l.inventoryStale,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              IconButton(
                tooltip: l.sshRefresh,
                onPressed:
                    c.stage == SshStage.connected && !c.busy && !c.runner.busy
                    ? () {
                        c.refresh();
                      }
                    : null,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (at != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                l.uiObservedAt(
                  DateFormat.yMd(l.localeName).add_Hm().format(at.toLocal()),
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          AppSettingsSection(
            title: l.uiPublicAddresses,
            child: Column(
              children: [
                if (addresses.isEmpty)
                  ListTile(title: Text(l.uiNoPublicAddresses)),
                for (final entry in addresses.entries)
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(entry.value == IpFamily.ipv4 ? 'v4' : 'v6'),
                    ),
                    title: SelectableText(entry.key),
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
                  if (c.trafficStorageFailed) Text(l.settingsSaveError),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
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
        ],
      );
    },
  );
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
