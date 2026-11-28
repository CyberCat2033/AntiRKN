import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../publication/publication_controller.dart';
import '../publication/publication_panel.dart';
import '../publication/profile_link_qr.dart';
import 'client_traffic_controller.dart';
import 'client_traffic_view.dart';
import 'vpn_controller.dart';
import 'vpn_strings.dart';

/// A client's card: its profile with the QR always in view, its traffic,
/// and editing or deleting it. A bottom sheet or dialog around it, or the
/// pane beside the list on a wide window ([embedded]).
class ProfileShareSheet extends StatefulWidget {
  const ProfileShareSheet({
    required this.controller,
    required this.user,
    required this.exporter,
    this.publications,
    this.traffic,
    this.serverName,
    this.motion = MotionPreference.system,
    this.onEdit,
    this.onDelete,
    this.embedded = false,
    super.key,
  });
  final VpnController controller;
  final VpnUser user;
  final ProfileExporter exporter;
  final PublicationController? publications;

  /// Traffic counted for this client on the servers; null: not shown.
  final ClientTrafficController? traffic;
  final String Function(String serverId)? serverName;
  final MotionPreference motion;

  /// Opens the client's form over the card.
  final Future<void> Function(BuildContext context)? onEdit;

  /// Asks and deletes the client; true once it is gone.
  final Future<bool> Function(BuildContext context)? onDelete;

  /// Beside the list instead of in a sheet or dialog: no close button and
  /// no height of its own.
  final bool embedded;
  @override
  State<ProfileShareSheet> createState() => _ProfileShareSheetState();
}

class _ProfileShareSheetState extends State<ProfileShareSheet> {
  bool saving = false;
  bool regenerating = false;
  bool openingPublished = false;
  String? message;

  /// The already published link read from Google Drive, when this device
  /// cannot build the profile itself.
  String? publishedLink;
  String? publishedMessage;

  Future<void> _openPublished() async {
    final l = AppLocalizations.of(context);
    setState(() {
      openingPublished = true;
      publishedMessage = null;
    });
    String? url, issue;
    try {
      url = await widget.publications?.publishedLinkFromDrive(widget.user.id);
      if (url == null) issue = l.profilePublishedMissing;
    } catch (_) {
      issue = l.profilePublishedFailed;
    }
    if (!mounted) return;
    setState(() {
      openingPublished = false;
      publishedLink = url;
      publishedMessage = issue;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final profileMissing =
          widget.controller.workspace.profiles[widget.user.id] == null &&
          widget.controller.results[widget.user.id] == null;
      if (profileMissing && !widget.controller.busy && !regenerating) {
        _regenerate(initial: true);
      } else if (widget.publications?.hasActiveSync != true &&
          (widget.publications?.verifiedLinkFor(widget.user.id) == null ||
              widget.publications?.bindingPending(widget.user.id) == true)) {
        // A running sync publishes this client itself.
        widget.publications?.publishUser(widget.user.id);
      }
    });
  }

  Future<void> _regenerate({bool initial = false}) async {
    final l = AppLocalizations.of(context);
    setState(() {
      regenerating = true;
      message = l.vpnRegeneratingProfile;
    });
    await widget.controller.regenerateProfile(widget.user.id);
    if (!mounted) return;
    final result = widget.controller.results[widget.user.id];
    final usable =
        widget.controller.error == null &&
        result?.yaml != null &&
        result?.hasBlockingErrors == false;
    if (usable) {
      await widget.publications?.publishUser(widget.user.id, force: !initial);
    }
    if (!mounted) return;
    setState(() {
      regenerating = false;
      message = widget.controller.error != null
          ? vpnMessage(l, widget.controller.error!)
          : usable
          ? l.vpnProfileRegenerated
          : l.vpnLastProfile;
    });
  }

