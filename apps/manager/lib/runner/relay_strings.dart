import '../l10n/app_localizations.dart';

String relayIssue(AppLocalizations l, String code) => switch (code) {
  'relay_unsupported' => l.relayUnsupported,
  'relay_client_inbound' => l.relayClientInbound,
  'relay_conflict' => l.relayConflict,
  'relay_config_failed' => l.relayConfigFailed,
  'relay_disable_first' => l.relayDisableFirst,
  'relay_missing' => l.relayMissing,
  _ => l.relayFailed,
};
