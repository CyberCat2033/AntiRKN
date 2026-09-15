/// Ownership of an approved operation, replicated alongside its request and
/// result. The runner serializes jobs and deduplicates their immutable IDs.
/// This metadata is not a distributed lock.
final class ServerOperation {
  const ServerOperation({
    required this.operationId,
    required this.executorDeviceId,
    this.expectedRevision,
  });

  factory ServerOperation.fromJson(Map value) {
    final id = value['operationId'], device = value['executorDeviceId'];
    final revision = value['expectedRevision'];
    if (value['version'] != 1 ||
        id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        device is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(device) ||
        (revision != null &&
            (revision is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision)))) {
      throw const FormatException('operation_invalid');
    }
    return ServerOperation(
      operationId: id,
      executorDeviceId: device,
      expectedRevision: revision as String?,
    );
  }

  final String operationId, executorDeviceId;

  /// Server plan fingerprint. Absent before preparing an offline intent or for
  /// jobs without a state precondition, such as updating the APT index.
  final String? expectedRevision;

  void validatePending(Map? request) {
    if (request != null &&
        (request['id'] != operationId ||
            request['fingerprint'] != expectedRevision)) {
      throw const FormatException('operation_invalid');
    }
  }

  ServerOperation withExecutor(String deviceId) => ServerOperation(
    operationId: operationId,
    executorDeviceId: deviceId,
    expectedRevision: expectedRevision,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'operationId': operationId,
    'executorDeviceId': executorDeviceId,
    'expectedRevision': expectedRevision,
  };
}
