# Changelog

All notable user-facing changes to AntiRKN are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The licenses page lists the licenses of all Go modules built into the Mihomo core.
- Settings → About: what the app is for, open-source licenses (GPL-3.0 and components) and a link to the source code.
- The project is licensed under GPL-3.0; added a disclaimer (intended use, no warranty) and a security policy.

### Changed

- Clients tab: one status above the list, only when needed — Google sign-in, the check in progress or profiles that failed (with "Show" to narrow the list to them); a Drive or account problem is no longer repeated on every client; switching a client's access shows "Undo".
- Clients tab: one header with the add button (a floating button on phones) and a menu for checking servers and publishing; each row shows the client's traffic this month instead of the shared protocol list, an error takes one line, sorting is a menu and disabled clients fold into a group.
- Release packages for Windows and Linux include the license and disclaimer; the Windows installer shows the license.
- Settings: the sync status card is now the only entry to Synchronization and is named "Synchronization"; the duplicate list item is gone.
- README rewritten in Russian and English; the user guide and privacy policy are updated and list every network destination of the app.


## [0.1.1] - 2026-11-28

### Added

- Signed in-app updates from GitHub Releases for Android, Windows and Linux.

### Changed

- Settings → Updates now controls app updates; server component checks are always on.

### Fixed

- After a sync from another device, a server whose last operation came from that device is no longer reported as "another device is applying changes" forever: its state is read again, and the app stops re-checking it every two seconds.
- Reading servers again after a sync waits for a connection that is still being established, instead of reporting "Connect to this server" until Retry.
- Android: app updates were always reported as unavailable.
- Android: Google Drive could look signed out after the phone was idle for a long time.

## [0.1.0] - 2026-11-27

### Added

- First release: VPS setup and management over SSH with the `antirkn-runner` service on Ubuntu.
- VLESS, TrustTunnel and AmneziaWG resources, client users and Mihomo profile compilation.
- Encrypted local storage, backups and Google Drive synchronization.
