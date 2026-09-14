import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

String realityTargetHost(String target) {
  try {
    final uri = Uri.parse('tcp://${target.trim()}');
    if (uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return '';
    }
    final host = uri.host.replaceAll('[', '').replaceAll(']', '');
    // IP addresses cannot supply a DNS SNI; the scan can still show certificate names.
    if (host.contains(':') || RegExp(r'^[0-9.]+$').hasMatch(host)) return '';
    return host;
  } catch (_) {
    return '';
  }
}

String normalizeRealityTarget(String target) {
  try {
    final uri = Uri.parse('tcp://$target');
    return uri.hasPort ? target : '$target:443';
  } catch (_) {
    return target;
  }
}

class RealityScanResultView extends StatelessWidget {
  const RealityScanResultView({
    required this.result,
    required this.onSni,
    super.key,
  });
  final Map<String, dynamic> result;
  final ValueChanged<String> onSni;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), ok = result['feasible'] == true;
    final reason = result['privateTarget'] == true
        ? l.realityScanPrivate
        : result['tlsVersion'] == null || result['tlsVersion'] == ''
        ? l.realityScanUnavailable
        : result['certValid'] != true
        ? l.realityScanCertificate
        : result['tls13'] != true
        ? l.realityScanTls
        : result['h2'] != true
        ? l.realityScanH2
        : l.realityScanCurve;
    final details = {
      l.realitySniUsed: result['host'],
      'TLS': result['tlsVersion'],
      'ALPN': result['alpn'],
      l.realityKeyExchange: result['curveID'],
      l.realityCertificate: [
        result['certSubject'],
        result['certIssuer'],
      ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
      l.realityCertificateExpiry: result['notAfter'],
      l.realityLatency: result['latencyMs'],
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            children: [
              Icon(ok ? Icons.check_circle_outline : Icons.info_outline),
              Text(ok ? l.realityFeasible : l.realityNotFeasible),
            ],
          ),
          if (!ok) Text(reason),
          for (final entry in details.entries)
            Text(
              '${entry.key}: ${entry.value == null || entry.value == '' ? '—' : entry.value}',
            ),
          if ((result['serverNames'] as List? ?? []).isNotEmpty) ...[
            Text(l.realityCertificateNames),
            Wrap(
              spacing: 8,
              children: [
                for (final name
                    in (result['serverNames'] as List).whereType<String>().take(
                      32,
                    ))
                  ActionChip(label: Text(name), onPressed: () => onSni(name)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
