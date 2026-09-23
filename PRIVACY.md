# AntiRKN privacy policy

Last updated: 2026-09-23

AntiRKN helps you manage your own VPN servers and client configurations. It connects to servers you add and, if you enable Google Drive features, to the Google account you authorize. The project does not operate an application backend that receives your workspace data.

## Data used

- Server addresses, credentials, client details and configuration material are stored in your local application workspace. The app uses them to connect to your servers and generate VPN configurations.
- When you sign in to Google, the app shows the connected account's name and email. It stores OAuth credentials locally so it can continue the Drive operations you authorized.
- With `drive.appdata`, the app stores encrypted workspace data and synchronization metadata in the private application data folder of your Google Drive account. Synchronization keys are also made available to your authorized installations through this folder. This setup does not protect those keys from Google as the storage provider.
- With `drive.file`, the app creates and updates the client configuration files that you choose to publish. A configuration can contain server addresses and client access credentials. If you enable link sharing, anyone with the link may be able to read that file.

AntiRKN uses Google data only to show the signed-in account, synchronize your workspace and manage the Drive files you choose to publish. The project does not sell Google user data or use it for advertising.

## Your choices and deletion

You can disconnect your Google account in the app and revoke AntiRKN's access in your Google Account settings. Disconnecting stops future access from that installation; it does not automatically erase files already stored in Drive. You can delete published files in Google Drive. For synchronized application data, remove AntiRKN data from your Google Drive application data settings. Removing local application data deletes the local copy; make sure you have any backup you need first.

For questions about this policy, open an issue in this repository.
