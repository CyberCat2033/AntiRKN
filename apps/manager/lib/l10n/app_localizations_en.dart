// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'AntiRKN';

  @override
  String get overview => 'Overview';

  @override
  String get templates => 'Templates';

  @override
  String get settings => 'Settings';

  @override
  String get workbench => 'Base profile check';

  @override
  String get prototype => 'P0 prototype';

  @override
  String get intro =>
      'Check which nodes are selected by your template groups. Editor changes stay in memory until the app is closed.';

  @override
  String get source => 'Base YAML';

  @override
  String get sourceHelp =>
      'Choose a .yml or .yaml file. The app works with an in-memory copy and does not modify the source file.';

  @override
  String get preview => 'Preview group members';

  @override
  String get pending => 'Checking…';

  @override
  String get stale => 'Preview is out of date — run the check';

  @override
  String get nodes => 'Preview nodes';

  @override
  String get sampleNotice =>
      'These are sample node names without credentials. Server connections and publishing are not available here yet.';

  @override
  String get mixed => 'VLESS + TrustTunnel + AWG';

  @override
  String get noRuWg => 'Without RU and WG';

  @override
  String get nodeName => 'Node name';

  @override
  String get add => 'Add to preview';

  @override
  String get remove => 'Remove from preview';

  @override
  String get groups => 'Selected group members';

  @override
  String get diagnostics => 'Template diagnostics';

  @override
  String get noIssues => 'No structural issues found';

  @override
  String get noMembers => 'No nodes selected';

  @override
  String get incomplete => 'Additional verification is required';

  @override
  String get coreNotRun => 'Mihomo: core validation has not run';

  @override
  String get connectionNotRun => 'Network connection has not been tested';

  @override
  String get overviewText =>
      'The prototype includes template checks and a sample address inventory for one VPS. SSH management, secret storage and Google Drive sync are planned for subsequent iterations.';

  @override
  String get scope =>
      'Ubuntu • x86_64\nWindows • Linux • Android\nVLESS / TrustTunnel / AmneziaWG → Mihomo';

  @override
  String get theme => 'Theme';

  @override
  String get system => 'System';

  @override
  String get light => 'Light';

  @override
  String get dark => 'Dark';

  @override
  String get motion => 'Animations';

  @override
  String get reduced => 'Reduced';

  @override
  String get off => 'Off';

  @override
  String get motionHelp =>
      'System animation restrictions take priority. Prototype theme and motion settings last until the app closes.';

  @override
  String get invalidName => 'Enter a unique, non-empty name';

  @override
  String get loadError => 'Could not load the base template';

  @override
  String get unexpectedError =>
      'Could not check the template. You can try again.';

  @override
  String get language => 'Interface language';

  @override
  String get languageSystem => 'Follow system';

  @override
  String get languageRussian => 'Русский';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageHelp =>
      'Your choice is saved on this device. Other system languages use English.';

  @override
  String get localeSaveError =>
      'Could not save the language preference. Please try again.';

  @override
  String get localeLoadError =>
      'Could not read the language preference. Following the system language.';

  @override
  String fallback(String value) {
    return 'Core behavior for an empty group: $value';
  }

  @override
  String unknownDiagnostic(String code) {
    return 'Template settings need review ($code).';
  }

  @override
  String get diagnosticEmptyGroupRequiresPolicy =>
      'Empty group: choose a policy before publishing.';

  @override
  String get diagnosticChainHasExtraNodes =>
      'Proxy_Chain contains nodes excluded from RemoteBalancer.';

  @override
  String get diagnosticUnreferencedGroup =>
      'Other groups and rules do not reference WG_Auto.';

  @override
  String get diagnosticBaseContainsProxies =>
      'The template already contains proxies. Choose how to import them first.';

  @override
  String get diagnosticInvalidYaml => 'Invalid YAML syntax or a duplicate key.';

  @override
  String get diagnosticTemplateSizeLimit => 'The template exceeds 256 KiB.';

  @override
  String get diagnosticTemplateDepthLimit => 'YAML nesting exceeds 32 levels.';

  @override
  String get diagnosticTemplateNodeLimit =>
      'The template contains too many elements.';

  @override
  String get diagnosticYamlAliasNotSupported =>
      'YAML aliases are not supported yet.';

  @override
  String get diagnosticYamlExplicitTagNotSupported =>
      'Explicit YAML tags are not supported yet.';

  @override
  String get diagnosticMultipleYamlDocuments =>
      'Expected a single YAML document.';

  @override
  String get diagnosticUnsupportedFilterPreview =>
      'This regular expression cannot be previewed precisely yet.';

  @override
  String get diagnosticProviderSnapshotRequired =>
      'A proxy-provider snapshot is needed to resolve the members.';

  @override
  String get diagnosticUnknownProxyReference =>
      'The group references an unknown node or group.';

  @override
  String get diagnosticUnknownRuleTarget =>
      'The rule references an unknown node or group.';

  @override
  String get diagnosticUnknownRuleProvider =>
      'A rule or DNS setting references an unknown rule-provider.';

  @override
  String get diagnosticGroupCycle => 'A cycle was found between proxy groups.';

  @override
  String get diagnosticDuplicateProxyName =>
      'Node and group names must be unique.';

  @override
  String get diagnosticInvalidEmptyFallback => 'Invalid empty-fallback value.';

  @override
  String get diagnosticUnsupportedRulePreview =>
      'This rule type still requires core validation.';

  @override
  String get selectTemplate => 'Choose YAML file';

  @override
  String importedTemplate(String name) {
    return 'Loaded into memory: $name';
  }

  @override
  String get templateReadError =>
      'Could not read the YAML file. The current template was kept.';

  @override
  String get server => 'Server';

  @override
  String get networkTitle => 'Server addresses';

  @override
  String get networkSampleNotice =>
      'Sample data for one VPS. No SSH connection is made and no server settings are changed.';

  @override
  String get networkLoadSample => 'Load sample inventory';

  @override
  String get networkReloadSample => 'Reload sample inventory';

  @override
  String get networkLoading => 'Loading inventory…';

  @override
  String get networkLoadError =>
      'Could not read the inventory. The previous inventory and your choices are kept.';

  @override
  String get networkEmpty => 'No assigned addresses were found.';

  @override
  String get networkNotLoaded =>
      'Load the sample to explore address selection.';

  @override
  String get networkListener => 'Service listening address';

  @override
  String get networkEndpoint => 'Client connection address';

  @override
  String get networkListenerHelp =>
      'Choose an assigned IP or all interfaces. Protocol support and port conflicts must be checked before applying settings.';

  @override
  String get networkEndpointHelp =>
      'Public, stable addresses are suggested. With NAT, the client address can differ from the listening address.';

  @override
  String get networkChoose => 'Choose an address';

  @override
  String get networkClear => 'Clear selection';

  @override
  String get networkClose => 'Close';

  @override
  String get networkNoCandidates =>
      'There are no suitable addresses for this role.';

  @override
  String get networkWildcard => 'All interfaces';

  @override
  String get networkAssigned => 'Assigned on interface';

  @override
  String get networkSampleSource => 'Source: sample iproute2 data';

  @override
  String get networkObservedSource => 'Source: iproute2 observation';

  @override
  String get networkNotVerified =>
      'Port use and TCP/UDP reachability have not been checked. Selecting an address does not apply any settings.';

  @override
  String networkObservedAt(String value) {
    return 'Inventory loaded: $value';
  }

  @override
  String networkSshPeer(String value) {
    return 'SSH transport address (separate): $value';
  }

  @override
  String networkSummary(int addresses, int routes, int rules) {
    return '$addresses unique IPs · $routes routes · $rules policy rules';
  }

  @override
  String get networkAssignments => 'Assigned addresses and status';

  @override
  String get networkSelectedUnavailable =>
      'Your previous choice is no longer usable. Choose an address again.';

  @override
  String get networkCategoryPublic => 'Public unicast';

  @override
  String get networkCategoryPrivate => 'Private';

  @override
  String get networkCategoryLoopback => 'Loopback';

  @override
  String get networkCategoryLinkLocal => 'Link-local';

  @override
  String get networkCategoryShared => 'Shared / CGNAT';

  @override
  String get networkCategoryDocumentation => 'Documentation range';

  @override
  String get networkCategoryMulticast => 'Multicast';

  @override
  String get networkCategoryUnspecified => 'Unspecified';

  @override
  String get networkCategorySpecial => 'Special-purpose range';

  @override
  String get networkHealthReady => 'Ready for selection';

  @override
  String get networkIssueDown => 'Interface is down';

  @override
  String get networkIssueUnknown => 'State or lifetime is unknown';

  @override
  String get networkIssueTentative => 'Address validation is pending';

  @override
  String get networkIssueDadfailed => 'Duplicate address detection failed';

  @override
  String get networkIssueExpired => 'Address has expired';

  @override
  String get networkIssueDeprecated => 'Address is deprecated';

  @override
  String get networkIssueTemporary => 'Temporary address';

  @override
  String get networkIssueNotPublic =>
      'Not suggested as a public client address';

  @override
  String get networkIssueUnsupported =>
      'Special address is not available for this role';

  @override
  String get networkIssueTunnel => 'Tunnel interface';

  @override
  String get networkIssueScope =>
      'Requires protocol support for an interface zone';

  @override
  String get networkIssueUnavailable => 'Address is no longer assigned';

  @override
  String get networkIssueStale =>
      'Observation time is in the future; refresh the inventory';

  @override
  String get networkSecondary => 'Secondary address';

  @override
  String networkPrefix(int value) {
    return 'Prefix: /$value';
  }

  @override
  String networkLifetime(String valid, String preferred) {
    return 'Valid / preferred lifetime: $valid / $preferred';
  }

  @override
  String get networkForever => 'Unlimited';

  @override
  String get networkUnknown => 'Unknown';

  @override
  String networkSeconds(int value) {
    return '$value s';
  }

  @override
  String get networkScopeGlobal => 'Global scope';

  @override
  String get networkScopeLink => 'Link scope';

  @override
  String get networkScopeHost => 'Host scope';

  @override
  String get networkScopeSite => 'Site scope';

  @override
  String get networkScopeOther => 'Other scope';

  @override
  String get networkInterfaceUp => 'Interface is up';

  @override
  String get networkInterfaceStateUnknown => 'Operational state is unknown';

  @override
  String get sshTitle => 'SSH connection';

  @override
  String get sshServerName => 'Server name (optional)';

  @override
  String get sshEdit => 'Edit connection';

  @override
  String get sshEditHelp =>
      'Changing the name keeps the connection open. Saving changed SSH settings disconnects the session; reconnect to apply them.';

  @override
  String get sshOsUnknown => 'OS version will be read on connection';

  @override
  String get sshReplaceServer => 'This is a different server';

  @override
  String get sshReplaceServerHelp =>
      'Continue only if you intentionally replaced the server or changed its address. Verify the new fingerprint through its VPS console. Confirming will replace the saved trusted key; rejecting keeps the old key. Your login details are retained.';

  @override
  String get sshReadOnly =>
      'Connect to an Ubuntu x86_64 VPS to read its network information.';

  @override
  String get sshHost => 'Server address';

  @override
  String get sshPort => 'SSH port';

  @override
  String get sshUser => 'SSH user';

  @override
  String get sshPassword => 'SSH password';

  @override
  String get sshAuthPassword => 'Password';

  @override
  String get sshAuthKey => 'Private key';

  @override
  String get sshAuthAgent => 'Linux SSH-agent';

  @override
  String get sshAgentHelp =>
      'Use keys loaded in the local SSH-agent. The private key stays with the agent.';

  @override
  String get sshPickKey => 'Choose private key';

  @override
  String get sshKeyHelp =>
      'Choose the private file, for example id_ed25519, without .pub. An independent copy is saved in the encrypted vault.';

  @override
  String get sshNoKey => 'No private key selected';

  @override
  String get sshPassphrase => 'Key passphrase (if encrypted)';

  @override
  String get sshSave => 'Save connection';

  @override
  String get sshSaved => 'Connection saved in the encrypted vault.';

  @override
  String get sshConnect => 'Save and connect';

  @override
  String get sshDisconnect => 'Disconnect';

  @override
  String get sshCancel => 'Cancel';

  @override
  String get sshRefresh => 'Refresh from server';

  @override
  String get sshConnecting => 'Connecting…';

  @override
  String get sshReading => 'Reading server information…';

  @override
  String get sshConnected => 'Connected';

  @override
  String get sshIdle => 'Disconnected';

  @override
  String get sshTrustTitle => 'Verify server identity';

  @override
  String get sshTrustHelp =>
      'Compare this SHA-256 fingerprint with a trusted source, such as your VPS console. Accepting saves this server identity before authentication.';

  @override
  String get sshTrustAccept => 'Trust and continue';

  @override
  String get sshTrustReject => 'Reject';

  @override
  String get sshTrustedKey => 'Trusted server key';

  @override
  String get sshDelete => 'Delete saved connection';

  @override
  String get sshDeleteHelp =>
      'Delete the saved credentials and trusted server key from this device? Server settings are unaffected.';

  @override
  String get sshInvalidSettings =>
      'Check the address, port, user and authentication details.';

  @override
  String get sshInvalidKey =>
      'Cannot read or decrypt this private key. Check its format and passphrase. A .pub file cannot be used for login.';

  @override
  String get sshAuthenticationError =>
      'Authentication failed. Check the user and credentials.';

  @override
  String get sshHostChanged =>
      'The server key differs from the trusted key. Connection blocked. Verify the change through your VPS console.';

  @override
  String get sshHostRejected => 'Server identity was not accepted.';

  @override
  String get sshNetworkError =>
      'Could not reach the SSH server or the connection was lost.';

  @override
  String get sshTimeout => 'The operation timed out. You can retry.';

  @override
  String get sshCancelled => 'Operation cancelled.';

  @override
  String get sshCommandError =>
      'The server could not provide complete information. The previous inventory is retained.';

  @override
  String get sshOutputLimit =>
      'Server output exceeded the allowed size. The previous inventory is retained.';

  @override
  String get sshInvalidInventory =>
      'The server returned an invalid inventory. The previous inventory is retained.';

  @override
  String get sshUnsupportedOs => 'This connection requires Ubuntu on x86_64.';

  @override
  String get sshDisconnected =>
      'SSH connection closed. Reconnect to refresh the inventory.';

  @override
  String get sshTrustSaveError =>
      'Could not save server trust. Authentication was stopped.';

  @override
  String get sshAgentError =>
      'Linux SSH-agent is unavailable or has no supported keys. Load your key into the agent or choose a private key file.';

  @override
  String get vaultTitle => 'Protected storage';

  @override
  String get vaultIntro =>
      'Save SSH credentials and server trust encrypted on this device. Choose how to unlock the storage.';

  @override
  String get vaultSystem => 'Use system storage';

  @override
  String get vaultMaster => 'Use master password';

  @override
  String get vaultMasterHelp =>
      'At least 12 characters. Remember this password: it is not saved and cannot be reset to recover the data. This option also works without a Linux keyring.';

  @override
  String get vaultPassword => 'Master password';

  @override
  String get vaultConfirmation => 'Repeat master password';

  @override
  String get vaultCreate => 'Create encrypted storage';

  @override
  String get vaultUnlock => 'Unlock';

  @override
  String get vaultLock => 'Lock storage';

  @override
  String get vaultLocked =>
      'Storage is locked. Unlock to use saved connections.';

  @override
  String get vaultUnlocked => 'Storage unlocked';

  @override
  String get vaultAutoLock =>
      'Locks after 5 minutes without activity and when the app goes into the background; SSH connections close.';

  @override
  String get vaultWorking => 'Opening storage…';

  @override
  String get vaultRetry => 'Retry';

  @override
  String get vaultUnavailable =>
      'System storage is unavailable. Retry after unlocking the OS keyring. When creating a new vault, you can choose a master password.';

  @override
  String get vaultMissingKey =>
      'The system encryption key is unavailable. Restore access to the original OS keyring to unlock this vault.';

  @override
  String get vaultDamaged =>
      'Incorrect master password or damaged storage. Saved data has been preserved.';

  @override
  String get vaultCorrupt =>
      'Storage is damaged or uses an unsupported format. Its file has been preserved.';

  @override
  String get vaultWriteFailed =>
      'Could not save. The previous saved version is retained.';

  @override
  String get vaultBusy =>
      'Storage is busy or was changed by another app instance. Lock it and unlock again before retrying.';

  @override
  String get vaultExists =>
      'Storage already exists. Unlock the existing storage.';

  @override
  String get vaultWeakPassword =>
      'Use matching passwords of 12 to 1024 characters.';
}
