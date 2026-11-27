# Changelog

All notable user-facing changes to AntiRKN are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Signed in-app updates from GitHub Releases for Android, Windows and Linux.

### Changed

- Settings → Updates now controls app updates; server component checks are always on.

### Fixed

- After a sync from another device, a server whose last operation came from that device is no longer reported as "another device is applying changes" forever: its state is read again, and the app stops re-checking it every two seconds.
- Reading servers again after a sync waits for a connection that is still being established, instead of reporting "Connect to this server" until Retry.

## [0.1.0] - 2026-11-27

### Added

- First release: VPS setup and management over SSH with the `antirkn-runner` service on Ubuntu.
- VLESS, TrustTunnel and AmneziaWG resources, client users and Mihomo profile compilation.
- Encrypted local storage, backups and Google Drive synchronization.
