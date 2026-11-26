import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../busy_reason.dart';
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

  /// The hardening wizard shows its own progress; bars behind its scrim
  /// would be a second indicator (UI-42).
  bool _wizardOpen = false;

  Widget _field(
    TextEditingController controller,
    String label, {
    required bool enabled,
    bool secret = false,
    String? id,
    String? hint,
    TextInputType? type,
  }) => TextField(
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
  );

  /// One gap between the rows of a form group, none after the last.
  static Widget _group(List<Widget> rows) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) const SizedBox(height: AppLayout.gap),
        rows[i],
      ],
    ],
  );

  /// Supporting text under a control: the secondary role (UI-56).
  static Widget _supporting(BuildContext context, String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  static String _authLabel(AppLocalizations l, SshAuthMethod method) =>
      switch (method) {
        SshAuthMethod.password => l.sshAuthPassword,
        SshAuthMethod.privateKey => l.sshAuthKey,
        SshAuthMethod.agent => l.sshAuthAgent,
      };

  static String _stageLabel(AppLocalizations l, SshStage stage) =>
      switch (stage) {
        SshStage.idle => l.sshIdle,
        SshStage.connecting => l.sshConnecting,
        SshStage.verifying => l.sshTrustTitle,
        SshStage.reading => l.sshReading,
        SshStage.checkingPrivileges => l.privilegesChecking,
        SshStage.connected => l.sshConnected,
      };

  bool _showsProgress(SshController c) =>
      c.busy && c.stage != SshStage.verifying && !c.vaultSaving && !_wizardOpen;

  /// The trusted key and the time of the last reading: technical values,
  /// shown on demand (AGENTS.md, section 4).
  void _showDetails(BuildContext context, SshController c) {
    final l = AppLocalizations.of(context);
    final key = c.trustedKey;
    final observed = c.stage != SshStage.connected ? c.lastInfo : null;
    showAppDetails(
      context,
      title: l.uiTechnicalDetails,
      children: [
        if (key != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.sshTrustedKey,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              SelectableText('${key.algorithm}\n${key.fingerprint}'),
            ],
          ),
        if (observed != null)
          Text(
            l.networkObservedAt(
              DateFormat.yMd(
                l.localeName,
              ).add_Hm().format(observed.observedAt.toLocal()),
            ),
          ),
      ],
    );
  }

  /// Connection state, OS and the trusted key behind one details action.
  Widget _status(BuildContext context, SshController c) {
    final l = AppLocalizations.of(context);
    final observation = c.observation;
    final details = c.trustedKey != null || c.lastInfo != null;
    return Semantics(
      container: true,
      liveRegion: true,
      child: SummaryCard(
        key: const ValueKey('ssh-status'),
        leading: AppIconTile(
          icon: switch (c.stage) {
            SshStage.connected => Icons.link,
            SshStage.idle => Icons.link_off,
            _ => Icons.sync,
          },
        ),
        title: _stageLabel(l, c.stage),
        subtitle: Text(
          c.stage == SshStage.connected && observation != null
              ? '${observation.os} · ${observation.architecture}'
              : c.os ?? l.sshOsUnknown,
        ),
        action: details
            ? TextButton.icon(
                key: const ValueKey('ssh-details'),
                onPressed: () => _showDetails(context, c),
                icon: const Icon(Icons.info_outline),
                label: Text(l.uiTechnicalDetails),
              )
            : null,
      ),
    );
  }

  Widget? _issue(SshController c, AppLocalizations l) => switch (c.error) {
    final issue? => AppNotice(
      message: sshIssueLabel(l, issue),
      error: true,
      action: issue == SshIssue.hostKeyChanged
          ? OutlinedButton(
              key: const ValueKey('ssh-replace-server'),
              onPressed: c.editing ? c.replaceServer : null,
              child: Text(l.sshReplaceServer),
            )
          : null,
    ),
    null => null,
  };

  /// Confirmation of a new key for a server whose trusted key changed: the
  /// only key decision left to the person (a first key is trusted on first
  /// use).
  Widget _challenge(BuildContext context, SshController c, TrustedHostKey key) {
    final l = AppLocalizations.of(context);
    final heading = Theme.of(context).textTheme.titleSmall;
    final previous = c.replacingServer && c.verifyingProfile?.id == c.serverId
        ? c.trustedKey
        : null;
    return SectionCard(
      title: l.sshTrustTitle,
      subheader: true,
      child: _group([
        if (c.replacingServer && c.verifyingProfile?.id == c.serverId)
          Text(l.sshReplaceServerHelp),
        if (previous != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.sshTrustedKey, style: heading),
              const SizedBox(height: 4),
              SelectableText('${previous.algorithm}\n${previous.fingerprint}'),
            ],
          ),
        Text(l.sshTrustHelp),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.verifyingProfile?.displayName ?? c.displayName,
              style: heading,
            ),
            Text(
              '${c.verifyingProfile?.host ?? c.host.text}:${c.verifyingProfile?.port ?? c.port.text}',
            ),
            const SizedBox(height: 4),
            SelectableText('${key.algorithm}\n${key.fingerprint}'),
          ],
        ),
        Wrap(
          spacing: AppLayout.smallGap,
          runSpacing: AppLayout.smallGap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(
              key: const ValueKey('ssh-trust-accept'),
              onPressed: () => c.decide(true),
              child: Text(l.sshTrustAccept),
            ),
            TextButton(
              key: const ValueKey('ssh-trust-reject'),
              onPressed: () => c.decide(false),
              child: Text(l.sshTrustReject),
            ),
          ],
        ),
      ]),
    );
  }

  Widget _connectButton(SshController c, AppLocalizations l) => FilledButton(
    key: const ValueKey('ssh-connect'),
    onPressed: c.editing
        ? () async {
            final adding = !c.hasSavedProfile;
            await c.connect();
            if (adding && c.hasSavedProfile) AppHaptics.added();
          }
        : null,
    child: Text(c.saved ? l.sshConnect : l.sshSaveAndConnect),
  );

  /// One filled action per state; the others are text buttons (M3).
  Widget _editorActions(BuildContext context, SshController c) {
    final l = AppLocalizations.of(context);
    final connectable =
        c.stage != SshStage.connected && widget.showConnectionActions;
    Future<void> save() async {
      final adding = !c.hasSavedProfile;
      if (await c.save() && adding) AppHaptics.added();
    }

    final saveEnabled = c.editing && !c.saved;
    return Wrap(
      spacing: AppLayout.smallGap,
      runSpacing: AppLayout.smallGap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (c.busy && widget.showConnectionActions)
          OutlinedButton(
            key: const ValueKey('ssh-cancel'),
            onPressed: c.disconnect,
            child: Text(l.sshCancel),
          )
        else ...[
          if (connectable) _connectButton(c, l),
          // Next to Connect, saving alone is secondary and only offered for
          // a changed draft; without it, Save is the form's main action.
          if (!connectable || !c.saved)
            AppDisabledReason(
              reason: busyReason(l, runner: c.runner, ssh: c),
              child: connectable
                  ? TextButton(
                      key: const ValueKey('ssh-save'),
                      onPressed: saveEnabled ? save : null,
                      child: Text(l.sshSave),
                    )
                  : FilledButton(
                      key: const ValueKey('ssh-save'),
                      onPressed: saveEnabled ? save : null,
                      child: Text(l.sshSave),
                    ),
            ),
          if (c.hasSavedProfile)
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
            c.editing &&
            c.hasSavedProfile &&
            c.stage != SshStage.connected)
          TextButton(
            key: const ValueKey('ssh-delete'),
            onPressed: () => confirmSshProfileDeletion(context, c),
            child: Text(l.sshDelete),
          ),
      ],
    );
  }

  /// The connection form: state, then the connection and sign-in groups.
  List<Widget> _editor(BuildContext context, SshController c) {
    final l = AppLocalizations.of(context);
    return [
      if (c.hasSavedProfile || c.stage != SshStage.idle) ...[
        _status(context, c),
        if (_showsProgress(c)) const LinearProgressIndicator(),
        const SizedBox(height: AppLayout.gap),
      ],
      ?_issue(c, l),
      if (c.challenge case final key?) _challenge(context, c, key),
      SectionCard(
        title: l.uiConnectionSettings,
        subheader: true,
        child: _group([
          _field(
            c.serverName,
            l.sshServerName,
            enabled: c.editing,
            id: 'ssh-name',
            hint: c.host.text,
          ),
          _field(c.host, l.sshHost, enabled: c.editing, id: 'ssh-host'),
          _field(
            c.port,
            l.sshPort,
            enabled: c.editing,
            id: 'ssh-port',
            type: TextInputType.number,
          ),
          _field(c.username, l.sshUser, enabled: c.editing, id: 'ssh-user'),
          if (c.showJumpPicker)
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
                    !c.jumpOptions.any((s) => s.id == c.jumpServerId))
                  (c.jumpServerId!, l.sshJumpMissing),
              ],
              onChanged: c.editing
                  ? (id) => c.setJump(id == '' ? null : id)
                  : null,
            ),
        ]),
      ),
      SectionCard(
        title: l.uiAuthentication,
        subheader: true,
        child: _group([
          AppChoice<SshAuthMethod>(
            keyPrefix: 'ssh-auth',
            value: c.authMethod,
            options: [
              for (final method in SshAuthMethod.values)
                if (method != SshAuthMethod.agent ||
                    c.agentAvailable ||
                    c.authMethod == method)
                  (method, _authLabel(l, method)),
            ],
            onChanged: c.editing ? c.setAuth : null,
          ),
          if (c.authMethod == SshAuthMethod.password)
            _field(
              c.password,
              l.sshPassword,
              enabled: c.editing,
              secret: true,
              id: 'ssh-password',
            ),
          if (c.authMethod == SshAuthMethod.privateKey) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  c.keyName ?? l.sshNoKey,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                _supporting(context, l.sshKeyHelp),
                if (c.picking) ...[
                  const SizedBox(height: AppLayout.smallGap),
                  const LinearProgressIndicator(),
                ],
                const SizedBox(height: AppLayout.smallGap),
                Wrap(
                  spacing: AppLayout.smallGap,
                  runSpacing: AppLayout.smallGap,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('ssh-pick-key'),
                      onPressed: c.editing ? c.importKey : null,
                      icon: const Icon(Icons.file_open_outlined),
                      label: Text(l.sshPickKey),
                    ),
                    if (c.picking)
                      TextButton(
                        key: const ValueKey('ssh-pick-cancel'),
                        onPressed: c.cancelKeyImport,
                        child: Text(l.sshCancel),
                      ),
                  ],
                ),
              ],
            ),
            _field(
              c.passphrase,
              l.sshPassphrase,
              enabled: c.editing,
              secret: true,
              id: 'ssh-passphrase',
            ),
          ],
          if (c.authMethod == SshAuthMethod.agent)
            _supporting(context, l.sshAgentHelp),
        ]),
      ),
      // Said only when it applies: this save closes the open session.
      if (c.saveDisconnects) AppNotice(message: l.sshEditHelp),
      _editorActions(context, c),
    ];
  }

  /// The saved connection as one card (the network workbench only).
  Widget _summary(BuildContext context, SshController c) {
    final l = AppLocalizations.of(context);
    return SectionCard(
      title: c.displayName,
      trailing: IconButton(
        key: const ValueKey('ssh-edit'),
        tooltip: l.sshEdit,
        onPressed: c.editing ? c.editSettings : null,
        icon: const Icon(Icons.edit_outlined),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showConnectionActions) Text(c.os ?? l.sshOsUnknown),
          Text(
            '${c.username.text} · ${c.port.text} · ${_authLabel(l, c.authMethod)}',
          ),
          if (c.jumpServerId != null)
            Text(l.sshVia(c.jumpName ?? l.sshJumpMissing)),
          if (_issue(c, l) case final issue?) ...[
            const SizedBox(height: AppLayout.smallGap),
            issue,
          ],
          const SizedBox(height: AppLayout.gap),
          if (_showsProgress(c)) const LinearProgressIndicator(),
          Semantics(liveRegion: true, child: Text(_stageLabel(l, c.stage))),
          const SizedBox(height: AppLayout.gap),
          if (widget.showConnectionActions)
            Wrap(
              spacing: AppLayout.smallGap,
              runSpacing: AppLayout.smallGap,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (c.stage == SshStage.connected) ...[
                  TextButton(onPressed: c.refresh, child: Text(l.sshRefresh)),
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
                else
                  _connectButton(c, l),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // The form shows text-derived state (hint, summary, trusted key); the
    // controller itself only reports changes of the saved flag.
    listenable: Listenable.merge([
      widget.controller,
      ...widget.controller.fields,
    ]),
    builder: (context, _) {
      final c = widget.controller;
      final expanded = widget.editorOnly || c.settingsExpanded;
      final l = AppLocalizations.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // One bar: a vault write the person waits for, else the
          // connection (UI-42).
          if (c.vaultSaving && !_wizardOpen) const LinearProgressIndicator(),
          if (c.vaultError case final issue?)
            AppNotice(message: vaultIssueLabel(l, issue), error: true),
          if (!c.initialised && !c.vaultBusy)
            OutlinedButton(onPressed: c.initialise, child: Text(l.vaultRetry)),
          if (c.unlocked) ...[
            AppAnimatedSize(
              motion: widget.motion,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: expanded
                    ? _editor(context, c)
                    : [_summary(context, c)],
              ),
            ),
            if ((c.showPrivilegePrompt ||
                    c.isRoot ||
                    c.profile?.hardenRecovery != null) &&
                (c.stage == SshStage.connected ||
                    c.stage == SshStage.checkingPrivileges ||
                    (c.stage == SshStage.reading && c.privileges != null))) ...[
              const SizedBox(height: AppLayout.gap),
              SectionCard(
                title: l.privilegesTitle,
                subheader: expanded,
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
                        onPressed: () async {
                          setState(() => _wizardOpen = true);
                          try {
                            await showSshHardenWizard(context, c);
                          } finally {
                            if (mounted) setState(() => _wizardOpen = false);
                          }
                        },
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
                      const SizedBox(height: AppLayout.smallGap),
                      _supporting(
                        context,
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
  final accepted = await confirmAppDanger(
    context,
    title: l.uiDeleteServer,
    message: l.sshDeleteHelp,
    confirmLabel: l.uiDeleteServer,
    cancelLabel: l.sshCancel,
    confirmKey: const ValueKey('ssh-delete-confirm'),
  );
  if (accepted && c.editing) {
    await c.deleteProfile();
  }
}
