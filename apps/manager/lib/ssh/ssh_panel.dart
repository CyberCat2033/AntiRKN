import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import 'ssh_controller.dart';
import 'ssh_harden_wizard.dart';

class SshPanel extends StatefulWidget {
  const SshPanel({
    required this.controller,
    this.motion = MotionPreference.system,
    this.showDelete = true,
    this.showConnectionActions = true,
    this.editorOnly = false,
    this.onCancel,
    super.key,
  });
  final SshController controller;
  final MotionPreference motion;
  final bool showDelete;
  final bool showConnectionActions;
  final bool editorOnly;
  final VoidCallback? onCancel;
  @override
  State<SshPanel> createState() => _SshPanelState();
}

class _SshPanelState extends State<SshPanel> {
  final _visibleSecrets = <String>{};

  Widget _field(
    TextEditingController controller,
    String label, {
    required bool enabled,
    bool secret = false,
    String? id,
    String? hint,
    TextInputType? type,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: AppLayout.gap),
    child: TextField(
      key: ValueKey(id ?? label),
      controller: controller,
      enabled: enabled,
      obscureText: secret && !_visibleSecrets.contains(id ?? label),
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      keyboardType: type,
      maxLength: secret ? 1024 : 253,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        counterText: '',
        suffixIcon: secret
            ? IconButton(
                key: ValueKey('show-${id ?? label}'),
                tooltip: _visibleSecrets.contains(id ?? label)
                    ? AppLocalizations.of(context).hidePassword
                    : AppLocalizations.of(context).showPassword,
                onPressed: () => setState(() {
                  if (!_visibleSecrets.add(id ?? label)) {
                    _visibleSecrets.remove(id ?? label);
                  }
                }),
                icon: Icon(
                  _visibleSecrets.contains(id ?? label)
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              )
            : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final expanded = widget.editorOnly || c.settingsExpanded;
      final l = AppLocalizations.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c.vaultBusy) const LinearProgressIndicator(),
          if (c.vaultError case final issue?)
            Semantics(liveRegion: true, child: Text(vaultIssueLabel(l, issue))),
          if (!c.initialised && !c.vaultBusy)
            OutlinedButton(onPressed: c.initialise, child: Text(l.vaultRetry)),
          if (c.unlocked) ...[
            SectionCard(
              title: expanded || !widget.showDelete
                  ? l.sshTitle
                  : c.displayName,
              trailing: expanded
                  ? null
                  : IconButton(
                      key: const ValueKey('ssh-edit'),
                      tooltip: l.sshEdit,
                      onPressed: c.editing ? c.editSettings : null,
                      icon: const Icon(Icons.edit_outlined),
                    ),
              child: AppAnimatedSize(
                motion: widget.motion,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (expanded) ...[
                      AppPageIntro(l.sshReadOnly),
                      AppSectionHeading(
                        title: l.uiConnectionSettings,
                        uppercase: true,
                      ),
                      _field(
                        c.serverName,
                        l.sshServerName,
                        enabled: c.editing,
                        id: 'ssh-name',
                        hint: c.host.text,
                      ),
                      _field(
                        c.host,
                        l.sshHost,
                        enabled: c.editing,
                        id: 'ssh-host',
                      ),
                      _field(
                        c.port,
                        l.sshPort,
                        enabled: c.editing,
                        id: 'ssh-port',
                        type: TextInputType.number,
                      ),
                      _field(
                        c.username,
                        l.sshUser,
                        enabled: c.editing,
                        id: 'ssh-user',
                      ),
                      if (c.showJumpPicker) ...[
                        AppSelectField<String>(
                          key: const ValueKey('ssh-jump'),
                          value: c.jumpServerId ?? '',
                          label: l.sshJump,
                          motion: widget.motion,
                          options: [
                            ('', l.sshDirect),
                            for (final server in c.jumpOptions)
                              (server.id, server.profile.displayName),
                            if (c.jumpServerId != null &&
                                !c.jumpOptions.any(
                                  (s) => s.id == c.jumpServerId,
                                ))
                              (c.jumpServerId!, l.sshJumpMissing),
                          ],
                          onChanged: c.editing
                              ? (id) => c.setJump(id == '' ? null : id)
                              : null,
                        ),
                        const SizedBox(height: 8),
                        Text(l.sshJumpHelp),
                        const SizedBox(height: AppLayout.gap),
                      ],
                      AppSectionHeading(
                        title: l.uiAuthentication,
                        uppercase: true,
                      ),
                      Wrap(
                        spacing: AppLayout.smallGap,
                        runSpacing: AppLayout.smallGap,
                        children: [
                          for (final method in SshAuthMethod.values)
                            if (method != SshAuthMethod.agent ||
                                c.agentAvailable ||
                                c.authMethod == method)
                              ChoiceChip(
                                key: ValueKey('ssh-auth-${method.name}'),
                                label: Text(switch (method) {
                                  SshAuthMethod.password => l.sshAuthPassword,
                                  SshAuthMethod.privateKey => l.sshAuthKey,
                                  SshAuthMethod.agent => l.sshAuthAgent,
                                }),
                                selected: c.authMethod == method,
                                onSelected: c.editing
                                    ? (_) => c.setAuth(method)
                                    : null,
                              ),
                        ],
                      ),
                      const SizedBox(height: AppLayout.gap),
                      if (c.authMethod == SshAuthMethod.password)
                        _field(
                          c.password,
                          l.sshPassword,
                          enabled: c.editing,
                          secret: true,
                          id: 'ssh-password',
                        ),
                      if (c.authMethod == SshAuthMethod.privateKey) ...[
                        Text(c.keyName ?? l.sshNoKey),
                        Text(l.sshKeyHelp),
                        if (c.picking) ...[
                          const LinearProgressIndicator(),
                          TextButton(
                            key: const ValueKey('ssh-pick-cancel'),
                            onPressed: c.cancelKeyImport,
                            child: Text(l.sshCancel),
                          ),
                        ],
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: OutlinedButton.icon(
                            key: const ValueKey('ssh-pick-key'),
                            onPressed: c.editing ? c.importKey : null,
                            icon: const Icon(Icons.file_open_outlined),
                            label: Text(l.sshPickKey),
                          ),
                        ),
                        const SizedBox(height: AppLayout.gap),
                        _field(
                          c.passphrase,
                          l.sshPassphrase,
                          enabled: c.editing,
                          secret: true,
                          id: 'ssh-passphrase',
                        ),
                      ],
                      if (c.authMethod == SshAuthMethod.agent)
                        Text(l.sshAgentHelp),
                      if (c.stage == SshStage.connected) Text(l.sshEditHelp),
                    ],
                    if (!expanded && widget.showConnectionActions)
                      Text(c.os ?? l.sshOsUnknown),
                    if (!expanded)
                      Text(
                        '${c.username.text} · ${c.port.text} · ${switch (c.authMethod) {
                          SshAuthMethod.password => l.sshAuthPassword,
                          SshAuthMethod.privateKey => l.sshAuthKey,
                          SshAuthMethod.agent => l.sshAuthAgent,
                        }}',
                      ),
                    if (expanded &&
                        c.stage != SshStage.connected &&
                        c.lastInfo != null)
                      Text(
                        l.networkObservedAt(
                          DateFormat.yMd(
                            l.localeName,
                          ).add_Hm().format(c.lastInfo!.observedAt.toLocal()),
                        ),
                      ),
                    if (c.jumpServerId != null)
                      Text(l.sshVia(c.jumpName ?? l.sshJumpMissing)),
                    if (c.error case final issue?)
                      Semantics(
                        liveRegion: true,
                        child: Text(sshIssueLabel(l, issue)),
                      ),
                    if (c.error == SshIssue.hostKeyChanged)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: OutlinedButton(
                          key: const ValueKey('ssh-replace-server'),
                          onPressed: c.editing ? c.replaceServer : null,
                          child: Text(l.sshReplaceServer),
                        ),
                      ),
                    if (expanded && c.saved) Text(l.sshSaved),
                    const SizedBox(height: AppLayout.gap),
                    if (c.busy && c.stage != SshStage.verifying)
                      const LinearProgressIndicator(),
                    Semantics(
                      liveRegion: true,
                      child: Text(switch (c.stage) {
                        SshStage.idle => l.sshIdle,
                        SshStage.connecting => l.sshConnecting,
                        SshStage.verifying => l.sshTrustTitle,
                        SshStage.reading => l.sshReading,
                        SshStage.checkingPrivileges => l.privilegesChecking,
                        SshStage.connected => l.sshConnected,
                      }),
                    ),
                    if (expanded && c.observation != null) ...[
                      Text(
                        '${c.observation!.os} · ${c.observation!.architecture}',
                      ),
                    ],
                    if (c.challenge case final key?) ...[
                      const SizedBox(height: AppLayout.gap),
                      if (c.replacingServer &&
                          c.verifyingProfile?.id == c.serverId) ...[
                        Text(l.sshReplaceServerHelp),
                        if (c.trustedKey case final previous?) ...[
                          Text(l.sshTrustedKey),
                          SelectableText(
                            '${previous.algorithm}\n${previous.fingerprint}',
                          ),
                        ],
                      ],
                      Text(l.sshTrustHelp),
                      Text(c.verifyingProfile?.displayName ?? c.displayName),
                      Text(
                        '${c.verifyingProfile?.host ?? c.host.text}:${c.verifyingProfile?.port ?? c.port.text}',
                      ),
                      SelectableText('${key.algorithm}\n${key.fingerprint}'),
                      Wrap(
                        spacing: AppLayout.smallGap,
                        children: [
                          FilledButton(
                            key: const ValueKey('ssh-trust-accept'),
                            onPressed: () => c.decide(true),
                            child: Text(l.sshTrustAccept),
                          ),
                          OutlinedButton(
                            onPressed: () => c.decide(false),
                            child: Text(l.sshTrustReject),
                          ),
                        ],
                      ),
                    ] else if (expanded && c.trustedKey != null) ...[
                      Text(l.sshTrustedKey),
                      SelectableText(
                        '${c.trustedKey!.algorithm}\n${c.trustedKey!.fingerprint}',
                      ),
                    ],
                    const SizedBox(height: AppLayout.gap),
                    Wrap(
                      spacing: AppLayout.smallGap,
                      runSpacing: AppLayout.smallGap,
                      children: [
                        if (c.stage == SshStage.connected && !expanded) ...[
                          if (widget.showConnectionActions)
                            TextButton(
                              onPressed: c.refresh,
                              child: Text(l.sshRefresh),
                            ),
                          if (widget.showConnectionActions)
                            OutlinedButton(
                              onPressed: c.disconnect,
                              child: Text(l.sshDisconnect),
                            ),
                        ] else if (c.busy && widget.showConnectionActions)
                          OutlinedButton(
                            key: const ValueKey('ssh-cancel'),
                            onPressed: c.disconnect,
                            child: Text(l.sshCancel),
                          )
                        else ...[
                          if (c.stage != SshStage.connected &&
                              widget.showConnectionActions)
                            FilledButton(
                              key: const ValueKey('ssh-connect'),
                              onPressed: c.editing
                                  ? () async {
                                      final adding = !c.hasSavedProfile;
                                      await c.connect();
                                      if (adding && c.hasSavedProfile) {
                                        AppHaptics.added();
                                      }
                                    }
                                  : null,
                              child: Text(
                                c.saved ? l.sshConnect : l.sshSaveAndConnect,
                              ),
                            ),
                          if (expanded)
                            OutlinedButton(
                              key: const ValueKey('ssh-save'),
                              onPressed: c.editing && !c.saved
                                  ? () async {
                                      final adding = !c.hasSavedProfile;
                                      if (await c.save() && adding) {
                                        AppHaptics.added();
                                      }
                                    }
                                  : null,
                              child: Text(l.sshSave),
                            ),
                          if (expanded && c.hasSavedProfile)
                            TextButton(
                              key: const ValueKey('ssh-edit-cancel'),
                              onPressed: c.editing
                                  ? () {
                                      c.cancelEditing();
                                      widget.onCancel?.call();
                                    }
                                  : null,
                              child: Text(l.sshCancel),
                            ),
                        ],
                        if (widget.showDelete &&
                            expanded &&
                            c.editing &&
                            c.hasSavedProfile &&
                            c.stage != SshStage.connected)
                          TextButton(
                            key: const ValueKey('ssh-delete'),
                            onPressed: () =>
                                confirmSshProfileDeletion(context, c),
                            child: Text(l.sshDelete),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (!expanded &&
                (c.showPrivilegePrompt ||
                    c.isRoot ||
                    c.profile?.hardenRecovery != null) &&
                (c.stage == SshStage.connected ||
                    c.stage == SshStage.checkingPrivileges ||
                    (c.stage == SshStage.reading && c.privileges != null))) ...[
              const SizedBox(height: AppLayout.gap),
              SectionCard(
                title: l.privilegesTitle,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        c.isRoot
                            ? l.privilegesRoot
                            : c.privileges == null
                            ? l.privilegesUnknown
                            : privilegeStatusLabel(l, c.privileges!.status),
                      ),
                    ),
                    if (c.isRoot || c.profile?.hardenRecovery != null) ...[
                      const SizedBox(height: AppLayout.gap),
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.shield_outlined),
                        label: Text(l.sshHardenBannerAction),
                        onPressed: () => showSshHardenWizard(context, c),
                      ),
                    ],
                    if (!c.isRoot) ...[
                      const SizedBox(height: AppLayout.gap),
                      _field(
                        c.sudoPassword,
                        l.privilegesSudoPassword,
                        enabled: c.canCheckPrivileges,
                        secret: true,
                        id: 'sudo-password',
                      ),
                      Text(
                        c.authMethod == SshAuthMethod.password
                            ? l.privilegesSshPasswordHint
                            : l.privilegesKeyPasswordHint,
                      ),
                    ],
                    const SizedBox(height: AppLayout.gap),
                    Text(l.privilegesScope),
                    const SizedBox(height: AppLayout.gap),
                    FilledButton.tonal(
                      key: const ValueKey('sudo-check'),
                      onPressed: c.canCheckPrivileges
                          ? c.checkPrivileges
                          : null,
                      child: Text(l.privilegesCheck),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      );
    },
  );
}

