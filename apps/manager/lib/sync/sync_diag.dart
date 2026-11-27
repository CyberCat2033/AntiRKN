import 'package:flutter/foundation.dart';

/// Field diagnostics of sync and the server re-read after a cloud pull,
/// read with `adb logcat -s flutter`. Codes, flags and internal ids only:
/// never hosts, credentials, secrets or upstream text.
void syncDiag(String message) => debugPrint('sync_diag $message');