  Future<void> _delete() async {
    final deleted = await widget.onDelete!(context);
    // A sheet or dialog closes with its client; the pane follows the list.
    if (deleted && mounted && !widget.embedded) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller,
      widget.publications?.changes,
    ]),
    builder: (context, _) {
      final c = widget.controller, l = AppLocalizations.of(context);
      final user = c.workspace.users
          .where((u) => u.id == widget.user.id)
          .firstOrNull;
      final result = c.results[widget.user.id];
      final usable =
          user?.enabled == true &&
          result?.yaml != null &&
          result?.hasBlockingErrors == false;
      final publication = widget.publications;
      final link = publication?.verifiedLinkFor(widget.user.id);
      final theme = Theme.of(context);
      return RepaintBoundary(
        child: ConstrainedBox(
          constraints: widget.embedded
              ? const BoxConstraints()
              : BoxConstraints(
                  maxWidth: 600,
                  maxHeight: MediaQuery.sizeOf(context).height * .9,
                ),
          child: SingleChildScrollView(
            padding: AppLayout.screenPadding(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        user?.name ?? widget.user.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('profile-regenerate'),
                      tooltip: l.vpnRegenerateProfile,
                      onPressed: regenerating || saving || !c.canMutate
                          ? null
                          : _regenerate,
                      // The generating card is the indicator while there is
                      // no profile yet (UI-47).
                      icon: regenerating && result != null
                          ? const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                    if (!widget.embedded)
                      IconButton(
                        key: const ValueKey('profile-close'),
                        tooltip: l.networkClose,
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
                Text(
                  user?.enabled == false ? l.vpnDisabled : l.uiClashImport,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppLayout.gap),
                if (regenerating && result == null) ...[
                  Card.filled(
                    key: const ValueKey('profile-generating-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(AppLayout.gap),
                      child: Row(
                        children: [
                          const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: AppLayout.gap),
                          Expanded(
                            child: Text(
                              l.vpnRegeneratingProfile,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppLayout.gap),
                ],
                if (publication != null &&
                    (link == null ||
                        publication.queues[widget.user.id]?['status'] ==
                            'error') &&
                    !(regenerating && result == null))
                  UserPublicationView(
                    controller: publication,
                    userId: widget.user.id,
                  ),
                if (link != null) ...[
                  const SizedBox(height: AppLayout.gap),
                  if (!usable) ...[
                    Card.filled(
                      child: ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(l.vpnPreviousProfileLink),
                      ),
                    ),
                    const SizedBox(height: AppLayout.smallGap),
                  ],
                  ProfileLinkQr(
                    url: link,
                    profileName: user?.name ?? widget.user.name,
                    beforeCopy: () async {
                      if (publication!.verifiedLinkFor(widget.user.id) !=
                          link) {
                        throw StateError('publication_changed');
                      }
                    },
                  ),
                ] else if (usable &&
                    publication?.settings?.access == PublicationAccess.private)
                  Text(l.publicationPrivateHelp),
                if (!usable && !(regenerating && result == null))
                  Text(
                    c.template().isEmpty
                        ? l.vpnEmptyTemplate
                        : l.vpnLastProfile,
                  ),
                if (!usable && link == null && publication != null) ...[
                  const SizedBox(height: AppLayout.gap),
                  if (publishedLink case final url?) ...[
                    AppNotice(
                      key: const ValueKey('profile-published-drive'),
                      icon: Icons.cloud_done_outlined,
                      message: l.profilePublishedFromDrive,
                    ),
                    ProfileLinkQr(
                      url: url,
                      profileName: user?.name ?? widget.user.name,
                      beforeCopy: () async {
                        if (c.workspace.userById(widget.user.id)?.enabled !=
                            true) {
                          throw StateError('publication_changed');
                        }
                      },
                    ),
                  ] else
                    AppNotice(
                      key: const ValueKey('profile-open-published'),
                      icon: Icons.cloud_outlined,
                      message: publishedMessage ?? l.profilePublishedDriveHelp,
                      action: TextButton(
                        key: const ValueKey('profile-open-published-action'),
                        onPressed: openingPublished ? null : _openPublished,
                        child: Text(l.profileOpenPublished),
                      ),
                    ),
                ],
                // Base-config warnings belong to the base config: the sheet
                // only shows what blocks this client's profile.
                if (result != null)
                  for (final d in result.diagnostics.where(
                    (d) => d.severity == DiagnosticSeverity.error,
                  ))
                    Card.filled(
                      child: ListTile(
                        leading: const Icon(Icons.error_outline),
                        title: Text(d.subject ?? vpnMessage(l, d.code)),
                        subtitle: d.subject == null
                            ? null
                            : Text(vpnMessage(l, d.code)),
                      ),
                    ),
                if (!usable &&
                    result?.diagnostics.any(
                          (d) => d.code == 'vpn_pending_client',
                        ) ==
                        true) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton.icon(
                      key: const ValueKey('profile-apply-servers'),
                      onPressed:
                          (!c.canMutate || c.hasRunning || c.hasObservedRunning)
                          ? null
                          : () => c.prepareAndApply(),
                      // Spins for the person's apply, not for background
                      // checks (UI-47).
                      icon:
                          (c.foregroundBusy ||
                              c.hasRunning ||
                              c.hasObservedRunning)
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_upload_outlined),
                      label: Text(
                        (c.hasRunning || c.hasObservedRunning)
                            ? l.vpnApplying
                            : l.vpnApply,
                      ),
                    ),
                  ),
                ],
                if (widget.traffic case final traffic? when user != null)
                  ClientTrafficCards(
                    controller: traffic,
                    userId: widget.user.id,
                    userName: user.name,
                    serverName: widget.serverName ?? (id) => id,
                    motion: widget.motion,
                  ),
                const SizedBox(height: 20),
                if (usable)
                  Card.filled(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.description_outlined),
                          title: Text(l.uiPreviewYaml),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => showAppDetails(
                            context,
                            title: l.uiPreviewYaml,
                            children: [SelectableText(result!.yaml!)],
                          ),
                        ),
                        const Divider(indent: 17, endIndent: 17),
                        ListTile(
                          leading: const Icon(Icons.info_outline),
                          title: Text(l.uiProfileDetails),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => showAppDetails(
                            context,
                            title: l.uiProfileDetails,
                            children: [
                              Text(l.uiClashRefreshHint),
                              const SizedBox(height: AppLayout.gap),
                              Text(l.vpnProfileValidation),
                              for (final group in result!.groups)
                                ListTile(
                                  title: Text(group.name),
                                  subtitle: Text(group.members.join(', ')),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                if (message != null && !(regenerating && result == null))
                  Semantics(liveRegion: true, child: Text(message!)),
                if (usable)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton.tonal(
                      onPressed: saving
                          ? null
                          : () async {
                              setState(() => saving = true);
                              try {
                                if (!mounted ||
                                    c.results[widget.user.id]?.sha256Hash !=
                                        result!.sha256Hash ||
                                    !c.workspace.users.any(
                                      (u) =>
                                          u.id == widget.user.id && u.enabled,
                                    )) {
                                  return;
                                }
                                final saved = await widget.exporter.save(
                                  '${widget.user.id}.yml',
                                  result.yaml!,
                                );
                                if (mounted && saved) {
                                  setState(() => message = l.vpnProfileSaved);
                                }
                              } catch (_) {
                                if (mounted) {
                                  setState(() => message = l.vpnFailed);
                                }
                              } finally {
                                if (mounted) setState(() => saving = false);
                              }
                            },
                      child: Text(l.vpnSaveProfile),
                    ),
                  ),
                if (user != null &&
                    (widget.onEdit != null || widget.onDelete != null)) ...[
                  const Divider(height: 32),
                  Wrap(
                    spacing: AppLayout.smallGap,
                    runSpacing: AppLayout.smallGap,
                    children: [
                      if (widget.onEdit case final edit?)
                        OutlinedButton.icon(
                          key: const ValueKey('client-card-edit'),
                          onPressed: !c.canMutate ? null : () => edit(context),
                          icon: const Icon(Icons.edit_outlined),
                          label: Text(l.vpnEdit),
                        ),
                      if (widget.onDelete != null)
                        TextButton.icon(
                          key: const ValueKey('client-card-delete'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                          ),
                          onPressed: !c.canMutate ? null : _delete,
                          icon: const Icon(Icons.delete_outline),
                          label: Text(l.vpnDeleteUser),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
