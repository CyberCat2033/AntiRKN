# AntiRKN privacy policy

Last updated: 2026-11-28

AntiRKN helps you manage your own VPN servers and client configurations. It connects to servers you add and, if you enable Google Drive features, to the Google account you authorize. The project does not operate an application backend that receives your workspace data.

## Data used

- Server addresses, credentials, client details and configuration material are stored in your local application workspace. The app uses them to connect to your servers and generate VPN configurations.
- When you sign in to Google, the app shows the connected account's name and email. It stores OAuth credentials locally so it can continue the Drive operations you authorized.
- With `drive.appdata`, the app stores encrypted workspace data and synchronization metadata in the private application data folder of your Google Drive account. Synchronization keys are also made available to your authorized installations through this folder. This setup does not protect those keys from Google as the storage provider.
- With `drive.file`, the app creates and updates the client configuration files that you choose to publish. A configuration can contain server addresses and client access credentials. If you enable link sharing, anyone with the link may be able to read that file.

AntiRKN uses Google data only to show the signed-in account, synchronize your workspace and manage the Drive files you choose to publish. The project does not sell Google user data or use it for advertising.

## Network connections

The app connects only to:

- the servers you add, over SSH;
- Google APIs, only if you sign in to Google;
- GitHub (`api.github.com`, `github.com` and its release file hosts), to check versions of server components and, if app updates are enabled in Settings → Updates, to download the signed update manifest and release files. These requests carry no account or device identifiers, but GitHub, like any web server, sees your IP address.
- public measurement addresses during network and connection checks: well-known public DNS resolvers (Cloudflare, Google, Quad9, AdGuard, Yandex), RIPE Atlas anchors and test pages such as `1.1.1.1/cdn-cgi/trace` and `www.gstatic.com/generate_204`. Only reachability is measured; no data about you or your workspace is sent. The list is documented in `docs/ip-diagnostics.md`.
- when you start a REALITY target search (VLESS form → Find): TLS handshakes from your device to the addresses you choose — by default the neighbours of your server in its /24 — at most 1024 addresses, with the certificate names of those addresses as SNI. Only TLS properties and certificates are read; nothing about you or your workspace is sent. If you check a candidate's connection, your device downloads 100 KB from `speed.cloudflare.com` through a temporary inbound on your server.

There is no analytics, crash reporting or other telemetry.

## Your choices and deletion

You can disconnect your Google account in the app and revoke AntiRKN's access in your Google Account settings. Disconnecting stops future access from that installation; it does not automatically erase files already stored in Drive. You can delete published files in Google Drive. For synchronized application data, remove AntiRKN data from your Google Drive application data settings. Removing local application data deletes the local copy; make sure you have any backup you need first.

For questions about this policy, open an issue in this repository.

See also the [disclaimer](DISCLAIMER.md).
