import 'package:intl/intl.dart';
import 'l10n/app_localizations.dart';

/// Local date and time in the app's language instead of `DateTime.toString()`
/// (UI-71).
extension DateTimeLabels on AppLocalizations {
  String formatDateTime(DateTime at) =>
      DateFormat.yMd(localeName).add_Hm().format(at.toLocal());

  /// [seconds] since the Unix epoch, as the runner reports them.
  String formatEpochSeconds(num seconds) => formatDateTime(
    DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round()),
  );
}

extension DiagnosticMessages on AppLocalizations {
  String diagnostic(String code) => switch (code) {
    'empty_group_requires_policy' => diagnosticEmptyGroupRequiresPolicy,
    'chain_has_extra_nodes' => diagnosticChainHasExtraNodes,
    'unreferenced_group' => diagnosticUnreferencedGroup,
    'base_contains_proxies' => diagnosticBaseContainsProxies,
    'invalid_yaml' => diagnosticInvalidYaml,
    'template_size_limit' => diagnosticTemplateSizeLimit,
    'template_depth_limit' => diagnosticTemplateDepthLimit,
    'template_node_limit' => diagnosticTemplateNodeLimit,
    'yaml_alias_not_supported' => diagnosticYamlAliasNotSupported,
    'yaml_explicit_tag_not_supported' => diagnosticYamlExplicitTagNotSupported,
    'multiple_yaml_documents' => diagnosticMultipleYamlDocuments,
    'unsupported_filter_preview' => diagnosticUnsupportedFilterPreview,
    'provider_snapshot_required' => diagnosticProviderSnapshotRequired,
    'unknown_proxy_reference' => diagnosticUnknownProxyReference,
    'unknown_rule_target' => diagnosticUnknownRuleTarget,
    'unknown_rule_provider' ||
    'unknown_dns_rule_provider' => diagnosticUnknownRuleProvider,
    'group_cycle' => diagnosticGroupCycle,
    'duplicate_proxy_name' ||
    'duplicate_group_name' => diagnosticDuplicateProxyName,
    'invalid_empty_fallback' => diagnosticInvalidEmptyFallback,
    'unsupported_rule_preview' => diagnosticUnsupportedRulePreview,
    _ => unknownDiagnostic(code),
  };
}
