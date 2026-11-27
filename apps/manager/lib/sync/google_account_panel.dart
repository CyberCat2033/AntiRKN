import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import 'auto_sync_controller.dart';

class GoogleAccountPanel extends StatefulWidget {
  const GoogleAccountPanel({
    required this.service,
    this.sync,
    this.showTitle = true,
    this.accountDetails = false,
    this.beforeAccountChange,
    this.afterAccountChange,
    super.key,
  });
  final GoogleAccountService service;
  final bool showTitle, accountDetails;
  final AutoSyncController? sync;
  final Future<void> Function()? beforeAccountChange;
  final void Function(bool signedIn)? afterAccountChange;
  @override
  State<GoogleAccountPanel> createState() => _GoogleAccountPanelState();
}

class _GoogleAccountPanelState extends State<GoogleAccountPanel> {
  GoogleDriveAccount? _account;
  GoogleAccountIssue? _error;
  bool _busy = true;
  bool _signingIn = false;
  @override
  void initState() {
    super.initState();
    widget.sync?.addListener(_syncChanged);
    _load();
  }

  Future<void> _load() async {
    try {
      if (widget.sync case final sync?) {
        await sync.ready;
        _account = sync.account;
        _error = sync.accountError;
      } else {
        _account = await widget.service.restore();
      }
    } on GoogleAccountFailure catch (e) {
      _error = e.issue;
    } catch (_) {
      _error = GoogleAccountIssue.storage;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _act(bool signIn) async {
    if (_busy) return;
    var signedIn = false;
    setState(() {
      _busy = true;
      _signingIn = signIn;
      _error = null;
    });
    try {
      await widget.beforeAccountChange?.call();
      await widget.sync?.suspendAccount();
      if (signIn) {
        final account = await widget.service.signIn();
        if (account != null) {
          _account = account;
          signedIn = true;
        }
      } else {
        await widget.service.signOut();
        _account = null;
      }
    } on GoogleAccountFailure catch (e) {
      _error = e.issue;
    } catch (_) {
      _error = GoogleAccountIssue.unavailable;
    } finally {
      await widget.sync?.accountChanged(_account);
      widget.afterAccountChange?.call(signedIn);
      if (mounted) {
        setState(() {
          _busy = false;
          _signingIn = false;
        });
      }
    }
  }

  void _syncChanged() {
    if (mounted) {
      setState(() {
        if (!_busy && widget.sync != null) {
          _account = widget.sync!.account;
          _error = widget.sync!.accountError;
        }
      });
    }
  }

  @override
  void dispose() {
    if (widget.service case final CancelableGoogleSignIn service
        when _signingIn) {
      service.cancelSignIn();
    }
    widget.sync?.removeListener(_syncChanged);
    super.dispose();
  }

  static String _accountName(GoogleDriveAccount account) =>
      account.displayName.isNotEmpty ? account.displayName : account.email;

  /// Desktop sign-in continues in the browser; it can be cancelled here.
  List<Widget> _desktopWaiting(AppLocalizations l) => [
    AppNotice(message: l.googleDesktopWaiting),
    TextButton(
      key: const ValueKey('google-cancel-sign-in'),
      onPressed: () =>
          (widget.service as CancelableGoogleSignIn).cancelSignIn(),
      child: Text(l.googleCancelSignIn),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final desktop = widget.service is CancelableGoogleSignIn;
    final account = _account;
    final error = switch (_error) {
      GoogleAccountIssue.configuration =>
        desktop
            ? l.googleDesktopConfigurationError
            : l.googleConfigurationError,
      GoogleAccountIssue.denied => l.googleDenied,
      GoogleAccountIssue.network => l.googleNetworkError,
      GoogleAccountIssue.storage => l.googleStorageError,
      GoogleAccountIssue.reauthorize => l.googleReauthorize,
      GoogleAccountIssue.busy => l.googleWorking,
      GoogleAccountIssue.unavailable =>
        desktop ? l.googleDesktopUnavailable : l.googleUnavailable,
      null => null,
    };
    final sync = widget.sync;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (error != null)
          AppNotice(
            key: const ValueKey('google-account-error'),
            message: error,
            error: true,
          ),
        if (widget.accountDetails) ...[
          ListTile(
            leading: const AppIconTile(icon: Icons.account_circle_outlined),
            title: Text(account?.displayName ?? l.uiGoogleDrive),
            subtitle: account == null
                ? Text(l.googleAccountHelp)
                : SelectableText(
                    account.email,
                    key: const ValueKey('google-account-email'),
                  ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('google-sign-in'),
            onPressed: _busy ? null : () => _act(true),
            icon: const Icon(Icons.account_circle_outlined),
            label: Text(
              account == null ? l.googleSignIn : l.googleSwitchAccount,
            ),
          ),
          if (_signingIn && desktop) ..._desktopWaiting(l),
          if (account != null)
            TextButton(
              key: const ValueKey('google-sign-out'),
              onPressed: _busy ? null : () => _act(false),
              child: Text(l.googleSignOut),
            ),
        ] else if (account == null)
          // Signed out: the row opens the sign-in sheet.
          ListTile(
            key: const ValueKey('google-drive-sign-in'),
            leading: const Icon(Icons.cloud_outlined),
            title: Text(l.uiGoogleDrive),
            subtitle: Text(
              account?.displayName.isNotEmpty == true
                  ? account!.displayName
                  : account?.email ?? l.googleSignIn,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy
                ? null
                : () async {
                    await showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AppFormDialog(
                        title: Text(l.uiGoogleDrive),
                        content: GoogleAccountPanel(
                          service: widget.service,
                          sync: sync,
                          showTitle: false,
                          accountDetails: true,
                          beforeAccountChange: widget.beforeAccountChange,
                          afterAccountChange: widget.afterAccountChange,
                        ),
                        // Every dialog can be closed by a button (UI-65).
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: Text(l.networkClose),
                          ),
                        ],
                      ),
                    );
                    if (mounted) await _load();
                  },
          )
        else ...[
          // One row names the account; switching and signing out are its
          // actions (Sync A).
          ListTile(
            key: const ValueKey('google-account'),
            leading: AppAvatar(
              name: _accountName(account),
              imageUrl: account.photoUrl,
            ),
            title: Text(_accountName(account)),
            subtitle: account.displayName.isEmpty ? null : Text(account.email),
            trailing: AppMoreMenu(
              tooltip: l.uiAccountActions,
              buttonKey: const ValueKey('google-account-menu'),
              children: [
                AppMenuItem(
                  key: const ValueKey('google-switch-account'),
                  icon: Icons.switch_account_outlined,
                  label: l.googleSwitchAccount,
                  onPressed: _busy ? null : () => _act(true),
                ),
                AppMenuItem(
                  key: const ValueKey('google-sign-out'),
                  icon: Icons.logout,
                  label: l.googleSignOut,
                  onPressed: _busy ? null : () => _act(false),
                ),
              ],
            ),
          ),
          if (_signingIn && desktop) ..._desktopWaiting(l),
          if (sync != null) ...[
            const Divider(indent: 17, endIndent: 17),
            _SyncStatusTile(sync: sync, busy: _busy),
            if (sync.divergence != null) SyncDivergenceNotice(sync: sync),
            const Divider(indent: 17, endIndent: 17),
            SwitchListTile(
              key: const ValueKey('google-auto-sync'),
              title: Text(l.autoSyncTitle),
              subtitle: Text(l.uiSyncAutomaticHelp),
              value: sync.enabled,
              onChanged: _busy
                  ? null
                  : (value) async {
                      try {
                        await sync.setEnabled(value);
                      } catch (_) {
                        if (mounted) {
                          setState(() => _error = GoogleAccountIssue.storage);
                        }
                      }
                    },
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: AppFormHint(l.uiPairDeviceNote),
          ),
        ],
      ],
    );
    return widget.showTitle
        ? AppSettingsSection(title: l.uiSynchronization, child: content)
        : content;
  }
}

/// The exchange state, when it last finished and "sync now".
class _SyncStatusTile extends StatelessWidget {
  const _SyncStatusTile({required this.sync, required this.busy});
  final AutoSyncController sync;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final phase = sync.phase;
    final problem = const {
      AutoSyncPhase.error,
      AutoSyncPhase.conflict,
      AutoSyncPhase.diverged,
    }.contains(phase);
    final syncedAt = sync.syncedAt;
    final running = phase == AutoSyncPhase.syncing || sync.applying;
    return AppActionTile(
      key: const ValueKey('google-sync-status'),
      leading: AppIconTile(
        size: 40,
        round: true,
        busy: running,
        icon: switch (phase) {
          AutoSyncPhase.synced => Icons.cloud_done_outlined,
          AutoSyncPhase.retrying => Icons.cloud_off_outlined,
          AutoSyncPhase.disabled => Icons.sync_disabled,
          _ when problem => Icons.sync_problem,
          _ => Icons.cloud_sync_outlined,
        },
      ),
      title: Text(
        syncStatusLabel(l, sync),
        style: problem ? TextStyle(color: colors.error) : null,
      ),
      subtitle: phase == AutoSyncPhase.synced && syncedAt != null
          ? Text(syncTimeLabel(context, syncedAt))
          : null,
      action: FilledButton.tonal(
        key: const ValueKey('google-sync-now'),
        onPressed:
            busy ||
                running ||
                !sync.enabled ||
                phase == AutoSyncPhase.diverged ||
                phase == AutoSyncPhase.disconnected
            ? null
            : sync.syncNow,
        child: Text(l.uiSyncNow),
      ),
    );
  }
}

