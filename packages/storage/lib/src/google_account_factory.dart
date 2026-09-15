import 'dart:io';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'android_google_account.dart';
import 'desktop_google_account.dart';
import 'workspace_database.dart';

GoogleSyncAccountService localGoogleAccountService(
  WorkspaceDatabase database,
) => Platform.isLinux || Platform.isWindows
    ? DesktopGoogleAccountService(store: database.googleSessionStore())
    : AndroidGoogleAccountService();
