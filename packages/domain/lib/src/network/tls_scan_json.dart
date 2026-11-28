/// The worker's TLS scan JSON, also the checkpoint format of a search.
library;

import 'tls_scan.dart';

const _reach = {
  'ok': TlsReach.ok,
  'refused': TlsReach.refused,
  'timeout': TlsReach.timeout,
  'unreachable': TlsReach.unreachable,
  'skipped': TlsReach.skipped,
};
const _handshake = {
  '': TlsHandshake.none,
  'ok': TlsHandshake.ok,
  'timeout': TlsHandshake.timeout,
  'reset': TlsHandshake.reset,
  'alert': TlsHandshake.alert,
  'failed': TlsHandshake.failed,
};
const _check = {
  'valid': TlsCertificateCheck.valid,
  'chain_only': TlsCertificateCheck.chainOnly,
  'expired': TlsCertificateCheck.expired,
  'name_mismatch': TlsCertificateCheck.nameMismatch,
  'untrusted': TlsCertificateCheck.untrusted,
};
const _dns = {
  '': TlsDnsCheck.notChecked,
  'match': TlsDnsCheck.match,
  'mismatch': TlsDnsCheck.mismatch,
  'unresolved': TlsDnsCheck.unresolved,
};
const _versions = {'', '1.3', '1.2', 'other'};
const _alpn = {'', 'h2', 'http/1.1'};
const _groups = {
  '',
  'other',
  'X25519MLKEM768',
  'X25519',
  'CurveP256',
  'CurveP384',
  'CurveP521',
  'SecP256r1MLKEM768',
  'SecP384r1MLKEM1024',
};
const _refusals = {
  'invalid_request',
  'private_target',
  'input_limit',
  'unsupported_route',
  'core_failure',
};
final _name = RegExp(r'^(\*\.)?[a-z0-9.-]{1,253}$');

T _one<T>(Map<String, T> values, Object? key) =>
    key is String && values.containsKey(key)
    ? values[key] as T
    : throw const FormatException('worker_result');

Duration _ms(Object? value) => value is int && value >= 0 && value <= 15000
    ? Duration(milliseconds: value)
    : throw const FormatException('worker_result');

String _hint(Object? value) =>
    value is String &&
        value.length <= 64 &&
        !value.contains(RegExp(r'[\x00-\x1f\x7f]'))
    ? value
    : throw const FormatException('worker_result');

DateTime _time(Object? value) => value is int
    ? DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true)
    : throw const FormatException('worker_result');

/// Strict reading of one worker answer for exactly [targets], in order.
/// Anything unexpected is a [FormatException], never a partial result.
TlsScanBatch parseTlsScan(
  Map<String, dynamic> json,
  List<TlsScanTarget> targets,
) {
  final probes = json['probes'];
  if (probes is! List) throw const FormatException('worker_result');
  if (json['status'] == 'not_tested') {
    final code = json['code'];
    if (code is! String || !_refusals.contains(code) || probes.isNotEmpty) {
      throw const FormatException('worker_result');
    }
    return TlsScanBatch(status: TlsScanStatus.notTested, code: code);
  }
  if (json['status'] != 'ok' ||
      json['code'] != 'scanned' ||
      probes.length != targets.length) {
    throw const FormatException('worker_result');
  }
  return TlsScanBatch(
    status: TlsScanStatus.scanned,
    code: 'scanned',
    probes: [
      for (var i = 0; i < targets.length; i++)
        parseTlsProbe(probes[i], targets[i]),
    ],
  );
}

/// Reads one observation of [target], as written by the worker or [tlsProbeJson].
TlsProbeResult parseTlsProbe(Object? raw, TlsScanTarget target) {
  if (raw is! Map ||
      raw['ip'] != target.ip.canonical ||
      raw['port'] != target.port ||
      raw['sni'] != target.sni) {
    throw const FormatException('worker_result');
  }
  final reach = _one(_reach, raw['reach']);
  final handshake = _one(_handshake, raw['tls']);
  final version = raw['version'], alpn = raw['alpn'], group = raw['group'];
  final dns = _one(_dns, raw['dns']);
  if (!_versions.contains(version) ||
      !_alpn.contains(alpn) ||
      !_groups.contains(group) ||
      (reach != TlsReach.ok) != (handshake == TlsHandshake.none) ||
      (handshake == TlsHandshake.ok) != (version != '') ||
      dns != TlsDnsCheck.notChecked && target.sni.isEmpty) {
    throw const FormatException('worker_result');
  }
  final cert = raw['certificate'];
  if (cert != null && (cert is! Map || handshake != TlsHandshake.ok)) {
    throw const FormatException('worker_result');
  }
  return TlsProbeResult(
    target: target,
    reach: reach,
    handshake: handshake,
    tcp: _ms(raw['tcpMs']),
    tls: _ms(raw['tlsMs']),
    version: version as String,
    alpn: alpn as String,
    group: group as String,
    certificate: cert is Map ? _certificate(cert, target) : null,
    dns: dns,
  );
}

TlsCertificateInfo _certificate(Map<dynamic, dynamic> raw, TlsScanTarget t) {
  final names = raw['names'], total = raw['namesTotal'];
  if (names is! List ||
      names.length > 8 ||
      total is! int ||
      total < names.length ||
      total > 10000 ||
      !names.every((n) => n is String && _name.hasMatch(n))) {
    throw const FormatException('worker_result');
  }
  final check = _one(_check, raw['verify']);
  if ((check == TlsCertificateCheck.chainOnly) != t.sni.isEmpty &&
      check != TlsCertificateCheck.expired &&
      check != TlsCertificateCheck.untrusted) {
    throw const FormatException('worker_result');
  }
  return TlsCertificateInfo(
    names: names.cast<String>(),
    namesTotal: total,
    commonName: _hint(raw['commonName']),
    issuer: _hint(raw['issuer']),
    notBefore: _time(raw['notBefore']),
    notAfter: _time(raw['notAfter']),
    check: check,
  );
}

String _key<T>(Map<String, T> values, T value) =>
    values.entries.firstWhere((e) => e.value == value).key;

/// Exactly the worker's form, so [parseTlsProbe] validates a checkpoint too.
Map<String, Object?> tlsProbeJson(TlsProbeResult p) {
  final c = p.certificate;
  return {
    ...p.target.toJson(),
    'reach': _key(_reach, p.reach),
    'tls': _key(_handshake, p.handshake),
    'tcpMs': p.tcp.inMilliseconds,
    'tlsMs': p.tls.inMilliseconds,
    'version': p.version,
    'alpn': p.alpn,
    'group': p.group,
    if (c != null)
      'certificate': {
        'names': c.names,
        'namesTotal': c.namesTotal,
        'commonName': c.commonName,
        'issuer': c.issuer,
        'notBefore': c.notBefore.millisecondsSinceEpoch ~/ 1000,
        'notAfter': c.notAfter.millisecondsSinceEpoch ~/ 1000,
        'verify': _key(_check, c.check),
      },
    'dns': _key(_dns, p.dns),
  };
}
