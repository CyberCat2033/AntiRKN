import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../runner/component_installation_view.dart' show vpnComponentName;

class ServerInventoryPanel extends StatelessWidget {
  const ServerInventoryPanel({
    required this.inventory,
    required this.current,
    this.motion = MotionPreference.system,
    super.key,
  });
  final ServerSoftwareInventory inventory;
  final bool current;
  final MotionPreference motion;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final duration = AppMotion.duration(context, motion);
    final animation = AnimationStyle(
      duration: duration,
      reverseDuration: duration,
    );
    return SectionCard(
      title: l.inventoryTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.networkObservedAt(
              DateFormat.yMd(
                l.localeName,
              ).add_Hms().format(inventory.observedAt.toLocal()),
            ),
          ),
          if (!current) Text(l.inventoryStale),
          for (final component in inventory.components)
            AppExpansionTile(
              expansionAnimationStyle: animation,
              key: PageStorageKey('component-${component.component.name}'),
              tilePadding: EdgeInsets.zero,
              title: Text(vpnComponentName(component.component)),
              subtitle: Text(switch (component.presence) {
                ComponentPresence.detected => l.inventoryDetected,
                ComponentPresence.absent => l.inventoryAbsent,
                ComponentPresence.unknown => l.inventoryUnknown,
              }),
              children: [
                if (component.issues.isNotEmpty)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      l.inventoryPartialList(
                        component.issues
                            .map((s) => inventoryStatusLabel(l, s))
                            .join(', '),
                      ),
                    ),
                  ),
                for (final installation in component.installations)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${switch (installation.source) {
                            InstallationSource.binary => l.inventoryBinary,
                            InstallationSource.systemd => 'systemd',
                            InstallationSource.docker => 'Docker',
                            InstallationSource.kernel => l.inventoryKernelModule,
                          }} · ${installation.identity}',
                        ),
                        if (current &&
                            (installation.source ==
                                    InstallationSource.systemd ||
                                installation.source ==
                                    InstallationSource.docker))
                          Text(switch (installation.state) {
                            ServiceState.running => l.inventoryRunning,
                            ServiceState.stopped => l.inventoryStopped,
                            ServiceState.failed => l.inventoryServiceFailed,
                            ServiceState.unknown => l.inventoryStateUnknown,
                          }),
                        if (installation.version != null ||
                            (installation.source !=
                                    InstallationSource.systemd &&
                                installation.source !=
                                    InstallationSource.docker))
                          Text(
                            installation.version?.value != null
                                ? l.inventoryVersion(
                                    installation.version!.value!,
                                  )
                                : installation.version == null
                                ? l.inventoryVersionUnknown
                                : l.inventoryVersionUnknownReason(
                                    inventoryStatusLabel(
                                      l,
                                      installation.version!.status,
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          const SizedBox(height: AppLayout.smallGap),
          for (final entry in inventory.facts.entries)
            Text(
              '${factLabel(l, entry.key)}: ${factValue(l, entry.key, entry.value)}',
            ),
          const SizedBox(height: AppLayout.smallGap),
          Text(l.inventoryPrivilegesHint),
          AppExpansionTile(
            expansionAnimationStyle: animation,
            key: const PageStorageKey('inventory-ports'),
            tilePadding: EdgeInsets.zero,
            title: Text(l.inventoryPorts),
            children: [
              Text(l.inventoryPortsHint),
              for (final group in inventory.sockets)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: AppLayout.smallGap),
                    Text(
                      '${group.protocol.name.toUpperCase()} · ${group.family == IpFamily.ipv4 ? 'IPv4' : 'IPv6'}',
                    ),
                    if (group.result.value == null)
                      Text(inventoryStatusLabel(l, group.result.status))
                    else if (group.result.value!.isEmpty)
                      Text(l.inventoryNoPorts)
                    else
                      for (final socket in group.result.value!)
                        Text(
                          '${socket.family == IpFamily.ipv6 ? '[${socket.address}]' : socket.address}:${socket.port}',
                        ),
                  ],
                ),
            ],
          ),
          Text(l.inventoryScope),
        ],
      ),
    );
  }
}

String inventoryStatusLabel(AppLocalizations l, InventoryStatus s) =>
    switch (s) {
      InventoryStatus.ok => l.inventoryOk,
      InventoryStatus.unavailable => l.inventoryUnavailable,
      InventoryStatus.denied => l.inventoryDenied,
      InventoryStatus.failed => l.inventoryFailed,
      InventoryStatus.timeout => l.inventoryTimeout,
      InventoryStatus.invalid => l.inventoryInvalid,
      InventoryStatus.outputLimit => l.inventoryOutputLimit,
    };
String factLabel(AppLocalizations l, ServerFact f) => switch (f) {
  ServerFact.kernel => l.inventoryKernel,
  ServerFact.init => l.inventoryInit,
  ServerFact.cpuCount => l.inventoryCpu,
  ServerFact.memoryKiB => l.inventoryMemory,
  ServerFact.availableMemoryKiB => l.inventoryAvailableMemory,
  ServerFact.freeDiskKiB => l.inventoryDisk,
  ServerFact.totalDiskKiB => l.uiDiskCapacity,
  ServerFact.networkTraffic => l.uiTraffic,
  ServerFact.uid => l.inventoryUid,
  ServerFact.tools => l.inventoryTools,
};
String factValue(
  AppLocalizations l,
  ServerFact f,
  InventoryValue<String> observation,
) {
  final value = observation.value;
  if (value == null) return inventoryStatusLabel(l, observation.status);
  if (f == ServerFact.tools) {
    return value.isEmpty ? l.inventoryToolsEmpty : value;
  }
  if (const {
    ServerFact.memoryKiB,
    ServerFact.availableMemoryKiB,
    ServerFact.freeDiskKiB,
  }.contains(f)) {
    // The value comes from the server: never trust it to be a number.
    final kib = int.tryParse(value.trim());
    if (kib == null) return l.inventoryInvalid;
    return l.inventoryMiB(
      NumberFormat.decimalPattern(l.localeName).format(kib / 1024),
    );
  }
  return value;
}
