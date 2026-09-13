import 'package:antirkn_domain/antirkn_domain.dart';

/// Fixed read-only commands; no hostname, unit name or remote output is shell code.
/// Markers separate unavailable tools / denied access from successful empty data.
abstract final class InventoryProbes {
  static const prefix =
      'LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export LC_ALL PATH; ';
  static const facts = <ServerFact, String>{
    ServerFact.kernel: 'uname -r',
    ServerFact.init: 'cat /proc/1/comm',
    ServerFact.cpuCount: 'getconf _NPROCESSORS_ONLN',
    ServerFact.memoryKiB: "awk '/^MemTotal:/ {print \$2}' /proc/meminfo",
    ServerFact.availableMemoryKiB:
        "awk '/^MemAvailable:/ {print \$2}' /proc/meminfo",
    ServerFact.freeDiskKiB: "df -Pk / | awk 'NR==2 {print \$4}'",
    ServerFact.uid: 'id -u',
    ServerFact.tools:
        'for t in apt-get dpkg-query systemctl docker sudo; do if command -v "\$t" >/dev/null 2>&1; then printf "%s\\n" "\$t"; fi; done',
  };
  static const patterns =
      "'x-ui*.service' 'xray*.service' 'trusttunnel*.service' 'awg-quick@*.service' 'amneziawg*.service'";
  static const services =
      'if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then printf "@unavailable\\n"; else systemctl list-units --all --type=service --no-legend --plain --no-pager --full $patterns; fi';
  static const serviceFiles =
      'if ! command -v systemctl >/dev/null 2>&1; then printf "@unavailable\\n"; else systemctl list-unit-files --type=service --no-legend --no-pager --full; fi';
  static const containers =
      r'''if [ ! -S /var/run/docker.sock ]; then printf '@unavailable\n';
elif ! command -v docker >/dev/null 2>&1; then printf '@denied\n';
elif [ -r /var/run/docker.sock ] && [ -w /var/run/docker.sock ]; then
DOCKER_CONTEXT= DOCKER_TLS_VERIFY= docker --host unix:///var/run/docker.sock ps --all --no-trunc --format '{{json .ID}}\t{{json .Image}}\t{{json .State}}\t{{json .Names}}';
elif command -v sudo >/dev/null 2>&1; then
sudo -n -- docker --host unix:///var/run/docker.sock ps --all --no-trunc --format '{{json .ID}}\t{{json .Image}}\t{{json .State}}\t{{json .Names}}' 2>/dev/null || printf '@denied\n';
else printf '@denied\n'; fi''';
  static const module = r'''if [ -d /sys/module/amneziawg ]; then
if [ -r /sys/module/amneziawg/version ]; then cat /sys/module/amneziawg/version; else printf '@present\n'; fi
else printf '@missing\n'; fi''';

  static const binaries = <String, VpnComponent>{
    '/usr/local/x-ui/x-ui': VpnComponent.panel,
    '/usr/local/x-ui/bin/xray-linux-amd64': VpnComponent.xray,
    '/usr/local/bin/xray': VpnComponent.xray,
    '/usr/bin/xray': VpnComponent.xray,
    '/opt/trusttunnel/trusttunnel_endpoint': VpnComponent.trustTunnel,
    '/usr/local/bin/trusttunnel_endpoint': VpnComponent.trustTunnel,
    '/usr/bin/awg': VpnComponent.amneziaWg,
    '/usr/local/bin/awg': VpnComponent.amneziaWg,
    '/usr/bin/amneziawg-go': VpnComponent.amneziaWg,
    '/usr/local/bin/amneziawg-go': VpnComponent.amneziaWg,
  };

  static String binaryPresence(String path) {
    if (!binaries.containsKey(path)) throw ArgumentError('Unknown probe');
    final parents = <String>[];
    var parent = path.substring(0, path.lastIndexOf('/'));
    while (parent.isNotEmpty) {
      parents.insert(0, parent);
      parent = parent.substring(0, parent.lastIndexOf('/'));
    }
    return 'for p in ${parents.join(' ')}; do '
        'if [ -d "\$p" ] && [ ! -x "\$p" ]; then printf "@denied\\n"; exit 0; fi; done; '
        'if [ -f $path ]; then printf "@present\\n"; '
        'elif [ -e $path ] || [ -L $path ]; then printf "@denied\\n"; '
        'else printf "@missing\\n"; fi';
  }

  static String version(String path) {
    final flag = switch (binaries[path]) {
      VpnComponent.panel => '-v',
      VpnComponent.xray => 'version',
      VpnComponent.trustTunnel || VpnComponent.amneziaWg => '--version',
      null => throw ArgumentError('Unknown probe'),
    };
    return 'if [ ! -x $path ]; then printf "@denied\\n"; else $path $flag; fi';
  }

  static const containerBinaries = ['amneziawg-go', 'awg'];

  static String containerVersion(String id, String binary) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        !containerBinaries.contains(binary)) {
      throw ArgumentError('Unknown container probe');
    }
    // Only version flags, no configuration, environment, peer keys or logs.
    final script =
        'for p in /usr/bin/$binary /usr/local/bin/$binary; do '
        'if [ -f "\$p" ]; then '
        'if [ ! -x "\$p" ]; then printf "@denied\\n"; exit 0; fi; '
        'exec "\$p" --version; fi; done; printf "@missing\\n"';
    final read =
        "docker --host unix:///var/run/docker.sock exec $id /bin/sh -c '$script'";
    return 'if [ ! -S /var/run/docker.sock ]; then printf "@unavailable\\n"; '
        'elif ! command -v docker >/dev/null 2>&1; then printf "@denied\\n"; '
        'elif [ -r /var/run/docker.sock ] && [ -w /var/run/docker.sock ]; then '
        'DOCKER_CONTEXT= DOCKER_TLS_VERIFY= $read; '
        'elif command -v sudo >/dev/null 2>&1; then '
        'sudo -n -- $read 2>/dev/null || printf "@denied\\n"; '
        'else printf "@denied\\n"; fi';
  }

  static bool isAllowedCommand(String command) {
    if (allowedCommands.contains(command)) return true;
    final id = RegExp(
      r' exec ([a-f0-9]{64}) /bin/sh -c ',
    ).firstMatch(command)?[1];
    return id != null &&
        containerBinaries.any(
          (binary) => command == '$prefix${containerVersion(id, binary)}',
        );
  }

  static bool canElevate(String command) =>
      isAllowedCommand(command) &&
      !facts.values.any((fact) => command == '$prefix$fact');

  static String sockets(SocketProtocol protocol, IpFamily family) =>
      'ss -H -n ${protocol == SocketProtocol.tcp ? '-l -t' : '-a -u'} ${family == IpFamily.ipv4 ? '-4' : '-6'}';

  static Set<String> get allowedCommands => {
    ...facts.values,
    services,
    serviceFiles,
    containers,
    module,
    for (final path in binaries.keys) ...[binaryPresence(path), version(path)],
    for (final protocol in SocketProtocol.values)
      for (final family in IpFamily.values) sockets(protocol, family),
  }.map((command) => '$prefix$command').toSet();
}
