import 'connection_check_view.dart';
import 'external_connection_check.dart';
import 'dart:async';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../runner/runner_controller.dart';
import 'vpn_strings.dart';
import 'vpn_controller.dart';
import 'adopt_resource.dart';

class AwgExistingPanel extends StatefulWidget {
  const AwgExistingPanel({
    required this.runner,
    required this.motion,
    required this.controller,
    required this.serverId,
    required this.serverHost,
    super.key,
  });
  final RunnerController runner;
  final VpnController controller;
  final String serverId, serverHost;
  final MotionPreference motion;
  @override
  State<AwgExistingPanel> createState() => _AwgExistingPanelState();
}

class _AwgExistingPanelState extends State<AwgExistingPanel> {
  String? queried;
  @override
  void initState() {
    super.initState();
    widget.runner.addListener(changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => changed());
  }

  @override
  void didUpdateWidget(AwgExistingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runner != widget.runner) {
      oldWidget.runner.removeListener(changed);
      widget.runner.addListener(changed);
      queried = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => changed());
    }
  }

  @override
  void dispose() {
    widget.runner.removeListener(changed);
    super.dispose();
  }

  void changed() {
    final r = widget.runner;
    final key =
        '${r.identity()}|${r.selected?.terminal == true ? r.selected?.id : ''}';
    if (mounted &&
        r.installed &&
        r.connected &&
        !r.busy &&
        (r.awgDiscovery == null || queried != key)) {
      queried = key;
      unawaited(r.awgRequest('awg_discover'));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.runner, widget.controller]),
    builder: (context, _) {
      final r = widget.runner, l = AppLocalizations.of(context);
      final external = (r.awgDiscovery?['resources'] as List? ?? [])
          .whereType<Map>()
          .where(
            (item) => !hasAdoptedSource(
              widget.controller.workspace.awgInterfaces
                  .where((r) => r.serverId == widget.serverId)
                  .map((r) => r.spec),
              item['id'] as String,
            ),
          );
      if (external.isEmpty) {
        return const SizedBox.shrink();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeading(
            title: l.awgObserved,
            count: external.length,
          ),
          ConnectionCheckAll(
            controller: widget.controller,
            targets: const [],
            readOthers: () async {
              final keys = <({String target, String resource})>[];
              for (final item in external) {
                if (!context.mounted) break;
                final key = await prepareExternalConnection(
                  context,
                  controller: widget.controller,
                  runner: r,
                  serverId: widget.serverId,
                  protocol: 'awg',
                  source: item['id'] as String,
                  host: widget.serverHost,
                );
                keys.add(
                  key ??
                      externalConnectionTarget(
                        widget.serverId,
                        'awg',
                        item['id'] as String,
                        null,
                      ),
                );
              }
              return keys;
            },
          ),
          for (final item in external)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ResourceTile(
                storageId: 'awg-existing-${item['id']}',
                footer: ExternalConnectionCheck(
                  controller: widget.controller,
                  runner: r,
                  serverId: widget.serverId,
                  protocol: 'awg',
                  source: item['id'] as String,
                  host: widget.serverHost,
                ),
                title: '${item['name']}',
                subtitle: l.uiPeerCount(item['peers'] as int),
                badge: item['active'] == true ? l.vpnEnabled : l.vpnDisabled,
                detailsLabel: l.componentsDetails,
                details: const [],
                actions: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: ValueKey('adopt-awg-${item['id']}'),
                      tooltip: l.vpnAdopt,
                      icon: const Icon(Icons.people_outline),
                      onPressed:
                          r.busy ||
                              widget.controller.busy ||
                              widget.controller.hasRunning
                          ? null
                          : () => adoptExistingResource(
                              context,
                              controller: widget.controller,
                              runner: r,
                              serverId: widget.serverId,
                              protocol: 'awg',
                              sourceId: item['id'] as String,
                              host: widget.serverHost,
                              motion: widget.motion,
                            ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: l.vpnEdit,
                      onPressed: r.busy || r.actionPending
                          ? null
                          : () async {
                              if (!await r.ensureReady()) return;
                              final snapshot = await r.awgRequest(
                                'awg_external_read',
                                id: item['id'] as String,
                              );
                              if (snapshot == null || !context.mounted) return;
                              await showDialog<void>(
                                context: context,
                                builder: (_) => _EditExistingAwg(
                                  runner: r,
                                  snapshot: snapshot,
                                ),
                                animationStyle: AnimationStyle(
                                  duration: AppMotion.duration(
                                    context,
                                    widget.motion,
                                  ),
                                ),
                              );
                            },
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: r.busy || r.actionPending
                  ? null
                  : () => r.requestAction(() async {
                      await r.awgRequest('awg_discover');
                    }),
              child: Text(l.awgRefresh),
            ),
          ),
        ],
      );
    },
  );
}

