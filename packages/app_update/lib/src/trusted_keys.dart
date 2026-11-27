import 'package:antirkn_domain/antirkn_domain.dart';

/// Public Ed25519 keys this build accepts for update manifests. Public, so
/// committed: `k1` signs releases in CI, `k2` is the offline reserve for
/// rotation. An empty list means updates are unavailable in this build.
const appUpdateTrustedKeys = <AppUpdateTrustedKey>[
  AppUpdateTrustedKey('k1', 'jUyqrWFylBE36fbpDvhWqjoH7YsDgCOT5ikwL2egpb8'),
  AppUpdateTrustedKey('k2', 'j_JW6mumWS5XTzwRl4ORyV6w1GN_dCtXs2PCxGjV2Nc'),
];
