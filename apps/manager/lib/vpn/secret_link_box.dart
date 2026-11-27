import 'dart:ui' as ui;

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';

/// A QR code as scanners read it best: dark modules on white, whatever the
/// theme (UI-73). Drawn once into an image at the screen's pixel size: the
/// QR painter issues a draw per module, which made every frame of a sheet
/// sliding over the code slow to render on phones.
class ScannableQrImage extends StatefulWidget {
  const ScannableQrImage({required this.data, this.size, super.key});
  final String data;
  final double? size;

  static const _padding = 16.0;

  @override
  State<ScannableQrImage> createState() => _ScannableQrImageState();
}

class _ScannableQrImageState extends State<ScannableQrImage> {
  ui.Image? _image;
  (String, int, double)? _drawn;

  ui.Image _render(int pixels, double logical) {
    final key = (widget.data, pixels, logical);
    if (_drawn == key) return _image!;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final side = pixels.toDouble();
    canvas.drawRect(
      Offset.zero & Size.square(side),
      Paint()..color = Colors.white,
    );
    final inset = ScannableQrImage._padding * side / logical;
    canvas.translate(inset, inset);
    QrPainter(
      data: widget.data,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Colors.black,
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Colors.black,
      ),
    ).paint(canvas, Size.square(side - 2 * inset));
    final picture = recorder.endRecording();
    final image = picture.toImageSync(pixels, pixels);
    picture.dispose();
    _image?.dispose();
    _drawn = key;
    return _image = image;
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final side = widget.size ?? constraints.biggest.shortestSide;
      final pixels = (side * MediaQuery.devicePixelRatioOf(context)).round();
      return SizedBox.square(
        dimension: side,
        child: pixels <= 0
            ? null
            : RawImage(
                image: _render(pixels, side),
                width: side,
                height: side,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.none,
              ),
      );
    },
  );
}

/// The one view of an access link (service mode test link, direct exit
/// link): help, what the link is for, then [SecretLinkBox]. [notice] is
/// shown instead of nothing when there is no link.
class AccessLinkView extends StatelessWidget {
  const AccessLinkView({
    required this.help,
    required this.keyPrefix,
    this.link,
    this.hint,
    this.copyLabel,
    this.loading = false,
    this.notice,
    this.noticeError = false,
    super.key,
  });
  final String help, keyPrefix;
  final String? link, hint, copyLabel, notice;
  final bool loading, noticeError;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(help),
      if (loading)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(),
        ),
      if (link case final text?) ...[
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(hint!, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 12),
        SecretLinkBox(text: text, keyPrefix: keyPrefix, copyLabel: copyLabel),
      ],
      if (notice != null)
        AppNotice(
          key: ValueKey('$keyPrefix-notice'),
          message: notice!,
          error: noticeError,
          margin: const EdgeInsets.only(top: 12),
        ),
    ],
  );
}

/// A link or config that grants access: hidden until shown, copied on
/// request, with its QR code while shown. Keys start with [keyPrefix]:
/// `-text`, `-hidden`, `-reveal`, `-copy`, `-qr`.
class SecretLinkBox extends StatefulWidget {
  const SecretLinkBox({
    required this.text,
    required this.keyPrefix,
    this.copyLabel,
    super.key,
  });
  final String text, keyPrefix;

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
        if (visible)
          Padding(
            padding: const EdgeInsets.only(top: AppLayout.gap),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppLayout.radius),
                child: Semantics(
                  label: l.linkQr,
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
