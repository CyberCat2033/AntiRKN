import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../l10n/app_localizations.dart';

/// Encodes and copies the same verified download URL, with no duplicate action.
class ProfileLinkQr extends StatefulWidget {
  const ProfileLinkQr({required this.url, required this.beforeCopy, super.key});
  final String url;
  final Future<void> Function() beforeCopy;
  @override
  State<ProfileLinkQr> createState() => _ProfileLinkQrState();
}

class _ProfileLinkQrState extends State<ProfileLinkQr> {
  bool copying = false;
  String? error;
  @override
  void didUpdateWidget(ProfileLinkQr oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) error = null;
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 256),
            child: AspectRatio(
              aspectRatio: 1,
              child: Semantics(
                button: true,
                enabled: !copying,
                label: l.publicationCopyLink,
                child: Tooltip(
                  message: l.publicationCopyLink,
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: const ValueKey('profile-link-qr'),
                      onTap: copying ? null : copy,
                      child: Padding(
                        padding: const EdgeInsets.all(AppLayout.gap),
                        child: ExcludeSemantics(
                          child: QrImageView(
                            data: widget.url,
                            padding: const EdgeInsets.all(16),
                            backgroundColor: Colors.white,
                            errorCorrectionLevel: QrErrorCorrectLevel.M,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: Colors.black,
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: Colors.black,
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
