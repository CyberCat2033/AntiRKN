import 'connection_check_view.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../busy_reason.dart';
import '../l10n/app_localizations.dart';
import '../network/network_controller.dart';
import '../network/server_address_field.dart';
import 'vpn_controller.dart';
import 'missing_on_server_notice.dart';
import 'adopt_resource.dart';
import 'vpn_plan_view.dart';
import 'awg_existing_panel.dart';
import '../runner/runner_controller.dart';

class AwgPanel extends StatelessWidget {
  const AwgPanel({
    required this.controller,
    required this.serverId,
    required this.network,
    required this.motion,
    this.runner,
    this.serverHost = '',
    super.key,
  });
  final VpnController controller;
  final String serverId;
  final NetworkController network;
  final MotionPreference motion;

  /// Reads the interfaces AntiRKN does not manage, for the one "check all"
  /// and refresh of the section (UI-49).
  final RunnerController? runner;
  final String serverHost;

  Future<void> edit(BuildContext context, [AwgInterface? current]) async {
    if (!await controller.ensureConnected(awgTarget(serverId)) ||
        !context.mounted) {
      return;
    }
    if (current?.spec.containsKey('adoption') == true) {
      final spec = await editAdoptedResource(context, current!.spec);
      if (spec == null) return;
      await controller.saveAwg(AwgInterface(serverId: serverId, spec: spec));
      if (controller.error == null) {
        await controller.prepareAndApply(serverIds: {awgTarget(serverId)});
      }
      return;
    }
    final spec = current?.spec ?? await controller.awgDefaults(serverId);
    if (spec == null || !context.mounted) return;
    final result = await showDialog<AwgInterface>(
      context: context,
      builder: (_) => AwgForm(
        serverId: serverId,
        spec: spec,
        network: network,
        motion: motion,
        existing: current != null,
      ),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, motion),
      ),
    );
    if (result == null) return;
    await controller.saveAwg(result);
    if (controller.error == null) {
      if (result.deleted && current != null && !current.deleted) {
        AppHaptics.deleted();
      } else if (current == null && !result.deleted) {
        AppHaptics.added();
      }
    }
    if (controller.error == null) {
      await controller.prepareAndApply(serverIds: {awgTarget(serverId)});
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, ?runner]),
    builder: (context, _) {
      final l = AppLocalizations.of(context), c = controller, r = runner;
      final target = awgTarget(serverId);
      final external = r == null
          ? const <Map>[]
          : awgExternalResources(r, c, serverId);
      final interfaces = c.workspace.awgInterfaces.where(
        (r) => r.serverId == serverId && !r.deleted,
      );
      final observed = (c.workspace.servers[target]?['observed'] as List? ?? [])
          .whereType<Map>();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppPageIntro(l.uiAwgIntro),
          AppDisabledReason(
            reason: busyReason(l, vpn: c),
            child: FilledButton.icon(
              key: const ValueKey('awg-add'),
              onPressed: !c.canMutate ? null : () => edit(context),
              icon: const Icon(Icons.add),
              label: Text(l.awgAdd),
            ),
          ),
          ConnectionCheckAll(
            controller: c,
            targets: [
              for (final r in interfaces) (target: target, resource: r.id),
            ],
            readOthers: r == null || external.isEmpty
                ? null
                : () => readAwgExternal(
                    context,
                    controller: c,
                    runner: r,
                    serverId: serverId,
                    host: serverHost,
                    external: external,
                  ),
          ),
          const SizedBox(height: 20),
          MissingOnServerNotice(controller: c, target: target),
          AppSectionHeading(
            title: l.uiInterfaces,
            count: interfaces.length,
            action: IconButton(
              tooltip: l.awgRefresh,
              onPressed:
                  !c.canMutate || r != null && (r.busy || r.actionPending)
                  ? null
                  : () async {
                      await c.refreshServer(target);
                      await r?.requestAction(() async {
                        await r.awgRequest('awg_discover');
                      });
                    },
              icon: const Icon(Icons.refresh),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (interfaces.isEmpty)
                AppEmptyState(title: l.awgEmpty, icon: Icons.shield_outlined),
              for (final r in interfaces)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
                  child: ResourceTile(
                    storageId: 'awg-${r.id}',
                    footer: ConnectionCheckView(
                      controller: c,
                      target: (target: target, resource: r.id),
                      onEdit: () => edit(context, r),
                    ),
                    title: r.name,
                    subtitle: '${r.spec['pool']}',
                    badge: r.enabled ? l.vpnEnabled : l.vpnDisabled,
                    note: r.spec.containsKey('adoption')
                        ? c.adoptionConfirmed(target, r.id)
                              ? l.vpnClientAccess
                              : l.vpnAdopting
                        : observed.any(
                            (s) => s['id'] == r.id && s['confirmed'] != true,
                          )
                        ? l.vpnConflict
                        : null,
                    actions: IconButton(
                      tooltip: busyReason(l, vpn: c) ?? l.vpnEdit,
                      onPressed: !c.canMutate ? null : () => edit(context, r),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ),
                ),
              VpnJobView(showSnapshot: false, controller: c, serverId: target),
            ],
          ),
        ],
      );
    },
  );
}

class AwgForm extends StatefulWidget {
  const AwgForm({
    required this.serverId,
    required this.spec,
    required this.network,
    required this.motion,
    this.existing = false,
    super.key,
  });
  final String serverId;
  final Map<String, Object?> spec;
  final NetworkController network;
  final MotionPreference motion;

