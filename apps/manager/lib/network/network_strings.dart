import 'package:antirkn_domain/antirkn_domain.dart';

import '../l10n/app_localizations.dart';

String scopeLabel(AppLocalizations l, String scope) => switch (scope) {
  'global' => l.networkScopeGlobal,
  'link' => l.networkScopeLink,
  'host' => l.networkScopeHost,
  'site' => l.networkScopeSite,
  _ => l.networkScopeOther,
};

String interfaceStateLabel(AppLocalizations l, String state) => switch (state) {
  'UP' => l.networkInterfaceUp,
  'DOWN' ||
  'LOWERLAYERDOWN' ||
  'NOTPRESENT' ||
  'DORMANT' ||
  'TESTING' => l.networkIssueDown,
  _ => l.networkInterfaceStateUnknown,
};

String categoryLabel(AppLocalizations l, IpCategory category) =>
    switch (category) {
      IpCategory.publicUnicast => l.networkCategoryPublic,
      IpCategory.private => l.networkCategoryPrivate,
      IpCategory.loopback => l.networkCategoryLoopback,
      IpCategory.linkLocal => l.networkCategoryLinkLocal,
      IpCategory.shared => l.networkCategoryShared,
      IpCategory.documentation => l.networkCategoryDocumentation,
      IpCategory.multicast => l.networkCategoryMulticast,
      IpCategory.unspecified => l.networkCategoryUnspecified,
      IpCategory.special => l.networkCategorySpecial,
    };

String issueLabel(AppLocalizations l, SelectionIssue issue) => switch (issue) {
  SelectionIssue.interfaceDown => l.networkIssueDown,
  SelectionIssue.unknown => l.networkIssueUnknown,
  SelectionIssue.tentative => l.networkIssueTentative,
  SelectionIssue.dadfailed => l.networkIssueDadfailed,
  SelectionIssue.expired => l.networkIssueExpired,
  SelectionIssue.deprecated => l.networkIssueDeprecated,
  SelectionIssue.temporary => l.networkIssueTemporary,
  SelectionIssue.notPublic => l.networkIssueNotPublic,
  SelectionIssue.unsupportedAddress => l.networkIssueUnsupported,
  SelectionIssue.tunnel => l.networkIssueTunnel,
  SelectionIssue.scopeRequired => l.networkIssueScope,
  SelectionIssue.unavailable => l.networkIssueUnavailable,
  SelectionIssue.stale => l.networkIssueStale,
};

String healthLabel(AppLocalizations l, AddressHealth health) =>
    switch (health) {
      AddressHealth.ready => l.networkHealthReady,
      AddressHealth.interfaceDown => l.networkIssueDown,
      AddressHealth.unknown => l.networkIssueUnknown,
      AddressHealth.tentative => l.networkIssueTentative,
      AddressHealth.dadfailed => l.networkIssueDadfailed,
      AddressHealth.expired => l.networkIssueExpired,
      AddressHealth.deprecated => l.networkIssueDeprecated,
      AddressHealth.temporary => l.networkIssueTemporary,
    };

String lifetimeLabel(AppLocalizations l, int? seconds) => switch (seconds) {
  null => l.networkUnknown,
  0xffffffff => l.networkForever,
  _ => l.networkSeconds(seconds),
};

String choiceDescription(AppLocalizations l, AddressChoice choice) => [
  choice.address.family == IpFamily.ipv4 ? 'IPv4' : 'IPv6',
  choice.source == AddressChoiceSource.wildcard
      ? l.networkWildcard
      : categoryLabel(l, choice.address.category),
  if (choice.assignment case final assignment?) assignment.interfaceName,
  if (choice.assignment?.isTunnel ?? false) l.networkIssueTunnel,
  if (choice.assignment?.flags.contains(AddressFlag.secondary) ?? false)
    l.networkSecondary,
  if (choice.issue case final issue?) issueLabel(l, issue),
].join(' · ');
