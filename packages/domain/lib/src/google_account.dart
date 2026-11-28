import 'sync_transport.dart';

final class GoogleDriveAccount {
  const GoogleDriveAccount({
    required this.permissionId,
    required this.email,
    required this.displayName,
    this.photoUrl,
  });
  final String permissionId, email, displayName;

  /// The account picture served by Google. Read data keeps it only when it
  /// is a Google content URL, so the UI never loads an arbitrary address.
  final String? photoUrl;

  static bool validPhotoUrl(String value) {
    if (value.length > 2048) return false;
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        (uri.host == 'googleusercontent.com' ||
            uri.host.endsWith('.googleusercontent.com'));
  }

  Map<String, Object?> toJson() => {
    'id': permissionId,
    'email': email,
    'name': displayName,
    if (photoUrl != null) 'photo': photoUrl,
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
      // An old or foreign value is dropped, not an error: the picture is
      // decoration.
      photoUrl: switch (value['photo']) {
        final String photo when validPhotoUrl(photo) => photo,
        _ => null,
      },
    );
  }
  @override
  bool operator ==(Object other) =>
      other is GoogleDriveAccount &&
      other.permissionId == permissionId &&
      other.email == email &&
      other.displayName == displayName &&
      other.photoUrl == photoUrl;
  @override
  int get hashCode => Object.hash(permissionId, email, displayName, photoUrl);
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

/// Each access renewal reads the identity from Drive. The same account with
/// another name, e-mail or picture replaces the stored one, so a profile
/// stored before a field existed (or changed in Google) catches up without a
/// new sign-in. [account] is the latest one; null when signed out.
abstract interface class GoogleAccountProfileSource {
  GoogleDriveAccount? get account;
}

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
