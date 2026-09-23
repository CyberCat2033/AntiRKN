# AntiRKN

AntiRKN is an app for managing personal VPN infrastructure on Android, Linux and Windows. It connects to your Ubuntu server over SSH, manages VLESS, AmneziaWG and TrustTunnel connections, creates client configurations, and can synchronize the workspace through your own Google Drive account. The app is under active development; this repository contains source code, not a signed release.

Google Drive access is used for two features:

- `drive.appdata`: synchronize encrypted workspace data between your devices in the private app data folder.
- `drive.file`: create and update configuration files that you choose to publish in your Drive. A published file may be shared by its link according to the access setting you select.

The app displays your Google account name and email to identify the connected account. OAuth tokens remain in local application storage. [Privacy policy](PRIVACY.md) · [Google Drive setup](docs/google-drive-setup.md)

## Build from source

Install Flutter 3.41.x with Dart 3.11.x and the platform tools for your target system. From the repository root:

```sh
flutter pub get --enforce-lockfile
cd apps/manager
flutter run -d linux
```

For Android, configure your own Google Cloud OAuth clients as described in the [Drive setup guide](docs/google-drive-setup.md). Client secrets, OAuth tokens and user data must stay outside the repository. Local checks are available through `bash tool/verify.sh`.
