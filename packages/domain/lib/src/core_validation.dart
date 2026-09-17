import 'ssh.dart';

enum CoreConfigStatus { valid, invalid, incomplete, cancelled, unavailable }

final class CoreConfigCheck {
  const CoreConfigCheck({
    required this.status,
    required this.code,
    required this.profileHash,
    required this.checkedAt,
    this.version = '',
    this.resourcesHash = '',
    this.path,
  });
  final CoreConfigStatus status;
  final String code, profileHash, version, resourcesHash;
  final DateTime checkedAt;
  final String? path;
  @override
  String toString() => 'CoreConfigCheck(${status.name}, $code)';
}

abstract interface class CoreConfigValidator {
  Future<CoreConfigCheck> validate(String yaml, CancellationToken cancellation);
}
