import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import 'vpn_controller.dart';
import 'vpn_plan_view.dart';
import 'vpn_strings.dart';

class UsersPage extends StatelessWidget {
  const UsersPage({
    required this.controller,
    required this.serverName,
    required this.exporter,
    required this.motion,
    super.key,
  });
  final VpnController controller;
  final String Function(String) serverName;
  final ProfileExporter exporter;
  final MotionPreference motion;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, l = AppLocalizations.of(context);
      return ListView(
        key: const PageStorageKey('vpn-users'),
        padding: AppLayout.padding,
        children: [
          SectionCard(
            title: l.vpnUsers,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.vpnUsersHelp),
                Wrap(
                  spacing: AppLayout.smallGap,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('vpn-user-add'),
                      onPressed: c.busy || !c.loaded
                          ? null
                          : () => _edit(context),
                      icon: const Icon(Icons.person_add_outlined),
                      label: Text(l.vpnAddUser),
                    ),
                    OutlinedButton(
                      onPressed: c.busy || c.workspace.serverIds.isEmpty
                          ? null
                          : c.prepare,
                      child: Text(l.vpnPrepare),
                    ),
                    TextButton(
                      onPressed: c.busy ? null : c.refreshProfiles,
                      child: Text(l.vpnRefreshProfiles),
                    ),
                    TextButton(
                      onPressed: c.busy ? null : c.load,
                      child: Text(l.sshRefresh),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppLayout.gap),
          VpnPlanView(controller: c, serverName: serverName),
          if (c.workspace.users.isEmpty) Text(l.vpnNoUsers),
          for (final u in c.workspace.users)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppLayout.smallGap),
              child: SectionCard(
                title: u.name,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${u.login} · ${u.enabled ? l.vpnEnabled : l.vpnDisabled}',
                    ),
                    Wrap(
                      spacing: AppLayout.smallGap,
                      children: [
                        TextButton(
                          onPressed: c.busy ? null : () => _edit(context, u),
                          child: Text(l.vpnEdit),
                        ),
                        OutlinedButton(
                          onPressed: c.busy ? null : () => _profile(context, u),
                          child: Text(l.vpnProfile),
                        ),
                      ],
                    ),
                    if (c.results[u.id]?.hasBlockingErrors == true)
                      Text(
                        vpnMessage(l, c.results[u.id]!.diagnostics.first.code),
                      ),
                  ],
                ),
              ),
            ),
          for (final id in c.workspace.serverIds)
            Padding(
              padding: const EdgeInsets.only(top: AppLayout.gap),
              child: SectionCard(
                title:
                    '${serverName(vpnServerId(id))}${isAwgTarget(id) ? ' · AWG' : ''}',
                child: VpnJobView(controller: c, serverId: id),
              ),
            ),
        ],
      );
    },
  );
  Future<void> _edit(BuildContext context, [VpnUser? user]) async {
    final result = await showDialog<VpnUser>(
      context: context,
      builder: (context) => _UserForm(user: user),
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
    await showDialog<void>(
      context: context,
      builder: (context) => _ProfileDialog(
        controller: controller,
        user: user,
        exporter: exporter,
      ),
      animationStyle: AnimationStyle(
        duration: AppMotion.duration(context, motion),
      ),
    );
  }
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

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({
    required this.controller,
    required this.user,
    required this.exporter,
  });
  final VpnController controller;
  final VpnUser user;
  final ProfileExporter exporter;
  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  bool revealed = false, saving = false;
  String? message;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller,
          l = AppLocalizations.of(context),
          result = c.results[widget.user.id];
      final usable =
          widget.user.enabled &&
          result?.yaml != null &&
          result?.hasBlockingErrors == false;
      return AlertDialog(
        title: Text('${l.vpnProfile} · ${widget.user.name}'),
        content: SizedBox(
          width: 700,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.vpnProfileValidation),
                if (!usable)
                  Text(
                    c.template().isEmpty
                        ? l.vpnEmptyTemplate
                        : l.vpnLastProfile,
                  ),
                if (result != null)
                  for (final d in result.diagnostics)
                    Text(
                      '${d.severity == DiagnosticSeverity.error ? l.profileError : l.profileWarning}: '
                      '${vpnMessage(l, d.code)}'
                      '${d.subject == null ? '' : ' (${d.subject})'}',
                    ),
                if (result != null)
                  for (final group in result.groups)
                    Text('${group.name}: ${group.members.join(', ')}'),
                if (usable) ...[
                  TextButton(
                    onPressed: () => setState(() => revealed = !revealed),
                    child: Text(l.vpnShowProfile),
                  ),
                  if (revealed) SelectableText(result!.yaml!),
                ],
                if (message != null) Text(message!),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.runnerNotNow),
          ),
          if (usable)
            TextButton(
              onPressed: saving
                  ? null
                  : () async {
                      try {
                        await c.checkProfileEffects();
                        await Clipboard.setData(
                          ClipboardData(text: result!.yaml!),
                        );
                      } on SyncMergeFailure {
                        if (mounted) {
                          setState(() => message = l.syncEffectsBlocked);
                        }
                      }
                    },
              child: Text(l.vpnCopyProfile),
            ),
          if (usable)
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setState(() => saving = true);
                      try {
                        await c.checkProfileEffects();
                        final saved = await widget.exporter.save(
                          '${widget.user.id}.yml',
                          result!.yaml!,
                        );
                        if (mounted && saved) {
                          setState(() => message = l.vpnProfileSaved);
                        }
                      } on SyncMergeFailure {
                        if (mounted) {
                          setState(() => message = l.syncEffectsBlocked);
                        }
                      } catch (_) {
                        if (mounted) setState(() => message = l.vpnFailed);
                      } finally {
                        if (mounted) setState(() => saving = false);
                      }
                    },
              child: Text(l.vpnSaveProfile),
            ),
        ],
      );
    },
  );
}
