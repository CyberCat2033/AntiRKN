import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import 'clash_profile_link.dart';
import '../vpn/secret_link_box.dart';

/// Scanning imports into Clash; tapping copies the verified direct YAML URL.
class ProfileLinkQr extends StatefulWidget {
  const ProfileLinkQr({
    required this.url,
    required this.beforeCopy,
    this.profileName = '',
    super.key,
  });
  final String url;
  final String profileName;
  final Future<void> Function() beforeCopy;
  @override
  State<ProfileLinkQr> createState() => _ProfileLinkQrState();
}

class _ProfileLinkQrState extends State<ProfileLinkQr> {
  bool copying = false;
  bool focused = false;
  String? error;
  late String _cachedLink;

  @override
  void initState() {
    super.initState();
    _updateLink();
  }

  @override
  void didUpdateWidget(ProfileLinkQr oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.profileName != widget.profileName) {
      error = null;
      _updateLink();
    }
  }

  void _updateLink() {
    _cachedLink = clashProfileLink(
      widget.url,
      name: widget.profileName,
    ).toString();
  }

  Future<void> copy() async {
    if (copying) return;
    final l = AppLocalizations.of(context), url = widget.url;
    setState(() {
      copying = true;
      error = null;
    });
    try {
      await widget.beforeCopy();
      if (!mounted || widget.url != url) return;
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.uiLinkCopied)));
      }
    } on SyncMergeFailure {
      if (mounted) setState(() => error = l.syncEffectsBlocked);
    } catch (_) {
      if (mounted) setState(() => error = l.uiCopyFailed);
    } finally {
      if (mounted) setState(() => copying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: AspectRatio(
              aspectRatio: 1,
              child: Semantics(
                button: true,
                enabled: !copying,
                label: l.publicationCopyLink,
                // The Semantics above names the button once; the tooltip
                // stays visual only (UI-73).
                child: Tooltip(
                  message: l.publicationCopyLink,
                  excludeFromSemantics: true,
                  // A keyboard focus ring on the card's edge, clear of the QR
                  // modules: a theme overlay alone is faint on white (UI-73).
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: focused
                          ? Border.all(color: scheme.primary, width: 3)
                          : null,
                    ),
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        key: const ValueKey('profile-link-qr'),
                        onTap: copying ? null : copy,
                        onFocusChange: (value) =>
                            setState(() => focused = value),
                        // The scrim role is dark in both themes, so hover and
                        // press stay visible on the white background.
                        overlayColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.pressed)
                              ? scheme.scrim.withValues(alpha: .12)
                              : states.contains(WidgetState.hovered) ||
                                    states.contains(WidgetState.focused)
                              ? scheme.scrim.withValues(alpha: .08)
                              : null,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(AppLayout.gap),
                          child: ExcludeSemantics(
                            child: RepaintBoundary(
                              child: ScannableQrImage(data: _cachedLink),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppLayout.smallGap),
        Text(l.uiQrCopyHint, textAlign: TextAlign.center),
        const SizedBox(height: AppLayout.smallGap),
        Text(
          l.uiClashRefreshHint,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (error != null)
          Semantics(
            liveRegion: true,
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}
