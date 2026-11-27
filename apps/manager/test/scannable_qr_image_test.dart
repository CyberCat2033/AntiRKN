import 'dart:ui' as ui;

import 'package:antirkn_manager/vpn/secret_link_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the QR code is one image at the screen pixel size', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget qr() => const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: ScannableQrImage(data: 'https://example.com/p', size: 200),
      ),
    );
    await tester.pumpWidget(qr());
    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(image.width, 400);
    await tester.pumpWidget(qr());
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(image),
      reason: 'a rebuild must not draw the code again',
    );
    final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    int red(int x, int y) => bytes.getUint8((y * image.width + x) * 4);
    expect(red(4, 4), 255); // White quiet zone.
    expect(red(36, 36), 0); // The finder pattern's dark edge.
  });
}
