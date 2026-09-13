import 'package:antirkn_domain/antirkn_domain.dart';

// Keep component metadata/versions. Runtime resource/port snapshots are not
// persisted: the next SSH observation supplies their current values.
Map<String, Object?> encodeServerInfo(ServerInfo info) => {
  'os': info.os,
  'architecture': info.architecture,
  'observedAt': info.observedAt.toUtc().toIso8601String(),
  'software': info.software == null
      ? null
      : {
          'observedAt': info.software!.observedAt.toUtc().toIso8601String(),
          'components': [
            for (final component in info.software!.components)
              {
                'component': component.component.name,
                'presence': component.presence.name,
                'issues': component.issues.map((v) => v.name).toList(),
                'installations': [
                  for (final installation in component.installations)
                    {
                      'source': installation.source.name,
                      'identity': installation.identity,
                      'version': installation.version == null
                          ? null
                          : {
                              'status': installation.version!.status.name,
                              'value': installation.version!.value,
                            },
                    },
                ],
              },
          ],
        },
};

ServerInfo decodeServerInfo(Map<String, Object?> data) {
  final software = data['software'] as Map<String, Object?>?;
  return ServerInfo(
    os: data['os'] as String,
    architecture: data['architecture'] as String,
    observedAt: DateTime.parse(data['observedAt'] as String),
    software: software == null
        ? null
        : ServerSoftwareInventory(
            observedAt: DateTime.parse(software['observedAt'] as String),
            facts: const {},
            sockets: const [],
            components: [
              for (final raw in software['components'] as List)
                _component(raw as Map<String, Object?>),
            ],
          ),
  );
}

ComponentObservation _component(Map<String, Object?> data) =>
    ComponentObservation(
      component: VpnComponent.values.byName(data['component'] as String),
      presence: ComponentPresence.values.byName(data['presence'] as String),
      issues: (data['issues'] as List).map(
        (v) => InventoryStatus.values.byName(v as String),
      ),
      installations: [
        for (final raw in data['installations'] as List)
          _installation(raw as Map<String, Object?>),
      ],
    );

ComponentInstallation _installation(Map<String, Object?> data) {
  final version = data['version'] as Map<String, Object?>?;
  return ComponentInstallation(
    source: InstallationSource.values.byName(data['source'] as String),
    identity: data['identity'] as String,
    version: version == null
        ? null
        : version['status'] == InventoryStatus.ok.name
        ? InventoryValue.ok(version['value'] as String)
        : InventoryValue.failure(
            InventoryStatus.values.byName(version['status'] as String),
          ),
  );
}
