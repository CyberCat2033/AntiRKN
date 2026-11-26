import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';

/// A QR code as scanners read it best: dark modules on white, whatever the
/// theme (UI-73).
class ScannableQrImage extends StatelessWidget {
  const ScannableQrImage({required this.data, this.size, super.key});
  final String data;
  final double? size;
  @override
  Widget build(BuildContext context) => QrImageView(
    data: data,
    size: size,
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
  );
}

/// A link or config that grants access: hidden until shown, copied on
/// request, with its QR code while shown ([qr]). Keys start with
/// [keyPrefix]: `-text`, `-hidden`, `-reveal`, `-copy`, `-qr`.
class SecretLinkBox extends StatefulWidget {
  const SecretLinkBox({
    required this.text,
    required this.keyPrefix,
    this.qr = false,
    this.copyLabel,
    super.key,
  });
  final String text, keyPrefix;
  final bool qr;

  /// The copy button label; "Copy link" when omitted.
  final String? copyLabel;
  @override
  State<SecretLinkBox> createState() => _SecretLinkBoxState();
}

class _SecretLinkBoxState extends State<SecretLinkBox> {
  bool visible = false, copyFailed = false;

  @override
  void didUpdateWidget(SecretLinkBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) copyFailed = false;
  }

  Future<void> copy() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: widget.text));
      if (mounted) setState(() => copyFailed = false);
      messenger.showSnackBar(SnackBar(content: Text(l.uiLinkCopied)));
    } catch (_) {
      if (mounted) setState(() => copyFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final prefix = widget.keyPrefix;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppLayout.radius),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppLayout.gap),
            child: visible
                ? SelectableText(
                    widget.text,
                    key: ValueKey('$prefix-text'),
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                : Text(
                    l.relayLinkHidden,
                    key: ValueKey('$prefix-hidden'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
          ),
        ),
        if (visible && widget.qr)
          Padding(
            padding: const EdgeInsets.only(top: AppLayout.gap),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppLayout.radius),
                child: Semantics(
                  label: l.serviceTestLinkQr,
                  image: true,
                  child: ExcludeSemantics(
                    child: ScannableQrImage(
                      key: ValueKey('$prefix-qr'),
                      data: widget.text,
                      size: 280,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (copyFailed)
          AppNotice(
            key: ValueKey('$prefix-copy-failed'),
            message: l.relayCopyFailed,
            error: true,
            margin: const EdgeInsets.only(top: 12),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              key: ValueKey('$prefix-reveal'),
              onPressed: () => setState(() => visible = !visible),
              icon: Icon(visible ? Icons.visibility_off : Icons.visibility),
              label: Text(visible ? l.relayHide : l.relayShow),
            ),
            FilledButton.tonalIcon(
              key: ValueKey('$prefix-copy'),
              onPressed: copy,
              icon: const Icon(Icons.copy),
              label: Text(widget.copyLabel ?? l.relayCopy),
            ),
          ],
        ),
      ],
    );
  }
}
