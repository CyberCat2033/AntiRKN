import 'sync_transport.dart';

final class GoogleDriveAccount {
  const GoogleDriveAccount({
    required this.permissionId,
    required this.email,
    required this.displayName,
  });
  final String permissionId, email, displayName;
  Map<String, Object?> toJson() => {
    'id': permissionId,
    'email': email,
    'name': displayName,
  };
  factory GoogleDriveAccount.fromJson(Map<String, dynamic> value) {
    final id = value['id'], email = value['email'], name = value['name'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 256 ||
        email is! String ||
        email.isEmpty ||
        email.length > 320 ||
        name is! String ||
        name.length > 512) {
      throw const FormatException('google_account');
    }
    return GoogleDriveAccount(
      permissionId: id,
      email: email,
      displayName: name,
    );
  }
  @override
  String toString() => 'GoogleDriveAccount(<private>)';
}

enum GoogleAccountIssue {
  unavailable,
  configuration,
  denied,
  network,
  storage,
  reauthorize,
  busy,
}

final class GoogleAccountFailure implements Exception {
  const GoogleAccountFailure(this.issue);
  final GoogleAccountIssue issue;
  @override
  String toString() => 'GoogleAccountFailure(${issue.name})';
}

abstract interface class GoogleAccountService {
  bool get supported;
  Future<GoogleDriveAccount?> restore();

  /// Null means the user cancelled. It does not replace an existing account.
  Future<GoogleDriveAccount?> signIn();

  /// Disconnects this installation; does not erase Drive or other devices.
  Future<void> signOut();
}

abstract interface class GoogleSyncAccountService
    implements GoogleAccountService, SyncAccessTokenProvider {}

/// Desktop browser authorization can outlive the settings screen.
abstract interface class CancelableGoogleSignIn {
  void cancelSignIn();
  Future<void> close();
}

/// User-initiated, additional Drive file consent. Sync-only sessions continue
/// working until publication is explicitly enabled on this installation.
abstract interface class GooglePublicationAuthorization {
  bool get publicationAuthorized;
  Future<GoogleDriveAccount?> authorizePublications();
}
