import 'package:antirkn_domain/antirkn_domain.dart';

/// Public Ed25519 keys this build accepts for update manifests. Public, so
/// committed: `k1` signs releases in CI, `k2` is the offline reserve for
/// rotation. Empty until the owner generates the keys: the app then reports
/// that updates are unavailable in this build.
const appUpdateTrustedKeys = <AppUpdateTrustedKey>[];
