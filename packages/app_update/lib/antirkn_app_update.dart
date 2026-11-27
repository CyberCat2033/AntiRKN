/// Adapters of the signed application update: GitHub feed and downloader,
/// Ed25519, the state file and the desktop installers. No Flutter: the
/// Android installer and the wiring live in the app.
library;

export 'src/desktop_installers.dart';
export 'src/ed25519.dart' show Ed25519UpdateVerifier, Sha256Stream;
export 'src/github_http.dart';
export 'src/tar_extract.dart';
export 'src/trusted_keys.dart';