/// "Today, 22:24" for today, otherwise the date and time.
String syncTimeLabel(BuildContext context, DateTime value) {
  final l = AppLocalizations.of(context);
  final locale = l.localeName;
  final local = value.toLocal(), now = DateTime.now();
  final time = DateFormat.Hm(locale).format(local);
  return local.year == now.year &&
          local.month == now.month &&
          local.day == now.day
      ? l.uiSyncedToday(time)
      : DateFormat.yMd(locale).add_Hm().format(local);
}

/// The paused exchange and the way out: choosing one of the two versions.
class SyncDivergenceNotice extends StatelessWidget {
  const SyncDivergenceNotice({required this.sync, super.key});
  final AutoSyncController sync;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final busy = sync.phase == AutoSyncPhase.syncing || sync.applying;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppNotice(
          key: const ValueKey('google-sync-divergence'),
          icon: Icons.call_split,
          message: sync.divergence?.otherWorkspace ?? false
              ? l.autoSyncOtherWorkspace
              : l.autoSyncDiverged,
          action: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonal(
                key: const ValueKey('google-sync-choose-version'),
                onPressed: busy ? null : () => chooseSyncVersion(context, sync),
                child: Text(l.autoSyncChooseVersion),
              ),
            ),
          ),
        ),
        if (sync.choiceBlocked)
          AppNotice(
            key: const ValueKey('google-sync-choice-blocked'),
            message: l.autoSyncChoiceBlocked,
            error: true,
          ),
      ],
    );
  }
}

