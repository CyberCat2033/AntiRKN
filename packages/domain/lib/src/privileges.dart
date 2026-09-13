/// Observations belong to the current SSH session, never to an offline profile.
enum PrivilegeStatus {
  root,
  sudoWithoutPassword,
  sudoWithPassword,
  passwordRequired,
  authenticationFailed,
  denied,
  unavailable,
  terminalRequired,
  invalidPassword,
}

final class PrivilegeCheck {
  const PrivilegeCheck(this.status);
  final PrivilegeStatus status;
  bool get granted => const {
    PrivilegeStatus.root,
    PrivilegeStatus.sudoWithoutPassword,
    PrivilegeStatus.sudoWithPassword,
  }.contains(status);
}

/// sudo's line-oriented password input cannot represent these characters.
bool validSudoPassword(String? value) =>
    value == null ||
    (value.length <= 1024 && !RegExp(r'[\x00\r\n]').hasMatch(value));
