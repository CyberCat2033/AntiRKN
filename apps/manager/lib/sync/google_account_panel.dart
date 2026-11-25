import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
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
          if (_signingIn && desktop) ...[
            AppNotice(message: l.googleDesktopWaiting),
            TextButton(
              key: const ValueKey('google-cancel-sign-in'),
              onPressed: () =>
                  (widget.service as CancelableGoogleSignIn).cancelSignIn(),
              child: Text(l.googleCancelSignIn),
            ),
          ],
          if (account != null)
            TextButton(
              key: const ValueKey('google-sign-out'),
              onPressed: _busy ? null : () => _act(false),
              child: Text(l.googleSignOut),
            ),
        ] else ...[
          if (account != null && sync != null) ...[
            ListTile(
              leading: const AppIconTile(icon: Icons.cloud_done_outlined),
              title: Text(
                syncStatusLabel(l, sync),
                key: const ValueKey('google-sync-status'),
              ),
              // The account is named once, on the Google Drive row (UI-51).
            ),
            const Divider(indent: 17, endIndent: 17),
            if ((sync.result?.otherWorkspaces ?? 0) > 0)
              AppNotice(
                key: const ValueKey('google-other-workspaces'),
                message: l.autoSyncOtherWorkspaces,
              ),
          ],
          ListTile(
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
                      builder: (_) => AppFormDialog(
                        title: Text(l.uiGoogleDrive),
                        content: GoogleAccountPanel(
                          service: widget.service,
                          sync: sync,
                          showTitle: false,
                          accountDetails: true,
                          beforeAccountChange: widget.beforeAccountChange,
                          afterAccountChange: widget.afterAccountChange,
                        ),
                      ),
                    );
                    if (mounted) await _load();
                  },
          ),
          if (account != null && sync != null) ...[
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
            const Divider(indent: 17, endIndent: 17),
            ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: Text(l.uiPairDevice),
              subtitle: Text(l.uiPairDeviceHelp),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showAppDetails(
                context,
                title: l.uiPairDevice,
                children: [Text(l.autoSyncPairing)],
              ),
            ),
          ],
        ],
      ],
    );
    return widget.showTitle
        ? AppSettingsSection(title: l.uiSynchronization, child: content)
        : content;
  }
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
  return switch (sync.phase) {
    AutoSyncPhase.disconnected => l.googleAccountHelp,
    AutoSyncPhase.disabled => l.autoSyncDisabled,
    AutoSyncPhase.waiting => l.autoSyncWaiting,
    AutoSyncPhase.syncing => l.autoSyncWorking,
    AutoSyncPhase.synced => l.autoSyncDone,
    AutoSyncPhase.editing => l.autoSyncEditing,
    AutoSyncPhase.conflict => l.autoSyncConflict,
    AutoSyncPhase.incomplete => l.autoSyncIncomplete,
    AutoSyncPhase.error => l.autoSyncError,
  };
}
