import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'ssh_controller.dart';

class SshPanel extends StatefulWidget {
  const SshPanel({
    required this.controller,
    this.motion = MotionPreference.system,
    super.key,
  });
  final SshController controller;
  final MotionPreference motion;
  @override
  State<SshPanel> createState() => _SshPanelState();
}

class _SshPanelState extends State<SshPanel> {
  VaultMode _creationMode = VaultMode.system;

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
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      keyboardType: type,
      maxLength: secret ? 1024 : 253,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        counterText: '',
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final l = AppLocalizations.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionCard(
            title: l.vaultTitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (c.vaultBusy) Text(l.vaultWorking),
                if (c.vaultError case final issue?)
                  Semantics(
                    liveRegion: true,
                    child: Text(vaultIssueLabel(l, issue)),
                  ),
                if (!c.initialised)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton(
                      onPressed: c.vaultBusy ? null : c.initialise,
                      child: Text(l.vaultRetry),
                    ),
                  )
                else if (!c.unlocked) ...[
                  Text(c.mode == null ? l.vaultIntro : l.vaultLocked),
                  const SizedBox(height: AppLayout.gap),
                  if (c.mode == null)
                    Wrap(
                      spacing: AppLayout.smallGap,
                      runSpacing: AppLayout.smallGap,
                      children: [
                        for (final mode in VaultMode.values)
                          ChoiceChip(
                            key: ValueKey('vault-mode-${mode.name}'),
                            label: Text(
                              mode == VaultMode.system
                                  ? l.vaultSystem
                                  : l.vaultMaster,
                            ),
                            selected: _creationMode == mode,
                            onSelected: c.vaultBusy
                                ? null
                                : (_) => setState(() => _creationMode = mode),
                          ),
                      ],
                    ),
                  if ((c.mode ?? _creationMode) ==
                      VaultMode.masterPassword) ...[
                    const SizedBox(height: AppLayout.gap),
                    _field(
                      c.masterPassword,
                      l.vaultPassword,
                      enabled: !c.vaultBusy,
                      secret: true,
                      id: 'vault-password',
                    ),
                    if (c.mode == null) ...[
                      _field(
                        c.masterConfirmation,
                        l.vaultConfirmation,
                        enabled: !c.vaultBusy,
                        secret: true,
                        id: 'vault-confirmation',
                      ),
                      Text(l.vaultMasterHelp),
                    ],
                  ],
                  const SizedBox(height: AppLayout.gap),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton(
                      key: const ValueKey('vault-open'),
                      onPressed: c.vaultBusy
                          ? null
                          : () => c.open(
                              createMode: c.mode == null ? _creationMode : null,
                            ),
                      child: Text(
                        c.mode == null ? l.vaultCreate : l.vaultUnlock,
                      ),
                    ),
                  ),
                ] else ...[
                  Text(l.vaultUnlocked),
                  Text(l.vaultAutoLock),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      key: const ValueKey('vault-lock'),
                      onPressed: c.lock,
                      icon: const Icon(Icons.lock_outline),
                      label: Text(l.vaultLock),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (c.unlocked) ...[
            const SizedBox(height: AppLayout.gap),
            SectionCard(
              title: c.settingsExpanded ? l.sshTitle : c.displayName,
              trailing: c.settingsExpanded
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
                    if (c.settingsExpanded) ...[
                      Text(l.sshReadOnly),
                      const SizedBox(height: AppLayout.gap),
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
                    if (!c.settingsExpanded)
                      Text(c.observation?.os ?? l.sshOsUnknown),
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
                    if (c.settingsExpanded && c.saved) Text(l.sshSaved),
                    const SizedBox(height: AppLayout.gap),
                    Semantics(
                      liveRegion: true,
                      child: Text(switch (c.stage) {
                        SshStage.idle => l.sshIdle,
                        SshStage.connecting => l.sshConnecting,
                        SshStage.verifying => l.sshTrustTitle,
                        SshStage.reading => l.sshReading,
                        SshStage.connected => l.sshConnected,
                      }),
                    ),
                    if (c.settingsExpanded && c.observation != null) ...[
                      Text(
                        '${c.observation!.os} · ${c.observation!.architecture}',
                      ),
                    ],
                    if (c.challenge case final key?) ...[
                      const SizedBox(height: AppLayout.gap),
                      if (c.replacingServer) ...[
                        Text(l.sshReplaceServerHelp),
                        if (c.trustedKey case final previous?) ...[
                          Text(l.sshTrustedKey),
                          SelectableText(
                            '${previous.algorithm}\n${previous.fingerprint}',
                          ),
                        ],
                      ],
                      Text(l.sshTrustHelp),
                      Text('${c.host.text}:${c.port.text}'),
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
                    ] else if (c.settingsExpanded && c.trustedKey != null) ...[
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
                        if (c.stage == SshStage.connected &&
                            !c.settingsExpanded) ...[
                          FilledButton(
                            onPressed: c.refresh,
                            child: Text(l.sshRefresh),
                          ),
                          OutlinedButton(
                            onPressed: c.disconnect,
                            child: Text(l.sshDisconnect),
                          ),
                        ] else if (c.busy)
                          OutlinedButton(
                            key: const ValueKey('ssh-cancel'),
                            onPressed: c.disconnect,
                            child: Text(l.sshCancel),
                          )
                        else ...[
                          if (c.stage != SshStage.connected)
                            FilledButton(
                              key: const ValueKey('ssh-connect'),
                              onPressed: c.editing ? c.connect : null,
                              child: Text(l.sshConnect),
                            ),
                          if (c.settingsExpanded)
                            OutlinedButton(
                              key: const ValueKey('ssh-save'),
                              onPressed: c.editing ? c.save : null,
                              child: Text(l.sshSave),
                            ),
                          if (c.settingsExpanded && c.hasSavedProfile)
                            TextButton(
                              key: const ValueKey('ssh-edit-cancel'),
                              onPressed: c.editing ? c.cancelEditing : null,
                              child: Text(l.sshCancel),
                            ),
                        ],
                        if (c.settingsExpanded &&
                            c.editing &&
                            c.hasSavedProfile &&
                            c.stage != SshStage.connected)
                          TextButton(
                            onPressed: () async {
                              final accepted = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text(l.sshDelete),
                                  content: Text(l.sshDeleteHelp),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: Text(l.sshCancel),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: Text(l.sshDelete),
                                    ),
                                  ],
                                ),
                              );
                              if (accepted == true && c.editing) {
                                await c.deleteProfile();
                              }
                            },
                            child: Text(l.sshDelete),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
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
};
