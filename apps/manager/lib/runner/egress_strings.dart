import '../l10n/app_localizations.dart';

String egressIssue(AppLocalizations l, String code) => switch (code) {
  'egress_panel_required' => l.egressPanelRequired,
  'egress_invalid' => l.egressInvalid,
  'egress_unsupported' => l.egressUnsupported,
  'egress_namespace' => l.egressNamespace,
  'egress_conflict' => l.egressConflict,
  'egress_disable_first' => l.egressDisableFirst,
  'egress_port_busy' => l.egressPortBusy,
  'egress_loop' => l.egressLoop,
  'egress_config_failed' => l.egressConfigFailed,
  'egress_network' => l.egressNetwork,
  'egress_probe_failed' => l.egressProbeFailed,
  'egress_rollback_failed' => l.egressRollbackFailed,
  _ => l.egressFailed,
};
