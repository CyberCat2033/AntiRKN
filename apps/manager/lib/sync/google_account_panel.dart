import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'auto_sync_controller.dart';

class GoogleAccountPanel extends StatefulWidget {
  const GoogleAccountPanel({required this.service, this.sync, super.key});
  final GoogleAccountService service;
  final AutoSyncController? sync;
  @override
  State<GoogleAccountPanel> createState() => _GoogleAccountPanelState();
}

class _GoogleAccountPanelState extends State<GoogleAccountPanel> {
  GoogleDriveAccount? _account;
  GoogleAccountIssue? _error;
  bool _busy = true;
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
      _error = null;
    });
    try {
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
      if (mounted) setState(() => _busy = false);
    }
  }

  void _syncChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.sync?.removeListener(_syncChanged);
    super.dispose();
  }

  String _syncStatus(AppLocalizations l) {
    final sync = widget.sync!;
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final account = _account;
    final error = switch (_error) {
      GoogleAccountIssue.configuration => l.googleConfigurationError,
      GoogleAccountIssue.denied => l.googleDenied,
      GoogleAccountIssue.network => l.googleNetworkError,
      GoogleAccountIssue.storage => l.googleStorageError,
      GoogleAccountIssue.reauthorize => l.googleReauthorize,
      GoogleAccountIssue.busy => l.googleWorking,
      GoogleAccountIssue.unavailable => l.googleUnavailable,
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
            Text(_syncStatus(l), key: const ValueKey('google-sync-status')),
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