String vaultIssueLabel(AppLocalizations l, VaultIssue issue) => switch (issue) {
  VaultIssue.locked => l.vaultLocked,
  VaultIssue.unavailable => l.vaultUnavailable,
  VaultIssue.missingKey => l.vaultMissingKey,
  VaultIssue.incorrectPasswordOrDamaged => l.vaultDamaged,
  VaultIssue.corrupt => l.vaultCorrupt,
  VaultIssue.writeFailed => l.vaultWriteFailed,
  VaultIssue.busy => l.vaultBusy,
  VaultIssue.alreadyExists => l.vaultExists,
  VaultIssue.weakPassword => l.vaultWeakPassword,
};
String sshIssueLabel(AppLocalizations l, SshIssue issue) => switch (issue) {
  SshIssue.invalidSettings => l.sshInvalidSettings,
  SshIssue.invalidKey => l.sshInvalidKey,
  SshIssue.authentication => l.sshAuthenticationError,
  SshIssue.hostKeyChanged => l.sshHostChanged,
  SshIssue.hostKeyRejected => l.sshHostRejected,
  SshIssue.network => l.sshNetworkError,
  SshIssue.timeout => l.sshTimeout,
  SshIssue.cancelled => l.sshCancelled,
  SshIssue.commandFailed => l.sshCommandError,
  SshIssue.outputLimit => l.sshOutputLimit,
  SshIssue.invalidInventory => l.sshInvalidInventory,
  SshIssue.unsupportedOs => l.sshUnsupportedOs,
  SshIssue.disconnected => l.sshDisconnected,
  SshIssue.trustSaveFailed => l.sshTrustSaveError,
  SshIssue.agentUnavailable => l.sshAgentError,
  SshIssue.invalidJumpRoute => l.sshInvalidJump,
  SshIssue.jumpHostKeyChanged => l.sshJumpHostChanged,
  SshIssue.sudoPasswordRequired => l.privilegesRequired,
  SshIssue.sudoAuthenticationFailed => l.privilegesAuthentication,
  SshIssue.sudoDenied => l.privilegesDenied,
  SshIssue.sudoUnavailable => l.privilegesUnavailable,
  SshIssue.sudoTerminalRequired => l.privilegesTerminal,
  SshIssue.invalidSudoPassword => l.privilegesInvalidPassword,
};

