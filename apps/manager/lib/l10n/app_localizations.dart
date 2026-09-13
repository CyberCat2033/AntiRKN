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

  /// No description provided for @templates.
  ///
  /// In en, this message translates to:
  /// **'Templates'**
  String get templates;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @workbench.
  ///
  /// In en, this message translates to:
  /// **'Base profile check'**
  String get workbench;

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
  /// **'Base YAML'**
  String get source;

  /// No description provided for @sourceHelp.
  ///
  /// In en, this message translates to:
  /// **'Choose a .yml or .yaml file. The app saves its own copy on this device; the source file is not modified.'**
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

  /// No description provided for @coreNotRun.
  ///
  /// In en, this message translates to:
  /// **'Mihomo: core validation has not run'**
  String get coreNotRun;

  /// No description provided for @connectionNotRun.
  ///
  /// In en, this message translates to:
  /// **'Network connection has not been tested'**
  String get connectionNotRun;

  /// No description provided for @overviewText.
  ///
  /// In en, this message translates to:
  /// **'Manage saved servers over SSH, inspect their software and IP addresses, and edit templates. Server installation, protocol configuration and Google Drive sync are planned for later stages.'**
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
  /// **'System animation restrictions take priority. Prototype theme and motion settings last until the app closes.'**
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
  /// **'Empty group: choose a policy before publishing.'**
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
  /// **'The template already contains proxies. Choose how to import them first.'**
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

  /// No description provided for @sshTitle.
  ///
  /// In en, this message translates to:
  /// **'SSH connection'**
  String get sshTitle;

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
  /// **'Changing the name keeps the connection open. Saving changed SSH settings disconnects the session; reconnect to apply them.'**
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

  /// No description provided for @sshReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Connect to an Ubuntu x86_64 VPS to read its network information.'**
  String get sshReadOnly;

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

  /// No description provided for @sshSaved.
  ///
  /// In en, this message translates to:
  /// **'Connection saved on this device.'**
  String get sshSaved;

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
  /// **'UID and sudo availability are observations. Elevation for installation has not been tested.'**
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
