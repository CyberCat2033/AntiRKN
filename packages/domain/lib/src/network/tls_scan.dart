import '../ssh.dart';
import 'ip_address.dart';

/// FR-SNI: TLS observations of REALITY target candidates, made from this
/// device. An observation is never proof that REALITY works through a target.

final _sni = RegExp(
  r'^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$',
);

/// One concrete DNS name: no wildcard, IP literal or upper case.
bool isTlsScanSni(String name) =>
    name.isNotEmpty &&
    name.length <= 253 &&
    _sni.hasMatch(name) &&
    IpAddress.tryParse(name) == null;

/// One public IP:port; an empty [sni] probes the default virtual host.
final class TlsScanTarget {
  TlsScanTarget(String ip, this.port, {this.sni = ''})
    : ip =
          IpAddress.tryParse(ip) ??
          (throw const FormatException('tls_scan_target')) {
    if (port < 1 ||
        port > 65535 ||
        sni.isNotEmpty && !isTlsScanSni(sni) ||
        this.ip.category != IpCategory.publicUnicast) {
      throw const FormatException('tls_scan_target');
    }
  }
  final IpAddress ip;
  final int port;
  final String sni;

  String get key => '${ip.canonical}|$port|$sni';
  Map<String, Object?> toJson() => {
    'ip': ip.canonical,
    'port': port,
    'sni': sni,
  };
  @override
  bool operator ==(Object other) => other is TlsScanTarget && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// Per-address limits of one session; FR-SNI-02 starts at 10 connections.
final class TlsScanLimits {
  const TlsScanLimits({
    this.concurrency = 10,
    this.connect = const Duration(milliseconds: 1500),
    this.handshake = const Duration(milliseconds: 3000),
  });
  final int concurrency;
  final Duration connect, handshake;

  static const maxBatch = 16, maxConcurrency = 16;

  /// Worst case one worker run may take; the worker itself stops at 15 s.
  static const budget = Duration(seconds: 12);

  bool get valid =>
      concurrency >= 1 &&
      concurrency <= maxConcurrency &&
      connect.inMilliseconds >= 300 &&
      connect.inMilliseconds <= 3000 &&
      handshake.inMilliseconds >= 500 &&
      handshake.inMilliseconds <= 5000;

  /// Largest batch whose every address can time out within [budget].
  int get batchSize {
    if (!valid) return 0;
    final rounds =
        budget.inMilliseconds ~/
        (connect.inMilliseconds + handshake.inMilliseconds);
    return (rounds * concurrency).clamp(0, maxBatch);
  }
}

enum TlsReach { ok, refused, timeout, unreachable, skipped }

/// [none]: TCP did not connect, so no handshake was attempted.
enum TlsHandshake { none, ok, timeout, reset, alert, failed }

/// Separate from the handshake, which accepts any certificate to observe it.
/// [chainOnly]: a probe without SNI has no name to match.
enum TlsCertificateCheck { valid, chainOnly, expired, nameMismatch, untrusted }

/// Whether the SNI's A/AAAA records contain the probed address.
enum TlsDnsCheck { notChecked, match, mismatch, unresolved }

final class TlsCertificateInfo {
  TlsCertificateInfo({
    required List<String> names,
    required this.namesTotal,
    required this.commonName,
    required this.issuer,
    required this.notBefore,
    required this.notAfter,
    required this.check,
  }) : names = List.unmodifiable(names);

  /// Up to eight SAN DNS names; a wildcard is kept as observed, never as SNI.
  final List<String> names;
  final int namesTotal;

  /// Hints only: a missing CN or organization never disqualifies a target.
  final String commonName, issuer;
  final DateTime notBefore, notAfter;
  final TlsCertificateCheck check;
}

final class TlsProbeResult {
  const TlsProbeResult({
    required this.target,
    required this.reach,
    this.handshake = TlsHandshake.none,
    this.tcp = Duration.zero,
    this.tls = Duration.zero,
    this.version = '',
    this.alpn = '',
    this.group = '',
    this.certificate,
    this.dns = TlsDnsCheck.notChecked,
  });
  final TlsScanTarget target;
  final TlsReach reach;
  final TlsHandshake handshake;
  final Duration tcp, tls;

  /// '1.3', '1.2', 'other', or '' without a handshake.
  final String version;

  /// 'h2', 'http/1.1' or '' when none was negotiated.
  final String alpn;

  /// Key exchange such as X25519MLKEM768 or X25519; 'other' or ''.
  final String group;
  final TlsCertificateInfo? certificate;
  final TlsDnsCheck dns;
}

enum TlsScanStatus { scanned, notTested, cancelled }

final class TlsScanBatch {
  TlsScanBatch({
    required this.status,
    required this.code,
    List<TlsProbeResult> probes = const [],
  }) : probes = List.unmodifiable(probes);
  final TlsScanStatus status;
  final String code;

  /// In the order of the requested targets; empty unless [status] is scanned.
  final List<TlsProbeResult> probes;
}

abstract interface class TlsScanTransport {
  /// Probes at most [TlsScanLimits.batchSize] distinct targets.
  /// [directInterface] makes the probes bypass an active device VPN.
  Future<TlsScanBatch> scan(
    List<TlsScanTarget> targets,
    CancellationToken cancellation, {
    TlsScanLimits limits = const TlsScanLimits(),
    bool resolve = true,
    String directInterface = '',
  });
}
