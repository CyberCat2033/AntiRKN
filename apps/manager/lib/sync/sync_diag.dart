import 'package:flutter/foundation.dart';

String? _last;

/// Field diagnostics of sync and the server re-read after a cloud pull,
/// read with `adb logcat -s flutter`. Codes, flags and internal ids only:
/// never hosts, credentials, secrets or upstream text.
///
/// A release build writes them on Android only, where logcat is the way to
/// read them; a desktop release keeps its terminal quiet. The same line in
/// a row (each idle autosync exchange) is written once.
void syncDiag(String message) {
  if (kReleaseMode && defaultTargetPlatform != TargetPlatform.android) return;
  if (message == _last) return;
  _last = message;
  debugPrint('sync_diag $message');
}
