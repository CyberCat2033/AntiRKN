import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../publication/publication_controller.dart';
import '../publication/publication_panel.dart';
import '../publication/profile_link_qr.dart';
import 'vpn_controller.dart';
import 'vpn_strings.dart';
import 'core_config_check.dart';

class ProfileShareSheet extends StatefulWidget {
  const ProfileShareSheet({
    required this.controller,
    required this.user,
    required this.exporter,
    this.publications,
    super.key,
  });
  final VpnController controller;
  final VpnUser user;
  final ProfileExporter exporter;
  final PublicationController? publications;
  @override
  State<ProfileShareSheet> createState() => _ProfileShareSheetState();
}

class _ProfileShareSheetState extends State<ProfileShareSheet> {
  bool saving = false;
  bool regenerating = false;
  String? message;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          (widget.publications?.verifiedLinkFor(widget.user.id) == null ||
              widget.publications?.bindingPending(widget.user.id) == true)) {
        widget.publications?.publishUser(widget.user.id);
      }
    });
  }

  Future<void> _regenerate() async {
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
    if (usable) await widget.publications?.publishUser(widget.user.id, force: true);
    setState(() {
      regenerating = false;
      message = widget.controller.error != null
          ? vpnMessage(l, widget.controller.error!)
          : usable
          ? l.vpnProfileRegenerated
          : l.vpnLastProfile;
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, widget.publications]),
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
      return ConstrainedBox(
        constraints: BoxConstraints(
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
                    onPressed: regenerating || saving || c.busy
                        ? null
                        : _regenerate,
                    icon: regenerating
                        ? const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                  IconButton(
                    key: const ValueKey('profile-close'),
                    tooltip: l.networkClose,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(
                l.uiClashImport,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppLayout.gap),
              if (publication != null && link == null)
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
                    await c.checkProfileEffects();
                    if (publication!.verifiedLinkFor(widget.user.id) != link) {
                      throw StateError('publication_changed');
                    }
                  },
                ),
              ] else if (usable &&
                  publication?.settings?.access == PublicationAccess.private)
                Text(l.publicationPrivateHelp),
              if (!usable)
                Text(
                  c.template().isEmpty ? l.vpnEmptyTemplate : l.vpnLastProfile,
                ),
              if (result != null)
                for (final d in result.diagnostics)
                  Card.filled(
                    child: ListTile(
                      leading: Icon(
                        d.severity == DiagnosticSeverity.error
                            ? Icons.error_outline
                            : Icons.warning_amber_outlined,
                      ),
                      title: Text(d.subject ?? vpnMessage(l, d.code)),
                      subtitle: d.subject == null
                          ? null
                          : Text(vpnMessage(l, d.code)),
                    ),
                  ),
              if (!usable &&
                  result?.diagnostics.any(
                    (d) => d.code == 'vpn_pending_client',
                  ) == true) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.icon(
                    key: const ValueKey('profile-apply-servers'),
                    onPressed: (c.busy || c.hasRunning)
                        ? null
                        : () => c.prepareAndApply(),
                    icon: (c.busy || c.hasRunning)
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload_outlined),
                    label: Text(c.hasRunning ? l.vpnApplying : l.vpnApply),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (usable)
                CoreConfigCheckAction(controller: c, userId: widget.user.id),
              const SizedBox(height: 12),
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
              if (message != null)
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
                              await c.checkProfileEffects();
                              if (!mounted ||
                                  c.results[widget.user.id]?.sha256Hash !=
                                      result!.sha256Hash ||
                                  !c.workspace.users.any(
                                    (u) => u.id == widget.user.id && u.enabled,
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
                            } on SyncMergeFailure {
                              if (mounted) {
                                setState(() => message = l.syncEffectsBlocked);
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
            ],
          ),
        ),
      );
    },
  );
}