class _EditExistingAwg extends StatefulWidget {
  const _EditExistingAwg({required this.runner, required this.snapshot});
  final RunnerController runner;
  final Map<String, dynamic> snapshot;
  @override
  State<_EditExistingAwg> createState() => _EditExistingAwgState();
}

class _EditExistingAwgState extends State<_EditExistingAwg> {
  late final values = Map<String, String>.from(
    widget.snapshot['values'] as Map,
  );
  late final fields = {
    for (final e in values.entries) e.key: TextEditingController(text: e.value),
  };
  Map<String, dynamic>? preview;
  Map<String, Object?>? payload;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), snapshot = widget.snapshot;
    return AppFormDialog(
      title: Text('${l.vpnEdit} · ${snapshot['name']}'),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.awgPeersPreserved),
              Text(
                '${snapshot['source']} · ${snapshot['path']} · ${snapshot['peers']} peers',
              ),
              if (snapshot['portLocked'] == true) Text(l.awgDockerPortHelp),
              for (final e in fields.entries)
                Padding(
                  padding: const EdgeInsets.only(top: AppLayout.gap),
                  child: TextField(
                    key: ValueKey('awg-existing-${e.key}'),
                    controller: e.value,
                    enabled:
                        !busy &&
                        !(e.key == 'ListenPort' &&
                            snapshot['portLocked'] == true),
                    autocorrect: false,
                    enableSuggestions: false,
                    minLines: 1,
                    maxLines: e.key.startsWith('I') ? null : 1,
                    decoration: InputDecoration(labelText: e.key),
                    onChanged: (_) => setState(() {
                      preview = null;
                      payload = null;
                    }),
                  ),
                ),
              if (busy) const LinearProgressIndicator(),
              if (error != null) Text(vpnMessage(l, error!)),
              if (preview != null) ...[
                const Divider(),
                Text(l.vpnPlan, style: Theme.of(context).textTheme.titleMedium),
                for (final e in (payload!['changes'] as Map).entries)
                  Text('${e.key}: ${values[e.key]} → ${e.value}'),
                Text(l.awgPeersPreserved),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(l.runnerNotNow),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    if (!await widget.runner.ensureReady()) {
                      if (mounted) setState(() => error = 'vpn_connection');
                      return;
                    }
                    if (preview == null) {
                      final changes = {
                        for (final e in fields.entries)
                          if (e.value.text.trim() != values[e.key])
                            e.key: e.value.text.trim(),
                      };
                      if (changes.isEmpty) {
                        if (mounted) Navigator.pop(context);
                        return;
                      }
                      final p = <String, Object?>{
                        'resourceId': snapshot['id'],
                        'observedHash': snapshot['fingerprint'],
                        'changes': changes,
                      };
                      final response = await widget.runner.awgRequest(
                        'awg_external_plan',
                        payload: p,
                      );
                      if (!mounted) return;
                      setState(() {
                        preview = response;
                        payload = p;
                        if (response == null) {
                          error = widget.runner.responseCode ?? 'awg_failed';
                        }
                      });
                    }
                    if (preview != null) {
                      final success = await widget.runner.applyExternalAwg(
                        payload!,
                        preview!['fingerprint'] as String,
                      );
                      if (!mounted) return;
                      if (success) {
                        Navigator.pop(context);
                      } else {
                        setState(
                          () => error =
                              widget.runner.responseCode ?? 'awg_failed',
                        );
                      }
                    }
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(l.vpnSave),
        ),
      ],
    );
  }
}
