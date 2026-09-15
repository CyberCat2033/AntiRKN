import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../publication/publication_controller.dart';
import '../publication/publication_panel.dart';
import 'profile_share_sheet.dart';
import 'vpn_controller.dart';
import 'vpn_plan_view.dart';
import 'vpn_strings.dart';

class UsersPage extends StatelessWidget {
  const UsersPage({
    required this.controller,
    required this.serverName,
    required this.exporter,
    required this.motion,
    this.publications,
    this.showAddAction = true,
    super.key,
  });
  final VpnController controller;
  final PublicationController? publications;
  final String Function(String) serverName;
  final ProfileExporter exporter;
  final MotionPreference motion;
  final bool showAddAction;

  static Future<void> edit(
    BuildContext context,
    VpnController controller,
    MotionPreference motion, [
    VpnUser? user,
  ]) async {
    final result = await showDialog<VpnUser>(
      context: context,
      builder: (_) => _UserForm(user: user),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, motion),
      ),
    );
    if (result == null) return;
    await controller.saveUser(result);
    if (controller.error == null && controller.workspace.serverIds.isNotEmpty) {
      await controller.prepare();
    }
  }

  Future<void> _profile(BuildContext context, VpnUser user) async {
    await controller.refreshProfiles();
    if (!context.mounted) return;
    final content = ProfileShareSheet(
      controller: controller,
      user: user,
      exporter: exporter,
      publications: publications,
    );
    if (MediaQuery.sizeOf(context).width < AppLayout.compact) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        sheetAnimationStyle: AnimationStyle(
          duration: AppMotion.duration(context, motion),
        ),
        builder: (_) => content,
      );
    } else {
      await showDialog<void>(
        context: context,
        animationStyle: AnimationStyle(
          duration: AppMotion.duration(context, motion),
        ),
        builder: (_) => Dialog(child: content),
      );
    }
  }

  bool _needsAttention(String id) {
    final c = controller,
        record = c.workspace.servers[id],
        job = c.currentJob(id);
    return record != null &&
        (record['error'] != null ||
            record['pending'] != null ||
            c.needsRestoreReview(id) ||
            c.observesOperation(id) ||
            job != null &&
                (!job.terminal ||
                    [
                      'failed',
                      'partially_applied',
                      'needs_attention',
                    ].contains(job.status)) ||
            record['authorizedPayload'] != null &&
                record['authorizedPayload'] != record['appliedPayload']);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, l = AppLocalizations.of(context);
      return ListView(
        key: const PageStorageKey('vpn-users'),
        padding: AppLayout.screenPadding(context),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PopupMenuButton<String>(
                tooltip: l.uiActions,
                onSelected: (action) {
                  if (action == 'prepare') {
                    c.prepare();
                  } else {
                    c.load();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'prepare',
                    enabled: !c.busy && c.workspace.serverIds.isNotEmpty,
                    child: Text(l.vpnPrepare),
                  ),
                  PopupMenuItem(
                    value: 'reload',
                    enabled: !c.busy,
                    child: Text(l.sshRefresh),
                  ),
                ],
              ),
              if (showAddAction)
                IconButton(
                  key: const ValueKey('vpn-user-add'),
                  tooltip: l.vpnAddUser,
                  onPressed: c.busy || !c.loaded
                      ? null
                      : () => edit(context, c, motion),
                  icon: const Icon(Icons.add),
                ),
            ],
          ),
          VpnPlanView(controller: c, serverName: serverName),
          if (c.workspace.users.isEmpty) Text(l.vpnNoUsers),
          for (final user in c.workspace.users)
            Padding(
              padding: const EdgeInsets.only(bottom: AppLayout.smallGap),
              child: Card.filled(
                child: ListTile(
                  title: Text(user.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${user.login} · ${user.enabled ? l.vpnEnabled : l.vpnDisabled}',
                      ),
                      if (publications != null)
                        UserPublicationView(
                          controller: publications!,
                          userId: user.id,
                        ),
                      if (c.results[user.id]?.hasBlockingErrors == true)
                        Text(
                          vpnMessage(
                            l,
                            c.results[user.id]!.diagnostics.first.code,
                          ),
                        ),
                    ],
                  ),
                  onTap: c.busy ? null : () => edit(context, c, motion, user),
                  trailing: IconButton(
                    tooltip: l.vpnProfile,
                    onPressed: c.busy ? null : () => _profile(context, user),
                    icon: const Icon(Icons.ios_share_outlined),
                  ),
                ),
              ),
            ),
          for (final id in c.workspace.serverIds.where(_needsAttention))
            ExpansionTile(
              key: PageStorageKey('vpn-operation-$id'),
              leading: const Icon(Icons.pending_actions),
              title: Text(serverName(vpnServerId(id))),
              subtitle: Text(
                c.workspace.servers[id]?['error'] != null
                    ? vpnMessage(l, c.workspace.servers[id]!['error'] as String)
                    : l.uiOperationPending,
              ),
              children: [VpnJobView(controller: c, serverId: id)],
            ),
        ],
      );
    },
  );
}

class _UserForm extends StatefulWidget {
  const _UserForm({this.user});
  final VpnUser? user;
  @override
  State<_UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<_UserForm> {
  late final login = TextEditingController(text: widget.user?.login ?? '');
  late final name = TextEditingController(text: widget.user?.name ?? '');
  late bool enabled = widget.user?.enabled ?? true;
  late bool automaticName =
      widget.user == null || widget.user!.name == widget.user!.login;
  String? error;
  @override
  void dispose() {
    login.dispose();
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.user == null ? l.vpnAddUser : l.vpnEdit),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('vpn-user-login'),
              controller: login,
              onChanged: (value) {
                if (automaticName) name.text = value.trim();
              },
              autocorrect: false,
              decoration: InputDecoration(labelText: l.vpnLogin),
            ),
            const SizedBox(height: AppLayout.gap),
            TextField(
              key: const ValueKey('vpn-user-name'),
              controller: name,
              onChanged: (value) => automaticName =
                  value.trim().isEmpty || value.trim() == login.text.trim(),
              decoration: InputDecoration(labelText: l.vpnName),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.vpnEnabled),
              value: enabled,
              onChanged: (v) => setState(() => enabled = v),
            ),
            if (error != null) Text(l.vpnInvalid),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.runnerNotNow),
        ),
        FilledButton(
          key: const ValueKey('vpn-user-save'),
          onPressed: () {
            try {
              final user = VpnUser(
                id: widget.user?.id ?? newVpnId(),
                login: login.text.trim(),
                name: name.text.trim().isEmpty
                    ? login.text.trim()
                    : name.text.trim(),
                enabled: enabled,
              );
              Navigator.pop(context, user);
            } catch (_) {
              setState(() => error = 'invalid');
            }
          },
          child: Text(l.vpnSave),
        ),
      ],
    );
  }
}