/// Asks which version to keep, with the date and device of both. The answer
/// is an explicit action; dismissing the sheet changes nothing. Replacing
/// another workspace in the cloud is confirmed once more: it reaches every
/// device of the account.
Future<void> chooseSyncVersion(
  BuildContext context,
  AutoSyncController sync,
) async {
  final divergence = sync.divergence;
  if (divergence == null) return;
  final l = AppLocalizations.of(context);
  String saved(SyncVersionInfo version, String fallbackDevice) =>
      l.autoSyncVersionSaved(
        version.savedAt == null
            ? l.autoSyncVersionUnknownTime
            : DateFormat.yMd(
                l.localeName,
              ).add_Hm().format(version.savedAt!.toLocal()),
        version.deviceName ?? fallbackDevice,
      );
  final other = divergence.otherWorkspace;
  final choice = await showAppChoice<SyncDivergenceChoice?>(
    context,
    title: l.autoSyncChooseTitle,
    message: other ? l.autoSyncOtherWorkspaceHelp : l.autoSyncChooseHelp,
    value: null,
    options: [
      (SyncDivergenceChoice.keepLocal, l.autoSyncKeepLocal),
      (SyncDivergenceChoice.takeCloud, l.autoSyncTakeCloud),
    ],
    descriptions: {
      SyncDivergenceChoice.keepLocal:
          '${saved(divergence.local, l.autoSyncThisDevice)}\n'
          '${other ? l.autoSyncOtherKeepLocalEffect : l.autoSyncKeepLocalEffect}',
      SyncDivergenceChoice.takeCloud:
          '${saved(divergence.cloud, l.autoSyncVersionUnknownDevice)}\n'
          '${other ? l.autoSyncOtherTakeCloudEffect : l.autoSyncTakeCloudEffect}',
    },
  );
  if (choice == null) return;
  if (other &&
      choice == SyncDivergenceChoice.keepLocal &&
      !(context.mounted &&
          await confirmAppDanger(
            context,
            title: l.autoSyncReplaceCloudTitle,
            message: l.autoSyncReplaceCloudHelp,
            confirmLabel: l.autoSyncReplaceCloud,
            cancelLabel: l.sshCancel,
            confirmKey: const ValueKey('google-sync-replace-cloud'),
          ))) {
    return;
  }
  await sync.resolve(choice);
}

String syncStatusLabel(AppLocalizations l, AutoSyncController sync) {
  if (sync.accountError == GoogleAccountIssue.reauthorize ||
      sync.transportError == SyncTransportIssue.unauthorized) {
    return l.googleReauthorize;
  }
  if (sync.accountError == GoogleAccountIssue.denied ||
      sync.transportError == SyncTransportIssue.forbidden) {
    return l.googleDenied;
  }
  if (sync.transportError == SyncTransportIssue.unsupportedVersion) {
    return l.autoSyncUpdateRequired;
  }
  return switch (sync.phase) {
    AutoSyncPhase.disconnected => l.googleAccountHelp,
    AutoSyncPhase.disabled => l.autoSyncDisabled,
    AutoSyncPhase.waiting => l.autoSyncWaiting,
    AutoSyncPhase.syncing => l.autoSyncWorking,
    AutoSyncPhase.synced => l.autoSyncDone,
    AutoSyncPhase.editing => l.autoSyncEditing,
    AutoSyncPhase.conflict => l.autoSyncConflict,
    AutoSyncPhase.remoteNewer => l.autoSyncRemoteNewer,
    AutoSyncPhase.retrying => l.autoSyncRetrying,
    AutoSyncPhase.diverged => l.autoSyncDivergedShort,
    AutoSyncPhase.error => l.autoSyncError,
  };
}
