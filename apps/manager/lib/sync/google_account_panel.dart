import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'auto_sync_controller.dart';

class GoogleAccountPanel extends StatefulWidget {
  const GoogleAccountPanel({
    required this.service,
    this.sync,
    this.beforeAccountChange,
    this.afterAccountChange,
    super.key,
  });
  final GoogleAccountService service;
  final AutoSyncController? sync;
  final Future<void> Function()? beforeAccountChange;
  final void Function()? afterAccountChange;
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
        if (account != null) _account = account;
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
      widget.afterAccountChange?.call();
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
    return SectionCard(
      title: l.googleAccountTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (account == null)
            Text(l.googleAccountHelp)
          else ...[
            if (account.displayName.isNotEmpty) Text(account.displayName),
            SelectableText(
              account.email,
              key: const ValueKey('google-account-email'),
            ),
            Text(l.googleConnected),
          ],
          if (_busy) ...[
            const SizedBox(height: AppLayout.smallGap),
            const LinearProgressIndicator(),
            Text(l.googleWorking),
            if (_signingIn && desktop) ...[
              Text(l.googleDesktopWaiting),
              TextButton(
                key: const ValueKey('google-cancel-sign-in'),
                onPressed: () =>
                    (widget.service as CancelableGoogleSignIn).cancelSignIn(),
                child: Text(l.googleCancelSignIn),
              ),
            ],
          ],
          if (error != null) ...[
            const SizedBox(height: AppLayout.smallGap),
            Text(
              error,
              key: const ValueKey('google-account-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: AppLayout.smallGap),
          Wrap(
            spacing: AppLayout.smallGap,
            runSpacing: AppLayout.smallGap,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('google-sign-in'),
                onPressed: _busy ? null : () => _act(true),
                icon: const Icon(Icons.login),
                label: Text(
                  account == null ? l.googleSignIn : l.googleSwitchAccount,
                ),
              ),
              if (account != null)
                TextButton(
                  key: const ValueKey('google-sign-out'),
                  onPressed: _busy ? null : () => _act(false),
                  child: Text(l.googleSignOut),
                ),
            ],
          ),
          const SizedBox(height: AppLayout.smallGap),
          if (_account != null && widget.sync != null) ...[
            SwitchListTile.adaptive(
              key: const ValueKey('google-auto-sync'),
              contentPadding: EdgeInsets.zero,
              title: Text(l.autoSyncTitle),
              subtitle: Text(l.autoSyncHelp),
              value: widget.sync!.enabled,
              onChanged: _busy
                  ? null
                  : (value) async {
                      try {
                        await widget.sync!.setEnabled(value);
                      } catch (_) {
                        if (mounted) {
                          setState(() => _error = GoogleAccountIssue.storage);
                        }
                      }
                    },
            ),
            Text(
              syncStatusLabel(l, widget.sync!),
              key: const ValueKey('google-sync-status'),
            ),
            if ((widget.sync!.result?.otherWorkspaces ?? 0) > 0)
              Text(
                l.autoSyncOtherWorkspaces,
                key: const ValueKey('google-other-workspaces'),
              ),
            if (widget.sync!.phase == AutoSyncPhase.syncing)
              const LinearProgressIndicator(),
            if (widget.sync!.result?.lastSuccess case final last?)
              Text(
                l.autoSyncLast(
                  MaterialLocalizations.of(
                    context,
                  ).formatTimeOfDay(TimeOfDay.fromDateTime(last.toLocal())),
                ),
              ),
            if (widget.sync!.enabled)
              TextButton.icon(
                key: const ValueKey('google-sync-now'),
                onPressed: _busy || widget.sync!.phase == AutoSyncPhase.syncing
                    ? null
                    : () => widget.sync!.request(immediate: true),
                icon: const Icon(Icons.sync),
                label: Text(l.autoSyncNow),
              ),
          ],
          Text(l.autoSyncPairing),
        ],
      ),
    );
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