  /// Deletion is offered only for an interface that already exists.
  final bool existing;
  @override
  State<AwgForm> createState() => _AwgFormState();
}

class _AwgFormState extends State<AwgForm> {
  late final spec = Map<String, Object?>.from(widget.spec);
  late final options = Map<String, Object?>.from(spec['options'] as Map);
  late final fields = {
    for (final k in [
      'name',
      'endpoint',
      'port',
      'externalPort',
      'pool',
      'pool6',
      'mtu',
      'keepalive',
    ])
      k: TextEditingController(text: '${spec[k]}'),
    for (final e in options.entries)
      if (e.value is! bool) e.key: TextEditingController(text: '${e.value}'),
  };
  bool invalid = false;
  late bool automaticPort = spec['port'] == spec['externalPort'];
  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  Widget field(String key, String label, {bool number = false}) => Padding(
    padding: const EdgeInsets.only(bottom: AppLayout.gap),
    child: TextField(
      key: ValueKey('awg-$key'),
      controller: fields[key],
      keyboardType: number ? TextInputType.number : TextInputType.text,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: label),
      onChanged: (value) {
        if (key == 'port' && automaticPort) {
          fields['externalPort']!.text = value;
        }
        if (key == 'externalPort') {
          automaticPort = value == fields['port']!.text;
        }
        if (key == 'endpoint') setState(() {});
      },
    ),
  );
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AppFormDialog(
      title: Text('AmneziaWG 3.1'),
      content: SizedBox(
        width: 650,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field('name', l.vpnNodeName),
              ServerAddressField(
                label: l.awgEndpoint,
                fieldKey: const ValueKey('awg-endpoint'),
                network: widget.network,
                controller: fields['endpoint']!,
                motion: widget.motion,
                role: AddressRole.endpoint,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppLayout.gap),
              field('port', l.awgPort, number: true),
              Text(l.awgEndpointHelp),
              AppExpansionTile(
                key: const ValueKey<String>('awg-advanced'),
                title: Text(l.awgAdvanced),
                children: [
                  field('externalPort', l.awgExternalPort, number: true),
                  field('pool', l.awgPool),
                  field('pool6', l.awgPool6),
                  field('mtu', 'MTU', number: true),
                  field('keepalive', 'PersistentKeepalive', number: true),
                  Text(l.awgDefaultsHelp),
                  for (final e in awgOptionRules.entries)
                    if ((e.value as Map)['type'] == 'boolean')
                      SwitchListTile(
                        title: Text('${e.value['config']}'),
                        value: options[e.key] as bool,
                        onChanged: (v) =>
                            setState(() => options[e.key as String] = v),
                      )
                    else if (e.key == 'i1')
                      SwitchListTile(
                        title: Text(l.awgCps),
                        value: fields['i1']!.text.isNotEmpty,
                        onChanged: (v) => setState(
                          () => fields['i1']!.text = v
                              ? e.value['default'] as String
                              : '',
                        ),
                      )
                    else
                      field(
                        e.key as String,
                        '${e.value['config']}',
                        number: e.value['type'] == 'integer',
                      ),
                ],
              ),
              SwitchListTile(
                title: Text(l.vpnEnabled),
                value: spec['enabled'] as bool,
                onChanged: (v) => setState(() => spec['enabled'] = v),
              ),
              Text(l.connectionAfterSave),
              if (invalid)
                AppNotice(
                  message: l.vpnInvalid,
                  error: true,
                  margin: const EdgeInsets.only(top: 12),
                ),
            ],
          ),
        ),
      ),
      actions: [
        // Deleting is its own confirmed action, not a form field (UI-54).
        if (widget.existing)
          AppDangerButton.text(
            key: const ValueKey('awg-delete'),
            onPressed: () async {
              final confirmed = await confirmAppDanger(
                context,
                title: l.awgDelete,
                message: l.awgDeleteHelp,
                confirmLabel: l.vpnDelete,
                cancelLabel: l.sshCancel,
                confirmKey: const ValueKey('awg-delete-confirm'),
              );
              if (!confirmed || !context.mounted) return;
              Navigator.pop(
                context,
                AwgInterface(
                  serverId: widget.serverId,
                  spec: {...widget.spec, 'deleted': true, 'enabled': false},
                ),
              );
            },
            child: Text(l.vpnDelete),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.sshCancel),
        ),
        FilledButton(
          key: const ValueKey('awg-save'),
          onPressed: () {
            try {
              for (final k in ['name', 'endpoint', 'pool', 'pool6']) {
                spec[k] = fields[k]!.text.trim();
              }
              for (final k in ['port', 'externalPort', 'mtu', 'keepalive']) {
                spec[k] = int.parse(fields[k]!.text.trim());
              }
              for (final e in awgOptionRules.entries) {
                if (e.value['type'] == 'boolean') continue;
                options[e.key as String] = e.value['type'] == 'integer'
                    ? int.parse(fields[e.key]!.text.trim())
                    : fields[e.key]!.text.trim();
              }
              spec['options'] = options;
              Navigator.pop(
                context,
                AwgInterface(serverId: widget.serverId, spec: spec),
              );
            } on FormatException {
              setState(() => invalid = true);
            }
          },
          child: Text(l.vpnSave),
        ),
      ],
    );
  }
}