String privilegeStatusLabel(AppLocalizations l, PrivilegeStatus status) =>
    switch (status) {
      PrivilegeStatus.root => l.privilegesRoot,
      PrivilegeStatus.sudoWithoutPassword => l.privilegesNoPassword,
      PrivilegeStatus.sudoWithPassword => l.privilegesPassword,
      PrivilegeStatus.passwordRequired => l.privilegesRequired,
      PrivilegeStatus.authenticationFailed => l.privilegesAuthentication,
      PrivilegeStatus.denied => l.privilegesDenied,
      PrivilegeStatus.unavailable => l.privilegesUnavailable,
      PrivilegeStatus.terminalRequired => l.privilegesTerminal,
      PrivilegeStatus.invalidPassword => l.privilegesInvalidPassword,
    };

Future<void> confirmSshProfileDeletion(
  BuildContext context,
  SshController c,
) async {
  final l = AppLocalizations.of(context);
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AppFormDialog(
      title: Text(l.uiDeleteServer),
      content: Text(l.sshDeleteHelp),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.sshCancel),
        ),
        TextButton(
          key: const ValueKey('ssh-delete-confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(l.uiDeleteServer),
        ),
      ],
    ),
  );
  if (accepted == true && c.editing) {
    await c.deleteProfile();
  }
}
