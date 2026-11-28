# Changelog

All notable user-facing changes to AntiRKN are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The licenses page lists the licenses of all Go modules built into the Mihomo core.
- VLESS REALITY form: **Find** searches the server's neighbours for a suitable target and SNI from this device (TLS 1.3, HTTP/2, key exchange, verified certificate, DNS), checks the best from the server itself (3x-ui) with the server-to-target time, recommends the best with reasons, can check a candidate's connection through a temporary inbound on the server with a 100 KB download, fills Target and SNI, can stop and continue, and exports results as JSON or CSV. The best result is offered to the next inbound of the server.
- Settings → About: what the app is for, open-source licenses (GPL-3.0 and components) and a link to the source code.
- The project is licensed under GPL-3.0; added a disclaimer (intended use, no warranty) and a security policy.

### Changed

- Clients tab: on a wide window the client's card opens beside the list, with a hint until a client is chosen.
- Clients tab: tapping a client opens its card (a bottom sheet on phones, a dialog on medium windows) with the QR always in view and a one-line hint; traffic opens in place under the month and all-time cards; Edit and Delete are in the card, and the QR button is gone from the row.
- Clients tab: from seven clients a search field narrows the list by name, disabled clients included.
- Clients tab: one status above the list, only when needed — Google sign-in, the check in progress or profiles that failed (with "Show" to narrow the list to them); a Drive or account problem is no longer repeated on every client; switching a client's access shows "Undo".
- Clients tab: one header with the add button (a floating button on phones) and a menu for checking servers and publishing; each row shows the client's traffic this month instead of the shared protocol list, an error takes one line, sorting is a menu and disabled clients fold into a group.
- XHTTP inbounds get a generated path (like `/assets/k3x9q2m7wd`) when the target is checked or chosen, if the path is still `/`.
- The REALITY target check button is now called **Check**.
- Release packages for Windows and Linux include the license and disclaimer; the Windows installer shows the license.
- Settings: the sync status card is now the only entry to Synchronization and is named "Synchronization"; the duplicate list item is gone.
- README rewritten in Russian and English; the user guide and privacy policy are updated and list every network destination of the app.

### Fixed

- Updates: Ubuntu packages are checked automatically on connection (read-only, at most every 6 hours) and the result is kept across leaving the page and restarts; preparing other components no longer resets it to "Not checked". Update with an older result reads the package list again first.
- Settings → Synchronization shows the Google account picture for an account connected before pictures were kept; it is picked up at the next access renewal, without signing in again.


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
