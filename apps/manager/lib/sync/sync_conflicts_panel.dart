import 'dart:convert';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

class SyncConflictsPanel extends StatefulWidget {
  const SyncConflictsPanel({
    required this.store,
    required this.canResolve,
    required this.onResolved,
    super.key,
  });
  final SyncMergeStore store;
  final bool Function() canResolve;
  final Future<void> Function() onResolved;
  @override
  State<SyncConflictsPanel> createState() => _SyncConflictsPanelState();
}

class _SyncConflictsPanelState extends State<SyncConflictsPanel> {
  SyncMergeStatus? status;
  bool busy = false;
  SyncMergeIssue? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await widget.store.readSyncMergeStatus();
      if (mounted) setState(() => status = next);
    } catch (_) {
      if (mounted) setState(() => error = SyncMergeIssue.storage);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _retry() async {
    if (busy || !widget.canResolve()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.retrySyncMerge();
      if (mounted) await widget.onResolved();
    } catch (_) {
      if (mounted) setState(() => error = SyncMergeIssue.storage);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _open(SyncConflict conflict) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _ConflictDialog(conflict: conflict),
    );
    if (selected == null || !mounted) return;
    if (!widget.canResolve()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).backupActiveWork)),
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.resolveSyncConflict(conflict, selected);
      if (mounted) await widget.onResolved();
    } on SyncMergeFailure catch (e) {
      if (mounted) setState(() => error = e.issue);
    } catch (_) {
      if (mounted) setState(() => error = SyncMergeIssue.storage);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await _loadAfterError();
      }
    }
  }

  Future<void> _loadAfterError() async {
    try {
      final next = await widget.store.readSyncMergeStatus();
      if (mounted) setState(() => status = next);
    } catch (_) {
      /* Preserve the actionable error. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SectionCard(
      title: l.syncConflictsTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.syncLocalHelp),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Semantics(
              liveRegion: true,
              child: Text(
                error == SyncMergeIssue.changed
                    ? l.syncChanged
                    : l.syncStorageError,
              ),
            ),
          if (status case final current?) ...[
            Text(l.syncConflictCount(current.conflicts.length)),
            if (current.waitingGroups > 0)
              Text(
                l.syncWaitingCount(
                  current.waitingGroups,
                  current.missingChangeIds.length,
                ),
              ),
            if (current.blockedGroups > 0)
              Text(l.syncBlockedCount(current.blockedGroups)),
            if (current.rejectedGroups > 0)
              Text(l.syncRejectedCount(current.rejectedGroups)),
            for (final change in current.blockedChanges)
              AppExpansionTile(
                key: PageStorageKey('blocked-change-${change.header.changeId}'),
                title: Text(_kindLabel(l, change.header.entityKind)),
                subtitle: Text(change.header.entityId),
                children: [_PendingChangeDetails(change: change)],
              ),
            for (final c in current.conflicts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_kindLabel(l, c.kind)),
                subtitle: Text(
                  c.entityId,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy ? null : () => _open(c),
              ),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: busy ? null : _load,
              child: Text(l.syncRefresh),
            ),
          ),
          if ((status?.waitingGroups ?? 0) + (status?.blockedGroups ?? 0) > 0)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: busy ? null : _retry,
                child: Text(l.syncRetry),
              ),
            ),
        ],
      ),
    );
  }
}

String _kindLabel(AppLocalizations l, ChangeEntityKind kind) => switch (kind) {
  ChangeEntityKind.server => l.syncKindServer,
  ChangeEntityKind.template => l.syncKindTemplate,
  ChangeEntityKind.vpnUser => l.syncKindUser,
  ChangeEntityKind.vlessInbound => l.syncKindVless,
  ChangeEntityKind.awgInterface => l.syncKindAwg,
  ChangeEntityKind.ttEndpoint => l.syncKindTt,
  ChangeEntityKind.vpnServerState ||
  ChangeEntityKind.runnerState => l.syncKindOperation,
  ChangeEntityKind.profile => l.syncKindProfile,
  _ => l.syncKindWorkspace,
};

class _ConflictDialog extends StatefulWidget {
  const _ConflictDialog({required this.conflict});
  final SyncConflict conflict;
  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  String? selected;
  final revealed = <String>{};
  String _content(LocalChange event) {
    final source = event.source!;
    if (event.header.entityKind == ChangeEntityKind.template) return source;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(source));
    } catch (_) {
      return source;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), c = widget.conflict;
    return AlertDialog(
      title: Text(_kindLabel(l, c.kind)),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.syncChooseHelp),
              for (var i = 0; i < c.variants.length; i++)
                Builder(
                  builder: (context) {
                    final event = c.variants[i], id = event.header.changeId;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              l.syncVariant(i + 1),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (event.header.deleted) Text(l.syncDeleted),
                            if (event.source != null) ...[
                              TextButton(
                                onPressed: () => setState(
                                  () => revealed.contains(id)
                                      ? revealed.remove(id)
                                      : revealed.add(id),
                                ),
                                child: Text(
                                  revealed.contains(id)
                                      ? l.syncHide
                                      : l.syncReveal,
                                ),
                              ),
                              if (revealed.contains(id))
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxHeight: 280,
                                  ),
                                  child: SingleChildScrollView(
                                    child: SelectableText(_content(event)),
                                  ),
                                ),
                            ],
                            ChoiceChip(
                              label: Text(l.syncSelect),
                              selected: selected == id,
                              onSelected: (_) => setState(() => selected = id),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.backupCancel),
        ),
        FilledButton(
          onPressed: selected == null
              ? null
              : () => Navigator.pop(context, selected),
          child: Text(l.syncResolve),
        ),
      ],
    );
  }
}

class _PendingChangeDetails extends StatefulWidget {
  const _PendingChangeDetails({required this.change});
  final LocalChange change;
  @override
  State<_PendingChangeDetails> createState() => _PendingChangeDetailsState();
}

class _PendingChangeDetailsState extends State<_PendingChangeDetails> {
  bool revealed = false;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton(
          onPressed: () => setState(() => revealed = !revealed),
          child: Text(revealed ? l.syncHide : l.syncReveal),
        ),
        if (revealed)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: SingleChildScrollView(
              child: SelectableText(widget.change.source ?? l.syncDeleted),
            ),
          ),
      ],
    );
  }
}
