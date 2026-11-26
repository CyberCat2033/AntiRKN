import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'AntiRKN'**
  String get appName;

  /// No description provided for @overview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get overview;

  /// No description provided for @templateReady.
  ///
  /// In en, this message translates to:
  /// **'Base configuration loaded.'**
  String get templateReady;

  /// No description provided for @templateLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading the base configuration…'**
  String get templateLoading;

  /// No description provided for @profileWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get profileWarning;

  /// No description provided for @profileError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get profileError;

  /// No description provided for @operationObserving.
  ///
  /// In en, this message translates to:
  /// **'An action from your device. Its status updates automatically.'**
  String get operationObserving;

  /// No description provided for @operationMissing.
  ///
  /// In en, this message translates to:
  /// **'The server has not reported this operation. Check its status before continuing here.'**
  String get operationMissing;

  /// No description provided for @operationTakeOver.
  ///
  /// In en, this message translates to:
  /// **'Check and continue on this device'**
  String get operationTakeOver;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @prototype.
  ///
  /// In en, this message translates to:
  /// **'P0 prototype'**
  String get prototype;

  /// No description provided for @intro.
  ///
  /// In en, this message translates to:
  /// **'Check which nodes are selected by your template groups.'**
  String get intro;

  /// No description provided for @source.
  ///
  /// In en, this message translates to:
  /// **'Base configuration'**
  String get source;

  /// No description provided for @sourceHelp.
  ///
  /// In en, this message translates to:
  /// **'Choose a .yml or .yaml file for client profiles. The app saves its own copy; the source file is not modified.'**
  String get sourceHelp;

  /// No description provided for @preview.
  ///
  /// In en, this message translates to:
  /// **'Preview group members'**
  String get preview;

  /// No description provided for @pending.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get pending;

  /// No description provided for @stale.
  ///
  /// In en, this message translates to:
  /// **'Preview is out of date — run the check'**
  String get stale;

  /// No description provided for @nodes.
  ///
  /// In en, this message translates to:
  /// **'Preview nodes'**
  String get nodes;

  /// No description provided for @sampleNotice.
  ///
  /// In en, this message translates to:
  /// **'These are sample node names without credentials. Server connections and publishing are not available here yet.'**
  String get sampleNotice;

  /// No description provided for @mixed.
  ///
  /// In en, this message translates to:
  /// **'VLESS + TrustTunnel + AWG'**
  String get mixed;

  /// No description provided for @noRuWg.
  ///
  /// In en, this message translates to:
  /// **'Without RU and WG'**
  String get noRuWg;

  /// No description provided for @nodeName.
  ///
  /// In en, this message translates to:
  /// **'Node name'**
  String get nodeName;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add to preview'**
  String get add;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove from preview'**
  String get remove;

  /// No description provided for @groups.
  ///
  /// In en, this message translates to:
  /// **'Selected group members'**
  String get groups;

  /// No description provided for @diagnostics.
  ///
  /// In en, this message translates to:
  /// **'Template diagnostics'**
  String get diagnostics;

  /// No description provided for @noIssues.
  ///
  /// In en, this message translates to:
  /// **'No structural issues found'**
  String get noIssues;

  /// No description provided for @noMembers.
  ///
  /// In en, this message translates to:
  /// **'No nodes selected'**
  String get noMembers;

  /// No description provided for @incomplete.
  ///
  /// In en, this message translates to:
  /// **'Additional verification is required'**
  String get incomplete;

  /// No description provided for @connectionNotRun.
  ///
  /// In en, this message translates to:
  /// **'Network connection has not been tested'**
  String get connectionNotRun;

  /// No description provided for @overviewText.
  ///
  /// In en, this message translates to:
  /// **'Manage servers and VPN clients, generate personal Mihomo profiles, and sync your workspace through Google Drive. Choose the base configuration in Settings.'**
  String get overviewText;

  /// No description provided for @scope.
  ///
  /// In en, this message translates to:
  /// **'Ubuntu • x86_64\nWindows • Linux • Android\nVLESS / TrustTunnel / AmneziaWG → Mihomo'**
  String get scope;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @system.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// No description provided for @light.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get light;

  /// No description provided for @dark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get dark;

  /// No description provided for @motion.
  ///
  /// In en, this message translates to:
  /// **'Animations'**
  String get motion;

  /// No description provided for @reduced.
  ///
  /// In en, this message translates to:
  /// **'Reduced'**
  String get reduced;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @motionHelp.
  ///
  /// In en, this message translates to:
  /// **'System animation restrictions take priority. Your preference is saved on this device.'**
  String get motionHelp;

  /// No description provided for @invalidName.
  ///
  /// In en, this message translates to:
  /// **'Enter a unique, non-empty name'**
  String get invalidName;

  /// No description provided for @loadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load the base template'**
  String get loadError;

  /// No description provided for @unexpectedError.
  ///
  /// In en, this message translates to:
  /// **'Could not check the template. You can try again.'**
  String get unexpectedError;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Interface language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get languageSystem;

  /// No description provided for @languageRussian.
  ///
  /// In en, this message translates to:
  /// **'Русский'**
  String get languageRussian;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageHelp.
  ///
  /// In en, this message translates to:
  /// **'Your choice is saved on this device. Other system languages use English.'**
  String get languageHelp;

  /// No description provided for @localeSaveError.
  ///
  /// In en, this message translates to:
  /// **'Could not save the language preference. Please try again.'**
  String get localeSaveError;

  /// No description provided for @localeLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not read the language preference. Following the system language.'**
  String get localeLoadError;

  /// No description provided for @fallback.
  ///
  /// In en, this message translates to:
  /// **'Core behavior for an empty group: {value}'**
  String fallback(String value);

  /// No description provided for @unknownDiagnostic.
  ///
  /// In en, this message translates to:
  /// **'Template settings need review ({code}).'**
  String unknownDiagnostic(String code);

  /// No description provided for @diagnosticEmptyGroupRequiresPolicy.
  ///
  /// In en, this message translates to:
  /// **'The group is empty. Mihomo will use its empty-group behavior; review the routing if needed.'**
  String get diagnosticEmptyGroupRequiresPolicy;

  /// No description provided for @diagnosticChainHasExtraNodes.
  ///
  /// In en, this message translates to:
  /// **'Proxy_Chain contains nodes excluded from RemoteBalancer.'**
  String get diagnosticChainHasExtraNodes;

  /// No description provided for @diagnosticUnreferencedGroup.
  ///
  /// In en, this message translates to:
  /// **'Other groups and rules do not reference WG_Auto.'**
  String get diagnosticUnreferencedGroup;

  /// No description provided for @diagnosticBaseContainsProxies.
  ///
  /// In en, this message translates to:
  /// **'Proxies from the base configuration are preserved and included in client profiles.'**
  String get diagnosticBaseContainsProxies;

  /// No description provided for @diagnosticInvalidYaml.
  ///
  /// In en, this message translates to:
  /// **'Invalid YAML syntax or a duplicate key.'**
  String get diagnosticInvalidYaml;

  /// No description provided for @diagnosticTemplateSizeLimit.
  ///
  /// In en, this message translates to:
  /// **'The template exceeds 256 KiB.'**
  String get diagnosticTemplateSizeLimit;

  /// No description provided for @diagnosticTemplateDepthLimit.
  ///
  /// In en, this message translates to:
  /// **'YAML nesting exceeds 32 levels.'**
  String get diagnosticTemplateDepthLimit;

  /// No description provided for @diagnosticTemplateNodeLimit.
  ///
  /// In en, this message translates to:
  /// **'The template contains too many elements.'**
  String get diagnosticTemplateNodeLimit;

  /// No description provided for @diagnosticYamlAliasNotSupported.
  ///
  /// In en, this message translates to:
  /// **'YAML aliases are not supported yet.'**
  String get diagnosticYamlAliasNotSupported;

  /// No description provided for @diagnosticYamlExplicitTagNotSupported.
  ///
  /// In en, this message translates to:
  /// **'Explicit YAML tags are not supported yet.'**
  String get diagnosticYamlExplicitTagNotSupported;

  /// No description provided for @diagnosticMultipleYamlDocuments.
  ///
  /// In en, this message translates to:
  /// **'Expected a single YAML document.'**
  String get diagnosticMultipleYamlDocuments;

  /// No description provided for @diagnosticUnsupportedFilterPreview.
  ///
  /// In en, this message translates to:
  /// **'This regular expression cannot be previewed precisely yet.'**
  String get diagnosticUnsupportedFilterPreview;

  /// No description provided for @diagnosticProviderSnapshotRequired.
  ///
  /// In en, this message translates to:
  /// **'A proxy-provider snapshot is needed to resolve the members.'**
  String get diagnosticProviderSnapshotRequired;

  /// No description provided for @diagnosticUnknownProxyReference.
  ///
  /// In en, this message translates to:
  /// **'The group references an unknown node or group.'**
  String get diagnosticUnknownProxyReference;

  /// No description provided for @diagnosticServiceModeGroupEmpty.
  ///
  /// In en, this message translates to:
  /// **'The group lists only nodes of servers in service mode and would be empty. The previous profile stays published; add another node to the group or bring a server back.'**
  String get diagnosticServiceModeGroupEmpty;

  /// No description provided for @diagnosticUnknownRuleTarget.
  ///
  /// In en, this message translates to:
  /// **'The rule references an unknown node or group.'**
  String get diagnosticUnknownRuleTarget;

  /// No description provided for @diagnosticUnknownRuleProvider.
  ///
  /// In en, this message translates to:
  /// **'A rule or DNS setting references an unknown rule-provider.'**
  String get diagnosticUnknownRuleProvider;

  /// No description provided for @diagnosticGroupCycle.
  ///
  /// In en, this message translates to:
  /// **'A cycle was found between proxy groups.'**
  String get diagnosticGroupCycle;

  /// No description provided for @diagnosticDuplicateProxyName.
  ///
  /// In en, this message translates to:
  /// **'Node and group names must be unique.'**
  String get diagnosticDuplicateProxyName;

  /// No description provided for @diagnosticInvalidEmptyFallback.
  ///
  /// In en, this message translates to:
  /// **'Invalid empty-fallback value.'**
  String get diagnosticInvalidEmptyFallback;

  /// No description provided for @diagnosticUnsupportedRulePreview.
  ///
  /// In en, this message translates to:
  /// **'This rule type still requires core validation.'**
  String get diagnosticUnsupportedRulePreview;

  /// No description provided for @selectTemplate.
  ///
  /// In en, this message translates to:
  /// **'Choose YAML file'**
  String get selectTemplate;

  /// No description provided for @importedTemplate.
  ///
  /// In en, this message translates to:
  /// **'Imported: {name}'**
  String importedTemplate(String name);

  /// No description provided for @templateReadError.
  ///
  /// In en, this message translates to:
  /// **'Could not read the YAML file. The current template was kept.'**
  String get templateReadError;

  /// No description provided for @server.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get server;

  /// No description provided for @networkTitle.
  ///
  /// In en, this message translates to:
  /// **'Server addresses'**
  String get networkTitle;

  /// No description provided for @networkSampleNotice.
  ///
  /// In en, this message translates to:
  /// **'Sample data for one VPS. No SSH connection is made and no server settings are changed.'**
  String get networkSampleNotice;

  /// No description provided for @networkLoadSample.
  ///
  /// In en, this message translates to:
  /// **'Load sample inventory'**
  String get networkLoadSample;

  /// No description provided for @networkReloadSample.
  ///
  /// In en, this message translates to:
  /// **'Reload sample inventory'**
  String get networkReloadSample;

  /// No description provided for @networkLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading inventory…'**
  String get networkLoading;

  /// No description provided for @networkLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not read the inventory. The previous inventory and your choices are kept.'**
  String get networkLoadError;

  /// No description provided for @networkEmpty.
  ///
  /// In en, this message translates to:
  /// **'No assigned addresses were found.'**
  String get networkEmpty;

  /// No description provided for @networkNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Load the sample to explore address selection.'**
  String get networkNotLoaded;

  /// No description provided for @networkListener.
  ///
  /// In en, this message translates to:
  /// **'Service listening address'**
  String get networkListener;

  /// No description provided for @networkEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Client connection address'**
  String get networkEndpoint;

  /// No description provided for @networkListenerHelp.
  ///
  /// In en, this message translates to:
  /// **'Choose an assigned IP or all interfaces. Protocol support and port conflicts must be checked before applying settings.'**
  String get networkListenerHelp;

  /// No description provided for @networkEndpointHelp.
  ///
  /// In en, this message translates to:
  /// **'Public, stable addresses are suggested. With NAT, the client address can differ from the listening address.'**
  String get networkEndpointHelp;

  /// No description provided for @networkChoose.
  ///
  /// In en, this message translates to:
  /// **'Choose an address'**
  String get networkChoose;

  /// No description provided for @networkClear.
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get networkClear;

  /// No description provided for @networkClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get networkClose;

  /// No description provided for @networkNoCandidates.
  ///
  /// In en, this message translates to:
  /// **'There are no suitable addresses for this role.'**
  String get networkNoCandidates;

  /// No description provided for @networkWildcard.
  ///
  /// In en, this message translates to:
  /// **'All interfaces'**
  String get networkWildcard;

  /// No description provided for @networkAssigned.
  ///
  /// In en, this message translates to:
  /// **'Assigned on interface'**
  String get networkAssigned;

  /// No description provided for @networkSampleSource.
  ///
  /// In en, this message translates to:
  /// **'Source: sample iproute2 data'**
  String get networkSampleSource;

  /// No description provided for @networkObservedSource.
  ///
  /// In en, this message translates to:
  /// **'Source: iproute2 observation'**
  String get networkObservedSource;

  /// No description provided for @networkNotVerified.
  ///
  /// In en, this message translates to:
  /// **'External TCP/UDP reachability has not been checked. Selecting an address does not apply any settings.'**
  String get networkNotVerified;

  /// No description provided for @networkObservedAt.
  ///
  /// In en, this message translates to:
  /// **'Inventory loaded: {value}'**
  String networkObservedAt(String value);

  /// No description provided for @networkSshPeer.
  ///
  /// In en, this message translates to:
  /// **'SSH transport address (separate): {value}'**
  String networkSshPeer(String value);

  /// No description provided for @networkSummary.
  ///
  /// In en, this message translates to:
  /// **'{addresses} unique IPs · {routes} routes · {rules} policy rules'**
  String networkSummary(int addresses, int routes, int rules);

  /// No description provided for @networkAssignments.
  ///
  /// In en, this message translates to:
  /// **'Assigned addresses and status'**
  String get networkAssignments;

  /// No description provided for @networkSelectedUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Your previous choice is no longer usable. Choose an address again.'**
  String get networkSelectedUnavailable;

  /// No description provided for @networkCategoryPublic.
  ///
  /// In en, this message translates to:
  /// **'Public unicast'**
  String get networkCategoryPublic;

  /// No description provided for @networkCategoryPrivate.
  ///
  /// In en, this message translates to:
  /// **'Private'**
  String get networkCategoryPrivate;

  /// No description provided for @networkCategoryLoopback.
  ///
  /// In en, this message translates to:
  /// **'Loopback'**
  String get networkCategoryLoopback;

  /// No description provided for @networkCategoryLinkLocal.
  ///
  /// In en, this message translates to:
  /// **'Link-local'**
  String get networkCategoryLinkLocal;

  /// No description provided for @networkCategoryShared.
  ///
  /// In en, this message translates to:
  /// **'Shared / CGNAT'**
  String get networkCategoryShared;

  /// No description provided for @networkCategoryDocumentation.
  ///
  /// In en, this message translates to:
  /// **'Documentation range'**
  String get networkCategoryDocumentation;

  /// No description provided for @networkCategoryMulticast.
  ///
  /// In en, this message translates to:
  /// **'Multicast'**
  String get networkCategoryMulticast;

  /// No description provided for @networkCategoryUnspecified.
  ///
  /// In en, this message translates to:
  /// **'Unspecified'**
  String get networkCategoryUnspecified;

  /// No description provided for @networkCategorySpecial.
  ///
  /// In en, this message translates to:
  /// **'Special-purpose range'**
  String get networkCategorySpecial;

  /// No description provided for @networkHealthReady.
  ///
  /// In en, this message translates to:
  /// **'Ready for selection'**
  String get networkHealthReady;

  /// No description provided for @networkIssueDown.
  ///
  /// In en, this message translates to:
  /// **'Interface is down'**
  String get networkIssueDown;

  /// No description provided for @networkIssueUnknown.
  ///
  /// In en, this message translates to:
  /// **'State or lifetime is unknown'**
  String get networkIssueUnknown;

  /// No description provided for @networkIssueTentative.
  ///
  /// In en, this message translates to:
  /// **'Address validation is pending'**
  String get networkIssueTentative;

  /// No description provided for @networkIssueDadfailed.
  ///
  /// In en, this message translates to:
  /// **'Duplicate address detection failed'**
  String get networkIssueDadfailed;

  /// No description provided for @networkIssueExpired.
  ///
  /// In en, this message translates to:
  /// **'Address has expired'**
  String get networkIssueExpired;

  /// No description provided for @networkIssueDeprecated.
  ///
  /// In en, this message translates to:
  /// **'Address is deprecated'**
  String get networkIssueDeprecated;

  /// No description provided for @networkIssueTemporary.
  ///
  /// In en, this message translates to:
  /// **'Temporary address'**
  String get networkIssueTemporary;

  /// No description provided for @networkIssueNotPublic.
  ///
  /// In en, this message translates to:
  /// **'Not suggested as a public client address'**
  String get networkIssueNotPublic;

  /// No description provided for @networkIssueUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Special address is not available for this role'**
  String get networkIssueUnsupported;

  /// No description provided for @networkIssueTunnel.
  ///
  /// In en, this message translates to:
  /// **'Tunnel interface'**
  String get networkIssueTunnel;

  /// No description provided for @networkIssueScope.
  ///
  /// In en, this message translates to:
  /// **'Requires protocol support for an interface zone'**
  String get networkIssueScope;

  /// No description provided for @networkIssueUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Address is no longer assigned'**
  String get networkIssueUnavailable;

  /// No description provided for @networkIssueStale.
  ///
  /// In en, this message translates to:
  /// **'Observation time is in the future; refresh the inventory'**
  String get networkIssueStale;

  /// No description provided for @networkSecondary.
  ///
  /// In en, this message translates to:
  /// **'Secondary address'**
  String get networkSecondary;

  /// No description provided for @networkPrefix.
  ///
  /// In en, this message translates to:
  /// **'Prefix: /{value}'**
  String networkPrefix(int value);

  /// No description provided for @networkLifetime.
  ///
  /// In en, this message translates to:
  /// **'Valid / preferred lifetime: {valid} / {preferred}'**
  String networkLifetime(String valid, String preferred);

  /// No description provided for @networkForever.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get networkForever;

  /// No description provided for @networkUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get networkUnknown;

  /// No description provided for @networkSeconds.
  ///
  /// In en, this message translates to:
  /// **'{value} s'**
  String networkSeconds(int value);

  /// No description provided for @networkScopeGlobal.
  ///
  /// In en, this message translates to:
  /// **'Global scope'**
  String get networkScopeGlobal;

  /// No description provided for @networkScopeLink.
  ///
  /// In en, this message translates to:
  /// **'Link scope'**
  String get networkScopeLink;

  /// No description provided for @networkScopeHost.
  ///
  /// In en, this message translates to:
  /// **'Host scope'**
  String get networkScopeHost;

  /// No description provided for @networkScopeSite.
  ///
  /// In en, this message translates to:
  /// **'Site scope'**
  String get networkScopeSite;

  /// No description provided for @networkScopeOther.
  ///
  /// In en, this message translates to:
  /// **'Other scope'**
  String get networkScopeOther;

  /// No description provided for @networkInterfaceUp.
  ///
  /// In en, this message translates to:
  /// **'Interface is up'**
  String get networkInterfaceUp;

  /// No description provided for @networkInterfaceStateUnknown.
  ///
  /// In en, this message translates to:
  /// **'Operational state is unknown'**
  String get networkInterfaceStateUnknown;

  /// No description provided for @sshServerName.
  ///
  /// In en, this message translates to:
  /// **'Server name (optional)'**
  String get sshServerName;

  /// No description provided for @sshEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit connection'**
  String get sshEdit;

  /// No description provided for @sshEditHelp.
  ///
  /// In en, this message translates to:
  /// **'Saving will close the SSH session. Connect again to apply the changes.'**
  String get sshEditHelp;

  /// No description provided for @sshOsUnknown.
  ///
  /// In en, this message translates to:
  /// **'OS version will be read on connection'**
  String get sshOsUnknown;

  /// No description provided for @sshReplaceServer.
  ///
  /// In en, this message translates to:
  /// **'This is a different server'**
  String get sshReplaceServer;

  /// No description provided for @sshReplaceServerHelp.
  ///
  /// In en, this message translates to:
  /// **'Continue only if you intentionally replaced the server or changed its address. Verify the new fingerprint through its VPS console. Confirming will replace the saved trusted key; rejecting keeps the old key. Your login details are retained.'**
  String get sshReplaceServerHelp;

  /// No description provided for @sshHost.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get sshHost;

  /// No description provided for @sshPort.
  ///
  /// In en, this message translates to:
  /// **'SSH port'**
  String get sshPort;

  /// No description provided for @sshUser.
  ///
  /// In en, this message translates to:
  /// **'SSH user'**
  String get sshUser;

  /// No description provided for @sshPassword.
  ///
  /// In en, this message translates to:
  /// **'SSH password'**
  String get sshPassword;

  /// No description provided for @sshAuthPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get sshAuthPassword;

  /// No description provided for @sshAuthKey.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get sshAuthKey;

  /// No description provided for @sshAuthAgent.
  ///
  /// In en, this message translates to:
  /// **'Linux SSH-agent'**
  String get sshAuthAgent;

  /// No description provided for @sshAgentHelp.
  ///
  /// In en, this message translates to:
  /// **'Use keys loaded in the local SSH-agent. The private key stays with the agent.'**
  String get sshAgentHelp;

  /// No description provided for @sshPickKey.
  ///
  /// In en, this message translates to:
  /// **'Choose private key'**
  String get sshPickKey;

  /// No description provided for @sshKeyHelp.
  ///
  /// In en, this message translates to:
  /// **'Choose the private file, for example id_ed25519, without .pub. An independent copy is saved in the encrypted vault.'**
  String get sshKeyHelp;

  /// No description provided for @sshNoKey.
  ///
  /// In en, this message translates to:
  /// **'No private key selected'**
  String get sshNoKey;

  /// No description provided for @sshPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Key passphrase (if encrypted)'**
  String get sshPassphrase;

  /// No description provided for @sshSave.
  ///
  /// In en, this message translates to:
  /// **'Save connection'**
  String get sshSave;

  /// No description provided for @sshConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get sshConnect;

  /// No description provided for @sshSaveAndConnect.
  ///
  /// In en, this message translates to:
  /// **'Save and connect'**
  String get sshSaveAndConnect;

  /// No description provided for @sshDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get sshDisconnect;

  /// No description provided for @sshCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get sshCancel;

  /// No description provided for @sshRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh from server'**
  String get sshRefresh;

  /// No description provided for @sshConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get sshConnecting;

  /// No description provided for @sshReading.
  ///
  /// In en, this message translates to:
  /// **'Reading server information…'**
  String get sshReading;

  /// No description provided for @sshConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get sshConnected;

  /// No description provided for @sshIdle.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get sshIdle;

  /// No description provided for @sshTrustTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify server identity'**
  String get sshTrustTitle;

  /// No description provided for @sshTrustHelp.
  ///
  /// In en, this message translates to:
  /// **'Compare this SHA-256 fingerprint with a trusted source, such as your VPS console. Accepting saves this server identity before authentication.'**
  String get sshTrustHelp;

  /// No description provided for @sshTrustAccept.
  ///
  /// In en, this message translates to:
  /// **'Trust and continue'**
  String get sshTrustAccept;

  /// No description provided for @sshTrustReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get sshTrustReject;

  /// No description provided for @sshTrustedKey.
  ///
  /// In en, this message translates to:
  /// **'Trusted server key'**
  String get sshTrustedKey;

  /// No description provided for @sshDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete saved connection'**
  String get sshDelete;

  /// No description provided for @sshDeleteHelp.
  ///
  /// In en, this message translates to:
  /// **'Delete this saved server and its credentials from this device? Nothing on the VPS will be changed.'**
  String get sshDeleteHelp;

  /// No description provided for @sshInvalidSettings.
  ///
  /// In en, this message translates to:
  /// **'Check the address, port, user and authentication details.'**
  String get sshInvalidSettings;

  /// No description provided for @sshInvalidKey.
  ///
  /// In en, this message translates to:
  /// **'Cannot read or decrypt this private key. Check its format and passphrase. A .pub file cannot be used for login.'**
  String get sshInvalidKey;

  /// No description provided for @sshAuthenticationError.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed. Check the user and credentials.'**
  String get sshAuthenticationError;

  /// No description provided for @sshHostChanged.
  ///
  /// In en, this message translates to:
  /// **'The server key differs from the trusted key. Connection blocked. Verify the change through your VPS console.'**
  String get sshHostChanged;

  /// No description provided for @sshHostRejected.
  ///
  /// In en, this message translates to:
  /// **'Server identity was not accepted.'**
  String get sshHostRejected;

  /// No description provided for @sshNetworkError.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the SSH server or the connection was lost.'**
  String get sshNetworkError;

  /// No description provided for @sshTimeout.
  ///
  /// In en, this message translates to:
  /// **'The operation timed out. You can retry.'**
  String get sshTimeout;

  /// No description provided for @sshCancelled.
  ///
  /// In en, this message translates to:
  /// **'Operation cancelled.'**
  String get sshCancelled;

  /// No description provided for @sshCommandError.
  ///
  /// In en, this message translates to:
  /// **'The server could not provide complete information. The previous inventory is retained.'**
  String get sshCommandError;

  /// No description provided for @sshOutputLimit.
  ///
  /// In en, this message translates to:
  /// **'Server output exceeded the allowed size. The previous inventory is retained.'**
  String get sshOutputLimit;

  /// No description provided for @sshInvalidInventory.
  ///
  /// In en, this message translates to:
  /// **'The server returned an invalid inventory. The previous inventory is retained.'**
  String get sshInvalidInventory;

  /// No description provided for @sshUnsupportedOs.
  ///
  /// In en, this message translates to:
  /// **'This connection requires Ubuntu on x86_64.'**
  String get sshUnsupportedOs;

  /// No description provided for @sshDisconnected.
  ///
  /// In en, this message translates to:
  /// **'SSH connection closed. Reconnect to refresh the inventory.'**
  String get sshDisconnected;

  /// No description provided for @sshTrustSaveError.
  ///
  /// In en, this message translates to:
  /// **'Could not save server trust. Authentication was stopped.'**
  String get sshTrustSaveError;

  /// No description provided for @sshAgentError.
  ///
  /// In en, this message translates to:
  /// **'Linux SSH-agent is unavailable or has no supported keys. Load your key into the agent or choose a private key file.'**
  String get sshAgentError;

  /// No description provided for @vaultPassword.
  ///
  /// In en, this message translates to:
  /// **'Master password'**
  String get vaultPassword;

  /// No description provided for @vaultLocked.
  ///
  /// In en, this message translates to:
  /// **'Connection data is unavailable. Reopen the server.'**
  String get vaultLocked;

  /// No description provided for @vaultRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get vaultRetry;

  /// No description provided for @vaultUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unable to open saved connections. Retry.'**
  String get vaultUnavailable;

  /// No description provided for @vaultMissingKey.
  ///
  /// In en, this message translates to:
  /// **'The device encryption key is unavailable. Saved data has been kept.'**
  String get vaultMissingKey;

  /// No description provided for @vaultDamaged.
  ///
  /// In en, this message translates to:
  /// **'Incorrect master password or damaged storage. Saved data has been preserved.'**
  String get vaultDamaged;

  /// No description provided for @vaultCorrupt.
  ///
  /// In en, this message translates to:
  /// **'Storage is damaged or uses an unsupported format. Its file has been preserved.'**
  String get vaultCorrupt;

  /// No description provided for @vaultWriteFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to save the connection. Previous data has been kept.'**
  String get vaultWriteFailed;

  /// No description provided for @vaultBusy.
  ///
  /// In en, this message translates to:
  /// **'This connection was changed in another app instance. Reopen it before editing.'**
  String get vaultBusy;

  /// No description provided for @vaultExists.
  ///
  /// In en, this message translates to:
  /// **'Saved data already exists. Reopen the server.'**
  String get vaultExists;

  /// No description provided for @vaultWeakPassword.
  ///
  /// In en, this message translates to:
  /// **'Use matching passwords of 12 to 1024 characters.'**
  String get vaultWeakPassword;

  /// No description provided for @networkExternal.
  ///
  /// In en, this message translates to:
  /// **'External addresses'**
  String get networkExternal;

  /// No description provided for @networkInternal.
  ///
  /// In en, this message translates to:
  /// **'Internal addresses'**
  String get networkInternal;

  /// No description provided for @networkExternalEmpty.
  ///
  /// In en, this message translates to:
  /// **'No public addresses were found on the interfaces.'**
  String get networkExternalEmpty;

  /// No description provided for @networkInternalEmpty.
  ///
  /// In en, this message translates to:
  /// **'No internal addresses were found.'**
  String get networkInternalEmpty;

  /// No description provided for @networkClassHint.
  ///
  /// In en, this message translates to:
  /// **'External means public unicast; internal includes local and special ranges. This does not prove Internet reachability.'**
  String get networkClassHint;

  /// No description provided for @inventoryTitle.
  ///
  /// In en, this message translates to:
  /// **'VPS software and resources'**
  String get inventoryTitle;

  /// No description provided for @inventoryScope.
  ///
  /// In en, this message translates to:
  /// **'Checks cover standard binary paths, systemd units and recognized images in local Docker. Custom paths, renamed images and rootless Docker may require a separate check. Detection does not confirm protocol compatibility.'**
  String get inventoryScope;

  /// No description provided for @inventoryStale.
  ///
  /// In en, this message translates to:
  /// **'Previous observation. Refresh after connecting to get current data.'**
  String get inventoryStale;

  /// No description provided for @inventoryDetected.
  ///
  /// In en, this message translates to:
  /// **'Detected'**
  String get inventoryDetected;

  /// No description provided for @inventoryAbsent.
  ///
  /// In en, this message translates to:
  /// **'Not found in checked locations'**
  String get inventoryAbsent;

  /// No description provided for @inventoryUnknown.
  ///
  /// In en, this message translates to:
  /// **'Could not determine presence'**
  String get inventoryUnknown;

  /// No description provided for @inventoryPartial.
  ///
  /// In en, this message translates to:
  /// **'Some checks were incomplete'**
  String get inventoryPartial;

  /// No description provided for @inventoryUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable on this system'**
  String get inventoryUnavailable;

  /// No description provided for @inventoryDenied.
  ///
  /// In en, this message translates to:
  /// **'Insufficient access'**
  String get inventoryDenied;

  /// No description provided for @inventoryFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not check'**
  String get inventoryFailed;

  /// No description provided for @inventoryTimeout.
  ///
  /// In en, this message translates to:
  /// **'Check timed out'**
  String get inventoryTimeout;

  /// No description provided for @inventoryInvalid.
  ///
  /// In en, this message translates to:
  /// **'Unrecognized response'**
  String get inventoryInvalid;

  /// No description provided for @inventoryOutputLimit.
  ///
  /// In en, this message translates to:
  /// **'Response exceeded the limit'**
  String get inventoryOutputLimit;

  /// No description provided for @inventoryOk.
  ///
  /// In en, this message translates to:
  /// **'Checked'**
  String get inventoryOk;

  /// No description provided for @inventoryVersionUnknown.
  ///
  /// In en, this message translates to:
  /// **'Version unknown'**
  String get inventoryVersionUnknown;

  /// No description provided for @inventoryVersion.
  ///
  /// In en, this message translates to:
  /// **'Version: {value}'**
  String inventoryVersion(String value);

  /// No description provided for @inventoryBinary.
  ///
  /// In en, this message translates to:
  /// **'Program file'**
  String get inventoryBinary;

  /// No description provided for @inventoryKernelModule.
  ///
  /// In en, this message translates to:
  /// **'Loaded kernel module'**
  String get inventoryKernelModule;

  /// No description provided for @inventoryRunning.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get inventoryRunning;

  /// No description provided for @inventoryStopped.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get inventoryStopped;

  /// No description provided for @inventoryServiceFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get inventoryServiceFailed;

  /// No description provided for @inventoryStateUnknown.
  ///
  /// In en, this message translates to:
  /// **'Runtime state unknown'**
  String get inventoryStateUnknown;

  /// No description provided for @inventoryKernel.
  ///
  /// In en, this message translates to:
  /// **'Kernel'**
  String get inventoryKernel;

  /// No description provided for @inventoryInit.
  ///
  /// In en, this message translates to:
  /// **'PID 1'**
  String get inventoryInit;

  /// No description provided for @inventoryCpu.
  ///
  /// In en, this message translates to:
  /// **'Online CPUs'**
  String get inventoryCpu;

  /// No description provided for @inventoryMemory.
  ///
  /// In en, this message translates to:
  /// **'Total RAM'**
  String get inventoryMemory;

  /// No description provided for @inventoryAvailableMemory.
  ///
  /// In en, this message translates to:
  /// **'Available RAM'**
  String get inventoryAvailableMemory;

  /// No description provided for @inventoryDisk.
  ///
  /// In en, this message translates to:
  /// **'Free space on /'**
  String get inventoryDisk;

  /// No description provided for @inventoryUid.
  ///
  /// In en, this message translates to:
  /// **'Effective UID'**
  String get inventoryUid;

  /// No description provided for @inventoryTools.
  ///
  /// In en, this message translates to:
  /// **'System tools'**
  String get inventoryTools;

  /// No description provided for @inventoryToolsEmpty.
  ///
  /// In en, this message translates to:
  /// **'None of the checked tools were found'**
  String get inventoryToolsEmpty;

  /// No description provided for @inventoryPrivilegesHint.
  ///
  /// In en, this message translates to:
  /// **'UID and sudo availability describe the SSH account. Use the administrative access check to retry restricted reads.'**
  String get inventoryPrivilegesHint;

  /// No description provided for @inventoryMiB.
  ///
  /// In en, this message translates to:
  /// **'{value} MiB'**
  String inventoryMiB(String value);

  /// No description provided for @inventoryPorts.
  ///
  /// In en, this message translates to:
  /// **'Occupied ports'**
  String get inventoryPorts;

  /// No description provided for @inventoryPortsHint.
  ///
  /// In en, this message translates to:
  /// **'TCP listeners and bound UDP sockets in the SSH network namespace. External reachability, firewall and dual-stack conflicts are not tested.'**
  String get inventoryPortsHint;

  /// No description provided for @inventoryNoPorts.
  ///
  /// In en, this message translates to:
  /// **'No sockets were found'**
  String get inventoryNoPorts;

  /// No description provided for @addServer.
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get addServer;

  /// No description provided for @noServers.
  ///
  /// In en, this message translates to:
  /// **'No servers yet'**
  String get noServers;

  /// No description provided for @noServersHelp.
  ///
  /// In en, this message translates to:
  /// **'Use + in the top right to add a server.'**
  String get noServersHelp;

  /// No description provided for @showPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get showPassword;

  /// No description provided for @hidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get hidePassword;

  /// No description provided for @migrateConnection.
  ///
  /// In en, this message translates to:
  /// **'Transfer saved connection'**
  String get migrateConnection;

  /// No description provided for @migrateConnectionHelp.
  ///
  /// In en, this message translates to:
  /// **'Enter your old master password once to transfer the saved connection. It will open automatically afterwards.'**
  String get migrateConnectionHelp;

  /// No description provided for @databaseOpenError.
  ///
  /// In en, this message translates to:
  /// **'Unable to open the local database. Your saved data has been kept.'**
  String get databaseOpenError;

  /// No description provided for @settingsSaveError.
  ///
  /// In en, this message translates to:
  /// **'Unable to save the setting. Try again.'**
  String get settingsSaveError;

  /// No description provided for @draftSaveError.
  ///
  /// In en, this message translates to:
  /// **'Template could not be saved on this device. Retry before closing the app.'**
  String get draftSaveError;

  /// No description provided for @draftSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving template…'**
  String get draftSaving;

  /// No description provided for @draftSaved.
  ///
  /// In en, this message translates to:
  /// **'Template saved on this device'**
  String get draftSaved;

  /// No description provided for @sshJump.
  ///
  /// In en, this message translates to:
  /// **'Jump SSH'**
  String get sshJump;

  /// No description provided for @sshDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct connection'**
  String get sshDirect;

  /// No description provided for @sshJumpMissing.
  ///
  /// In en, this message translates to:
  /// **'Server unavailable'**
  String get sshJumpMissing;

  /// No description provided for @sshVia.
  ///
  /// In en, this message translates to:
  /// **'Via {server}'**
  String sshVia(String server);

  /// No description provided for @sshInvalidJump.
  ///
  /// In en, this message translates to:
  /// **'The SSH route is invalid: a server is missing or the route contains a cycle. Edit the jump selection.'**
  String get sshInvalidJump;

  /// No description provided for @sshJumpHostChanged.
  ///
  /// In en, this message translates to:
  /// **'The jump server’s SSH key has changed. Open that server and verify its new fingerprint before connecting.'**
  String get sshJumpHostChanged;

  /// No description provided for @privilegesTitle.
  ///
  /// In en, this message translates to:
  /// **'Administrative access'**
  String get privilegesTitle;

  /// No description provided for @privilegesUnknown.
  ///
  /// In en, this message translates to:
  /// **'Administrative access has not been checked in this session.'**
  String get privilegesUnknown;

  /// No description provided for @privilegesRoot.
  ///
  /// In en, this message translates to:
  /// **'Connected as root. No additional password is needed.'**
  String get privilegesRoot;

  /// No description provided for @privilegesNoPassword.
  ///
  /// In en, this message translates to:
  /// **'The sudo check succeeded without a password.'**
  String get privilegesNoPassword;

  /// No description provided for @privilegesPassword.
  ///
  /// In en, this message translates to:
  /// **'The sudo check succeeded with a password.'**
  String get privilegesPassword;

  /// No description provided for @privilegesRequired.
  ///
  /// In en, this message translates to:
  /// **'sudo requires a password. Enter it below and retry.'**
  String get privilegesRequired;

  /// No description provided for @privilegesAuthentication.
  ///
  /// In en, this message translates to:
  /// **'sudo rejected the password. Check it before retrying.'**
  String get privilegesAuthentication;

  /// No description provided for @privilegesDenied.
  ///
  /// In en, this message translates to:
  /// **'The server denied this sudo command. The account may lack permission.'**
  String get privilegesDenied;

  /// No description provided for @privilegesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'sudo is not available on the server.'**
  String get privilegesUnavailable;

  /// No description provided for @privilegesTerminal.
  ///
  /// In en, this message translates to:
  /// **'The sudo policy requires an interactive terminal. This mode is not supported yet.'**
  String get privilegesTerminal;

  /// No description provided for @privilegesInvalidPassword.
  ///
  /// In en, this message translates to:
  /// **'Use up to 1024 characters without line breaks or NUL.'**
  String get privilegesInvalidPassword;

  /// No description provided for @privilegesCheck.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get privilegesCheck;

  /// No description provided for @privilegesChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking administrative access…'**
  String get privilegesChecking;

  /// No description provided for @privilegesSudoPassword.
  ///
  /// In en, this message translates to:
  /// **'Separate sudo password'**
  String get privilegesSudoPassword;

  /// No description provided for @privilegesSshPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to use the saved SSH password. A separate password is stored encrypted.'**
  String get privilegesSshPasswordHint;

  /// No description provided for @privilegesKeyPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Enter the account password requested by sudo. The private key passphrase is not used. The password is stored encrypted.'**
  String get privilegesKeyPasswordHint;

  /// No description provided for @privilegesScope.
  ///
  /// In en, this message translates to:
  /// **'Enter the sudo password to continue. It will be saved encrypted on confirmation.'**
  String get privilegesScope;

  /// No description provided for @runnerTitle.
  ///
  /// In en, this message translates to:
  /// **'Server jobs'**
  String get runnerTitle;

  /// No description provided for @runnerHelp.
  ///
  /// In en, this message translates to:
  /// **'Installation and diagnostic jobs run on the server. Progress is retained after the app closes or SSH disconnects.'**
  String get runnerHelp;

  /// No description provided for @runnerPrepare.
  ///
  /// In en, this message translates to:
  /// **'Set up server jobs'**
  String get runnerPrepare;

  /// No description provided for @runnerStart.
  ///
  /// In en, this message translates to:
  /// **'Run server check'**
  String get runnerStart;

  /// No description provided for @runnerPlanTitle.
  ///
  /// In en, this message translates to:
  /// **'Server change plan'**
  String get runnerPlanTitle;

  /// No description provided for @runnerPlanBody.
  ///
  /// In en, this message translates to:
  /// **'Install or repair the bundled executor; the known previous release will be upgraded while retaining the journal. Enable the systemd service at startup and create a private job directory. The executor needs network access and write access to /usr/local and /etc for approved installations. Requires Python 3.8+ with SQLite and systemd 235+. Package upgrades are not part of this plan.'**
  String get runnerPlanBody;

  /// No description provided for @runnerPlanRelease.
  ///
  /// In en, this message translates to:
  /// **'Bundle SHA-256'**
  String get runnerPlanRelease;

  /// No description provided for @runnerApply.
  ///
  /// In en, this message translates to:
  /// **'Apply plan'**
  String get runnerApply;

  /// No description provided for @runnerNotNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get runnerNotNow;

  /// No description provided for @runnerPending.
  ///
  /// In en, this message translates to:
  /// **'The submission is saved locally; its server result needs checking.'**
  String get runnerPending;

  /// No description provided for @runnerRetry.
  ///
  /// In en, this message translates to:
  /// **'Check and retry this request'**
  String get runnerRetry;

  /// No description provided for @runnerReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect runner'**
  String get runnerReconnect;

  /// No description provided for @runnerResend.
  ///
  /// In en, this message translates to:
  /// **'Send again'**
  String get runnerResend;

  /// No description provided for @runnerConnectionLost.
  ///
  /// In en, this message translates to:
  /// **'Connection lost. The server job may still be running. Reconnect to retrieve its result.'**
  String get runnerConnectionLost;

  /// No description provided for @runnerNotRunning.
  ///
  /// In en, this message translates to:
  /// **'The worker has not confirmed that it is running. Refresh its status or apply the setup plan.'**
  String get runnerNotRunning;

  /// No description provided for @runnerCancelRequested.
  ///
  /// In en, this message translates to:
  /// **'Cancellation requested; waiting for a safe stopping point.'**
  String get runnerCancelRequested;

  /// No description provided for @runnerCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel server job'**
  String get runnerCancel;

  /// No description provided for @runnerResetQueue.
  ///
  /// In en, this message translates to:
  /// **'Reset job queue'**
  String get runnerResetQueue;

  /// No description provided for @runnerResetQueueTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset the job queue?'**
  String get runnerResetQueueTitle;

  /// No description provided for @runnerResetQueueHelp.
  ///
  /// In en, this message translates to:
  /// **'All server jobs of this server are cancelled and the queue is cleared. Steps already applied on the server are not undone; check the server state afterwards.'**
  String get runnerResetQueueHelp;

  /// No description provided for @runnerEventsTruncated.
  ///
  /// In en, this message translates to:
  /// **'Older events have been rotated on the server. The current checkpoint is available.'**
  String get runnerEventsTruncated;

  /// No description provided for @runnerJournal.
  ///
  /// In en, this message translates to:
  /// **'Job events'**
  String get runnerJournal;

  /// No description provided for @runnerHistory.
  ///
  /// In en, this message translates to:
  /// **'Recent jobs'**
  String get runnerHistory;

  /// No description provided for @runnerPrerequisites.
  ///
  /// In en, this message translates to:
  /// **'This runner requires Ubuntu x86_64, a running systemd 235+, and Python 3.8+ with SQLite. No changes were applied.'**
  String get runnerPrerequisites;

  /// No description provided for @runnerConflict.
  ///
  /// In en, this message translates to:
  /// **'The server state conflicts with this plan or request. Refresh the details before continuing.'**
  String get runnerConflict;

  /// No description provided for @runnerIncompatible.
  ///
  /// In en, this message translates to:
  /// **'The installed runner version is incompatible with this build.'**
  String get runnerIncompatible;

  /// No description provided for @runnerVersionDetails.
  ///
  /// In en, this message translates to:
  /// **'Installed: {installed} · App: {bundled}. Update the app or report these IDs.'**
  String runnerVersionDetails(String installed, String bundled);

  /// No description provided for @runnerInstallFailed.
  ///
  /// In en, this message translates to:
  /// **'Setup could not be confirmed. Some changes may have been applied. Refresh the server state before retrying.'**
  String get runnerInstallFailed;

  /// No description provided for @runnerInvalidResponse.
  ///
  /// In en, this message translates to:
  /// **'The runner returned an invalid response. Check the saved result before retrying.'**
  String get runnerInvalidResponse;

  /// No description provided for @runnerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The job service is unavailable. Check the SSH connection and administrative access.'**
  String get runnerUnavailable;

  /// No description provided for @runnerStorage.
  ///
  /// In en, this message translates to:
  /// **'The local job journal could not be saved or restored. Check local storage before retrying.'**
  String get runnerStorage;

  /// No description provided for @runnerBusy.
  ///
  /// In en, this message translates to:
  /// **'Another server job is active. Wait for it to finish.'**
  String get runnerBusy;

  /// No description provided for @runnerMissing.
  ///
  /// In en, this message translates to:
  /// **'This request has not been found on the server.'**
  String get runnerMissing;

  /// No description provided for @runnerCapacity.
  ///
  /// In en, this message translates to:
  /// **'The server job journal has reached its capacity.'**
  String get runnerCapacity;

  /// No description provided for @runnerPlanned.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get runnerPlanned;

  /// No description provided for @runnerRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get runnerRunning;

  /// No description provided for @runnerSucceeded.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get runnerSucceeded;

  /// No description provided for @runnerCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get runnerCancelled;

  /// No description provided for @runnerFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get runnerFailed;

  /// No description provided for @runnerPartial.
  ///
  /// In en, this message translates to:
  /// **'Partially applied'**
  String get runnerPartial;

  /// No description provided for @runnerAttention.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get runnerAttention;

  /// No description provided for @runnerSample.
  ///
  /// In en, this message translates to:
  /// **'Server check passed'**
  String get runnerSample;

  /// No description provided for @runnerRecovered.
  ///
  /// In en, this message translates to:
  /// **'Resumed from a saved checkpoint'**
  String get runnerRecovered;

  /// No description provided for @runnerUpgradePreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing upgrade...'**
  String get runnerUpgradePreparing;

  /// No description provided for @runnerUpgradeDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading package...'**
  String get runnerUpgradeDownloading;

  /// No description provided for @runnerUpgradeBackingUp.
  ///
  /// In en, this message translates to:
  /// **'Creating backup...'**
  String get runnerUpgradeBackingUp;

  /// No description provided for @runnerUpgradeSyntaxChecking.
  ///
  /// In en, this message translates to:
  /// **'Validating binary...'**
  String get runnerUpgradeSyntaxChecking;

  /// No description provided for @runnerUpgradeSwitching.
  ///
  /// In en, this message translates to:
  /// **'Switching version...'**
  String get runnerUpgradeSwitching;

  /// No description provided for @runnerUpgradeVerifying.
  ///
  /// In en, this message translates to:
  /// **'Checking the service and real connections (up to 1 min)…'**
  String get runnerUpgradeVerifying;

  /// No description provided for @runnerUpgradeRollingBack.
  ///
  /// In en, this message translates to:
  /// **'Rolling back...'**
  String get runnerUpgradeRollingBack;

  /// No description provided for @runnerUpgradeCompleted.
  ///
  /// In en, this message translates to:
  /// **'Upgrade completed'**
  String get runnerUpgradeCompleted;

  /// No description provided for @runnerUpgradeRolledBack.
  ///
  /// In en, this message translates to:
  /// **'Rolled back to previous version'**
  String get runnerUpgradeRolledBack;

  /// No description provided for @runnerUpgradeSyntaxFailed.
  ///
  /// In en, this message translates to:
  /// **'Binary validation failed'**
  String get runnerUpgradeSyntaxFailed;

  /// No description provided for @runnerUpgradeHealthcheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Health check failed (rolled back)'**
  String get runnerUpgradeHealthcheckFailed;

  /// No description provided for @runnerUpgradeAwaitingConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Connections verified · confirming (automatic rollback in 5 minutes without confirmation)'**
  String get runnerUpgradeAwaitingConfirmation;

  /// No description provided for @runnerUpgradeConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Update confirmed'**
  String get runnerUpgradeConfirmed;

  /// No description provided for @runnerUpgradeConnectivityFailed.
  ///
  /// In en, this message translates to:
  /// **'Connections stopped working after the update — rolled back'**
  String get runnerUpgradeConnectivityFailed;

  /// No description provided for @runnerUpgradeDownloadMissing.
  ///
  /// In en, this message translates to:
  /// **'Package asset not found (404)'**
  String get runnerUpgradeDownloadMissing;

  /// No description provided for @runnerUpgradeDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get runnerUpgradeDownloadFailed;

  /// No description provided for @runnerUpgradeChecksumFailed.
  ///
  /// In en, this message translates to:
  /// **'Checksum mismatch'**
  String get runnerUpgradeChecksumFailed;

  /// No description provided for @runnerUpgradeConflict.
  ///
  /// In en, this message translates to:
  /// **'Server state conflict'**
  String get runnerUpgradeConflict;

  /// No description provided for @runnerUpgradeFailedGeneric.
  ///
  /// In en, this message translates to:
  /// **'Upgrade failed'**
  String get runnerUpgradeFailedGeneric;

  /// No description provided for @runnerUpgradeInProgressGeneric.
  ///
  /// In en, this message translates to:
  /// **'Upgrading...'**
  String get runnerUpgradeInProgressGeneric;

  /// No description provided for @componentsInstall.
  ///
  /// In en, this message translates to:
  /// **'Install components'**
  String get componentsInstall;

  /// No description provided for @componentsSelectionHelp.
  ///
  /// In en, this message translates to:
  /// **'Install a missing panel and its Xray. TrustTunnel and AmneziaWG installers will follow.'**
  String get componentsSelectionHelp;

  /// No description provided for @componentsPort.
  ///
  /// In en, this message translates to:
  /// **'Panel local port'**
  String get componentsPort;

  /// No description provided for @componentsPortHelp.
  ///
  /// In en, this message translates to:
  /// **'SSH access only; this is not a VPN port.'**
  String get componentsPortHelp;

  /// No description provided for @componentsPortInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a port between 1024 and 65535.'**
  String get componentsPortInvalid;

  /// No description provided for @componentsPrepare.
  ///
  /// In en, this message translates to:
  /// **'Prepare plan'**
  String get componentsPrepare;

  /// No description provided for @componentsPlan.
  ///
  /// In en, this message translates to:
  /// **'3x-ui / Xray installation plan'**
  String get componentsPlan;

  /// No description provided for @componentsExisting.
  ///
  /// In en, this message translates to:
  /// **'An existing installation was found or could not be ruled out. Automatic reinstallation is unavailable; its configuration is preserved.'**
  String get componentsExisting;

  /// No description provided for @componentsPrerequisites.
  ///
  /// In en, this message translates to:
  /// **'Requires Ubuntu x86_64, Python 3.8+ with SQLite, systemd 235+, nsenter, ca-certificates and 600 MiB free space. Missing prerequisites need separate preparation.'**
  String get componentsPrerequisites;

  /// No description provided for @componentsPortBusy.
  ///
  /// In en, this message translates to:
  /// **'Panel port is occupied. Choose another port and prepare a new plan.'**
  String get componentsPortBusy;

  /// No description provided for @componentsPlanBody.
  ///
  /// In en, this message translates to:
  /// **'The pinned archive will be downloaded and verified, then a new configuration and service with automatic startup will be created. Initial setup runs in an isolated network; the panel then listens only on 127.0.0.1. Credentials are created once and the subscription service is disabled.'**
  String get componentsPlanBody;

  /// No description provided for @componentsDependencies.
  ///
  /// In en, this message translates to:
  /// **'The archive includes Xray and geodata. This plan does not update APT packages.'**
  String get componentsDependencies;

  /// No description provided for @componentsRunnerDependency.
  ///
  /// In en, this message translates to:
  /// **'The job runner will be installed, repaired or upgraded from the known previous release. It requires network access and write access to installation directories. Job history is retained.'**
  String get componentsRunnerDependency;

  /// No description provided for @componentsPanelAccess.
  ///
  /// In en, this message translates to:
  /// **'Installed panel access'**
  String get componentsPanelAccess;

  /// No description provided for @componentsAccessHelp.
  ///
  /// In en, this message translates to:
  /// **'Credentials are stored encrypted. The address is reachable on the server through an SSH tunnel.'**
  String get componentsAccessHelp;

  /// No description provided for @componentsPassword.
  ///
  /// In en, this message translates to:
  /// **'Panel password'**
  String get componentsPassword;

  /// No description provided for @componentsHidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get componentsHidePassword;

  /// No description provided for @componentsShowPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get componentsShowPassword;

  /// No description provided for @componentsVerified.
  ///
  /// In en, this message translates to:
  /// **'API verified through SSH: {time}'**
  String componentsVerified(String time);

  /// No description provided for @componentsVerifyApi.
  ///
  /// In en, this message translates to:
  /// **'Verify API through SSH'**
  String get componentsVerifyApi;

  /// No description provided for @componentsJob.
  ///
  /// In en, this message translates to:
  /// **'3x-ui / Xray'**
  String get componentsJob;

  /// No description provided for @componentsDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Archive downloaded and verified'**
  String get componentsDownloaded;

  /// No description provided for @componentsExtracted.
  ///
  /// In en, this message translates to:
  /// **'Files installed'**
  String get componentsExtracted;

  /// No description provided for @componentsConfigured.
  ///
  /// In en, this message translates to:
  /// **'Private panel configured and credentials created'**
  String get componentsConfigured;

  /// No description provided for @componentsStarted.
  ///
  /// In en, this message translates to:
  /// **'Service started'**
  String get componentsStarted;

  /// No description provided for @componentsChecked.
  ///
  /// In en, this message translates to:
  /// **'Versions, settings and API verified on the server'**
  String get componentsChecked;

  /// No description provided for @componentsDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Archive download failed. Installation is incomplete.'**
  String get componentsDownloadFailed;

  /// No description provided for @componentsChecksumFailed.
  ///
  /// In en, this message translates to:
  /// **'Checksum mismatch. The archive will not be executed.'**
  String get componentsChecksumFailed;

  /// No description provided for @componentsApiFailed.
  ///
  /// In en, this message translates to:
  /// **'Panel operation could not be verified. Check the journal and service state.'**
  String get componentsApiFailed;

  /// No description provided for @componentsPartial.
  ///
  /// In en, this message translates to:
  /// **'The operation stopped after applying some changes. Created files are retained; the installation has not been rolled back.'**
  String get componentsPartial;

  /// No description provided for @componentsResume.
  ///
  /// In en, this message translates to:
  /// **'Resume installation'**
  String get componentsResume;

  /// No description provided for @componentsResumePlan.
  ///
  /// In en, this message translates to:
  /// **'The same job will resume from its saved step. Verified files are reused and credentials are retained. Resource ownership is checked before changes; a conflict stops the operation.'**
  String get componentsResumePlan;

  /// No description provided for @componentsDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading archive'**
  String get componentsDownloading;

  /// No description provided for @componentsExtracting.
  ///
  /// In en, this message translates to:
  /// **'Extracting and verifying files'**
  String get componentsExtracting;

  /// No description provided for @componentsConfiguring.
  ///
  /// In en, this message translates to:
  /// **'Configuring panel in isolated network'**
  String get componentsConfiguring;

  /// No description provided for @componentsStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting service'**
  String get componentsStarting;

  /// No description provided for @componentsChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking state and API'**
  String get componentsChecking;

  /// No description provided for @componentsBuilding.
  ///
  /// In en, this message translates to:
  /// **'Building executables on server'**
  String get componentsBuilding;

  /// No description provided for @componentStepProgress.
  ///
  /// In en, this message translates to:
  /// **'Step {current} of {total}: {step}'**
  String componentStepProgress(int current, int total, String step);

  /// No description provided for @componentsPlanSummary.
  ///
  /// In en, this message translates to:
  /// **'Install the panel and Xray with automatic startup. Panel access is through SSH.'**
  String get componentsPlanSummary;

  /// No description provided for @componentsRunnerSummary.
  ///
  /// In en, this message translates to:
  /// **'The server job service will also be set up.'**
  String get componentsRunnerSummary;

  /// No description provided for @componentsDetails.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get componentsDetails;

  /// No description provided for @componentsEditPlan.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get componentsEditPlan;

  /// No description provided for @vpnUsers.
  ///
  /// In en, this message translates to:
  /// **'Clients'**
  String get vpnUsers;

  /// No description provided for @vpnUsersHelp.
  ///
  /// In en, this message translates to:
  /// **'Create each client once. AntiRKN prepares personal access to every configured managed inbound on every server.'**
  String get vpnUsersHelp;

  /// No description provided for @vpnAddUser.
  ///
  /// In en, this message translates to:
  /// **'Add client'**
  String get vpnAddUser;

  /// No description provided for @vpnSortBy.
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get vpnSortBy;

  /// No description provided for @vpnSortByName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get vpnSortByName;

  /// No description provided for @vpnSortByDate.
  ///
  /// In en, this message translates to:
  /// **'Date created'**
  String get vpnSortByDate;

  /// No description provided for @vpnSortAscending.
  ///
  /// In en, this message translates to:
  /// **'Ascending'**
  String get vpnSortAscending;

  /// No description provided for @vpnSortDescending.
  ///
  /// In en, this message translates to:
  /// **'Descending'**
  String get vpnSortDescending;

  /// No description provided for @vpnDisabledClients.
  ///
  /// In en, this message translates to:
  /// **'Disabled clients'**
  String get vpnDisabledClients;

  /// No description provided for @vpnSyncAndPublish.
  ///
  /// In en, this message translates to:
  /// **'Publish verified profiles'**
  String get vpnSyncAndPublish;

  /// No description provided for @vpnSyncAndPublishDone.
  ///
  /// In en, this message translates to:
  /// **'Profiles published to Drive: {published} of {total}'**
  String vpnSyncAndPublishDone(int published, int total);

  /// No description provided for @vpnSyncAndPublishUpToDate.
  ///
  /// In en, this message translates to:
  /// **'All {total} profiles on Drive are already up to date.'**
  String vpnSyncAndPublishUpToDate(int total);

  /// No description provided for @vpnSyncAndPublishPartial.
  ///
  /// In en, this message translates to:
  /// **'{uploaded} of {total} published to Drive ({upToDate} already up to date).'**
  String vpnSyncAndPublishPartial(int uploaded, int total, int upToDate);

  /// No description provided for @vpnSyncAndPublishWithErrors.
  ///
  /// In en, this message translates to:
  /// **'{uploaded} published, {failed} failed of {total}.'**
  String vpnSyncAndPublishWithErrors(int uploaded, int failed, int total);

  /// No description provided for @vpnSyncAndPublishTooltip.
  ///
  /// In en, this message translates to:
  /// **'Click to publish from the last verified server state; local changes trigger a server check. Press and hold to check all servers and Drive files.'**
  String get vpnSyncAndPublishTooltip;

  /// No description provided for @vpnSyncServerUnverified.
  ///
  /// In en, this message translates to:
  /// **'Server check failed. Current profiles were not published; the previous verified links remain available.'**
  String get vpnSyncServerUnverified;

  /// No description provided for @publicationPreviousVerified.
  ///
  /// In en, this message translates to:
  /// **'Current profile is unverified. The previous verified link remains available.'**
  String get publicationPreviousVerified;

  /// No description provided for @vpnSyncAndPublishFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to fully sync with servers or publish to Drive.'**
  String get vpnSyncAndPublishFailed;

  /// No description provided for @vpnNoUsers.
  ///
  /// In en, this message translates to:
  /// **'No clients yet'**
  String get vpnNoUsers;

  /// No description provided for @vpnLogin.
  ///
  /// In en, this message translates to:
  /// **'Client login'**
  String get vpnLogin;

  /// No description provided for @vpnName.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get vpnName;

  /// No description provided for @vpnEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get vpnEnabled;

  /// No description provided for @vpnDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get vpnDisabled;

  /// No description provided for @vpnSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get vpnSave;

  /// No description provided for @vpnInbounds.
  ///
  /// In en, this message translates to:
  /// **'VLESS'**
  String get vpnInbounds;

  /// No description provided for @vpnAddInbound.
  ///
  /// In en, this message translates to:
  /// **'Add inbound'**
  String get vpnAddInbound;

  /// No description provided for @vpnInboundHelp.
  ///
  /// In en, this message translates to:
  /// **'Each client receives personal access to enabled inbounds with an open lock. Close the lock to reserve an inbound for internal use.'**
  String get vpnInboundHelp;

  /// No description provided for @vpnNoInbounds.
  ///
  /// In en, this message translates to:
  /// **'No inbounds on this server'**
  String get vpnNoInbounds;

  /// No description provided for @vpnTransport.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get vpnTransport;

  /// No description provided for @vpnSecurity.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get vpnSecurity;

  /// No description provided for @vpnListen.
  ///
  /// In en, this message translates to:
  /// **'Listen address'**
  String get vpnListen;

  /// No description provided for @vpnPort.
  ///
  /// In en, this message translates to:
  /// **'Listen port'**
  String get vpnPort;

  /// No description provided for @vpnEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Inbound address (IP or domain)'**
  String get vpnEndpoint;

  /// No description provided for @vpnExternalPort.
  ///
  /// In en, this message translates to:
  /// **'Inbound port for connections'**
  String get vpnExternalPort;

  /// No description provided for @vpnSni.
  ///
  /// In en, this message translates to:
  /// **'Server name (SNI)'**
  String get vpnSni;

  /// No description provided for @vpnTarget.
  ///
  /// In en, this message translates to:
  /// **'REALITY target (host:port)'**
  String get vpnTarget;

  /// No description provided for @vpnPath.
  ///
  /// In en, this message translates to:
  /// **'XHTTP path'**
  String get vpnPath;

  /// No description provided for @vpnHost.
  ///
  /// In en, this message translates to:
  /// **'XHTTP Host (optional)'**
  String get vpnHost;

  /// No description provided for @vpnMode.
  ///
  /// In en, this message translates to:
  /// **'XHTTP mode'**
  String get vpnMode;

  /// No description provided for @vpnCertificate.
  ///
  /// In en, this message translates to:
  /// **'Certificate chain file on server'**
  String get vpnCertificate;

  /// No description provided for @vpnCertificateKey.
  ///
  /// In en, this message translates to:
  /// **'Certificate private key file on server'**
  String get vpnCertificateKey;

  /// No description provided for @vpnTlsHelp.
  ///
  /// In en, this message translates to:
  /// **'Use an existing certificate for the SNI domain. Certificate issuance and renewal are separate tasks.'**
  String get vpnTlsHelp;

  /// No description provided for @vpnRegion.
  ///
  /// In en, this message translates to:
  /// **'Add the explicit RU tag for template filters'**
  String get vpnRegion;

  /// No description provided for @vpnDeleteInbound.
  ///
  /// In en, this message translates to:
  /// **'Delete inbound and its client access'**
  String get vpnDeleteInbound;

  /// No description provided for @vpnDeleteHelp.
  ///
  /// In en, this message translates to:
  /// **'The next plan will remove this inbound and its orphaned server client records. Clients in this app remain.'**
  String get vpnDeleteHelp;

  /// No description provided for @vpnPlan.
  ///
  /// In en, this message translates to:
  /// **'Client access plan'**
  String get vpnPlan;

  /// No description provided for @vpnPlanHelp.
  ///
  /// In en, this message translates to:
  /// **'Apply the listed inbounds and personal access through 3x-ui. A private configuration backup is saved on each server. Xray restarts at completion; connections may briefly pause. Existing clients keep their credentials.'**
  String get vpnPlanHelp;

  /// No description provided for @vpnPrepare.
  ///
  /// In en, this message translates to:
  /// **'Prepare access plan'**
  String get vpnPrepare;

  /// No description provided for @vpnApply.
  ///
  /// In en, this message translates to:
  /// **'Apply plan to all listed servers'**
  String get vpnApply;

  /// No description provided for @vpnPending.
  ///
  /// In en, this message translates to:
  /// **'Access changes are pending on one or more servers. A complete current profile is not ready yet.'**
  String get vpnPending;

  /// No description provided for @vpnPendingReadback.
  ///
  /// In en, this message translates to:
  /// **'The server has not confirmed this resource yet.'**
  String get vpnPendingReadback;

  /// No description provided for @vpnPendingSettings.
  ///
  /// In en, this message translates to:
  /// **'The server reported different settings for this resource.'**
  String get vpnPendingSettings;

  /// No description provided for @vpnPendingClient.
  ///
  /// In en, this message translates to:
  /// **'This client is missing from the confirmed server state.'**
  String get vpnPendingClient;

  /// No description provided for @vpnPendingIdentity.
  ///
  /// In en, this message translates to:
  /// **'The saved server identity must be reviewed before this access can be issued.'**
  String get vpnPendingIdentity;

  /// No description provided for @vpnPendingReview.
  ///
  /// In en, this message translates to:
  /// **'The managed server resource changed and requires review.'**
  String get vpnPendingReview;

  /// No description provided for @vpnPendingResource.
  ///
  /// In en, this message translates to:
  /// **'The access resource is no longer present in the current configuration.'**
  String get vpnPendingResource;

  /// No description provided for @vpnProfile.
  ///
  /// In en, this message translates to:
  /// **'Personal Mihomo profile'**
  String get vpnProfile;

  /// No description provided for @vpnShowProfile.
  ///
  /// In en, this message translates to:
  /// **'Show profile and client credentials'**
  String get vpnShowProfile;

  /// No description provided for @vpnSaveProfile.
  ///
  /// In en, this message translates to:
  /// **'Save YAML'**
  String get vpnSaveProfile;

  /// No description provided for @vpnCopyProfile.
  ///
  /// In en, this message translates to:
  /// **'Copy YAML'**
  String get vpnCopyProfile;

  /// No description provided for @vpnProfileSaved.
  ///
  /// In en, this message translates to:
  /// **'Profile saved'**
  String get vpnProfileSaved;

  /// No description provided for @vpnProfileValidation.
  ///
  /// In en, this message translates to:
  /// **'Structural validation only in this screen. Core and network tests for the presets are documented separately.'**
  String get vpnProfileValidation;

  /// No description provided for @vpnLastProfile.
  ///
  /// In en, this message translates to:
  /// **'The current profile is not ready. The last valid version was retained.'**
  String get vpnLastProfile;

  /// No description provided for @vpnPreviousProfileLink.
  ///
  /// In en, this message translates to:
  /// **'This QR still points to the last verified profile and does not include the pending changes.'**
  String get vpnPreviousProfileLink;

  /// No description provided for @vpnRegenerateProfile.
  ///
  /// In en, this message translates to:
  /// **'Recheck servers and regenerate profile'**
  String get vpnRegenerateProfile;

  /// No description provided for @vpnRegeneratingProfile.
  ///
  /// In en, this message translates to:
  /// **'Rechecking servers and regenerating the profile…'**
  String get vpnRegeneratingProfile;

  /// No description provided for @vpnProfileRegenerated.
  ///
  /// In en, this message translates to:
  /// **'Server state was rechecked and the current profile was regenerated.'**
  String get vpnProfileRegenerated;

  /// No description provided for @vpnInvalid.
  ///
  /// In en, this message translates to:
  /// **'Check names, addresses, ports and the selected transport/security combination.'**
  String get vpnInvalid;

  /// No description provided for @vpnDuplicate.
  ///
  /// In en, this message translates to:
  /// **'Client logins and resource identifiers must be unique.'**
  String get vpnDuplicate;

  /// No description provided for @vpnConflict.
  ///
  /// In en, this message translates to:
  /// **'Server configuration has changed. Refresh and review the conflict before applying again.'**
  String get vpnConflict;

  /// No description provided for @vpnConnection.
  ///
  /// In en, this message translates to:
  /// **'Connect to this server in the Servers section. Pending access changes are retained.'**
  String get vpnConnection;

  /// No description provided for @vpnPanelRequired.
  ///
  /// In en, this message translates to:
  /// **'Connect to the server to load the panel and inbounds. Client management requires access to the panel API.'**
  String get vpnPanelRequired;

  /// No description provided for @vpnRunnerNotReady.
  ///
  /// In en, this message translates to:
  /// **'The server service needs an update. Open this server to update it.'**
  String get vpnRunnerNotReady;

  /// No description provided for @vpnPanelLogin.
  ///
  /// In en, this message translates to:
  /// **'Sign in to 3x-ui on this server to continue.'**
  String get vpnPanelLogin;

  /// No description provided for @vpnDeletionOtherDevice.
  ///
  /// In en, this message translates to:
  /// **'Another device is removing this client. Open the details to continue on this device.'**
  String get vpnDeletionOtherDevice;

  /// No description provided for @vpnRestoreReview.
  ///
  /// In en, this message translates to:
  /// **'Restored from a backup. Open the details to continue.'**
  String get vpnRestoreReview;

  /// No description provided for @vpnWaitingRemoval.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the client removal to finish on this server.'**
  String get vpnWaitingRemoval;

  /// No description provided for @vpnServiceMode.
  ///
  /// In en, this message translates to:
  /// **'The server is in service mode: new clients are not added to it until it returns.'**
  String get vpnServiceMode;

  /// No description provided for @vpnServiceModeOtherDevice.
  ///
  /// In en, this message translates to:
  /// **'Another device is bringing this server back from service mode. Retry the return here to continue on this device.'**
  String get vpnServiceModeOtherDevice;

  /// No description provided for @vpnStorage.
  ///
  /// In en, this message translates to:
  /// **'Could not save the encrypted client database. Retry after resolving the storage error.'**
  String get vpnStorage;

  /// No description provided for @vpnStorageConflict.
  ///
  /// In en, this message translates to:
  /// **'Another application instance changed the client database. Reload before editing.'**
  String get vpnStorageConflict;

  /// No description provided for @vpnIdentity.
  ///
  /// In en, this message translates to:
  /// **'This saved server now has a different address or SSH identity. Its previous access bindings require review.'**
  String get vpnIdentity;

  /// No description provided for @vpnFailed.
  ///
  /// In en, this message translates to:
  /// **'The operation was not confirmed. Refresh the server status or retry the saved operation.'**
  String get vpnFailed;

  /// No description provided for @vpnBusy.
  ///
  /// In en, this message translates to:
  /// **'Another operation is still running, so this change was not made. Try again when it finishes.'**
  String get vpnBusy;

  /// No description provided for @vpnPortBusy.
  ///
  /// In en, this message translates to:
  /// **'The listen address or port is unavailable or conflicts with another inbound.'**
  String get vpnPortBusy;

  /// No description provided for @vpnPartial.
  ///
  /// In en, this message translates to:
  /// **'Some changes may already be applied. Review the saved job and resume it when ready.'**
  String get vpnPartial;

  /// No description provided for @vpnApplying.
  ///
  /// In en, this message translates to:
  /// **'Applying client access'**
  String get vpnApplying;

  /// No description provided for @vpnChecking.
  ///
  /// In en, this message translates to:
  /// **'Verifying the applied configuration'**
  String get vpnChecking;

  /// No description provided for @vpnPrepareStep.
  ///
  /// In en, this message translates to:
  /// **'Checking preconditions and saving the backup'**
  String get vpnPrepareStep;

  /// No description provided for @vpnEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get vpnEdit;

  /// No description provided for @vpnRefreshProfiles.
  ///
  /// In en, this message translates to:
  /// **'Rebuild profiles'**
  String get vpnRefreshProfiles;

  /// No description provided for @vpnSnapshot.
  ///
  /// In en, this message translates to:
  /// **'Last observation'**
  String get vpnSnapshot;

  /// No description provided for @vpnChanged.
  ///
  /// In en, this message translates to:
  /// **'Changes awaiting approval'**
  String get vpnChanged;

  /// No description provided for @vpnEmptyTemplate.
  ///
  /// In en, this message translates to:
  /// **'Choose a base YAML file in Settings.'**
  String get vpnEmptyTemplate;

  /// No description provided for @vpnNoAccess.
  ///
  /// In en, this message translates to:
  /// **'No active inbounds are configured for this client yet.'**
  String get vpnNoAccess;

  /// No description provided for @protocolSoftware.
  ///
  /// In en, this message translates to:
  /// **'Component updates'**
  String get protocolSoftware;

  /// No description provided for @protocolExisting.
  ///
  /// In en, this message translates to:
  /// **'An existing installation or modified files were found. Automatic adoption is unavailable.'**
  String get protocolExisting;

  /// No description provided for @protocolCurrent.
  ///
  /// In en, this message translates to:
  /// **'The verified version supported by this app is installed.'**
  String get protocolCurrent;

  /// No description provided for @protocolInstallPlan.
  ///
  /// In en, this message translates to:
  /// **'Install the selected server component and verify its executables.'**
  String get protocolInstallPlan;

  /// No description provided for @protocolUpdatePlan.
  ///
  /// In en, this message translates to:
  /// **'Replace the executables. The previous version remains available for recovery; configurations and keys are preserved.'**
  String get protocolUpdatePlan;

  /// No description provided for @protocolConfigurationSeparate.
  ///
  /// In en, this message translates to:
  /// **'Installing the software does not create a VPN connection. Endpoint, certificates and peers require separate configuration.'**
  String get protocolConfigurationSeparate;

  /// No description provided for @protocolGoDependency.
  ///
  /// In en, this message translates to:
  /// **'Dependencies: Go 1.26.8 and AWG source verified by SHA-256; Go modules verified against go.sum. Built on the server; requires at least 2000 MiB free space.'**
  String get protocolGoDependency;

  /// No description provided for @protocolPrepared.
  ///
  /// In en, this message translates to:
  /// **'Plan verified'**
  String get protocolPrepared;

  /// No description provided for @protocolBuilt.
  ///
  /// In en, this message translates to:
  /// **'Executables ready'**
  String get protocolBuilt;

  /// No description provided for @protocolStaged.
  ///
  /// In en, this message translates to:
  /// **'New version staged'**
  String get protocolStaged;

  /// No description provided for @protocolSwitched.
  ///
  /// In en, this message translates to:
  /// **'New version installed'**
  String get protocolSwitched;

  /// No description provided for @protocolBuildFailed.
  ///
  /// In en, this message translates to:
  /// **'AmneziaWG build failed. Check Go modules connectivity, server memory and disk space.'**
  String get protocolBuildFailed;

  /// No description provided for @protocolCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Installed version verification failed.'**
  String get protocolCheckFailed;

  /// No description provided for @updatesCheck.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updatesCheck;

  /// No description provided for @updatesCheckedRecently.
  ///
  /// In en, this message translates to:
  /// **'Updates were checked moments ago; the result shown is current.'**
  String get updatesCheckedRecently;

  /// No description provided for @updatesLastChecked.
  ///
  /// In en, this message translates to:
  /// **'Last checked: {time}'**
  String updatesLastChecked(String time);

  /// No description provided for @updatesAutomatic.
  ///
  /// In en, this message translates to:
  /// **'Check for new versions'**
  String get updatesAutomatic;

  /// No description provided for @updatesSuggestions.
  ///
  /// In en, this message translates to:
  /// **'Suggest updates'**
  String get updatesSuggestions;

  /// No description provided for @updatesFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates. The previous result may be stale.'**
  String get updatesFailed;

  /// No description provided for @updatesChecked.
  ///
  /// In en, this message translates to:
  /// **'Last successful check: {date}'**
  String updatesChecked(String date);

  /// No description provided for @updatesLatest.
  ///
  /// In en, this message translates to:
  /// **'latest upstream version'**
  String get updatesLatest;

  /// No description provided for @updatesCompatibility.
  ///
  /// In en, this message translates to:
  /// **'The new version has not been verified for compatibility yet.'**
  String get updatesCompatibility;

  /// No description provided for @updatesAvailable.
  ///
  /// In en, this message translates to:
  /// **'{component}: update available {current} → {latest}.'**
  String updatesAvailable(String component, String current, String latest);

  /// No description provided for @protocolRestart.
  ///
  /// In en, this message translates to:
  /// **'Services to restart: {services}. Connections may be interrupted. A configuration backup remains with the job journal.'**
  String protocolRestart(String services);

  /// No description provided for @protocolPrerequisites.
  ///
  /// In en, this message translates to:
  /// **'Installation requires Ubuntu x86_64, Python 3.8+/SQLite, systemd 235+ and ca-certificates. Free space: TrustTunnel — 150 MiB; AmneziaWG — 2000 MiB and an available /dev/net/tun.'**
  String get protocolPrerequisites;

  /// No description provided for @componentManage.
  ///
  /// In en, this message translates to:
  /// **'Manage / update'**
  String get componentManage;

  /// No description provided for @panelObservedHelp.
  ///
  /// In en, this message translates to:
  /// **'Existing panel detected. Its inbounds are shown below; the panel settings and existing clients are preserved.'**
  String get panelObservedHelp;

  /// No description provided for @panelDiscoveryFailed.
  ///
  /// In en, this message translates to:
  /// **'Some panel settings could not be read. Refresh to retry.'**
  String get panelDiscoveryFailed;

  /// No description provided for @vpnInternal.
  ///
  /// In en, this message translates to:
  /// **'Internal use'**
  String get vpnInternal;

  /// No description provided for @vpnClientAccess.
  ///
  /// In en, this message translates to:
  /// **'Assign to clients'**
  String get vpnClientAccess;

  /// No description provided for @vpnInternalHelp.
  ///
  /// In en, this message translates to:
  /// **'Keep the inbound enabled, exclude it from client profiles and revoke AntiRKN client access through the plan.'**
  String get vpnInternalHelp;

  /// No description provided for @vpnObserved.
  ///
  /// In en, this message translates to:
  /// **'Existing · outside client management'**
  String get vpnObserved;

  /// No description provided for @vpnPendingDeletion.
  ///
  /// In en, this message translates to:
  /// **'Deleting · waiting for the server to confirm'**
  String get vpnPendingDeletion;

  /// No description provided for @vpnObservedHelp.
  ///
  /// In en, this message translates to:
  /// **'Existing settings and clients are preserved. This inbound is not assigned to AntiRKN clients.'**
  String get vpnObservedHelp;

  /// No description provided for @panelCliHelp.
  ///
  /// In en, this message translates to:
  /// **'Install the official x-ui command from 3x-ui 3.7.0. Panel settings, clients and service remain unchanged.'**
  String get panelCliHelp;

  /// No description provided for @panelCliInstall.
  ///
  /// In en, this message translates to:
  /// **'Install x-ui management menu'**
  String get panelCliInstall;

  /// No description provided for @panelInstallMethod.
  ///
  /// In en, this message translates to:
  /// **'Official GitHub release archive and x-ui.sh menu. AntiRKN installs and configures them in recoverable steps; upstream install.sh is not run.'**
  String get panelInstallMethod;

  /// No description provided for @vpnConnectionAddress.
  ///
  /// In en, this message translates to:
  /// **'Inbound connection address'**
  String get vpnConnectionAddress;

  /// No description provided for @vpnConnectionAddressHelp.
  ///
  /// In en, this message translates to:
  /// **'Uses the server address and listen port by default. Change these only when the inbound is reached through a different address or port (NAT / reverse proxy).'**
  String get vpnConnectionAddressHelp;

  /// No description provided for @xhttpAdvanced.
  ///
  /// In en, this message translates to:
  /// **'XHTTP settings'**
  String get xhttpAdvanced;

  /// No description provided for @xhttpDefault.
  ///
  /// In en, this message translates to:
  /// **'Default (leave empty)'**
  String get xhttpDefault;

  /// No description provided for @xmuxHelp.
  ///
  /// In en, this message translates to:
  /// **'Connection reuse settings shared by this inbound’s client profiles. maxConcurrency and maxConnections cannot both be greater than zero. Ranges use min-max.'**
  String get xmuxHelp;

  /// No description provided for @xhttpHeaders.
  ///
  /// In en, this message translates to:
  /// **'HTTP headers'**
  String get xhttpHeaders;

  /// No description provided for @vpnRegenerateReality.
  ///
  /// In en, this message translates to:
  /// **'Regenerate keys'**
  String get vpnRegenerateReality;

  /// No description provided for @vpnRealityRegenerated.
  ///
  /// In en, this message translates to:
  /// **'New REALITY keys and Short ID will be applied with the plan. Client profiles will be rebuilt.'**
  String get vpnRealityRegenerated;

  /// No description provided for @vpnRealityKeyPlan.
  ///
  /// In en, this message translates to:
  /// **'Apply the selected REALITY key revision and rebuild client profiles.'**
  String get vpnRealityKeyPlan;

  /// No description provided for @realityScan.
  ///
  /// In en, this message translates to:
  /// **'Scan target'**
  String get realityScan;

  /// No description provided for @realityScanHelp.
  ///
  /// In en, this message translates to:
  /// **'Checks TLS and the certificate from this server using 3x-ui. SNI follows Target until you change it.'**
  String get realityScanHelp;

  /// No description provided for @realityScanFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not check the target. Connect to the server and verify panel access.'**
  String get realityScanFailed;

  /// No description provided for @realityFeasible.
  ///
  /// In en, this message translates to:
  /// **'Suitable for REALITY'**
  String get realityFeasible;

  /// No description provided for @realityNotFeasible.
  ///
  /// In en, this message translates to:
  /// **'Not suitable for REALITY'**
  String get realityNotFeasible;

  /// No description provided for @realityScanPrivate.
  ///
  /// In en, this message translates to:
  /// **'The target resolves to a private address.'**
  String get realityScanPrivate;

  /// No description provided for @realityScanTls.
  ///
  /// In en, this message translates to:
  /// **'TLS 1.3 was not negotiated.'**
  String get realityScanTls;

  /// No description provided for @realityScanH2.
  ///
  /// In en, this message translates to:
  /// **'HTTP/2 (h2) was not negotiated.'**
  String get realityScanH2;

  /// No description provided for @realityScanCurve.
  ///
  /// In en, this message translates to:
  /// **'X25519 key exchange was not negotiated.'**
  String get realityScanCurve;

  /// No description provided for @realityScanCertificate.
  ///
  /// In en, this message translates to:
  /// **'The certificate is not valid for this SNI or is not trusted.'**
  String get realityScanCertificate;

  /// No description provided for @realityScanUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The target could not complete a TLS handshake.'**
  String get realityScanUnavailable;

  /// No description provided for @realitySniUsed.
  ///
  /// In en, this message translates to:
  /// **'SNI used'**
  String get realitySniUsed;

  /// No description provided for @realityCertificate.
  ///
  /// In en, this message translates to:
  /// **'Certificate'**
  String get realityCertificate;

  /// No description provided for @realityCertificateExpiry.
  ///
  /// In en, this message translates to:
  /// **'Certificate expires'**
  String get realityCertificateExpiry;

  /// No description provided for @realityKeyExchange.
  ///
  /// In en, this message translates to:
  /// **'Key exchange'**
  String get realityKeyExchange;

  /// No description provided for @realityLatency.
  ///
  /// In en, this message translates to:
  /// **'Latency, ms'**
  String get realityLatency;

  /// No description provided for @realityCertificateNames.
  ///
  /// In en, this message translates to:
  /// **'Names from the certificate — select an SNI, then scan again'**
  String get realityCertificateNames;

  /// No description provided for @softwareTitle.
  ///
  /// In en, this message translates to:
  /// **'Server components'**
  String get softwareTitle;

  /// No description provided for @softwareInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get softwareInstall;

  /// No description provided for @softwareInspect.
  ///
  /// In en, this message translates to:
  /// **'Inspect installation'**
  String get softwareInspect;

  /// No description provided for @softwareUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get softwareUpdate;

  /// No description provided for @softwareUpdateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get softwareUpdateAvailable;

  /// No description provided for @softwarePanelAccess.
  ///
  /// In en, this message translates to:
  /// **'Panel access'**
  String get softwarePanelAccess;

  /// No description provided for @panelAutomaticAddress.
  ///
  /// In en, this message translates to:
  /// **'A free port and random panel path are assigned automatically.'**
  String get panelAutomaticAddress;

  /// No description provided for @panelUpdateManual.
  ///
  /// In en, this message translates to:
  /// **'A new version is available. Applying 3x-ui/Xray updates in the app is not supported yet; use the x-ui command on the server.'**
  String get panelUpdateManual;

  /// No description provided for @aptTitle.
  ///
  /// In en, this message translates to:
  /// **'Ubuntu updates'**
  String get aptTitle;

  /// No description provided for @aptUpdate.
  ///
  /// In en, this message translates to:
  /// **'Refresh APT indexes'**
  String get aptUpdate;

  /// No description provided for @aptUpgrade.
  ///
  /// In en, this message translates to:
  /// **'Upgrade packages'**
  String get aptUpgrade;

  /// No description provided for @aptUpdatePlan.
  ///
  /// In en, this message translates to:
  /// **'Refresh available package lists (apt update). Installed packages will stay as they are.'**
  String get aptUpdatePlan;

  /// No description provided for @aptUpgradePlan.
  ///
  /// In en, this message translates to:
  /// **'Upgrade the listed packages using the current APT indexes. Keep local configuration files. No packages are removed; new dependencies and reboot are separate actions. Services may restart.'**
  String get aptUpgradePlan;

  /// No description provided for @aptCurrent.
  ///
  /// In en, this message translates to:
  /// **'No upgrades in the current indexes. Refresh APT indexes to check again.'**
  String get aptCurrent;

  /// No description provided for @aptPackageCount.
  ///
  /// In en, this message translates to:
  /// **'Packages to upgrade: {count}'**
  String aptPackageCount(int count);

  /// No description provided for @aptReboot.
  ///
  /// In en, this message translates to:
  /// **'The server requires a reboot. Restart it when convenient.'**
  String get aptReboot;

  /// No description provided for @aptUpdating.
  ///
  /// In en, this message translates to:
  /// **'Refreshing APT indexes…'**
  String get aptUpdating;

  /// No description provided for @aptUpgrading.
  ///
  /// In en, this message translates to:
  /// **'Upgrading Ubuntu packages…'**
  String get aptUpgrading;

  /// No description provided for @aptRunningHelp.
  ///
  /// In en, this message translates to:
  /// **'The job continues after the app closes. Cancellation waits for the current APT command to finish.'**
  String get aptRunningHelp;

  /// No description provided for @aptFailed.
  ///
  /// In en, this message translates to:
  /// **'APT did not complete the command. Check repositories, disk space and package manager locks, then prepare a new plan.'**
  String get aptFailed;

  /// No description provided for @aptConflict.
  ///
  /// In en, this message translates to:
  /// **'The package state changed. Prepare a new upgrade plan.'**
  String get aptConflict;

  /// No description provided for @aptInterrupted.
  ///
  /// In en, this message translates to:
  /// **'The upgrade may be partially applied. Check APT on the server before preparing a new plan; an interrupted command is not repeated automatically.'**
  String get aptInterrupted;

  /// No description provided for @serverDetails.
  ///
  /// In en, this message translates to:
  /// **'Server and network details'**
  String get serverDetails;

  /// No description provided for @panelConnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in to 3x-ui'**
  String get panelConnectTitle;

  /// No description provided for @panelAuthFailed.
  ///
  /// In en, this message translates to:
  /// **'3x-ui rejected the panel username or password. Check the panel account; SSH credentials are separate.'**
  String get panelAuthFailed;

  /// No description provided for @panelUnreachable.
  ///
  /// In en, this message translates to:
  /// **'The runner could not reach the panel API. Check that x-ui is running and that its listening address and HTTPS certificate are valid.'**
  String get panelUnreachable;

  /// No description provided for @panelConnectUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Could not identify a unique systemd panel at this port. Docker API connections are not supported yet.'**
  String get panelConnectUnsupported;

  /// No description provided for @panelLoginLimited.
  ///
  /// In en, this message translates to:
  /// **'3x-ui temporarily blocked login attempts. Wait before trying again.'**
  String get panelLoginLimited;

  /// No description provided for @panelUsername.
  ///
  /// In en, this message translates to:
  /// **'Panel username'**
  String get panelUsername;

  /// No description provided for @panelConnectHelp.
  ///
  /// In en, this message translates to:
  /// **'Enter the 3x-ui administrator account to view and edit through its API. Access will be saved for future connections.'**
  String get panelConnectHelp;

  /// No description provided for @observedClientsKept.
  ///
  /// In en, this message translates to:
  /// **'Existing clients and settings outside this plan are preserved.'**
  String get observedClientsKept;

  /// No description provided for @observedFullConfig.
  ///
  /// In en, this message translates to:
  /// **'Full configuration'**
  String get observedFullConfig;

  /// No description provided for @observedEditPlan.
  ///
  /// In en, this message translates to:
  /// **'Save changes to the existing inbound and restart Xray. Active connections may be interrupted.'**
  String get observedEditPlan;

  /// No description provided for @componentUpdateUnverified.
  ///
  /// In en, this message translates to:
  /// **'This release is not yet included in the app’s verified versions. The installed version is retained.'**
  String get componentUpdateUnverified;

  /// No description provided for @observedTransportJson.
  ///
  /// In en, this message translates to:
  /// **'Transport settings (JSON)'**
  String get observedTransportJson;

  /// No description provided for @observedTransportInvalid.
  ///
  /// In en, this message translates to:
  /// **'The JSON is invalid: it must be an object, with realitySettings and xhttpSettings as objects. Fix it to save or to edit the fields.'**
  String get observedTransportInvalid;

  /// No description provided for @panelUpdateSummary.
  ///
  /// In en, this message translates to:
  /// **'Save settings and clients, create a backup, and update 3x-ui together with Xray. VPN connections will briefly stop during the restart.'**
  String get panelUpdateSummary;

  /// No description provided for @panelUpdateRecovery.
  ///
  /// In en, this message translates to:
  /// **'On failure, the backup remains on the server. Resume checks files already replaced. The database is not rolled back automatically.'**
  String get panelUpdateRecovery;

  /// No description provided for @panelUpdateCompatibility.
  ///
  /// In en, this message translates to:
  /// **'Updates require verified versions of a standard 3x-ui installation with systemd and SQLite. Newer Xray cores are never downgraded.'**
  String get panelUpdateCompatibility;

  /// No description provided for @panelUpdatePreparing.
  ///
  /// In en, this message translates to:
  /// **'Checking the installed panel'**
  String get panelUpdatePreparing;

  /// No description provided for @panelUpdateBackup.
  ///
  /// In en, this message translates to:
  /// **'Saving a backup and validating Xray'**
  String get panelUpdateBackup;

  /// No description provided for @panelUpdateSwitching.
  ///
  /// In en, this message translates to:
  /// **'Updating 3x-ui and Xray, restarting'**
  String get panelUpdateSwitching;

  /// No description provided for @panelLoginOnce.
  ///
  /// In en, this message translates to:
  /// **'Sign in to 3x-ui. Your credentials will be saved for future connections.'**
  String get panelLoginOnce;

  /// No description provided for @panelLoginRequiredFields.
  ///
  /// In en, this message translates to:
  /// **'Enter the panel username and password.'**
  String get panelLoginRequiredFields;

  /// No description provided for @panelUpdateCoreCompatibility.
  ///
  /// In en, this message translates to:
  /// **'Xray 26.9.8/26.9.9 is incompatible with the verified Mihomo REALITY profiles. This plan uses compatible core 26.7.28; if already installed, its version stays the same.'**
  String get panelUpdateCoreCompatibility;

  /// No description provided for @awgAdd.
  ///
  /// In en, this message translates to:
  /// **'Add interface'**
  String get awgAdd;

  /// No description provided for @awgRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh state'**
  String get awgRefresh;

  /// No description provided for @awgEmpty.
  ///
  /// In en, this message translates to:
  /// **'No managed AWG interfaces yet.'**
  String get awgEmpty;

  /// No description provided for @awgConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Configuration confirmed on server'**
  String get awgConfirmed;

  /// No description provided for @awgHandshake.
  ///
  /// In en, this message translates to:
  /// **'Last handshake'**
  String get awgHandshake;

  /// No description provided for @awgNoHandshake.
  ///
  /// In en, this message translates to:
  /// **'Client has not connected yet'**
  String get awgNoHandshake;

  /// No description provided for @awgEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Connection IP or domain'**
  String get awgEndpoint;

  /// No description provided for @awgPort.
  ///
  /// In en, this message translates to:
  /// **'UDP port'**
  String get awgPort;

  /// No description provided for @awgExternalPort.
  ///
  /// In en, this message translates to:
  /// **'External UDP port (NAT)'**
  String get awgExternalPort;

  /// No description provided for @awgAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced settings'**
  String get awgAdvanced;

  /// No description provided for @awgPool.
  ///
  /// In en, this message translates to:
  /// **'Client IPv4 pool (CIDR)'**
  String get awgPool;

  /// No description provided for @awgPool6.
  ///
  /// In en, this message translates to:
  /// **'IPv6 ULA pool /64 (optional)'**
  String get awgPool6;

  /// No description provided for @awgDefaultsHelp.
  ///
  /// In en, this message translates to:
  /// **'Defaults follow AmneziaVPN 3.1. Client keys and addresses are generated automatically and retained when profiles are rebuilt. S1–S4 must match when RandomTrailers is enabled.'**
  String get awgDefaultsHelp;

  /// No description provided for @awgCps.
  ///
  /// In en, this message translates to:
  /// **'Initial obfuscation packet I1'**
  String get awgCps;

  /// No description provided for @awgNetworkPlan.
  ///
  /// In en, this message translates to:
  /// **'The plan enables IP forwarding and this interface’s UDP, forwarding and NAT rules. Shared settings update all client profiles; connections may briefly stop.'**
  String get awgNetworkPlan;

  /// No description provided for @awgPrerequisites.
  ///
  /// In en, this message translates to:
  /// **'A new interface requires managed AmneziaWG, TUN, iptables/ip6tables and administrator access.'**
  String get awgPrerequisites;

  /// No description provided for @awgPoolConflict.
  ///
  /// In en, this message translates to:
  /// **'The pool overlaps an existing route or interface. Choose another range.'**
  String get awgPoolConflict;

  /// No description provided for @awgPoolFull.
  ///
  /// In en, this message translates to:
  /// **'The pool has insufficient free client addresses.'**
  String get awgPoolFull;

  /// No description provided for @awgObserved.
  ///
  /// In en, this message translates to:
  /// **'Existing installations'**
  String get awgObserved;

  /// No description provided for @awgPeersPreserved.
  ///
  /// In en, this message translates to:
  /// **'Existing peers, keys and untouched fields will be preserved. Update previously issued client configurations after changing shared parameters.'**
  String get awgPeersPreserved;

  /// No description provided for @awgExternalUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Read-only: this installation has no verified editing adapter yet.'**
  String get awgExternalUnsupported;

  /// No description provided for @awgDockerPortHelp.
  ///
  /// In en, this message translates to:
  /// **'Docker publishes this port, so it is preserved when editing. Moving it requires recreating the container with a new port mapping.'**
  String get awgDockerPortHelp;

  /// No description provided for @ttAdd.
  ///
  /// In en, this message translates to:
  /// **'Add endpoint'**
  String get ttAdd;

  /// No description provided for @ttEmpty.
  ///
  /// In en, this message translates to:
  /// **'No managed TrustTunnel endpoints yet.'**
  String get ttEmpty;

  /// No description provided for @ttPort.
  ///
  /// In en, this message translates to:
  /// **'Listening port'**
  String get ttPort;

  /// No description provided for @ttExternalPort.
  ///
  /// In en, this message translates to:
  /// **'Connection port (external port for NAT)'**
  String get ttExternalPort;

  /// No description provided for @ttDomain.
  ///
  /// In en, this message translates to:
  /// **'TLS domain (SNI)'**
  String get ttDomain;

  /// No description provided for @ttOutbound.
  ///
  /// In en, this message translates to:
  /// **'Outbound connection'**
  String get ttOutbound;

  /// No description provided for @ttDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get ttDirect;

  /// No description provided for @ttSocksAddress.
  ///
  /// In en, this message translates to:
  /// **'SOCKS5 address and port'**
  String get ttSocksAddress;

  /// No description provided for @ttSocksHelp.
  ///
  /// In en, this message translates to:
  /// **'For example, 127.0.0.1:1080 on this server. A local SOCKS5 proxy without authentication is supported; UDP also requires UDP support in SOCKS5 and its upstream route.'**
  String get ttSocksHelp;

  /// No description provided for @ttQuic.
  ///
  /// In en, this message translates to:
  /// **'QUIC / HTTP/3'**
  String get ttQuic;

  /// No description provided for @ttIpv6.
  ///
  /// In en, this message translates to:
  /// **'Allow outgoing IPv6'**
  String get ttIpv6;

  /// No description provided for @ttAllowPrivate.
  ///
  /// In en, this message translates to:
  /// **'Allow access to private networks'**
  String get ttAllowPrivate;

  /// No description provided for @ttRotate.
  ///
  /// In en, this message translates to:
  /// **'Replace passwords for all clients of this endpoint'**
  String get ttRotate;

  /// No description provided for @ttRegeneratePasswords.
  ///
  /// In en, this message translates to:
  /// **'Regenerate passwords'**
  String get ttRegeneratePasswords;

  /// No description provided for @ttPasswordsRegenerated.
  ///
  /// In en, this message translates to:
  /// **'New passwords for all clients will be applied with the plan. Client profiles will be rebuilt.'**
  String get ttPasswordsRegenerated;

  /// No description provided for @ttCertificates.
  ///
  /// In en, this message translates to:
  /// **'TLS certificates'**
  String get ttCertificates;

  /// No description provided for @ttAddCertificate.
  ///
  /// In en, this message translates to:
  /// **'Add or issue certificate'**
  String get ttAddCertificate;

  /// No description provided for @ttCertificateSource.
  ///
  /// In en, this message translates to:
  /// **'Certificate source'**
  String get ttCertificateSource;

  /// No description provided for @ttServerFiles.
  ///
  /// In en, this message translates to:
  /// **'Existing server files'**
  String get ttServerFiles;

  /// No description provided for @ttImportPem.
  ///
  /// In en, this message translates to:
  /// **'Import PEM files'**
  String get ttImportPem;

  /// No description provided for @ttIssueAcme.
  ///
  /// In en, this message translates to:
  /// **'Issue with ACME HTTP-01'**
  String get ttIssueAcme;

  /// No description provided for @ttFilesHelp.
  ///
  /// In en, this message translates to:
  /// **'Select discovered files or enter server paths. The existing issuer continues renewal; AntiRKN checks changes and restarts linked TrustTunnel services.'**
  String get ttFilesHelp;

  /// No description provided for @ttImportHelp.
  ///
  /// In en, this message translates to:
  /// **'Select the full certificate chain and its private key. Files are copied securely to the server. Imported files need a new import when renewed.'**
  String get ttImportHelp;

  /// No description provided for @ttExpectedIps.
  ///
  /// In en, this message translates to:
  /// **'Expected domain IPs, separated by commas'**
  String get ttExpectedIps;

  /// No description provided for @ttAcmeEmail.
  ///
  /// In en, this message translates to:
  /// **'Email for ACME registration'**
  String get ttAcmeEmail;

  /// No description provided for @ttAcmeHelp.
  ///
  /// In en, this message translates to:
  /// **'Server IPs are detected automatically. The domain must point to this server, and TCP port 80 must be reachable from the internet. Confirmation issues a Let’s Encrypt certificate and enables automatic renewal. No email is required.'**
  String get ttAcmeHelp;

  /// No description provided for @ttExpiry.
  ///
  /// In en, this message translates to:
  /// **'Valid until'**
  String get ttExpiry;

  /// No description provided for @ttLastSuccess.
  ///
  /// In en, this message translates to:
  /// **'Last successful check'**
  String get ttLastSuccess;

  /// No description provided for @ttNextCheck.
  ///
  /// In en, this message translates to:
  /// **'Next check'**
  String get ttNextCheck;

  /// No description provided for @ttExpirySoon.
  ///
  /// In en, this message translates to:
  /// **'Certificate expires in less than 21 days.'**
  String get ttExpirySoon;

  /// No description provided for @ttRenewAcme.
  ///
  /// In en, this message translates to:
  /// **'Automatic renewal with Certbot'**
  String get ttRenewAcme;

  /// No description provided for @ttRenewExternal.
  ///
  /// In en, this message translates to:
  /// **'Renewed by the existing issuer'**
  String get ttRenewExternal;

  /// No description provided for @ttRenewImport.
  ///
  /// In en, this message translates to:
  /// **'Update by importing renewed files'**
  String get ttRenewImport;

  /// No description provided for @ttRestartPlan.
  ///
  /// In en, this message translates to:
  /// **'After a certificate or configuration change, restart TrustTunnel and verify the service. Active connections may be interrupted briefly.'**
  String get ttRestartPlan;

  /// No description provided for @ttDnsChecked.
  ///
  /// In en, this message translates to:
  /// **'DNS matches the selected IPs'**
  String get ttDnsChecked;

  /// No description provided for @ttCertbotPresent.
  ///
  /// In en, this message translates to:
  /// **'Installed Certbot'**
  String get ttCertbotPresent;

  /// No description provided for @ttCertbotInstall.
  ///
  /// In en, this message translates to:
  /// **'Install Certbot and its required dependencies'**
  String get ttCertbotInstall;

  /// No description provided for @ttPreserveUsers.
  ///
  /// In en, this message translates to:
  /// **'Existing users, passwords and untouched configuration fields are preserved.'**
  String get ttPreserveUsers;

  /// No description provided for @ttKeepCertificate.
  ///
  /// In en, this message translates to:
  /// **'Keep existing certificate'**
  String get ttKeepCertificate;

  /// No description provided for @ttChooseCertificate.
  ///
  /// In en, this message translates to:
  /// **'Select certificate'**
  String get ttChooseCertificate;

  /// No description provided for @ttNeedCertificate.
  ///
  /// In en, this message translates to:
  /// **'Select an existing certificate or issue one for the entered SNI.'**
  String get ttNeedCertificate;

  /// No description provided for @ttCertificatePending.
  ///
  /// In en, this message translates to:
  /// **'Certificate issuance was submitted to the server. The certificate will be selected automatically after it succeeds.'**
  String get ttCertificatePending;

  /// No description provided for @ttPrerequisites.
  ///
  /// In en, this message translates to:
  /// **'Install the verified TrustTunnel version first.'**
  String get ttPrerequisites;

  /// No description provided for @ttUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This TrustTunnel installation or configuration is not supported for editing.'**
  String get ttUnsupported;

  /// No description provided for @ttSocksFailed.
  ///
  /// In en, this message translates to:
  /// **'SOCKS5 did not accept a connection without authentication. Check its address, port and configuration.'**
  String get ttSocksFailed;

  /// No description provided for @ttCertInvalid.
  ///
  /// In en, this message translates to:
  /// **'Certificate validation failed: check domain, validity, full chain and matching private key.'**
  String get ttCertInvalid;

  /// No description provided for @ttRestartFailed.
  ///
  /// In en, this message translates to:
  /// **'TrustTunnel did not start with the expected certificate. The previous certificate was restored where available; check server status.'**
  String get ttRestartFailed;

  /// No description provided for @ttDnsFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to resolve the domain’s A/AAAA records.'**
  String get ttDnsFailed;

  /// No description provided for @ttDnsMismatch.
  ///
  /// In en, this message translates to:
  /// **'The domain points to a different IP. Set its A/AAAA records to this server’s IPs and try again.'**
  String get ttDnsMismatch;

  /// No description provided for @ttAcmePortBusy.
  ///
  /// In en, this message translates to:
  /// **'TCP port 80 is occupied. HTTP-01 standalone issuance cannot start.'**
  String get ttAcmePortBusy;

  /// No description provided for @ttCertbotRequired.
  ///
  /// In en, this message translates to:
  /// **'Certbot could not be installed after refreshing the APT indexes. Check the Ubuntu repositories and retry this request.'**
  String get ttCertbotRequired;

  /// No description provided for @ttAcmeFailed.
  ///
  /// In en, this message translates to:
  /// **'ACME issuance or renewal failed. Check public DNS, port 80 reachability and the ACME log on the server.'**
  String get ttAcmeFailed;

  /// No description provided for @backupTitle.
  ///
  /// In en, this message translates to:
  /// **'Backups'**
  String get backupTitle;

  /// No description provided for @backupHelp.
  ///
  /// In en, this message translates to:
  /// **'Save servers, clients, keys, templates and change history in an encrypted file to restore on another installation.'**
  String get backupHelp;

  /// No description provided for @backupExport.
  ///
  /// In en, this message translates to:
  /// **'Back up'**
  String get backupExport;

  /// No description provided for @backupImport.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get backupImport;

  /// No description provided for @backupPassword.
  ///
  /// In en, this message translates to:
  /// **'Backup password'**
  String get backupPassword;

  /// No description provided for @backupRepeat.
  ///
  /// In en, this message translates to:
  /// **'Repeat password'**
  String get backupRepeat;

  /// No description provided for @backupPasswordHelp.
  ///
  /// In en, this message translates to:
  /// **'Use a separate password of at least 12 characters. Restoration requires the file and this password. The app does not save it.'**
  String get backupPasswordHelp;

  /// No description provided for @backupPasswordMismatch.
  ///
  /// In en, this message translates to:
  /// **'Enter at least 12 characters; both fields must match when creating a backup.'**
  String get backupPasswordMismatch;

  /// No description provided for @backupShowPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get backupShowPassword;

  /// No description provided for @backupHidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get backupHidePassword;

  /// No description provided for @backupInvalid.
  ///
  /// In en, this message translates to:
  /// **'Incorrect password or damaged backup. Your data was not replaced.'**
  String get backupInvalid;

  /// No description provided for @backupVersion.
  ///
  /// In en, this message translates to:
  /// **'This app version does not support the backup format.'**
  String get backupVersion;

  /// No description provided for @backupTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The backup exceeds 64 MiB.'**
  String get backupTooLarge;

  /// No description provided for @backupChanged.
  ///
  /// In en, this message translates to:
  /// **'Data changed after the preview. Select the backup again and review its contents.'**
  String get backupChanged;

  /// No description provided for @backupStorage.
  ///
  /// In en, this message translates to:
  /// **'Could not read or write storage. Restoration was not applied.'**
  String get backupStorage;

  /// No description provided for @backupFileError.
  ///
  /// In en, this message translates to:
  /// **'Could not read or save the file. Check access and try again.'**
  String get backupFileError;

  /// No description provided for @backupWorking.
  ///
  /// In en, this message translates to:
  /// **'Processing backup…'**
  String get backupWorking;

  /// No description provided for @backupSaved.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup saved.'**
  String get backupSaved;

  /// No description provided for @backupSummary.
  ///
  /// In en, this message translates to:
  /// **'Created: {date}\nServers: {servers}\nClients: {users}'**
  String backupSummary(String date, int servers, int users);

  /// No description provided for @backupReplaceHelp.
  ///
  /// In en, this message translates to:
  /// **'Current servers, clients and templates will be replaced by the backup. Save a separate backup of your current data first if you need it. SSH connections will close. The app will reopen the restored workspace; unfinished VPN operations will require a new decision. This device’s preferences will be retained.'**
  String get backupReplaceHelp;

  /// No description provided for @backupActiveWork.
  ///
  /// In en, this message translates to:
  /// **'Wait for the current operation or data save to finish, then try again.'**
  String get backupActiveWork;

  /// No description provided for @backupClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get backupClose;

  /// No description provided for @backupCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get backupCancel;

  /// No description provided for @backupReplace.
  ///
  /// In en, this message translates to:
  /// **'Replace and restore'**
  String get backupReplace;

  /// No description provided for @backupSelect.
  ///
  /// In en, this message translates to:
  /// **'Select file'**
  String get backupSelect;

  /// No description provided for @backupOperationReview.
  ///
  /// In en, this message translates to:
  /// **'This operation came from another device or a backup and is not submitted automatically. Check the server and approve a new plan, or choose to cancel or retry the existing job.'**
  String get backupOperationReview;

  /// No description provided for @backupReviewServer.
  ///
  /// In en, this message translates to:
  /// **'Check server state'**
  String get backupReviewServer;

  /// No description provided for @syncEffectsBlocked.
  ///
  /// In en, this message translates to:
  /// **'Resolve change conflicts in Settings first. Server actions and profile export are paused.'**
  String get syncEffectsBlocked;

  /// No description provided for @googleAccountHelp.
  ///
  /// In en, this message translates to:
  /// **'Sign in to Google to sync your devices.'**
  String get googleAccountHelp;

  /// No description provided for @googleSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in to Google'**
  String get googleSignIn;

  /// No description provided for @googleSwitchAccount.
  ///
  /// In en, this message translates to:
  /// **'Switch account'**
  String get googleSwitchAccount;

  /// No description provided for @googleSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get googleSignOut;

  /// No description provided for @googleWorking.
  ///
  /// In en, this message translates to:
  /// **'Connecting to Google…'**
  String get googleWorking;

  /// No description provided for @googleConfigurationError.
  ///
  /// In en, this message translates to:
  /// **'Google sign-in is not configured for this build. Check the Android client and app certificate.'**
  String get googleConfigurationError;

  /// No description provided for @googleDenied.
  ///
  /// In en, this message translates to:
  /// **'Google Drive access was not granted. Sign in again and allow access.'**
  String get googleDenied;

  /// No description provided for @googleNetworkError.
  ///
  /// In en, this message translates to:
  /// **'Could not reach Google. Check your connection and sign in again.'**
  String get googleNetworkError;

  /// No description provided for @googleStorageError.
  ///
  /// In en, this message translates to:
  /// **'Could not save the account in secure storage. Try again.'**
  String get googleStorageError;

  /// No description provided for @googleReauthorize.
  ///
  /// In en, this message translates to:
  /// **'Please sign in to Google again.'**
  String get googleReauthorize;

  /// No description provided for @googleUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Google sign-in is unavailable. Check Google Play services and try again.'**
  String get googleUnavailable;

  /// No description provided for @autoSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Automatic sync'**
  String get autoSyncTitle;

  /// No description provided for @autoSyncDisabled.
  ///
  /// In en, this message translates to:
  /// **'Automatic sync is off.'**
  String get autoSyncDisabled;

  /// No description provided for @autoSyncWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting to sync'**
  String get autoSyncWaiting;

  /// No description provided for @autoSyncWorking.
  ///
  /// In en, this message translates to:
  /// **'Exchanging data with Google Drive…'**
  String get autoSyncWorking;

  /// No description provided for @autoSyncDone.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get autoSyncDone;

  /// No description provided for @autoSyncEditing.
  ///
  /// In en, this message translates to:
  /// **'A newer version from Google Drive is downloaded. It is applied as soon as editors and dialogs are closed and current operations finish.'**
  String get autoSyncEditing;

  /// No description provided for @autoSyncConflict.
  ///
  /// In en, this message translates to:
  /// **'This device has unsent changes, and Google Drive holds a different version. Nothing was overwritten: the changes stay on this device and are not uploaded automatically.'**
  String get autoSyncConflict;

  /// No description provided for @autoSyncError.
  ///
  /// In en, this message translates to:
  /// **'The exchange did not finish. Your data is saved on this device. The next attempt happens after the next edit, or when the app enters the background or you return to it.'**
  String get autoSyncError;

  /// No description provided for @autoSyncRetrying.
  ///
  /// In en, this message translates to:
  /// **'No connection to Google Drive. Your data is saved on this device; the app will retry automatically.'**
  String get autoSyncRetrying;

  /// No description provided for @autoSyncRemoteNewer.
  ///
  /// In en, this message translates to:
  /// **'Google Drive has a newer version. It loads when you return to the app; nothing was uploaded from this device.'**
  String get autoSyncRemoteNewer;

  /// No description provided for @autoSyncDiverged.
  ///
  /// In en, this message translates to:
  /// **'This device has unsent changes, and Google Drive holds another version. Automatic exchange is paused and nothing was overwritten. Choose which data to keep.'**
  String get autoSyncDiverged;

  /// No description provided for @autoSyncDivergedShort.
  ///
  /// In en, this message translates to:
  /// **'Choose a version of your data'**
  String get autoSyncDivergedShort;

  /// No description provided for @autoSyncChooseVersion.
  ///
  /// In en, this message translates to:
  /// **'Choose version'**
  String get autoSyncChooseVersion;

  /// No description provided for @autoSyncChooseTitle.
  ///
  /// In en, this message translates to:
  /// **'Which data to keep?'**
  String get autoSyncChooseTitle;

  /// No description provided for @autoSyncChooseHelp.
  ///
  /// In en, this message translates to:
  /// **'Nothing is merged: one of the versions remains. Unfinished server operations and client deletions are kept either way.'**
  String get autoSyncChooseHelp;

  /// No description provided for @autoSyncKeepLocal.
  ///
  /// In en, this message translates to:
  /// **'Keep this device\'s data'**
  String get autoSyncKeepLocal;

  /// No description provided for @autoSyncTakeCloud.
  ///
  /// In en, this message translates to:
  /// **'Take from the cloud'**
  String get autoSyncTakeCloud;

  /// No description provided for @autoSyncKeepLocalEffect.
  ///
  /// In en, this message translates to:
  /// **'The version in Google Drive will be replaced.'**
  String get autoSyncKeepLocalEffect;

  /// No description provided for @autoSyncTakeCloudEffect.
  ///
  /// In en, this message translates to:
  /// **'Unsent changes on this device will be replaced.'**
  String get autoSyncTakeCloudEffect;

  /// No description provided for @autoSyncVersionSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved {time} · {device}'**
  String autoSyncVersionSaved(String time, String device);

  /// No description provided for @autoSyncVersionUnknownTime.
  ///
  /// In en, this message translates to:
  /// **'time unknown'**
  String get autoSyncVersionUnknownTime;

  /// No description provided for @autoSyncVersionUnknownDevice.
  ///
  /// In en, this message translates to:
  /// **'device not named'**
  String get autoSyncVersionUnknownDevice;

  /// No description provided for @autoSyncThisDevice.
  ///
  /// In en, this message translates to:
  /// **'this device'**
  String get autoSyncThisDevice;

  /// No description provided for @autoSyncChoiceBlocked.
  ///
  /// In en, this message translates to:
  /// **'Close editors and dialogs first and wait for operations to finish, then choose the version again.'**
  String get autoSyncChoiceBlocked;

  /// No description provided for @autoSyncOtherWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Google Drive holds data started separately on another device, and this device has data of its own. Nothing was overwritten. Choose which data to keep.'**
  String get autoSyncOtherWorkspace;

  /// No description provided for @autoSyncOtherWorkspaceHelp.
  ///
  /// In en, this message translates to:
  /// **'These are two separate sets of data: one of them remains whole, nothing is merged. Unfinished server operations of the replaced data are not kept.'**
  String get autoSyncOtherWorkspaceHelp;

  /// No description provided for @autoSyncOtherKeepLocalEffect.
  ///
  /// In en, this message translates to:
  /// **'The data in Google Drive will be replaced. Your other devices will be asked the same question.'**
  String get autoSyncOtherKeepLocalEffect;

  /// No description provided for @autoSyncOtherTakeCloudEffect.
  ///
  /// In en, this message translates to:
  /// **'All data on this device will be replaced with the data from Google Drive.'**
  String get autoSyncOtherTakeCloudEffect;

  /// No description provided for @autoSyncReplaceCloudTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace the data in Google Drive?'**
  String get autoSyncReplaceCloudTitle;

  /// No description provided for @autoSyncReplaceCloudHelp.
  ///
  /// In en, this message translates to:
  /// **'Servers and clients saved in Google Drive from other devices will be removed from it. Devices that hold them will be asked which data to keep.'**
  String get autoSyncReplaceCloudHelp;

  /// No description provided for @autoSyncReplaceCloud.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get autoSyncReplaceCloud;

  /// No description provided for @autoSyncUpdateRequired.
  ///
  /// In en, this message translates to:
  /// **'The data in Google Drive was saved by a newer version of AntiRKN. Update the app on this device. Until then nothing is downloaded from or sent to Google Drive; the data on this device is unchanged.'**
  String get autoSyncUpdateRequired;

  /// No description provided for @restoredCacheRunning.
  ///
  /// In en, this message translates to:
  /// **'Server data is being read again in the background after sync. Data saved on this device is shown meanwhile.'**
  String get restoredCacheRunning;

  /// No description provided for @restoredCacheStale.
  ///
  /// In en, this message translates to:
  /// **'Servers not answering: {count}. Showing data from {date}. Profiles already published can be opened from Google Drive.'**
  String restoredCacheStale(int count, String date);

  /// No description provided for @restoredCacheMissing.
  ///
  /// In en, this message translates to:
  /// **'Servers not answering: {count}. This device has no saved data about them. Profiles already published can be opened from Google Drive.'**
  String restoredCacheMissing(int count);

  /// No description provided for @profilePublishedDriveHelp.
  ///
  /// In en, this message translates to:
  /// **'This device has not built the profile yet: it needs data from the servers. You can open the file already published in Google Drive.'**
  String get profilePublishedDriveHelp;

  /// No description provided for @profileOpenPublished.
  ///
  /// In en, this message translates to:
  /// **'Open published file'**
  String get profileOpenPublished;

  /// No description provided for @profilePublishedMissing.
  ///
  /// In en, this message translates to:
  /// **'Google Drive has no file of this client published by link.'**
  String get profilePublishedMissing;

  /// No description provided for @profilePublishedFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open the published file. Check the connection to Google Drive and try again.'**
  String get profilePublishedFailed;

  /// No description provided for @profilePublishedFromDrive.
  ///
  /// In en, this message translates to:
  /// **'Published file from Google Drive. It was not rebuilt on this device.'**
  String get profilePublishedFromDrive;

  /// No description provided for @autoSyncPairing.
  ///
  /// In en, this message translates to:
  /// **'Sign in to the same Google account on your devices and use them in turn. Changes upload 30 seconds after an edit and when the app closes or enters the background; a device without unsent changes loads the newer version at launch and when you return to the app.'**
  String get autoSyncPairing;

  /// No description provided for @googleDesktopConfigurationError.
  ///
  /// In en, this message translates to:
  /// **'Google sign-in is not configured. Select a Desktop OAuth client JSON from your Google project when prompted.'**
  String get googleDesktopConfigurationError;

  /// No description provided for @googleDesktopUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not open Google sign-in in the system browser. Check your default browser and try again.'**
  String get googleDesktopUnavailable;

  /// No description provided for @googleDesktopWaiting.
  ///
  /// In en, this message translates to:
  /// **'Complete sign-in in your browser, then return here. On first setup, select your Google Desktop client file if prompted.'**
  String get googleDesktopWaiting;

  /// No description provided for @googleCancelSignIn.
  ///
  /// In en, this message translates to:
  /// **'Cancel sign-in'**
  String get googleCancelSignIn;

  /// No description provided for @publicationTitle.
  ///
  /// In en, this message translates to:
  /// **'Profile publication'**
  String get publicationTitle;

  /// No description provided for @publicationHelp.
  ///
  /// In en, this message translates to:
  /// **'Automatically save client YAML profiles to Google Drive and update the same file. Set up the folder on one device, then sync the others.'**
  String get publicationHelp;

  /// No description provided for @publicationAuthorize.
  ///
  /// In en, this message translates to:
  /// **'Allow publishing to Drive'**
  String get publicationAuthorize;

  /// No description provided for @publicationAuthorizeHelp.
  ///
  /// In en, this message translates to:
  /// **'Grant AntiRKN access to its sync data and published client files in Google.'**
  String get publicationAuthorizeHelp;

  /// No description provided for @publicationAccess.
  ///
  /// In en, this message translates to:
  /// **'Profile access'**
  String get publicationAccess;

  /// No description provided for @publicationPrivate.
  ///
  /// In en, this message translates to:
  /// **'Private file'**
  String get publicationPrivate;

  /// No description provided for @publicationLink.
  ///
  /// In en, this message translates to:
  /// **'Anyone with the link'**
  String get publicationLink;

  /// No description provided for @publicationLinkHelp.
  ///
  /// In en, this message translates to:
  /// **'Anyone with the link can download the profile and its client credentials.'**
  String get publicationLinkHelp;

  /// No description provided for @publicationPrivateHelp.
  ///
  /// In en, this message translates to:
  /// **'The file is saved in Drive. A subscription URL requires access for anyone with the link.'**
  String get publicationPrivateHelp;

  /// No description provided for @publicationFolder.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get publicationFolder;

  /// No description provided for @publicationNewFolder.
  ///
  /// In en, this message translates to:
  /// **'Create AntiRKN profiles folder'**
  String get publicationNewFolder;

  /// No description provided for @publicationChooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose a folder accessible to the app'**
  String get publicationChooseFolder;

  /// No description provided for @publicationEnable.
  ///
  /// In en, this message translates to:
  /// **'Set up publication'**
  String get publicationEnable;

  /// No description provided for @publicationAuto.
  ///
  /// In en, this message translates to:
  /// **'Automatic publication'**
  String get publicationAuto;

  /// No description provided for @publicationCompleteSetup.
  ///
  /// In en, this message translates to:
  /// **'Complete folder setup'**
  String get publicationCompleteSetup;

  /// No description provided for @publicationMissing.
  ///
  /// In en, this message translates to:
  /// **'The file or folder is unavailable. Check Drive access and trash; the existing binding is preserved.'**
  String get publicationMissing;

  /// No description provided for @publicationConflict.
  ///
  /// In en, this message translates to:
  /// **'The Drive version changed. Sync devices and review the conflict; the file was not overwritten.'**
  String get publicationConflict;

  /// No description provided for @publicationForceOverwrite.
  ///
  /// In en, this message translates to:
  /// **'Force overwrite'**
  String get publicationForceOverwrite;

  /// No description provided for @publicationAccountChanged.
  ///
  /// In en, this message translates to:
  /// **'This publication requires the Google account used to select its folder.'**
  String get publicationAccountChanged;

  /// No description provided for @publicationLinkUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The link does not return the expected YAML without Google sign-in. Retry the check later.'**
  String get publicationLinkUnavailable;

  /// No description provided for @publicationNetwork.
  ///
  /// In en, this message translates to:
  /// **'Drive is temporarily unavailable. Publication remains queued.'**
  String get publicationNetwork;

  /// No description provided for @publicationWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting to publish'**
  String get publicationWaiting;

  /// No description provided for @publicationFailed.
  ///
  /// In en, this message translates to:
  /// **'Publication is incomplete. Check settings and retry.'**
  String get publicationFailed;

  /// No description provided for @publicationPublished.
  ///
  /// In en, this message translates to:
  /// **'Profile published'**
  String get publicationPublished;

  /// No description provided for @publicationRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry publication'**
  String get publicationRetry;

  /// No description provided for @publicationClientsFailed.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} client profile was not published} other{{count} client profiles were not published}}'**
  String publicationClientsFailed(int count);

  /// No description provided for @publicationClientsFailedMixed.
  ///
  /// In en, this message translates to:
  /// **'Reasons differ: see the client cards below.'**
  String get publicationClientsFailedMixed;

  /// No description provided for @publicationCopyLink.
  ///
  /// In en, this message translates to:
  /// **'Copy profile link'**
  String get publicationCopyLink;

  /// No description provided for @uiGoogleDrive.
  ///
  /// In en, this message translates to:
  /// **'Google Drive'**
  String get uiGoogleDrive;

  /// No description provided for @uiAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance & language'**
  String get uiAppearance;

  /// No description provided for @uiActions.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get uiActions;

  /// No description provided for @uiProtocols.
  ///
  /// In en, this message translates to:
  /// **'Protocols'**
  String get uiProtocols;

  /// No description provided for @uiMaintenance.
  ///
  /// In en, this message translates to:
  /// **'Maintenance'**
  String get uiMaintenance;

  /// No description provided for @uiConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get uiConnection;

  /// No description provided for @uiDisconnectBeforeDelete.
  ///
  /// In en, this message translates to:
  /// **'Finish active operations and disconnect SSH before deleting.'**
  String get uiDisconnectBeforeDelete;

  /// No description provided for @uiQrCopyHint.
  ///
  /// In en, this message translates to:
  /// **'Scan to import into Clash Mi / Meta. Tap the QR to copy the direct YAML link.'**
  String get uiQrCopyHint;

  /// No description provided for @uiLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied'**
  String get uiLinkCopied;

  /// No description provided for @uiCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not copy the link. Tap the QR code to retry.'**
  String get uiCopyFailed;

  /// No description provided for @uiPreviewYaml.
  ///
  /// In en, this message translates to:
  /// **'Preview YAML'**
  String get uiPreviewYaml;

  /// No description provided for @uiProfileDetails.
  ///
  /// In en, this message translates to:
  /// **'Profile details'**
  String get uiProfileDetails;

  /// No description provided for @uiOperationPending.
  ///
  /// In en, this message translates to:
  /// **'Operation needs attention'**
  String get uiOperationPending;

  /// No description provided for @vpnDeleteUser.
  ///
  /// In en, this message translates to:
  /// **'Delete client'**
  String get vpnDeleteUser;

  /// No description provided for @vpnDeleteExplanation.
  ///
  /// In en, this message translates to:
  /// **'The client will leave the list. Access on unavailable servers will be revoked after reconnecting. The name and login can be used again.'**
  String get vpnDeleteExplanation;

  /// No description provided for @vpnDeleteFile.
  ///
  /// In en, this message translates to:
  /// **'Also move the configuration file to Google Drive trash'**
  String get vpnDeleteFile;

  /// No description provided for @vpnRevocationPending.
  ///
  /// In en, this message translates to:
  /// **'Waiting to revoke access'**
  String get vpnRevocationPending;

  /// No description provided for @vpnDeleteFilePending.
  ///
  /// In en, this message translates to:
  /// **'Access revoked. Waiting to delete the file'**
  String get vpnDeleteFilePending;

  /// No description provided for @vpnAccessRevoked.
  ///
  /// In en, this message translates to:
  /// **'Access revoked'**
  String get vpnAccessRevoked;

  /// No description provided for @vpnRevocationFailed.
  ///
  /// In en, this message translates to:
  /// **'Revocation is incomplete. Check the server and retry.'**
  String get vpnRevocationFailed;

  /// No description provided for @vpnUserDeleted.
  ///
  /// In en, this message translates to:
  /// **'This client record was deleted. You can create a new client with the same name and login.'**
  String get vpnUserDeleted;

  /// No description provided for @vpnNodeName.
  ///
  /// In en, this message translates to:
  /// **'Node name'**
  String get vpnNodeName;

  /// No description provided for @uiDeleteServer.
  ///
  /// In en, this message translates to:
  /// **'Delete server'**
  String get uiDeleteServer;

  /// No description provided for @vpnConnectToManage.
  ///
  /// In en, this message translates to:
  /// **'Connect to manage inbounds and client access.'**
  String get vpnConnectToManage;

  /// No description provided for @catalogEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit list'**
  String get catalogEdit;

  /// No description provided for @catalogSelected.
  ///
  /// In en, this message translates to:
  /// **'Selected: {count}'**
  String catalogSelected(int count);

  /// No description provided for @catalogDeleteSelected.
  ///
  /// In en, this message translates to:
  /// **'Delete selected'**
  String get catalogDeleteSelected;

  /// No description provided for @catalogSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all / clear selection'**
  String get catalogSelectAll;

  /// No description provided for @catalogExitEditing.
  ///
  /// In en, this message translates to:
  /// **'Exit editing'**
  String get catalogExitEditing;

  /// No description provided for @catalogServerDeleteBlocked.
  ///
  /// In en, this message translates to:
  /// **'Could not delete the selection. Disconnect these servers and finish pending operations. A server used as an SSH jump by an unselected server must be kept. If the list changed, select it again.'**
  String get catalogServerDeleteBlocked;

  /// No description provided for @catalogForgetServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Forget inaccessible server?'**
  String get catalogForgetServerTitle;

  /// No description provided for @catalogForgetServerWarning.
  ///
  /// In en, this message translates to:
  /// **'Forget these servers on this device without connecting to them? Their VPN resources and pending operations will be removed from local profiles. Access already issued on a VPS may remain active because revocation cannot be verified. Nothing on the VPS will be changed.'**
  String get catalogForgetServerWarning;

  /// No description provided for @catalogForgetServerAction.
  ///
  /// In en, this message translates to:
  /// **'Forget locally'**
  String get catalogForgetServerAction;

  /// No description provided for @catalogServerForgetBlocked.
  ///
  /// In en, this message translates to:
  /// **'Could not forget the selection. Local changes are in progress or the server list changed. Try again after they finish.'**
  String get catalogServerForgetBlocked;

  /// No description provided for @publicationBindTitle.
  ///
  /// In en, this message translates to:
  /// **'Client configuration file'**
  String get publicationBindTitle;

  /// No description provided for @publicationBindHelp.
  ///
  /// In en, this message translates to:
  /// **'Paste the existing Google Drive link or choose a file. Grant access through Google’s picker for files this app cannot access yet.'**
  String get publicationBindHelp;

  /// No description provided for @publicationFileLink.
  ///
  /// In en, this message translates to:
  /// **'Google Drive link or file ID'**
  String get publicationFileLink;

  /// No description provided for @publicationInspect.
  ///
  /// In en, this message translates to:
  /// **'Check file'**
  String get publicationInspect;

  /// No description provided for @publicationPickFile.
  ///
  /// In en, this message translates to:
  /// **'Choose in Google Drive'**
  String get publicationPickFile;

  /// No description provided for @publicationPickerSetupHelp.
  ///
  /// In en, this message translates to:
  /// **'Configure Google Picker in Settings → Drive: API key and numeric Project number from the same Google Cloud project. Enable Drive API and Picker API in that project.'**
  String get publicationPickerSetupHelp;

  /// No description provided for @publicationPickerWaiting.
  ///
  /// In en, this message translates to:
  /// **'Choose a file in your browser, then return to AntiRKN. Cancel ends the session.'**
  String get publicationPickerWaiting;

  /// No description provided for @publicationFileAccessHelp.
  ///
  /// In en, this message translates to:
  /// **'File not found or not yet accessible to AntiRKN. Use the \'Choose in Google Drive\' button above to grant access. Pasting a file ID works only for files this app already has access to.'**
  String get publicationFileAccessHelp;

  /// No description provided for @publicationBindReplace.
  ///
  /// In en, this message translates to:
  /// **'Confirmation replaces this file with the client profile and enables future updates to the same ID. The previous file keeps its contents and access, and stops receiving updates. An interrupted replacement can be reviewed again or changed to another file.'**
  String get publicationBindReplace;

  /// No description provided for @publicationOldContent.
  ///
  /// In en, this message translates to:
  /// **'Current file contents'**
  String get publicationOldContent;

  /// No description provided for @publicationNewContent.
  ///
  /// In en, this message translates to:
  /// **'Replacement profile'**
  String get publicationNewContent;

  /// No description provided for @publicationBindConfirm.
  ///
  /// In en, this message translates to:
  /// **'Replace and bind'**
  String get publicationBindConfirm;

  /// No description provided for @publicationPickerSettings.
  ///
  /// In en, this message translates to:
  /// **'Google Drive file selection'**
  String get publicationPickerSettings;

  /// No description provided for @publicationPickerApiKey.
  ///
  /// In en, this message translates to:
  /// **'Public API key'**
  String get publicationPickerApiKey;

  /// No description provided for @publicationPickerProject.
  ///
  /// In en, this message translates to:
  /// **'Project number (numeric)'**
  String get publicationPickerProject;

  /// No description provided for @publicationBindPending.
  ///
  /// In en, this message translates to:
  /// **'Rebinding is pending. The previous link remains available until the new link is verified.'**
  String get publicationBindPending;

  /// No description provided for @publicationChangeFile.
  ///
  /// In en, this message translates to:
  /// **'Change file / link'**
  String get publicationChangeFile;

  /// No description provided for @publicationSaveClientFirst.
  ///
  /// In en, this message translates to:
  /// **'Save client changes before changing the link.'**
  String get publicationSaveClientFirst;

  /// No description provided for @publicationBindSetupHelp.
  ///
  /// In en, this message translates to:
  /// **'First configure and enable publication in Settings → Drive.'**
  String get publicationBindSetupHelp;

  /// No description provided for @publicationBindInvalid.
  ///
  /// In en, this message translates to:
  /// **'Choose an editable UTF-8 text file using a Google Drive link. Folders, Google Docs and another client’s files cannot be used.'**
  String get publicationBindInvalid;

  /// No description provided for @uiSyncOptions.
  ///
  /// In en, this message translates to:
  /// **'Sync options'**
  String get uiSyncOptions;

  /// No description provided for @uiPairDevice.
  ///
  /// In en, this message translates to:
  /// **'Connect another device'**
  String get uiPairDevice;

  /// No description provided for @uiSystemUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update system'**
  String get uiSystemUpdate;

  /// No description provided for @uiSystemUpdateHelp.
  ///
  /// In en, this message translates to:
  /// **'Refresh the package list and install available Ubuntu package updates.'**
  String get uiSystemUpdateHelp;

  /// No description provided for @uiCheck.
  ///
  /// In en, this message translates to:
  /// **'Check'**
  String get uiCheck;

  /// No description provided for @uiShareProfile.
  ///
  /// In en, this message translates to:
  /// **'Connection QR'**
  String get uiShareProfile;

  /// No description provided for @uiPublicAddresses.
  ///
  /// In en, this message translates to:
  /// **'Public IP addresses'**
  String get uiPublicAddresses;

  /// No description provided for @uiNoPublicAddresses.
  ///
  /// In en, this message translates to:
  /// **'No public addresses found'**
  String get uiNoPublicAddresses;

  /// No description provided for @uiOffline.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get uiOffline;

  /// No description provided for @uiProtocolClients.
  ///
  /// In en, this message translates to:
  /// **'Client access'**
  String get uiProtocolClients;

  /// No description provided for @uiServices.
  ///
  /// In en, this message translates to:
  /// **'Services & updates'**
  String get uiServices;

  /// No description provided for @uiNetworkSsh.
  ///
  /// In en, this message translates to:
  /// **'Network & SSH'**
  String get uiNetworkSsh;

  /// No description provided for @uiAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get uiAccount;

  /// No description provided for @uiInterface.
  ///
  /// In en, this message translates to:
  /// **'Interface'**
  String get uiInterface;

  /// No description provided for @uiInterfaceHelp.
  ///
  /// In en, this message translates to:
  /// **'Theme and app language'**
  String get uiInterfaceHelp;

  /// No description provided for @uiSynchronization.
  ///
  /// In en, this message translates to:
  /// **'Synchronization'**
  String get uiSynchronization;

  /// No description provided for @uiSyncHelp.
  ///
  /// In en, this message translates to:
  /// **'Google Drive and your devices'**
  String get uiSyncHelp;

  /// No description provided for @uiClientProfiles.
  ///
  /// In en, this message translates to:
  /// **'Client profiles'**
  String get uiClientProfiles;

  /// No description provided for @uiClientProfilesHelp.
  ///
  /// In en, this message translates to:
  /// **'Base YAML, folder and links'**
  String get uiClientProfilesHelp;

  /// No description provided for @uiBackupHelp.
  ///
  /// In en, this message translates to:
  /// **'Save and restore your data'**
  String get uiBackupHelp;

  /// No description provided for @uiComponentUpdates.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get uiComponentUpdates;

  /// No description provided for @uiUpdatesHelp.
  ///
  /// In en, this message translates to:
  /// **'Check component versions'**
  String get uiUpdatesHelp;

  /// No description provided for @uiAppSettings.
  ///
  /// In en, this message translates to:
  /// **'App settings'**
  String get uiAppSettings;

  /// No description provided for @uiMyData.
  ///
  /// In en, this message translates to:
  /// **'My data'**
  String get uiMyData;

  /// No description provided for @uiPersonalWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Personal workspace'**
  String get uiPersonalWorkspace;

  /// No description provided for @uiBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get uiBack;

  /// No description provided for @uiSshAccess.
  ///
  /// In en, this message translates to:
  /// **'SSH access'**
  String get uiSshAccess;

  /// No description provided for @uiActivity.
  ///
  /// In en, this message translates to:
  /// **'Activity history'**
  String get uiActivity;

  /// No description provided for @uiActivityHelp.
  ///
  /// In en, this message translates to:
  /// **'Actions from all your devices'**
  String get uiActivityHelp;

  /// No description provided for @uiServerAbout.
  ///
  /// In en, this message translates to:
  /// **'About server'**
  String get uiServerAbout;

  /// No description provided for @uiServerAboutSummary.
  ///
  /// In en, this message translates to:
  /// **'Public IPs, traffic and disk space'**
  String get uiServerAboutSummary;

  /// No description provided for @uiServerAboutHelp.
  ///
  /// In en, this message translates to:
  /// **'Server data from the latest refresh'**
  String get uiServerAboutHelp;

  /// No description provided for @uiNoActivity.
  ///
  /// In en, this message translates to:
  /// **'No actions yet'**
  String get uiNoActivity;

  /// No description provided for @uiServerChanges.
  ///
  /// In en, this message translates to:
  /// **'Server change'**
  String get uiServerChanges;

  /// No description provided for @uiNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get uiNotConfigured;

  /// No description provided for @uiNoClientAccess.
  ///
  /// In en, this message translates to:
  /// **'Access is not configured yet'**
  String get uiNoClientAccess;

  /// No description provided for @uiDiskCapacity.
  ///
  /// In en, this message translates to:
  /// **'Disk capacity'**
  String get uiDiskCapacity;

  /// No description provided for @uiTraffic.
  ///
  /// In en, this message translates to:
  /// **'Server traffic'**
  String get uiTraffic;

  /// No description provided for @uiTrafficReceived.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get uiTrafficReceived;

  /// No description provided for @uiTrafficSent.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get uiTrafficSent;

  /// No description provided for @uiTrafficReset.
  ///
  /// In en, this message translates to:
  /// **'Reset counter'**
  String get uiTrafficReset;

  /// No description provided for @uiTrafficSinceBoot.
  ///
  /// In en, this message translates to:
  /// **'Since the current server boot'**
  String get uiTrafficSinceBoot;

  /// No description provided for @uiTrafficResetHelp.
  ///
  /// In en, this message translates to:
  /// **'The counter is saved on this device. Default-route interfaces are counted. It starts again after the server reboots.'**
  String get uiTrafficResetHelp;

  /// No description provided for @uiDiskSpace.
  ///
  /// In en, this message translates to:
  /// **'System disk space'**
  String get uiDiskSpace;

  /// No description provided for @uiDiskFree.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get uiDiskFree;

  /// No description provided for @uiCopyAddress.
  ///
  /// In en, this message translates to:
  /// **'Copy address'**
  String get uiCopyAddress;

  /// No description provided for @uiClashRefreshHint.
  ///
  /// In en, this message translates to:
  /// **'Clash Mi defaults to a 24-hour refresh interval for newly imported profiles. Updates require the client to be running and online.'**
  String get uiClashRefreshHint;

  /// No description provided for @uiConnectionCount.
  ///
  /// In en, this message translates to:
  /// **'Connections: {count}'**
  String uiConnectionCount(int count);

  /// No description provided for @uiObservedAt.
  ///
  /// In en, this message translates to:
  /// **'Updated: {time}'**
  String uiObservedAt(String time);

  /// No description provided for @uiTrafficSince.
  ///
  /// In en, this message translates to:
  /// **'Since reset on {time}'**
  String uiTrafficSince(String time);

  /// No description provided for @uiDiskTotal.
  ///
  /// In en, this message translates to:
  /// **'Total: {size}'**
  String uiDiskTotal(String size);

  /// No description provided for @uiAddressCopied.
  ///
  /// In en, this message translates to:
  /// **'IP address copied'**
  String get uiAddressCopied;

  /// No description provided for @uiServersIntro.
  ///
  /// In en, this message translates to:
  /// **'Your servers and connections'**
  String get uiServersIntro;

  /// No description provided for @uiMyServers.
  ///
  /// In en, this message translates to:
  /// **'My servers'**
  String get uiMyServers;

  /// No description provided for @uiClientsIntro.
  ///
  /// In en, this message translates to:
  /// **'Access and profiles for your clients'**
  String get uiClientsIntro;

  /// No description provided for @uiClientsEmptyHelp.
  ///
  /// In en, this message translates to:
  /// **'Add a client to set up access and share a connection profile.'**
  String get uiClientsEmptyHelp;

  /// No description provided for @uiBackupExportHelp.
  ///
  /// In en, this message translates to:
  /// **'Save application data to a file'**
  String get uiBackupExportHelp;

  /// No description provided for @uiBackupImportHelp.
  ///
  /// In en, this message translates to:
  /// **'Move your data to this device'**
  String get uiBackupImportHelp;

  /// No description provided for @uiApplicationData.
  ///
  /// In en, this message translates to:
  /// **'Application data'**
  String get uiApplicationData;

  /// No description provided for @uiUpdatesShort.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get uiUpdatesShort;

  /// No description provided for @uiUpdatesAutomaticHelp.
  ///
  /// In en, this message translates to:
  /// **'New versions of server components'**
  String get uiUpdatesAutomaticHelp;

  /// No description provided for @uiUpdatesSuggestionsHelp.
  ///
  /// In en, this message translates to:
  /// **'Notify about available updates'**
  String get uiUpdatesSuggestionsHelp;

  /// No description provided for @uiSyncAutomaticHelp.
  ///
  /// In en, this message translates to:
  /// **'Upload after edits and on leaving, load on return'**
  String get uiSyncAutomaticHelp;

  /// No description provided for @uiPairDeviceHelp.
  ///
  /// In en, this message translates to:
  /// **'Sign in to the same Google account'**
  String get uiPairDeviceHelp;

  /// No description provided for @uiPublicProfileHelp.
  ///
  /// In en, this message translates to:
  /// **'The profile is available by direct link. Open the client to get its QR code and link.'**
  String get uiPublicProfileHelp;

  /// No description provided for @uiPublicationAutoHelp.
  ///
  /// In en, this message translates to:
  /// **'Save changes at the same profile links'**
  String get uiPublicationAutoHelp;

  /// No description provided for @uiInterfaces.
  ///
  /// In en, this message translates to:
  /// **'Interfaces'**
  String get uiInterfaces;

  /// No description provided for @uiConnections.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get uiConnections;

  /// No description provided for @uiTtSetup.
  ///
  /// In en, this message translates to:
  /// **'Set up TrustTunnel'**
  String get uiTtSetup;

  /// No description provided for @uiPeerCount.
  ///
  /// In en, this message translates to:
  /// **'Connections: {count}'**
  String uiPeerCount(int count);

  /// No description provided for @uiForceDeleteClient.
  ///
  /// In en, this message translates to:
  /// **'Force delete'**
  String get uiForceDeleteClient;

  /// No description provided for @uiForceDeleteWarning.
  ///
  /// In en, this message translates to:
  /// **'“{name}” will disappear from the app. Access may still work on unavailable servers ({servers}). Revocation will finish when they reconnect.'**
  String uiForceDeleteWarning(String name, String servers);

  /// No description provided for @uiClashImport.
  ///
  /// In en, this message translates to:
  /// **'Connection profile for Clash Mi'**
  String get uiClashImport;

  /// No description provided for @uiConnectionSettings.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get uiConnectionSettings;

  /// No description provided for @uiAuthentication.
  ///
  /// In en, this message translates to:
  /// **'Sign-in credentials'**
  String get uiAuthentication;

  /// No description provided for @uiOtherComponents.
  ///
  /// In en, this message translates to:
  /// **'Other components'**
  String get uiOtherComponents;

  /// No description provided for @uiRemoveProtocol.
  ///
  /// In en, this message translates to:
  /// **'Remove protocol'**
  String get uiRemoveProtocol;

  /// No description provided for @uiRemoveProtocolHelp.
  ///
  /// In en, this message translates to:
  /// **'The services and all connections for this protocol will be removed from the server, including connections created outside AntiRKN. Clients will lose access through this protocol.'**
  String get uiRemoveProtocolHelp;

  /// No description provided for @uiRemoveVlessHelp.
  ///
  /// In en, this message translates to:
  /// **'This removes the whole 3x-ui / Xray installation. All its inbounds, including other protocols, will stop working.'**
  String get uiRemoveVlessHelp;

  /// No description provided for @uiRemoveProtocolBusy.
  ///
  /// In en, this message translates to:
  /// **'Wait for the current server operation to finish.'**
  String get uiRemoveProtocolBusy;

  /// No description provided for @uiRemoveProtocolConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect over SSH first, then hold the protocol tile again.'**
  String get uiRemoveProtocolConnect;

  /// No description provided for @uiRemoveProtocolStarted.
  ///
  /// In en, this message translates to:
  /// **'Removal started. The result will appear in server maintenance.'**
  String get uiRemoveProtocolStarted;

  /// No description provided for @uiRemoveProtocolFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not remove the protocol. Check the server state and retry.'**
  String get uiRemoveProtocolFailed;

  /// No description provided for @uiRemoveProtocolConflict.
  ///
  /// In en, this message translates to:
  /// **'The installation changed. Refresh the server and confirm a new removal plan.'**
  String get uiRemoveProtocolConflict;

  /// No description provided for @uiRemoveProtocolUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This installation has a nonstandard configuration. Automatic removal is unavailable.'**
  String get uiRemoveProtocolUnsupported;

  /// No description provided for @uiNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'Not installed'**
  String get uiNotInstalled;

  /// No description provided for @uiInstallProtocolHelp.
  ///
  /// In en, this message translates to:
  /// **'Install the protocol software and its required dependencies? The app will connect to the server and start the installation.'**
  String get uiInstallProtocolHelp;

  /// No description provided for @uiInstallProtocolConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect to the server over SSH, then tap the protocol again to install it.'**
  String get uiInstallProtocolConnect;

  /// No description provided for @sshHardenBannerTitle.
  ///
  /// In en, this message translates to:
  /// **'Root access is not hardened'**
  String get sshHardenBannerTitle;

  /// No description provided for @sshHardenBannerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'It is recommended to create a sudo user, change the SSH port to 2222, and disable root login.'**
  String get sshHardenBannerSubtitle;

  /// No description provided for @sshHardenBannerAction.
  ///
  /// In en, this message translates to:
  /// **'Secure server'**
  String get sshHardenBannerAction;

  /// No description provided for @sshHardenDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'SSH Hardening Wizard'**
  String get sshHardenDialogTitle;

  /// No description provided for @sshHardenDialogDescription.
  ///
  /// In en, this message translates to:
  /// **'Create a user with sudo and choose the SSH port. The app verifies new access before and after applying the final settings. Unfinished changes are automatically rolled back, including after a server restart.'**
  String get sshHardenDialogDescription;

  /// No description provided for @sshHardenUsername.
  ///
  /// In en, this message translates to:
  /// **'New username'**
  String get sshHardenUsername;

  /// No description provided for @sshHardenPort.
  ///
  /// In en, this message translates to:
  /// **'New SSH port'**
  String get sshHardenPort;

  /// No description provided for @sshHardenSudoPassword.
  ///
  /// In en, this message translates to:
  /// **'Password for the new user and sudo'**
  String get sshHardenSudoPassword;

  /// No description provided for @sshHardenSudoPasswordConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm sudo password'**
  String get sshHardenSudoPasswordConfirm;

  /// No description provided for @sshHardenPasswordMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get sshHardenPasswordMismatch;

  /// No description provided for @sshHardenPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter a sudo password'**
  String get sshHardenPasswordRequired;

  /// No description provided for @sshHardenFirewallWarning.
  ///
  /// In en, this message translates to:
  /// **'Notice: If a Cloud Firewall is enabled in your hosting panel (Hetzner, Timeweb, Selectel, etc.), make sure port {port}/TCP is open before confirming.'**
  String sshHardenFirewallWarning(int port);

  /// No description provided for @sshHardenStartAction.
  ///
  /// In en, this message translates to:
  /// **'Start hardening'**
  String get sshHardenStartAction;

  /// No description provided for @sshHardenPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing and verifying configuration...'**
  String get sshHardenPreparing;

  /// No description provided for @sshHardenUserCreated.
  ///
  /// In en, this message translates to:
  /// **'User created and SSH keys configured...'**
  String get sshHardenUserCreated;

  /// No description provided for @sshHardenSudoersConfigured.
  ///
  /// In en, this message translates to:
  /// **'Sudo privileges configured and validated...'**
  String get sshHardenSudoersConfigured;

  /// No description provided for @sshHardenPortsConfigured.
  ///
  /// In en, this message translates to:
  /// **'SSH ports configured (dual-port listening)...'**
  String get sshHardenPortsConfigured;

  /// No description provided for @sshHardenFirewallConfigured.
  ///
  /// In en, this message translates to:
  /// **'Firewall (UFW) configured...'**
  String get sshHardenFirewallConfigured;

  /// No description provided for @sshHardenWatchdogStarted.
  ///
  /// In en, this message translates to:
  /// **'Safety watchdog started...'**
  String get sshHardenWatchdogStarted;

  /// No description provided for @sshHardenTesting.
  ///
  /// In en, this message translates to:
  /// **'Verifying new user connection...'**
  String get sshHardenTesting;

  /// No description provided for @sshHardenTestingCountdown.
  ///
  /// In en, this message translates to:
  /// **'Auto-rollback in {time}'**
  String sshHardenTestingCountdown(String time);

  /// No description provided for @sshHardenTestSuccess.
  ///
  /// In en, this message translates to:
  /// **'Verification successful! User {user} connected on port {port} and confirmed sudo privileges.'**
  String sshHardenTestSuccess(String user, int port);

  /// No description provided for @sshHardenTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not connect to port {port} as the new user. Check your cloud firewall rules.'**
  String sshHardenTestFailed(int port);

  /// No description provided for @sshHardenConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Apply protection'**
  String get sshHardenConfirmAction;

  /// No description provided for @sshHardenAbortAction.
  ///
  /// In en, this message translates to:
  /// **'Roll back changes'**
  String get sshHardenAbortAction;

  /// No description provided for @sshHardenRetryAction.
  ///
  /// In en, this message translates to:
  /// **'Retry verification'**
  String get sshHardenRetryAction;

  /// No description provided for @sshHardenConfirmed.
  ///
  /// In en, this message translates to:
  /// **'SSH protection applied. The new connection and sudo access have been verified.'**
  String get sshHardenConfirmed;

  /// No description provided for @sshHardenAborted.
  ///
  /// In en, this message translates to:
  /// **'Changes rolled back. Root access preserved.'**
  String get sshHardenAborted;

  /// No description provided for @sshHardenConflict.
  ///
  /// In en, this message translates to:
  /// **'SSH configuration changed during hardening.'**
  String get sshHardenConflict;

  /// No description provided for @sshHardenInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid username or port.'**
  String get sshHardenInvalid;

  /// No description provided for @sshHardenPortBusy.
  ///
  /// In en, this message translates to:
  /// **'The selected port is already in use.'**
  String get sshHardenPortBusy;

  /// No description provided for @sshHardenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not complete SSH protection. Check the connection and recovery status.'**
  String get sshHardenFailed;

  /// No description provided for @sshHardenRandomUser.
  ///
  /// In en, this message translates to:
  /// **'Pick a random character'**
  String get sshHardenRandomUser;

  /// No description provided for @sshHardenRandomPassword.
  ///
  /// In en, this message translates to:
  /// **'Generate random password'**
  String get sshHardenRandomPassword;

  /// No description provided for @uiServerDataNotCached.
  ///
  /// In en, this message translates to:
  /// **'Connect to the server once to save its data on this device.'**
  String get uiServerDataNotCached;

  /// No description provided for @inboundDeleteSelectionHelp.
  ///
  /// In en, this message translates to:
  /// **'Delete the selected inbounds and their connections? Orphaned server client records will also be deleted. Clients in this app remain, and affected profiles will be updated.'**
  String get inboundDeleteSelectionHelp;

  /// No description provided for @inboundDeleteIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Deletion is incomplete. Check the job in server maintenance; unfinished jobs can be resumed.'**
  String get inboundDeleteIncomplete;

  /// No description provided for @diagSuspectedBlocking.
  ///
  /// In en, this message translates to:
  /// **'Signs of blocking'**
  String get diagSuspectedBlocking;

  /// No description provided for @diagConnectionLost.
  ///
  /// In en, this message translates to:
  /// **'Connection lost after this IP'**
  String get diagConnectionLost;

  /// No description provided for @diagConnectionRestored.
  ///
  /// In en, this message translates to:
  /// **'Connection restored'**
  String get diagConnectionRestored;

  /// No description provided for @diagQueued.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get diagQueued;

  /// No description provided for @diagNotTested.
  ///
  /// In en, this message translates to:
  /// **'Not tested'**
  String get diagNotTested;

  /// No description provided for @diagNoIpv4.
  ///
  /// In en, this message translates to:
  /// **'No public IPv4 addresses available for testing (up to 64 per server).'**
  String get diagNoIpv4;

  /// No description provided for @diagTitle.
  ///
  /// In en, this message translates to:
  /// **'IP diagnostics'**
  String get diagTitle;

  /// No description provided for @diagBaseline.
  ///
  /// In en, this message translates to:
  /// **'Checking the initial connection'**
  String get diagBaseline;

  /// No description provided for @diagTarget.
  ///
  /// In en, this message translates to:
  /// **'Checking the address'**
  String get diagTarget;

  /// No description provided for @diagControls.
  ///
  /// In en, this message translates to:
  /// **'Checking control addresses'**
  String get diagControls;

  /// No description provided for @diagRecovery.
  ///
  /// In en, this message translates to:
  /// **'Watching for connection recovery'**
  String get diagRecovery;

  /// No description provided for @diagComplete.
  ///
  /// In en, this message translates to:
  /// **'Check complete'**
  String get diagComplete;

  /// No description provided for @diagCancelled.
  ///
  /// In en, this message translates to:
  /// **'Check stopped'**
  String get diagCancelled;

  /// No description provided for @diagNetworkChanged.
  ///
  /// In en, this message translates to:
  /// **'Network changed — results are incomplete'**
  String get diagNetworkChanged;

  /// No description provided for @diagInsufficient.
  ///
  /// In en, this message translates to:
  /// **'Too few stable control addresses'**
  String get diagInsufficient;

  /// No description provided for @diagDegraded.
  ///
  /// In en, this message translates to:
  /// **'Queue stopped after connection loss'**
  String get diagDegraded;

  /// No description provided for @diagFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to complete the check'**
  String get diagFailed;

  /// No description provided for @diagInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter up to 64 public IPs, port 1–65535, and a certificate hostname for TLS. Targets must be IP addresses, not domain names.'**
  String get diagInvalid;

  /// No description provided for @diagConsent.
  ///
  /// In en, this message translates to:
  /// **'Contacting a target IP may temporarily interrupt internet access. The app will test from this device, close idle SSH connections and pause its background sync. If connectivity deteriorates, the queue stops and only controls are checked for about 3 minutes. VPNs and other apps may affect results.'**
  String get diagConsent;

  /// No description provided for @diagStart.
  ///
  /// In en, this message translates to:
  /// **'Start check'**
  String get diagStart;

  /// No description provided for @diagIntro.
  ///
  /// In en, this message translates to:
  /// **'Check IP reachability and signs of temporary connection loss after contacting it. Specify a port on which the server should accept connections.'**
  String get diagIntro;

  /// No description provided for @diagChooseServer.
  ///
  /// In en, this message translates to:
  /// **'Choose server addresses'**
  String get diagChooseServer;

  /// No description provided for @diagAddresses.
  ///
  /// In en, this message translates to:
  /// **'IP addresses, one per line'**
  String get diagAddresses;

  /// No description provided for @diagPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get diagPort;

  /// No description provided for @diagProtocol.
  ///
  /// In en, this message translates to:
  /// **'Probe method'**
  String get diagProtocol;

  /// No description provided for @diagSni.
  ///
  /// In en, this message translates to:
  /// **'TLS hostname (SNI and certificate)'**
  String get diagSni;

  /// No description provided for @diagStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get diagStop;

  /// No description provided for @diagBusy.
  ///
  /// In en, this message translates to:
  /// **'Wait for current server and profile operations to finish.'**
  String get diagBusy;

  /// No description provided for @diagHistoryError.
  ///
  /// In en, this message translates to:
  /// **'Unable to read or save diagnostic history.'**
  String get diagHistoryError;

  /// No description provided for @diagNetwork.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get diagNetwork;

  /// No description provided for @diagControlCount.
  ///
  /// In en, this message translates to:
  /// **'Reachable controls: {reachable} of {total}'**
  String diagControlCount(int reachable, int total);

  /// No description provided for @diagStrong.
  ///
  /// In en, this message translates to:
  /// **'Signs of strong blocking: after contacting the IP, connectivity to several independent control networks deteriorated in two consecutive checks.'**
  String get diagStrong;

  /// No description provided for @diagRegional.
  ///
  /// In en, this message translates to:
  /// **'Foreign control servers are unavailable while the Russian control is reachable.'**
  String get diagRegional;

  /// No description provided for @diagRecovered.
  ///
  /// In en, this message translates to:
  /// **'Control connectivity recovered after {seconds} s. Start a new check to continue.'**
  String diagRecovered(int seconds);

  /// No description provided for @diagNotRecovered.
  ///
  /// In en, this message translates to:
  /// **'Normal connectivity did not recover during observation.'**
  String get diagNotRecovered;

  /// No description provided for @diagLimits.
  ///
  /// In en, this message translates to:
  /// **'An IP may be unavailable because of a closed port, server failure or routing problem. This check does not prove RKN blocking. A successful connection only applies to the selected port and probe method.'**
  String get diagLimits;

  /// No description provided for @diagControlList.
  ///
  /// In en, this message translates to:
  /// **'Control addresses'**
  String get diagControlList;

  /// No description provided for @diagControlHelp.
  ///
  /// In en, this message translates to:
  /// **'14 IPv4 and 12 IPv6 addresses. Each family is checked twice before use; only stable controls are used, excluding target IPs. At least 90% reachable is normal: 9 of 10 or 13 of 14. DNS controls use TCP port 53; RIPE Atlas uses HTTP port 80. Anycast does not guarantee a foreign route.'**
  String get diagControlHelp;

  /// No description provided for @diagHistory.
  ///
  /// In en, this message translates to:
  /// **'Recent checks'**
  String get diagHistory;

  /// No description provided for @diagCopyReport.
  ///
  /// In en, this message translates to:
  /// **'Copy report'**
  String get diagCopyReport;

  /// No description provided for @diagClearHistory.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get diagClearHistory;

  /// No description provided for @diagInterrupted.
  ///
  /// In en, this message translates to:
  /// **'Interrupted when the app closed'**
  String get diagInterrupted;

  /// No description provided for @diagReachable.
  ///
  /// In en, this message translates to:
  /// **'Connection succeeded'**
  String get diagReachable;

  /// No description provided for @diagRefused.
  ///
  /// In en, this message translates to:
  /// **'Connection refused: the port may be closed'**
  String get diagRefused;

  /// No description provided for @diagTlsError.
  ///
  /// In en, this message translates to:
  /// **'TLS or certificate error'**
  String get diagTlsError;

  /// No description provided for @diagProtocolError.
  ///
  /// In en, this message translates to:
  /// **'Service response does not match the selected protocol'**
  String get diagProtocolError;

  /// No description provided for @diagUnreachable.
  ///
  /// In en, this message translates to:
  /// **'No connection: cause undetermined'**
  String get diagUnreachable;

  /// No description provided for @diagWifi.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi'**
  String get diagWifi;

  /// No description provided for @diagMobile.
  ///
  /// In en, this message translates to:
  /// **'Mobile network'**
  String get diagMobile;

  /// No description provided for @diagSystem.
  ///
  /// In en, this message translates to:
  /// **'System route'**
  String get diagSystem;

  /// No description provided for @diagForeign.
  ///
  /// In en, this message translates to:
  /// **'Foreign server'**
  String get diagForeign;

  /// No description provided for @diagRussia.
  ///
  /// In en, this message translates to:
  /// **'Russian server'**
  String get diagRussia;

  /// No description provided for @diagAnycast.
  ///
  /// In en, this message translates to:
  /// **'Anycast, location depends on routing'**
  String get diagAnycast;

  /// No description provided for @sshHardenDisableRoot.
  ///
  /// In en, this message translates to:
  /// **'Disable direct root login'**
  String get sshHardenDisableRoot;

  /// No description provided for @sshHardenRecoveryFailed.
  ///
  /// In en, this message translates to:
  /// **'Recovery could not be verified. Keep the saved access details and retry rollback.'**
  String get sshHardenRecoveryFailed;

  /// No description provided for @sshHardenSudoRequired.
  ///
  /// In en, this message translates to:
  /// **'The new account must require a password for sudo.'**
  String get sshHardenSudoRequired;

  /// No description provided for @sshHardenStorageFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the access details. The server transition has not been committed.'**
  String get sshHardenStorageFailed;

  /// No description provided for @vpnAdopt.
  ///
  /// In en, this message translates to:
  /// **'Manage client access'**
  String get vpnAdopt;

  /// No description provided for @vpnAdoptWarning.
  ///
  /// In en, this message translates to:
  /// **'AntiRKN will manage access for its clients. Existing settings and users will be preserved.'**
  String get vpnAdoptWarning;

  /// No description provided for @vpnAdopting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for management to be confirmed'**
  String get vpnAdopting;

  /// No description provided for @vpnAdoptUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This connection cannot be imported with its current settings. No server settings were changed.'**
  String get vpnAdoptUnsupported;

  /// No description provided for @vpnAdoptConflict.
  ///
  /// In en, this message translates to:
  /// **'The connection has changed or is already managed. Refresh its state and try again.'**
  String get vpnAdoptConflict;

  /// No description provided for @vpnAdoptFailed.
  ///
  /// In en, this message translates to:
  /// **'Client management could not be confirmed. Check the operation status before retrying.'**
  String get vpnAdoptFailed;

  /// No description provided for @templateCoreChecking.
  ///
  /// In en, this message translates to:
  /// **'Mihomo is checking the file…'**
  String get templateCoreChecking;

  /// No description provided for @templateCoreValid.
  ///
  /// In en, this message translates to:
  /// **'Mihomo accepted the base configuration.'**
  String get templateCoreValid;

  /// No description provided for @templateCoreRejected.
  ///
  /// In en, this message translates to:
  /// **'Mihomo found an error in the file. The current base configuration was kept.'**
  String get templateCoreRejected;

  /// No description provided for @templateCoreProviderRejected.
  ///
  /// In en, this message translates to:
  /// **'Mihomo could not read a rule set from the file. The current base configuration was kept.'**
  String get templateCoreProviderRejected;

  /// No description provided for @templateCoreIncomplete.
  ///
  /// In en, this message translates to:
  /// **'The file was added, but Mihomo checked it only partially: rule sets or other external files were unavailable.'**
  String get templateCoreIncomplete;

  /// No description provided for @templateCoreInputLimit.
  ///
  /// In en, this message translates to:
  /// **'The file was added without a full check: it exceeds the core check limit.'**
  String get templateCoreInputLimit;

  /// No description provided for @templateCoreUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The file was added without a core check: Mihomo could not start.'**
  String get templateCoreUnavailable;

  /// No description provided for @connectionCheck.
  ///
  /// In en, this message translates to:
  /// **'Check connection'**
  String get connectionCheck;

  /// No description provided for @connectionCheckAll.
  ///
  /// In en, this message translates to:
  /// **'Check all'**
  String get connectionCheckAll;

  /// No description provided for @connectionTargetsFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the list of connections to check. Refresh the server and try again.'**
  String get connectionTargetsFailed;

  /// No description provided for @connectionStop.
  ///
  /// In en, this message translates to:
  /// **'Stop check'**
  String get connectionStop;

  /// No description provided for @connectionReconfigure.
  ///
  /// In en, this message translates to:
  /// **'Reconfigure'**
  String get connectionReconfigure;

  /// No description provided for @connectionChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking connection…'**
  String get connectionChecking;

  /// No description provided for @connectionWorking.
  ///
  /// In en, this message translates to:
  /// **'Connected · TCP and UDP'**
  String get connectionWorking;

  /// No description provided for @connectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed. Review the settings.'**
  String get connectionFailed;

  /// No description provided for @connectionEndpointUnreachable.
  ///
  /// In en, this message translates to:
  /// **'The server address does not answer from this network, it is likely blocked by the provider. The settings are fine: move the protocol to another server address.'**
  String get connectionEndpointUnreachable;

  /// No description provided for @connectionCancelled.
  ///
  /// In en, this message translates to:
  /// **'Check stopped'**
  String get connectionCancelled;

  /// No description provided for @connectionVpnActive.
  ///
  /// In en, this message translates to:
  /// **'Turn off this device’s VPN to check the connection'**
  String get connectionVpnActive;

  /// No description provided for @connectionNetworkChanged.
  ///
  /// In en, this message translates to:
  /// **'Network changed. Run the check again.'**
  String get connectionNetworkChanged;

  /// No description provided for @connectionNetworkProblem.
  ///
  /// In en, this message translates to:
  /// **'Network or test destinations unavailable. Try again later.'**
  String get connectionNetworkProblem;

  /// No description provided for @connectionRouteUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This route cannot yet be checked from this device'**
  String get connectionRouteUnsupported;

  /// No description provided for @connectionAccessRequired.
  ///
  /// In en, this message translates to:
  /// **'Server access is needed to check this connection'**
  String get connectionAccessRequired;

  /// No description provided for @connectionCleanupPending.
  ///
  /// In en, this message translates to:
  /// **'Check interrupted. The server will remove temporary access automatically.'**
  String get connectionCleanupPending;

  /// No description provided for @connectionChanged.
  ///
  /// In en, this message translates to:
  /// **'Connection settings changed during the check. Run it again.'**
  String get connectionChanged;

  /// No description provided for @connectionCoreUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not run the Mihomo check. Try again.'**
  String get connectionCoreUnavailable;

  /// No description provided for @connectionUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Mihomo cannot check this connection configuration.'**
  String get connectionUnsupported;

  /// No description provided for @connectionBusy.
  ///
  /// In en, this message translates to:
  /// **'The server or check service is busy. Try again in a moment.'**
  String get connectionBusy;

  /// No description provided for @connectionTimeout.
  ///
  /// In en, this message translates to:
  /// **'Connection check timed out. Verify server and port availability.'**
  String get connectionTimeout;

  /// No description provided for @connectionNotTested.
  ///
  /// In en, this message translates to:
  /// **'Not tested'**
  String get connectionNotTested;

  /// No description provided for @connectionProgress.
  ///
  /// In en, this message translates to:
  /// **'Checked: {done} of {total}. Skipped: {skipped}.'**
  String connectionProgress(int done, int total, int skipped);

  /// No description provided for @xrayUpgradeTitle.
  ///
  /// In en, this message translates to:
  /// **'Xray core update'**
  String get xrayUpgradeTitle;

  /// No description provided for @xrayUpgradeBaseline.
  ///
  /// In en, this message translates to:
  /// **'Checking connections before updating…'**
  String get xrayUpgradeBaseline;

  /// No description provided for @xrayUpgradePreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing recovery and updating Xray…'**
  String get xrayUpgradePreparing;

  /// No description provided for @xrayUpgradeComparison.
  ///
  /// In en, this message translates to:
  /// **'Comparing connections after updating…'**
  String get xrayUpgradeComparison;

  /// No description provided for @xrayUpgradeCommitted.
  ///
  /// In en, this message translates to:
  /// **'Xray updated. HTTPS and UDP work on all tested inbounds.'**
  String get xrayUpgradeCommitted;

  /// No description provided for @xrayUpgradeRestored.
  ///
  /// In en, this message translates to:
  /// **'The previous core was restored. Results of connection rechecks are below.'**
  String get xrayUpgradeRestored;

  /// No description provided for @xrayUpgradeUnchanged.
  ///
  /// In en, this message translates to:
  /// **'The update did not start.'**
  String get xrayUpgradeUnchanged;

  /// No description provided for @xrayUpgradePending.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the server to confirm recovery. Rollback continues independently of the app.'**
  String get xrayUpgradePending;

  /// No description provided for @xrayUpgradeCoverage.
  ///
  /// In en, this message translates to:
  /// **'Every enabled inbound needs successful HTTPS and UDP checks. Up to 8 VLESS inbounds are supported per run; unavailable or unsupported connections are not skipped.'**
  String get xrayUpgradeCoverage;

  /// No description provided for @xrayUpgradeLayout.
  ///
  /// In en, this message translates to:
  /// **'Updating requires a supported 3x-ui 3.7/3.8 installation on Ubuntu x64 and an earlier Xray version.'**
  String get xrayUpgradeLayout;

  /// No description provided for @xrayUpgradeProblem.
  ///
  /// In en, this message translates to:
  /// **'The check did not finish. Review the connection results and retry when connectivity is restored.'**
  String get xrayUpgradeProblem;

  /// No description provided for @xrayUpgradeConflict.
  ///
  /// In en, this message translates to:
  /// **'The server state changed. External edits were preserved; check the server before retrying.'**
  String get xrayUpgradeConflict;

  /// No description provided for @xrayUpgradePanelApi.
  ///
  /// In en, this message translates to:
  /// **'After the Xray restart the app could not sign in to 3x-ui or read the same inbounds. The core was not confirmed and the server returns the previous version.'**
  String get xrayUpgradePanelApi;

  /// No description provided for @xrayUpgradePrerelease.
  ///
  /// In en, this message translates to:
  /// **'Pre-release'**
  String get xrayUpgradePrerelease;

  /// No description provided for @xrayUpgradeNoStable.
  ///
  /// In en, this message translates to:
  /// **'No verified stable Xray update is available.'**
  String get xrayUpgradeNoStable;

  /// No description provided for @xrayUpgradeBefore.
  ///
  /// In en, this message translates to:
  /// **'Before'**
  String get xrayUpgradeBefore;

  /// No description provided for @xrayUpgradeAfter.
  ///
  /// In en, this message translates to:
  /// **'After'**
  String get xrayUpgradeAfter;

  /// No description provided for @xrayUpgradeRecovery.
  ///
  /// In en, this message translates to:
  /// **'After rollback'**
  String get xrayUpgradeRecovery;

  /// No description provided for @xrayUpgradeDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled — not tested'**
  String get xrayUpgradeDisabled;

  /// No description provided for @xrayUpgradeNotTested.
  ///
  /// In en, this message translates to:
  /// **'Not tested'**
  String get xrayUpgradeNotTested;

  /// No description provided for @xrayUpgradeAttention.
  ///
  /// In en, this message translates to:
  /// **'Recovery is not confirmed. Check the Xray service and binary changes on the server; the backup is retained.'**
  String get xrayUpgradeAttention;

  /// No description provided for @serverReboot.
  ///
  /// In en, this message translates to:
  /// **'Restart server'**
  String get serverReboot;

  /// No description provided for @serverRebootConfirm.
  ///
  /// In en, this message translates to:
  /// **'Restart the server? SSH and VPN connections will be interrupted briefly.'**
  String get serverRebootConfirm;

  /// No description provided for @serverRebootWaiting.
  ///
  /// In en, this message translates to:
  /// **'The server is restarting. Waiting for it to reconnect…'**
  String get serverRebootWaiting;

  /// No description provided for @serverRebootDone.
  ///
  /// In en, this message translates to:
  /// **'Server restart confirmed.'**
  String get serverRebootDone;

  /// No description provided for @serverRebootFailed.
  ///
  /// In en, this message translates to:
  /// **'The restart is not confirmed yet. Reconnect to check its status.'**
  String get serverRebootFailed;

  /// No description provided for @egressTitle.
  ///
  /// In en, this message translates to:
  /// **'Internet egress'**
  String get egressTitle;

  /// No description provided for @egressUnknown.
  ///
  /// In en, this message translates to:
  /// **'Egress has not been checked'**
  String get egressUnknown;

  /// No description provided for @egressDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get egressDirect;

  /// No description provided for @egressClientTraffic.
  ///
  /// In en, this message translates to:
  /// **'Client traffic only: VLESS, TrustTunnel and AmneziaWG.'**
  String get egressClientTraffic;

  /// No description provided for @egressChecked.
  ///
  /// In en, this message translates to:
  /// **'TCP and UDP checked'**
  String get egressChecked;

  /// No description provided for @egressConfigure.
  ///
  /// In en, this message translates to:
  /// **'Configure'**
  String get egressConfigure;

  /// No description provided for @egressCheck.
  ///
  /// In en, this message translates to:
  /// **'Check'**
  String get egressCheck;

  /// No description provided for @egressInstallPanel.
  ///
  /// In en, this message translates to:
  /// **'Install 3x-ui'**
  String get egressInstallPanel;

  /// No description provided for @egressViaServer.
  ///
  /// In en, this message translates to:
  /// **'Through another server'**
  String get egressViaServer;

  /// No description provided for @egressSource.
  ///
  /// In en, this message translates to:
  /// **'Connection source'**
  String get egressSource;

  /// No description provided for @egressLink.
  ///
  /// In en, this message translates to:
  /// **'VLESS link'**
  String get egressLink;

  /// No description provided for @egressCatalog.
  ///
  /// In en, this message translates to:
  /// **'Choose from servers'**
  String get egressCatalog;

  /// No description provided for @egressTarget.
  ///
  /// In en, this message translates to:
  /// **'Exit server'**
  String get egressTarget;

  /// No description provided for @egressAddress.
  ///
  /// In en, this message translates to:
  /// **'Address reachable from this server'**
  String get egressAddress;

  /// No description provided for @egressPort.
  ///
  /// In en, this message translates to:
  /// **'External VLESS port'**
  String get egressPort;

  /// No description provided for @egressServiceAccess.
  ///
  /// In en, this message translates to:
  /// **'Applying creates a separate access credential for this server.'**
  String get egressServiceAccess;

  /// No description provided for @egressReveal.
  ///
  /// In en, this message translates to:
  /// **'Show or hide link'**
  String get egressReveal;

  /// No description provided for @egressPaste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get egressPaste;

  /// No description provided for @egressAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get egressAdvanced;

  /// No description provided for @egressSocksPort.
  ///
  /// In en, this message translates to:
  /// **'Local SOCKS port'**
  String get egressSocksPort;

  /// No description provided for @egressSocksHelp.
  ///
  /// In en, this message translates to:
  /// **'127.0.0.1. Disable egress before changing the port.'**
  String get egressSocksHelp;

  /// No description provided for @egressRulesHelp.
  ///
  /// In en, this message translates to:
  /// **'TCP/UDP are routed through VLESS. Existing Xray rules keep priority. There is no automatic direct fallback if the exit is unavailable.'**
  String get egressRulesHelp;

  /// No description provided for @egressApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get egressApply;

  /// No description provided for @egressPanelRequired.
  ///
  /// In en, this message translates to:
  /// **'Shared egress requires 3x-ui on this server.'**
  String get egressPanelRequired;

  /// No description provided for @egressInvalid.
  ///
  /// In en, this message translates to:
  /// **'Check the VLESS link and connection settings. Unsupported options cannot be applied.'**
  String get egressInvalid;

  /// No description provided for @egressUnsupported.
  ///
  /// In en, this message translates to:
  /// **'An unsupported configuration was found. Settings were not changed.'**
  String get egressUnsupported;

  /// No description provided for @egressNamespace.
  ///
  /// In en, this message translates to:
  /// **'AmneziaWG in a separate Docker network is not supported yet. Shared egress requires host networking or a native installation.'**
  String get egressNamespace;

  /// No description provided for @egressConflict.
  ///
  /// In en, this message translates to:
  /// **'Settings have changed. Refresh and try again.'**
  String get egressConflict;

  /// No description provided for @egressPortBusy.
  ///
  /// In en, this message translates to:
  /// **'The local port is unavailable. Choose another port or automatic selection.'**
  String get egressPortBusy;

  /// No description provided for @egressLoop.
  ///
  /// In en, this message translates to:
  /// **'The exit points to this server. Choose a different server.'**
  String get egressLoop;

  /// No description provided for @egressConfigFailed.
  ///
  /// In en, this message translates to:
  /// **'Xray or TrustTunnel rejected the settings. Check the recovery result.'**
  String get egressConfigFailed;

  /// No description provided for @egressNetwork.
  ///
  /// In en, this message translates to:
  /// **'Could not configure AmneziaWG client routes. iproute2, iptables and TPROXY are required.'**
  String get egressNetwork;

  /// No description provided for @egressProbeFailed.
  ///
  /// In en, this message translates to:
  /// **'TCP or UDP through the exit server failed. Check the VLESS credential and network.'**
  String get egressProbeFailed;

  /// No description provided for @egressRollbackFailed.
  ///
  /// In en, this message translates to:
  /// **'Automatic recovery is incomplete. Review the server settings.'**
  String get egressRollbackFailed;

  /// No description provided for @egressFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not configure egress. See the operation history for details.'**
  String get egressFailed;

  /// No description provided for @egressPreparing.
  ///
  /// In en, this message translates to:
  /// **'Checking the exit connection'**
  String get egressPreparing;

  /// No description provided for @egressApplying.
  ///
  /// In en, this message translates to:
  /// **'Configuring client egress'**
  String get egressApplying;

  /// No description provided for @egressChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking applied settings'**
  String get egressChecking;

  /// No description provided for @egressDisableFirst.
  ///
  /// In en, this message translates to:
  /// **'Disable egress through another server before removing 3x-ui.'**
  String get egressDisableFirst;

  /// No description provided for @egressTtInherited.
  ///
  /// In en, this message translates to:
  /// **'Client egress is enabled in the server settings. TrustTunnel uses it automatically.'**
  String get egressTtInherited;

  /// No description provided for @vpnIndividualTemplate.
  ///
  /// In en, this message translates to:
  /// **'Individual base config'**
  String get vpnIndividualTemplate;

  /// No description provided for @vpnIndividualTemplateHelp.
  ///
  /// In en, this message translates to:
  /// **'Use a separate YAML file for this client.'**
  String get vpnIndividualTemplateHelp;

  /// No description provided for @vpnSharedTemplateHelp.
  ///
  /// In en, this message translates to:
  /// **'Use the shared base config from settings.'**
  String get vpnSharedTemplateHelp;

  /// No description provided for @vpnIndividualTemplateRequired.
  ///
  /// In en, this message translates to:
  /// **'Select a YAML file for this client.'**
  String get vpnIndividualTemplateRequired;

  /// No description provided for @catalogForgetServerJumpWarning.
  ///
  /// In en, this message translates to:
  /// **'SSH jump references to these servers will be removed from other saved connections. Choose a new SSH route for those servers afterwards.'**
  String get catalogForgetServerJumpWarning;

  /// No description provided for @versionsChoose.
  ///
  /// In en, this message translates to:
  /// **'Versions'**
  String get versionsChoose;

  /// No description provided for @versionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Versions · {name}'**
  String versionsTitle(Object name);

  /// No description provided for @versionsLoading.
  ///
  /// In en, this message translates to:
  /// **'Getting the release list and the server state…'**
  String get versionsLoading;

  /// No description provided for @versionsFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not get the release list or the server state. Check the connection and try again.'**
  String get versionsFailed;

  /// No description provided for @versionsHelp.
  ///
  /// In en, this message translates to:
  /// **'A new version is installed with a check of real connections. If they stop working, or this device loses the server, the server returns the previous version by itself within 5 minutes. Older versions are not offered: you can only go back to the one that ran before the last update.'**
  String get versionsHelp;

  /// No description provided for @versionsInstalled.
  ///
  /// In en, this message translates to:
  /// **'installed {version}'**
  String versionsInstalled(Object version);

  /// No description provided for @versionsNothing.
  ///
  /// In en, this message translates to:
  /// **'No newer versions and nothing to go back to.'**
  String get versionsNothing;

  /// No description provided for @versionsVerified.
  ///
  /// In en, this message translates to:
  /// **'checked by AntiRKN'**
  String get versionsVerified;

  /// No description provided for @versionsUnverified.
  ///
  /// In en, this message translates to:
  /// **'not checked by AntiRKN'**
  String get versionsUnverified;

  /// No description provided for @versionsPreview.
  ///
  /// In en, this message translates to:
  /// **'pre-release'**
  String get versionsPreview;

  /// No description provided for @versionsPrevious.
  ///
  /// In en, this message translates to:
  /// **'previous version'**
  String get versionsPrevious;

  /// No description provided for @versionsInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get versionsInstall;

  /// No description provided for @versionsRestore.
  ///
  /// In en, this message translates to:
  /// **'Go back'**
  String get versionsRestore;

  /// No description provided for @versionsInstallTitle.
  ///
  /// In en, this message translates to:
  /// **'Install {name} {version}?'**
  String versionsInstallTitle(Object name, Object version);

  /// No description provided for @versionsRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Go back to {name} {version}?'**
  String versionsRestoreTitle(Object name, Object version);

  /// No description provided for @versionsChange.
  ///
  /// In en, this message translates to:
  /// **'Now: {from} → {to}.'**
  String versionsChange(Object from, Object to);

  /// No description provided for @versionsPanelCarriesXray.
  ///
  /// In en, this message translates to:
  /// **'The 3x-ui release carries its own Xray: the core changes together with the panel.'**
  String get versionsPanelCarriesXray;

  /// No description provided for @versionsPanelRestoresXray.
  ///
  /// In en, this message translates to:
  /// **'Xray {version} comes back together with the panel.'**
  String versionsPanelRestoresXray(Object version);

  /// No description provided for @versionsSafety.
  ///
  /// In en, this message translates to:
  /// **'Inbounds, clients and settings stay as they are. After the switch the server checks real connections; if this device does not confirm within 5 minutes, the server returns the current version.'**
  String get versionsSafety;

  /// No description provided for @versionsAssetMissing.
  ///
  /// In en, this message translates to:
  /// **'This release has no file for this server\'s architecture or no checksum. Choose another version.'**
  String get versionsAssetMissing;

  /// No description provided for @versionsAwgBuild.
  ///
  /// In en, this message translates to:
  /// **'AmneziaWG is built from source on the server: this takes several minutes.'**
  String get versionsAwgBuild;

  /// No description provided for @versionsSafetyInstaller.
  ///
  /// In en, this message translates to:
  /// **'Keys and settings stay as they are. The new version goes into its own folder; if the service does not start or connections stop working after the switch, the server returns to the current version by itself.'**
  String get versionsSafetyInstaller;

  /// No description provided for @versionsXraySafety.
  ///
  /// In en, this message translates to:
  /// **'Xray changes only with a check: real connections are tested before and after the switch, and the app must still sign in to 3x-ui and see the same inbounds. Otherwise, or if this device does not confirm within 5 minutes, the server returns the current version. Inbounds, clients and settings stay as they are.'**
  String get versionsXraySafety;

  /// No description provided for @versionsXrayUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Xray can change only together with the connection check. Open the server\'s Updates page on a device that can test connections and choose the version again.'**
  String get versionsXrayUnavailable;

  /// No description provided for @versionsHelpInstaller.
  ///
  /// In en, this message translates to:
  /// **'Newer stable releases are installed into their own folder next to the current one. If the service does not start or connections stop working after the switch, the server returns to the current version by itself. Older versions are not offered.'**
  String get versionsHelpInstaller;

  /// No description provided for @uiOperationRunning.
  ///
  /// In en, this message translates to:
  /// **'In progress…'**
  String get uiOperationRunning;

  /// No description provided for @uiOperationQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get uiOperationQueued;

  /// No description provided for @vpnMissingOnServer.
  ///
  /// In en, this message translates to:
  /// **'Not on the server yet. The app sends it by itself.'**
  String get vpnMissingOnServer;

  /// No description provided for @vpnMissingNotice.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 connection from the app is not on this server yet. The app sends it by itself; if that did not work, send it again.} other{{count} connections from the app are not on this server yet. The app sends them by itself; if that did not work, send them again.}}'**
  String vpnMissingNotice(int count);

  /// No description provided for @vpnSendToServer.
  ///
  /// In en, this message translates to:
  /// **'Send to server'**
  String get vpnSendToServer;

  /// No description provided for @ttIssueWaiting.
  ///
  /// In en, this message translates to:
  /// **'The server is busy with another operation. Issuing becomes available when it finishes.'**
  String get ttIssueWaiting;

  /// No description provided for @vpnDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get vpnDelete;

  /// No description provided for @awgDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete AmneziaWG interface'**
  String get awgDelete;

  /// No description provided for @awgDeleteHelp.
  ///
  /// In en, this message translates to:
  /// **'The next plan removes this AmneziaWG interface and its client keys on the server. Clients in this app remain.'**
  String get awgDeleteHelp;

  /// No description provided for @ttDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete TrustTunnel endpoint'**
  String get ttDelete;

  /// No description provided for @ttDeleteHelp.
  ///
  /// In en, this message translates to:
  /// **'The next plan removes this TrustTunnel endpoint and its client credentials on the server. Clients in this app remain.'**
  String get ttDeleteHelp;

  /// No description provided for @xrayUpgradeStopTitle.
  ///
  /// In en, this message translates to:
  /// **'Stop the Xray upgrade?'**
  String get xrayUpgradeStopTitle;

  /// No description provided for @xrayUpgradeStopHelp.
  ///
  /// In en, this message translates to:
  /// **'The server aborts the upgrade and restores the previous core. Connections are checked again.'**
  String get xrayUpgradeStopHelp;

  /// No description provided for @uiProtocolActions.
  ///
  /// In en, this message translates to:
  /// **'Protocol actions'**
  String get uiProtocolActions;

  /// No description provided for @uiBusySync.
  ///
  /// In en, this message translates to:
  /// **'Profiles are being synced and published'**
  String get uiBusySync;

  /// No description provided for @uiBusyChanges.
  ///
  /// In en, this message translates to:
  /// **'Wait for the current change to finish'**
  String get uiBusyChanges;

  /// No description provided for @uiBusyServerOperation.
  ///
  /// In en, this message translates to:
  /// **'The server is running another operation'**
  String get uiBusyServerOperation;

  /// No description provided for @uiBusyConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the server'**
  String get uiBusyConnecting;

  /// No description provided for @uiNeedsConnection.
  ///
  /// In en, this message translates to:
  /// **'Not connected to the server'**
  String get uiNeedsConnection;

  /// No description provided for @uiApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get uiApply;

  /// No description provided for @inboundDeleteReadFailed.
  ///
  /// In en, this message translates to:
  /// **'The selected inbounds could not be read on the server. Nothing was deleted; try again after refreshing the list.'**
  String get inboundDeleteReadFailed;

  /// No description provided for @egressCheckedAt.
  ///
  /// In en, this message translates to:
  /// **'TCP and UDP checked · {ms} ms · {date}'**
  String egressCheckedAt(Object date, Object ms);

  /// No description provided for @egressInbound.
  ///
  /// In en, this message translates to:
  /// **'VLESS inbound'**
  String get egressInbound;

  /// No description provided for @inventoryPartialList.
  ///
  /// In en, this message translates to:
  /// **'Some checks were incomplete: {items}'**
  String inventoryPartialList(Object items);

  /// No description provided for @inventoryVersionUnknownReason.
  ///
  /// In en, this message translates to:
  /// **'Version unknown: {reason}'**
  String inventoryVersionUnknownReason(Object reason);

  /// No description provided for @xrayUpgradeProblemAfter.
  ///
  /// In en, this message translates to:
  /// **'{reason} The check did not finish. Review the connection results and retry when connectivity is restored.'**
  String xrayUpgradeProblemAfter(Object reason);

  /// No description provided for @uiClientAccessFor.
  ///
  /// In en, this message translates to:
  /// **'Access for {name}'**
  String uiClientAccessFor(Object name);

  /// No description provided for @aptDiskFull.
  ///
  /// In en, this message translates to:
  /// **'Not enough free disk space on the server for APT (/, /boot or the package cache). Free up space, then try again.'**
  String get aptDiskFull;

  /// No description provided for @aptMemoryLow.
  ///
  /// In en, this message translates to:
  /// **'Not enough free memory on the server for APT. Stop heavy processes or add memory, then try again.'**
  String get aptMemoryLow;

  /// No description provided for @aptLockBusy.
  ///
  /// In en, this message translates to:
  /// **'Another package manager process (for example, automatic Ubuntu updates) holds the APT lock. Wait for it to finish, then try again.'**
  String get aptLockBusy;

  /// No description provided for @aptDpkgInterrupted.
  ///
  /// In en, this message translates to:
  /// **'A previous package installation was interrupted. Run sudo dpkg --configure -a on the server, then try again.'**
  String get aptDpkgInterrupted;

  /// No description provided for @runnerUpgradeDiskFull.
  ///
  /// In en, this message translates to:
  /// **'Not enough free disk space for the update'**
  String get runnerUpgradeDiskFull;

  /// No description provided for @runnerUpgradeMemoryLow.
  ///
  /// In en, this message translates to:
  /// **'Not enough free memory for the update'**
  String get runnerUpgradeMemoryLow;

  /// No description provided for @runnerUpgradeNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'The component is not installed on the server'**
  String get runnerUpgradeNotInstalled;

  /// No description provided for @runnerUpgradeInvalidComponent.
  ///
  /// In en, this message translates to:
  /// **'This component cannot be updated this way'**
  String get runnerUpgradeInvalidComponent;

  /// No description provided for @runnerUpgradeBinaryNotFound.
  ///
  /// In en, this message translates to:
  /// **'The package does not contain the expected program file'**
  String get runnerUpgradeBinaryNotFound;

  /// No description provided for @runnerUpgradeArchitectureMismatch.
  ///
  /// In en, this message translates to:
  /// **'The package is built for a different server architecture'**
  String get runnerUpgradeArchitectureMismatch;

  /// No description provided for @runnerUpgradeRollbackFailed.
  ///
  /// In en, this message translates to:
  /// **'Rollback failed: the previous version was not restored. Check the server'**
  String get runnerUpgradeRollbackFailed;

  /// No description provided for @softwareAwgDockerUpdate.
  ///
  /// In en, this message translates to:
  /// **'AmneziaWG runs in Docker. The app does not update Docker containers: update the container image yourself.'**
  String get softwareAwgDockerUpdate;

  /// No description provided for @relayTitle.
  ///
  /// In en, this message translates to:
  /// **'Direct exit for servers'**
  String get relayTitle;

  /// No description provided for @relayHelp.
  ///
  /// In en, this message translates to:
  /// **'Traffic of this inbound leaves the server directly, bypassing the internet egress. For your own servers, not for clients.'**
  String get relayHelp;

  /// No description provided for @relayEgressOff.
  ///
  /// In en, this message translates to:
  /// **'Internet egress is not set up now, so traffic already goes direct. The setting takes effect once egress is enabled.'**
  String get relayEgressOff;

  /// No description provided for @relayClientFacing.
  ///
  /// In en, this message translates to:
  /// **'This inbound is assigned to clients. Switch it to “Internal use” first.'**
  String get relayClientFacing;

  /// No description provided for @relayInboundDisabled.
  ///
  /// In en, this message translates to:
  /// **'Enable the inbound to set up the direct exit.'**
  String get relayInboundDisabled;

  /// No description provided for @relayBadge.
  ///
  /// In en, this message translates to:
  /// **'Direct exit'**
  String get relayBadge;

  /// No description provided for @relayStaleBadge.
  ///
  /// In en, this message translates to:
  /// **'Direct exit not in effect'**
  String get relayStaleBadge;

  /// No description provided for @relayStale.
  ///
  /// In en, this message translates to:
  /// **'The inbound settings changed in 3x-ui, so the direct exit is not in effect now. Apply it again.'**
  String get relayStale;

  /// No description provided for @relayApplyAgain.
  ///
  /// In en, this message translates to:
  /// **'Apply again'**
  String get relayApplyAgain;

  /// No description provided for @relayLink.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get relayLink;

  /// No description provided for @relayLinkTitle.
  ///
  /// In en, this message translates to:
  /// **'Link for servers'**
  String get relayLinkTitle;

  /// No description provided for @relayLinkHelp.
  ///
  /// In en, this message translates to:
  /// **'Service access for your own servers. Do not give this link to clients. To change the link, turn the direct exit off and on again.'**
  String get relayLinkHelp;

  /// No description provided for @relayLinkHidden.
  ///
  /// In en, this message translates to:
  /// **'Link hidden'**
  String get relayLinkHidden;

  /// No description provided for @relayShow.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get relayShow;

  /// No description provided for @relayHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get relayHide;

  /// No description provided for @relayCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get relayCopy;

  /// No description provided for @relayCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not copy the link.'**
  String get relayCopyFailed;

  /// No description provided for @relayDirectCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Direct: {count} inbound} other{Direct: {count} inbounds}}'**
  String relayDirectCount(num count);

  /// No description provided for @relayInternalLocked.
  ///
  /// In en, this message translates to:
  /// **'Turn off the direct exit for servers first'**
  String get relayInternalLocked;

  /// No description provided for @relayStateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the direct exit state. The last known state is shown.'**
  String get relayStateFailed;

  /// No description provided for @relayPreparing.
  ///
  /// In en, this message translates to:
  /// **'Checking the direct exit settings'**
  String get relayPreparing;

  /// No description provided for @relayApplying.
  ///
  /// In en, this message translates to:
  /// **'Configuring the direct exit'**
  String get relayApplying;

  /// No description provided for @relayUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This inbound cannot be a direct exit: an enabled 3x-ui VLESS inbound is required.'**
  String get relayUnsupported;

  /// No description provided for @relayClientInbound.
  ///
  /// In en, this message translates to:
  /// **'This inbound is assigned to clients. Switch it to “Internal use”, apply, and try again.'**
  String get relayClientInbound;

  /// No description provided for @relayConflict.
  ///
  /// In en, this message translates to:
  /// **'Settings have changed. Refresh and try again.'**
  String get relayConflict;

  /// No description provided for @relayConfigFailed.
  ///
  /// In en, this message translates to:
  /// **'Xray rejected the routing settings. Nothing was changed.'**
  String get relayConfigFailed;

  /// No description provided for @relayDisableFirst.
  ///
  /// In en, this message translates to:
  /// **'The direct exit for servers is on for this inbound. Turn it off first.'**
  String get relayDisableFirst;

  /// No description provided for @relayMissing.
  ///
  /// In en, this message translates to:
  /// **'The inbound or its service access was not found on the server. Refresh the list.'**
  String get relayMissing;

  /// No description provided for @relayFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not configure the direct exit. See the operation history for details.'**
  String get relayFailed;

  /// No description provided for @vpnNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected. The changes will be applied after connecting.'**
  String get vpnNotConnected;

  /// No description provided for @opsRemoving.
  ///
  /// In en, this message translates to:
  /// **'Removing {names}'**
  String opsRemoving(String names);

  /// No description provided for @opsApplying.
  ///
  /// In en, this message translates to:
  /// **'Applying changes on servers'**
  String get opsApplying;

  /// No description provided for @opsMoreServers.
  ///
  /// In en, this message translates to:
  /// **'{servers} and {count} more'**
  String opsMoreServers(String servers, int count);

  /// No description provided for @opsOpenServer.
  ///
  /// In en, this message translates to:
  /// **'Open server'**
  String get opsOpenServer;

  /// No description provided for @opsContinueHere.
  ///
  /// In en, this message translates to:
  /// **'Continue here'**
  String get opsContinueHere;

  /// No description provided for @opsDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'Server changes'**
  String get opsDetailsTitle;

  /// No description provided for @opsRemovalOf.
  ///
  /// In en, this message translates to:
  /// **'Revoke access · {name}'**
  String opsRemovalOf(String name);

  /// No description provided for @uiRecentActivity.
  ///
  /// In en, this message translates to:
  /// **'Recent activity'**
  String get uiRecentActivity;

  /// No description provided for @uiViewAll.
  ///
  /// In en, this message translates to:
  /// **'View all'**
  String get uiViewAll;

  /// No description provided for @uiActivityToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get uiActivityToday;

  /// No description provided for @uiActivityYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get uiActivityYesterday;

  /// No description provided for @uiActivityEarlier.
  ///
  /// In en, this message translates to:
  /// **'Earlier'**
  String get uiActivityEarlier;

  /// No description provided for @uiActivityStep.
  ///
  /// In en, this message translates to:
  /// **'Step {current} of {total}'**
  String uiActivityStep(int current, int total);

  /// No description provided for @uiActivitySteps.
  ///
  /// In en, this message translates to:
  /// **'Steps'**
  String get uiActivitySteps;

  /// No description provided for @uiActivityStepsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The full list of steps could not be loaded. The last step is shown.'**
  String get uiActivityStepsUnavailable;

  /// No description provided for @uiTechnicalDetails.
  ///
  /// In en, this message translates to:
  /// **'Technical details'**
  String get uiTechnicalDetails;

  /// No description provided for @uiActivityJobId.
  ///
  /// In en, this message translates to:
  /// **'Job ID'**
  String get uiActivityJobId;

  /// No description provided for @activityApply.
  ///
  /// In en, this message translates to:
  /// **'Apply configuration'**
  String get activityApply;

  /// No description provided for @activityInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get activityInstall;

  /// No description provided for @activityUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get activityUpdate;

  /// No description provided for @activityEditExisting.
  ///
  /// In en, this message translates to:
  /// **'Edit existing setup'**
  String get activityEditExisting;

  /// No description provided for @activityCertificate.
  ///
  /// In en, this message translates to:
  /// **'Certificate'**
  String get activityCertificate;

  /// No description provided for @activityComponents.
  ///
  /// In en, this message translates to:
  /// **'Components'**
  String get activityComponents;

  /// No description provided for @activityEditInbound.
  ///
  /// In en, this message translates to:
  /// **'Edit inbound'**
  String get activityEditInbound;

  /// No description provided for @activityRemoveInbound.
  ///
  /// In en, this message translates to:
  /// **'Remove inbound'**
  String get activityRemoveInbound;

  /// No description provided for @activityServerAccess.
  ///
  /// In en, this message translates to:
  /// **'Access for another server'**
  String get activityServerAccess;

  /// No description provided for @activityCheck.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get activityCheck;

  /// No description provided for @activitySshHarden.
  ///
  /// In en, this message translates to:
  /// **'SSH hardening'**
  String get activitySshHarden;

  /// No description provided for @activityDiagnostic.
  ///
  /// In en, this message translates to:
  /// **'Server check'**
  String get activityDiagnostic;

  /// No description provided for @serviceModeTitle.
  ///
  /// In en, this message translates to:
  /// **'Service mode'**
  String get serviceModeTitle;

  /// No description provided for @serviceModeHelp.
  ///
  /// In en, this message translates to:
  /// **'The server stays in the app and keeps running, but its proxies leave client profiles and new clients are not added to it. Turn it on while you test, repair or rebuild the server.'**
  String get serviceModeHelp;

  /// No description provided for @serviceModeOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get serviceModeOff;

  /// No description provided for @serviceModeSince.
  ///
  /// In en, this message translates to:
  /// **'On since {time}'**
  String serviceModeSince(String time);

  /// No description provided for @serviceModeReturningBadge.
  ///
  /// In en, this message translates to:
  /// **'Returning'**
  String get serviceModeReturningBadge;

  /// No description provided for @serviceModeReturning.
  ///
  /// In en, this message translates to:
  /// **'Returning: the server is getting the current client accesses. It comes back to profiles once the server confirms them.'**
  String get serviceModeReturning;

  /// No description provided for @serviceModeReturnStalled.
  ///
  /// In en, this message translates to:
  /// **'The return is not finished'**
  String get serviceModeReturnStalled;

  /// No description provided for @serviceModeRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get serviceModeRetry;

  /// No description provided for @serviceModeEnter.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get serviceModeEnter;

  /// No description provided for @serviceModeExit.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get serviceModeExit;

  /// No description provided for @serviceModeCancelExit.
  ///
  /// In en, this message translates to:
  /// **'Cancel the return'**
  String get serviceModeCancelExit;

  /// No description provided for @serviceModeEnterTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on service mode?'**
  String get serviceModeEnterTitle;

  /// No description provided for @serviceModeEnterIntro.
  ///
  /// In en, this message translates to:
  /// **'{server} keeps running, and client accesses stay on it for the way back.'**
  String serviceModeEnterIntro(String server);

  /// No description provided for @serviceModeEnterProfiles.
  ///
  /// In en, this message translates to:
  /// **'Its proxies leave client profiles: the next publication goes without them.'**
  String get serviceModeEnterProfiles;

  /// No description provided for @serviceModeEnterPublication.
  ///
  /// In en, this message translates to:
  /// **'Publication no longer waits for this server.'**
  String get serviceModeEnterPublication;

  /// No description provided for @serviceModeEnterNewClients.
  ///
  /// In en, this message translates to:
  /// **'New clients are not added to it. Protocol changes apply at once, and connection checks work.'**
  String get serviceModeEnterNewClients;

  /// No description provided for @serviceModeEnterRevocations.
  ///
  /// In en, this message translates to:
  /// **'Disabling and deleting clients still applies on it whenever it is reachable.'**
  String get serviceModeEnterRevocations;

  /// No description provided for @serviceModeEnterEgress.
  ///
  /// In en, this message translates to:
  /// **'Other servers leave to the internet through this one (relay or internal inbound). Service mode does not switch them: if this server stops, their clients lose internet access.'**
  String get serviceModeEnterEgress;

  /// No description provided for @serviceModeEnterEgressUnknown.
  ///
  /// In en, this message translates to:
  /// **'If other servers leave to the internet through this one, service mode does not switch them.'**
  String get serviceModeEnterEgressUnknown;

  /// No description provided for @serviceModeExitTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn off service mode?'**
  String get serviceModeExitTitle;

  /// No description provided for @serviceModeExitClients.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{By the server\'s last data, no new clients will be added to it.} =1{By the server\'s last data, 1 client will be added to it.} other{By the server\'s last data, {count} clients will be added to it.}}'**
  String serviceModeExitClients(int count);

  /// No description provided for @serviceModeExitHelp.
  ///
  /// In en, this message translates to:
  /// **'The server gets the current client accesses first. It returns to client profiles only after it confirms them; until then it stays out of them, as now.'**
  String get serviceModeExitHelp;

  /// No description provided for @serviceAccessWaiting.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{An access change for 1 client waits for this server.} other{Access changes for {count} clients wait for this server.}}'**
  String serviceAccessWaiting(int count);

  /// No description provided for @serviceAccessWaitingHelp.
  ///
  /// In en, this message translates to:
  /// **'Changes are sent automatically once the server is reachable.'**
  String get serviceAccessWaitingHelp;

  /// No description provided for @serviceAccessSendNow.
  ///
  /// In en, this message translates to:
  /// **'Send now'**
  String get serviceAccessSendNow;

  /// No description provided for @serviceModeHeld.
  ///
  /// In en, this message translates to:
  /// **'Changes wait for servers in service mode'**
  String get serviceModeHeld;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
