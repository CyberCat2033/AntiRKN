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

  /// No description provided for @sshJumpHelp.
  ///
  /// In en, this message translates to:
  /// **'Connect through another saved server. Each server uses its own login and SSH key.'**
  String get sshJumpHelp;

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
  /// **'Save and prepare access plan'**
  String get vpnSave;

  /// No description provided for @vpnInbounds.
  ///
  /// In en, this message translates to:
  /// **'VLESS inbounds'**
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
  /// **'The next plan will remove this inbound for all clients.'**
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

  /// No description provided for @vpnOfflinePlan.
  ///
  /// In en, this message translates to:
  /// **'Server offline. The approved changes will run after reconnection and precondition checks.'**
  String get vpnOfflinePlan;

  /// No description provided for @vpnPending.
  ///
  /// In en, this message translates to:
  /// **'Access changes are pending on one or more servers. A complete current profile is not ready yet.'**
  String get vpnPending;

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
  /// **'The previous valid revision is retained. Fix the template or complete pending access changes before export.'**
  String get vpnLastProfile;

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
  /// **'Choose a base YAML in Templates first.'**
  String get vpnEmptyTemplate;

  /// No description provided for @vpnNoAccess.
  ///
  /// In en, this message translates to:
  /// **'No active inbounds are configured for this client yet.'**
  String get vpnNoAccess;

  /// No description provided for @vpnRealityCompatibility.
  ///
  /// In en, this message translates to:
  /// **'REALITY uses minClientVer=1.8.2 for Mihomo compatibility. Xray warns of increased detection risk when lowering this threshold. Compatibility tests do not establish resistance to blocking.'**
  String get vpnRealityCompatibility;

  /// No description provided for @protocolSoftware.
  ///
  /// In en, this message translates to:
  /// **'Protocol updates'**
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

  /// No description provided for @updatesAutomatic.
  ///
  /// In en, this message translates to:
  /// **'Automatically check protocol versions'**
  String get updatesAutomatic;

  /// No description provided for @updatesSuggestions.
  ///
  /// In en, this message translates to:
  /// **'Show update suggestions'**
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
  /// **'New releases are checked for 3x-ui, Xray, TrustTunnel and AmneziaWG. Applying verified TrustTunnel/AmneziaWG updates is available through their plans; applying 3x-ui/Xray updates is not available yet.'**
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
  /// **'Regenerate REALITY keys and Short ID'**
  String get vpnRegenerateReality;

  /// No description provided for @vpnRealityAutomatic.
  ///
  /// In en, this message translates to:
  /// **'REALITY keys and Short ID are generated automatically and kept when editing.'**
  String get vpnRealityAutomatic;

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
