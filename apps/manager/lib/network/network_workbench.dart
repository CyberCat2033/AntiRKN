import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import 'network_controller.dart';
import 'network_strings.dart';
import '../ssh/ssh_controller.dart';
import '../ssh/ssh_panel.dart';
import '../ssh/server_inventory_panel.dart';

class NetworkWorkbench extends StatelessWidget {
  const NetworkWorkbench({
    required this.controller,
    required this.motion,
    this.ssh,
    super.key,
  });
  final NetworkController controller;
  final MotionPreference motion;
  final SshController? ssh;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, ?ssh]),
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      final inventory = controller.inventory;
      return ListView(
        key: const PageStorageKey('network-workbench'),
        primary: false,
        padding: AppLayout.padding,
        children: [
          if (ssh != null) ...[
            SshPanel(controller: ssh!, motion: motion),
            const SizedBox(height: AppLayout.gap),
            if (ssh!.software case final software?) ...[
              ServerInventoryPanel(
                inventory: software,
                current: ssh!.stage == SshStage.connected,
                motion: motion,
              ),
              const SizedBox(height: AppLayout.gap),
            ],
          ],
          if (ssh == null || inventory != null)
            SectionCard(
              title: l.networkTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (ssh == null) Text(l.networkSampleNotice),
                  const SizedBox(height: AppLayout.gap),
                  if (ssh == null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FilledButton(
                        key: const ValueKey('load-network-sample'),
                        onPressed: controller.loading ? null : controller.load,
                        child: Text(
                          controller.loading
                              ? l.networkLoading
                              : inventory == null
                              ? l.networkLoadSample
                              : l.networkReloadSample,
                        ),
                      ),
                    ),
                  if (controller.failed) ...[
                    const SizedBox(height: AppLayout.smallGap),
                    Semantics(
                      liveRegion: true,
                      child: Text(l.networkLoadError),
                    ),
                  ],
                  if (inventory == null) ...[
                    const SizedBox(height: AppLayout.gap),
                    Text(l.networkNotLoaded),
                  ] else ...[
                    const SizedBox(height: AppLayout.gap),
                    Text(
                      inventory.source == NetworkSource.sample
                          ? l.networkSampleSource
                          : l.networkObservedSource,
                    ),
                    Text(
                      l.networkObservedAt(
                        DateFormat.yMd(
                          l.localeName,
                        ).add_Hms().format(inventory.observedAt.toLocal()),
                      ),
                    ),
                    Text(
                      l.networkSummary(
                        inventory.addresses.length,
                        inventory.routes.length,
                        inventory.rules.length,
                      ),
                    ),
                    if (inventory.sshPeer case final peer?)
                      Text(l.networkSshPeer(peer.canonical)),
                    const SizedBox(height: AppLayout.smallGap),
                    Text(l.networkNotVerified),
                  ],
                ],
              ),
            ),
          if (inventory != null) ...[
            const SizedBox(height: AppLayout.gap),
            SectionCard(
              title: l.networkAssignments,
              child: inventory.addresses.isEmpty
                  ? Text(l.networkEmpty)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(l.networkClassHint),
                        for (final addressClass in AddressClass.values) ...[
                          const SizedBox(height: AppLayout.gap),
                          Text(
                            addressClass == AddressClass.external
                                ? l.networkExternal
                                : l.networkInternal,
                            key: ValueKey('addresses-${addressClass.name}'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: AppLayout.smallGap),
                          if (!inventory.addresses.any(
                            (a) => a.addressClass == addressClass,
                          ))
                            Text(
                              addressClass == AddressClass.external
                                  ? l.networkExternalEmpty
                                  : l.networkInternalEmpty,
                            ),
                          for (final entry in inventory.addresses.where(
                            (a) => a.addressClass == addressClass,
                          ))
                            for (final assignment in entry.assignments)
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: AppLayout.gap,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      entry.address.canonical,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    Text(
                                      '${entry.address.family == IpFamily.ipv4 ? 'IPv4' : 'IPv6'} · ${assignment.interfaceName} · ${categoryLabel(l, entry.address.category)}',
                                    ),
                                    Text(
                                      '${l.networkPrefix(assignment.prefixLength)} · ${scopeLabel(l, assignment.scope)} · ${interfaceStateLabel(l, assignment.operState)}',
                                    ),
                                    Text(
                                      healthLabel(
                                        l,
                                        assignment.healthAt(controller.clock()),
                                      ),
                                    ),
                                    if (assignment.isTunnel)
                                      Text(l.networkIssueTunnel),
                                    if (assignment.flags.contains(
                                      AddressFlag.secondary,
                                    ))
                                      Text(l.networkSecondary),
                                    Text(
                                      l.networkLifetime(
                                        lifetimeLabel(
                                          l,
                                          assignment.validLifetimeSeconds,
                                        ),
                                        lifetimeLabel(
                                          l,
                                          assignment.preferredLifetimeSeconds,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                      ],
                    ),
            ),
          ],
        ],
      );
    },
  );
}
