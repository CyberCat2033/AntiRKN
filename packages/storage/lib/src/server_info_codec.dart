import 'package:antirkn_domain/antirkn_domain.dart';

// Retain display metrics, never cached privileges or live port/service state.
const _cachedFacts = {
  ServerFact.freeDiskKiB,
  ServerFact.totalDiskKiB,
  ServerFact.networkTraffic,
};
Map<String, Object?> encodeServerInfo(ServerInfo info) => {
  'os': info.os,
  'architecture': info.architecture,
  'observedAt': info.observedAt.toUtc().toIso8601String(),
  'publicAddresses': info.publicAddresses?.map((ip) => ip.canonical).toList(),
  'software': info.software == null
      ? null
      : {
          'observedAt': info.software!.observedAt.toUtc().toIso8601String(),
          'facts': {
            for (final entry in info.software!.facts.entries)
              if (_cachedFacts.contains(entry.key))
                entry.key.name: {
                  'status': entry.value.status.name,
                  'value': entry.value.value,
                },
          },
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
    publicAddresses: (data['publicAddresses'] as List?)
        ?.map((ip) => IpAddress.parse(ip as String))
        .toList(growable: false),
    software: software == null
        ? null
        : ServerSoftwareInventory(
            observedAt: DateTime.parse(software['observedAt'] as String),
            facts: {
              for (final fact in _cachedFacts)
                if ((software['facts'] as Map?)?[fact.name]
                    case final Map value)
                  fact: value['status'] == InventoryStatus.ok.name
                      ? InventoryValue.ok(value['value'] as String)
                      : InventoryValue.failure(
                          InventoryStatus.values.byName(
                            value['status'] as String,
                          ),
                        ),
            },
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
