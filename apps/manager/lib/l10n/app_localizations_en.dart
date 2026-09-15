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
  String get templateReady => 'Base configuration loaded.';

  @override
  String get templateLoading => 'Reading the base configuration…';

  @override
  String get profileWarning => 'Warning';

  @override
  String get profileError => 'Error';

  @override
  String get operationObserving =>
      'This operation was approved on another device. Its status is read from the server.';

  @override
  String get operationMissing =>
      'The server has not reported this operation. Check its status before continuing here.';

  @override
  String get operationTakeOver => 'Check and continue on this device';

  @override
  String get settings => 'Settings';

  @override
  String get prototype => 'P0 prototype';

  @override
  String get intro => 'Check which nodes are selected by your template groups.';

  @override
  String get source => 'Base configuration';

  @override
  String get sourceHelp =>
      'Choose a .yml or .yaml file for client profiles. The app saves its own copy; the source file is not modified.';

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
      'Manage servers and VPN clients, generate personal Mihomo profiles, and sync your workspace through Google Drive. Choose the base configuration in Settings.';

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
      'System animation restrictions take priority. Your preference is saved on this device.';

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
      'The group is empty. Mihomo will use its empty-group behavior; review the routing if needed.';

  @override
  String get diagnosticChainHasExtraNodes =>
      'Proxy_Chain contains nodes excluded from RemoteBalancer.';

  @override
  String get diagnosticUnreferencedGroup =>
      'Other groups and rules do not reference WG_Auto.';

  @override
  String get diagnosticBaseContainsProxies =>
      'Proxies from the base configuration are preserved and included in client profiles.';

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
    return 'Imported: $name';
  }

  @override
  String get templateReadError =>
      'Could not read the YAML file. The current template was kept.';

  @override
  String get server => 'Servers';

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
      'External TCP/UDP reachability has not been checked. Selecting an address does not apply any settings.';

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
  String get sshSaved => 'Connection saved on this device.';

  @override
  String get sshConnect => 'Connect';

  @override
  String get sshSaveAndConnect => 'Save and connect';

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
      'Delete this saved server and its credentials from this device? Nothing on the VPS will be changed.';

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
  String get vaultPassword => 'Master password';

  @override
  String get vaultLocked =>
      'Connection data is unavailable. Reopen the server.';

  @override
  String get vaultRetry => 'Retry';

  @override
  String get vaultUnavailable => 'Unable to open saved connections. Retry.';

  @override
  String get vaultMissingKey =>
      'The device encryption key is unavailable. Saved data has been kept.';

  @override
  String get vaultDamaged =>
      'Incorrect master password or damaged storage. Saved data has been preserved.';

  @override
  String get vaultCorrupt =>
      'Storage is damaged or uses an unsupported format. Its file has been preserved.';

  @override
  String get vaultWriteFailed =>
      'Unable to save the connection. Previous data has been kept.';

  @override
  String get vaultBusy =>
      'This connection was changed in another app instance. Reopen it before editing.';

  @override
  String get vaultExists => 'Saved data already exists. Reopen the server.';

  @override
  String get vaultWeakPassword =>
      'Use matching passwords of 12 to 1024 characters.';

  @override
  String get networkExternal => 'External addresses';

  @override
  String get networkInternal => 'Internal addresses';

  @override
  String get networkExternalEmpty =>
      'No public addresses were found on the interfaces.';

  @override
  String get networkInternalEmpty => 'No internal addresses were found.';

  @override
  String get networkClassHint =>
      'External means public unicast; internal includes local and special ranges. This does not prove Internet reachability.';

  @override
  String get inventoryTitle => 'VPS software and resources';

  @override
  String get inventoryScope =>
      'Checks cover standard binary paths, systemd units and recognized images in local Docker. Custom paths, renamed images and rootless Docker may require a separate check. Detection does not confirm protocol compatibility.';

  @override
  String get inventoryStale =>
      'Previous observation. Refresh after connecting to get current data.';

  @override
  String get inventoryDetected => 'Detected';

  @override
  String get inventoryAbsent => 'Not found in checked locations';

  @override
  String get inventoryUnknown => 'Could not determine presence';

  @override
  String get inventoryPartial => 'Some checks were incomplete';

  @override
  String get inventoryUnavailable => 'Unavailable on this system';

  @override
  String get inventoryDenied => 'Insufficient access';

  @override
  String get inventoryFailed => 'Could not check';

  @override
  String get inventoryTimeout => 'Check timed out';

  @override
  String get inventoryInvalid => 'Unrecognized response';

  @override
  String get inventoryOutputLimit => 'Response exceeded the limit';

  @override
  String get inventoryOk => 'Checked';

  @override
  String get inventoryVersionUnknown => 'Version unknown';

  @override
  String inventoryVersion(String value) {
    return 'Version: $value';
  }

  @override
  String get inventoryBinary => 'Program file';

  @override
  String get inventoryKernelModule => 'Loaded kernel module';

  @override
  String get inventoryRunning => 'Active';

  @override
  String get inventoryStopped => 'Inactive';

  @override
  String get inventoryServiceFailed => 'Failed';

  @override
  String get inventoryStateUnknown => 'Runtime state unknown';

  @override
  String get inventoryKernel => 'Kernel';

  @override
  String get inventoryInit => 'PID 1';

  @override
  String get inventoryCpu => 'Online CPUs';

  @override
  String get inventoryMemory => 'Total RAM';

  @override
  String get inventoryAvailableMemory => 'Available RAM';

  @override
  String get inventoryDisk => 'Free space on /';

  @override
  String get inventoryUid => 'Effective UID';

  @override
  String get inventoryTools => 'System tools';

  @override
  String get inventoryToolsEmpty => 'None of the checked tools were found';

  @override
  String get inventoryPrivilegesHint =>
      'UID and sudo availability describe the SSH account. Use the administrative access check to retry restricted reads.';

  @override
  String inventoryMiB(String value) {
    return '$value MiB';
  }

  @override
  String get inventoryPorts => 'Occupied ports';

  @override
  String get inventoryPortsHint =>
      'TCP listeners and bound UDP sockets in the SSH network namespace. External reachability, firewall and dual-stack conflicts are not tested.';

  @override
  String get inventoryNoPorts => 'No sockets were found';

  @override
  String get addServer => 'Add server';

  @override
  String get noServers => 'No servers yet';

  @override
  String get noServersHelp => 'Use + in the top right to add a server.';

  @override
  String get showPassword => 'Show password';

  @override
  String get hidePassword => 'Hide password';

  @override
  String get migrateConnection => 'Transfer saved connection';

  @override
  String get migrateConnectionHelp =>
      'Enter your old master password once to transfer the saved connection. It will open automatically afterwards.';

  @override
  String get databaseOpenError =>
      'Unable to open the local database. Your saved data has been kept.';

  @override
  String get settingsSaveError => 'Unable to save the setting. Try again.';

  @override
  String get draftSaveError =>
      'Template could not be saved on this device. Retry before closing the app.';

  @override
  String get draftSaving => 'Saving template…';

  @override
  String get draftSaved => 'Template saved on this device';

  @override
  String get sshJump => 'Jump SSH';

  @override
  String get sshDirect => 'Direct connection';

  @override
  String get sshJumpMissing => 'Server unavailable';

  @override
  String get sshJumpHelp =>
      'Connect through another saved server. Each server uses its own login and SSH key.';

  @override
  String sshVia(String server) {
    return 'Via $server';
  }

  @override
  String get sshInvalidJump =>
      'The SSH route is invalid: a server is missing or the route contains a cycle. Edit the jump selection.';

  @override
  String get sshJumpHostChanged =>
      'The jump server’s SSH key has changed. Open that server and verify its new fingerprint before connecting.';

  @override
  String get privilegesTitle => 'Administrative access';

  @override
  String get privilegesUnknown =>
      'Administrative access has not been checked in this session.';

  @override
  String get privilegesRoot =>
      'Connected as root. No additional password is needed.';

  @override
  String get privilegesNoPassword =>
      'The sudo check succeeded without a password.';

  @override
  String get privilegesPassword => 'The sudo check succeeded with a password.';

  @override
  String get privilegesRequired =>
      'sudo requires a password. Enter it below and retry.';

  @override
  String get privilegesAuthentication =>
      'sudo rejected the password. Check it before retrying.';

  @override
  String get privilegesDenied =>
      'The server denied this sudo command. The account may lack permission.';

  @override
  String get privilegesUnavailable => 'sudo is not available on the server.';

  @override
  String get privilegesTerminal =>
      'The sudo policy requires an interactive terminal. This mode is not supported yet.';

  @override
  String get privilegesInvalidPassword =>
      'Use up to 1024 characters without line breaks or NUL.';

  @override
  String get privilegesCheck => 'Confirm password';

  @override
  String get privilegesChecking => 'Checking administrative access…';

  @override
  String get privilegesSudoPassword => 'Separate sudo password';

  @override
  String get privilegesSshPasswordHint =>
      'Leave empty to use the saved SSH password. A separate password is stored encrypted.';

  @override
  String get privilegesKeyPasswordHint =>
      'Enter the account password requested by sudo. The private key passphrase is not used. The password is stored encrypted.';

  @override
  String get privilegesScope =>
      'Enter the sudo password to continue. It will be saved encrypted on confirmation.';

  @override
  String get runnerTitle => 'Server jobs';

  @override
  String get runnerHelp =>
      'Installation and diagnostic jobs run on the server. Progress is retained after the app closes or SSH disconnects.';

  @override
  String get runnerPrepare => 'Set up server jobs';

  @override
  String get runnerStart => 'Run server check';

  @override
  String get runnerPlanTitle => 'Server change plan';

  @override
  String get runnerPlanBody =>
      'Install or repair the bundled executor; the known previous release will be upgraded while retaining the journal. Enable the systemd service at startup and create a private job directory. The executor needs network access and write access to /usr/local and /etc for approved installations. Requires Python 3.8+ with SQLite and systemd 235+. Package upgrades are not part of this plan.';

  @override
  String get runnerPlanRelease => 'Bundle SHA-256';

  @override
  String get runnerApply => 'Apply plan';

  @override
  String get runnerNotNow => 'Not now';

  @override
  String get runnerPending =>
      'The submission is saved locally; its server result needs checking.';

  @override
  String get runnerRetry => 'Check and retry this request';

  @override
  String get runnerConnectionLost =>
      'Connection lost. The server job may still be running. Reconnect to retrieve its result.';

  @override
  String get runnerNotRunning =>
      'The worker has not confirmed that it is running. Refresh its status or apply the setup plan.';

  @override
  String get runnerCancelRequested =>
      'Cancellation requested; waiting for a safe stopping point.';

  @override
  String get runnerCancel => 'Cancel server job';

  @override
  String get runnerEventsTruncated =>
      'Older events have been rotated on the server. The current checkpoint is available.';

  @override
  String get runnerJournal => 'Job events';

  @override
  String get runnerHistory => 'Recent jobs';

  @override
  String get runnerPrerequisites =>
      'This runner requires Ubuntu x86_64, a running systemd 235+, and Python 3.8+ with SQLite. No changes were applied.';

  @override
  String get runnerConflict =>
      'The server state conflicts with this plan or request. Refresh the details before continuing.';

  @override
  String get runnerIncompatible =>
      'The installed runner version is incompatible with this build.';

  @override
  String get runnerInstallFailed =>
      'Setup could not be confirmed. Some changes may have been applied. Refresh the server state before retrying.';

  @override
  String get runnerInvalidResponse =>
      'The runner returned an invalid response. Check the saved result before retrying.';

  @override
  String get runnerUnavailable =>
      'The job service is unavailable. Check the SSH connection and administrative access.';

  @override
  String get runnerStorage =>
      'The local job journal could not be saved or restored. Check local storage before retrying.';

  @override
  String get runnerBusy =>
      'Another server job is active. Wait for it to finish.';

  @override
  String get runnerMissing => 'This request has not been found on the server.';

  @override
  String get runnerCapacity =>
      'The server job journal has reached its capacity.';

  @override
  String get runnerPlanned => 'Queued';

  @override
  String get runnerRunning => 'Running';

  @override
  String get runnerSucceeded => 'Completed';

  @override
  String get runnerCancelled => 'Cancelled';

  @override
  String get runnerFailed => 'Failed';

  @override
  String get runnerPartial => 'Partially applied';

  @override
  String get runnerAttention => 'Needs attention';

  @override
  String get runnerSample => 'Server check passed';

  @override
  String get runnerRecovered => 'Resumed from a saved checkpoint';

  @override
  String get componentsInstall => 'Install components';

  @override
  String get componentsSelectionHelp =>
      'Install a missing panel and its Xray. TrustTunnel and AmneziaWG installers will follow.';

  @override
  String get componentsPort => 'Panel local port';

  @override
  String get componentsPortHelp => 'SSH access only; this is not a VPN port.';

  @override
  String get componentsPortInvalid => 'Enter a port between 1024 and 65535.';

  @override
  String get componentsPrepare => 'Prepare plan';

  @override
  String get componentsPlan => '3x-ui / Xray installation plan';

  @override
  String get componentsExisting =>
      'An existing installation was found or could not be ruled out. Automatic reinstallation is unavailable; its configuration is preserved.';

  @override
  String get componentsPrerequisites =>
      'Requires Ubuntu x86_64, Python 3.8+ with SQLite, systemd 235+, nsenter, ca-certificates and 600 MiB free space. Missing prerequisites need separate preparation.';

  @override
  String get componentsPortBusy =>
      'Panel port is occupied. Choose another port and prepare a new plan.';

  @override
  String get componentsPlanBody =>
      'The pinned archive will be downloaded and verified, then a new configuration and service with automatic startup will be created. Initial setup runs in an isolated network; the panel then listens only on 127.0.0.1. Credentials are created once and the subscription service is disabled.';

  @override
  String get componentsDependencies =>
      'The archive includes Xray and geodata. This plan does not update APT packages.';

  @override
  String get componentsRunnerDependency =>
      'The job runner will be installed, repaired or upgraded from the known previous release. It requires network access and write access to installation directories. Job history is retained.';

  @override
  String get componentsPanelAccess => 'Installed panel access';

  @override
  String get componentsAccessHelp =>
      'Credentials are stored encrypted. The address is reachable on the server through an SSH tunnel.';

  @override
  String get componentsPassword => 'Panel password';

  @override
  String get componentsHidePassword => 'Hide password';

  @override
  String get componentsShowPassword => 'Show password';

  @override
  String componentsVerified(String time) {
    return 'API verified through SSH: $time';
  }

  @override
  String get componentsVerifyApi => 'Verify API through SSH';

  @override
  String get componentsJob => '3x-ui / Xray';

  @override
  String get componentsDownloaded => 'Archive downloaded and verified';

  @override
  String get componentsExtracted => 'Files installed';

  @override
  String get componentsConfigured =>
      'Private panel configured and credentials created';

  @override
  String get componentsStarted => 'Service started';

  @override
  String get componentsChecked =>
      'Versions, settings and API verified on the server';

  @override
  String get componentsDownloadFailed =>
      'Archive download failed. Installation is incomplete.';

  @override
  String get componentsChecksumFailed =>
      'Checksum mismatch. The archive will not be executed.';

  @override
  String get componentsApiFailed =>
      'Panel operation could not be verified. Check the journal and service state.';

  @override
  String get componentsPartial =>
      'The operation stopped after applying some changes. Created files are retained; the installation has not been rolled back.';

  @override
  String get componentsResume => 'Resume installation';

  @override
  String get componentsResumePlan =>
      'The same job will resume from its saved step. Verified files are reused and credentials are retained. Resource ownership is checked before changes; a conflict stops the operation.';

  @override
  String get componentsDownloading => 'Downloading archive';

  @override
  String get componentsExtracting => 'Extracting and verifying files';

  @override
  String get componentsConfiguring => 'Configuring panel in isolated network';

  @override
  String get componentsStarting => 'Starting service';

  @override
  String get componentsChecking => 'Checking state and API';

  @override
  String get componentsPlanSummary =>
      'Install the panel and Xray with automatic startup. Panel access is through SSH.';

  @override
  String get componentsRunnerSummary =>
      'The server job service will also be set up.';

  @override
  String get componentsDetails => 'Details';

  @override
  String get componentsEditPlan => 'Edit';

  @override
  String get vpnUsers => 'Clients';

  @override
  String get vpnUsersHelp =>
      'Create each client once. AntiRKN prepares personal access to every configured managed inbound on every server.';

  @override
  String get vpnAddUser => 'Add client';

  @override
  String get vpnNoUsers => 'No clients yet';

  @override
  String get vpnLogin => 'Client login';

  @override
  String get vpnName => 'Display name';

  @override
  String get vpnEnabled => 'Enabled';

  @override
  String get vpnDisabled => 'Disabled';

  @override
  String get vpnSave => 'Save and prepare access plan';

  @override
  String get vpnInbounds => 'VLESS inbounds';

  @override
  String get vpnAddInbound => 'Add inbound';

  @override
  String get vpnInboundHelp =>
      'Each client receives personal access to enabled inbounds with an open lock. Close the lock to reserve an inbound for internal use.';

  @override
  String get vpnNoInbounds => 'No inbounds on this server';

  @override
  String get vpnTransport => 'Transport';

  @override
  String get vpnSecurity => 'Security';

  @override
  String get vpnListen => 'Listen address';

  @override
  String get vpnPort => 'Listen port';

  @override
  String get vpnEndpoint => 'Inbound address (IP or domain)';

  @override
  String get vpnExternalPort => 'Inbound port for connections';

  @override
  String get vpnSni => 'Server name (SNI)';

  @override
  String get vpnTarget => 'REALITY target (host:port)';

  @override
  String get vpnPath => 'XHTTP path';

  @override
  String get vpnHost => 'XHTTP Host (optional)';

  @override
  String get vpnMode => 'XHTTP mode';

  @override
  String get vpnCertificate => 'Certificate chain file on server';

  @override
  String get vpnCertificateKey => 'Certificate private key file on server';

  @override
  String get vpnTlsHelp =>
      'Use an existing certificate for the SNI domain. Certificate issuance and renewal are separate tasks.';

  @override
  String get vpnRegion => 'Add the explicit RU tag for template filters';

  @override
  String get vpnDeleteInbound => 'Delete inbound and its client access';

  @override
  String get vpnDeleteHelp =>
      'The next plan will remove this inbound for all clients.';

  @override
  String get vpnPlan => 'Client access plan';

  @override
  String get vpnPlanHelp =>
      'Apply the listed inbounds and personal access through 3x-ui. A private configuration backup is saved on each server. Xray restarts at completion; connections may briefly pause. Existing clients keep their credentials.';

  @override
  String get vpnPrepare => 'Prepare access plan';

  @override
  String get vpnApply => 'Apply plan to all listed servers';

  @override
  String get vpnOfflinePlan =>
      'Server offline. The approved changes will run after reconnection and precondition checks.';

  @override
  String get vpnPending =>
      'Access changes are pending on one or more servers. A complete current profile is not ready yet.';

  @override
  String get vpnProfile => 'Personal Mihomo profile';

  @override
  String get vpnShowProfile => 'Show profile and client credentials';

  @override
  String get vpnSaveProfile => 'Save YAML';

  @override
  String get vpnCopyProfile => 'Copy YAML';

  @override
  String get vpnProfileSaved => 'Profile saved';

  @override
  String get vpnProfileValidation =>
      'Structural validation only in this screen. Core and network tests for the presets are documented separately.';

  @override
  String get vpnLastProfile =>
      'Could not generate the current profile. The previous saved version is retained.';

  @override
  String get vpnInvalid =>
      'Check names, addresses, ports and the selected transport/security combination.';

  @override
  String get vpnDuplicate =>
      'Client logins and resource identifiers must be unique.';

  @override
  String get vpnConflict =>
      'Server configuration has changed. Refresh and review the conflict before applying again.';

  @override
  String get vpnConnection =>
      'Connect to this server in the Servers section. Pending access changes are retained.';

  @override
  String get vpnPanelRequired =>
      'Connect to the server to load the panel and inbounds. Client management requires access to the panel API.';

  @override
  String get vpnStorage =>
      'Could not save the encrypted client database. Retry after resolving the storage error.';

  @override
  String get vpnStorageConflict =>
      'Another application instance changed the client database. Reload before editing.';

  @override
  String get vpnIdentity =>
      'This saved server now has a different address or SSH identity. Its previous access bindings require review.';

  @override
  String get vpnFailed =>
      'The operation was not confirmed. Refresh the server status or retry the saved operation.';

  @override
  String get vpnPortBusy =>
      'The listen address or port is unavailable or conflicts with another inbound.';

  @override
  String get vpnPartial =>
      'Some changes may already be applied. Review the saved job and resume it when ready.';

  @override
  String get vpnApplying => 'Applying client access';

  @override
  String get vpnChecking => 'Verifying the applied configuration';

  @override
  String get vpnPrepareStep => 'Checking preconditions and saving the backup';

  @override
  String get vpnEdit => 'Edit';

  @override
  String get vpnRefreshProfiles => 'Rebuild profiles';

  @override
  String get vpnSnapshot => 'Last observation';

  @override
  String get vpnChanged => 'Changes awaiting approval';

  @override
  String get vpnEmptyTemplate => 'Choose a base YAML file in Settings.';

  @override
  String get vpnNoAccess =>
      'No active inbounds are configured for this client yet.';

  @override
  String get protocolSoftware => 'Protocol updates';

  @override
  String get protocolExisting =>
      'An existing installation or modified files were found. Automatic adoption is unavailable.';

  @override
  String get protocolCurrent =>
      'The verified version supported by this app is installed.';

  @override
  String get protocolInstallPlan =>
      'Install the selected server component and verify its executables.';

  @override
  String get protocolUpdatePlan =>
      'Replace the executables. The previous version remains available for recovery; configurations and keys are preserved.';

  @override
  String get protocolConfigurationSeparate =>
      'Installing the software does not create a VPN connection. Endpoint, certificates and peers require separate configuration.';

  @override
  String get protocolGoDependency =>
      'Dependencies: Go 1.26.8 and AWG source verified by SHA-256; Go modules verified against go.sum. Built on the server; requires at least 2000 MiB free space.';

  @override
  String get protocolPrepared => 'Plan verified';

  @override
  String get protocolBuilt => 'Executables ready';

  @override
  String get protocolStaged => 'New version staged';

  @override
  String get protocolSwitched => 'New version installed';

  @override
  String get protocolBuildFailed =>
      'AmneziaWG build failed. Check Go modules connectivity, server memory and disk space.';

  @override
  String get protocolCheckFailed => 'Installed version verification failed.';

  @override
  String get updatesCheck => 'Check for updates';

  @override
  String get updatesAutomatic => 'Automatically check protocol versions';

  @override
  String get updatesSuggestions => 'Show update suggestions';

  @override
  String get updatesFailed =>
      'Could not check for updates. The previous result may be stale.';

  @override
  String updatesChecked(String date) {
    return 'Last successful check: $date';
  }

  @override
  String get updatesLatest => 'latest upstream version';

  @override
  String get updatesCompatibility =>
      'New releases are checked for 3x-ui, Xray, TrustTunnel and AmneziaWG. Applying verified TrustTunnel/AmneziaWG updates is available through their plans; applying 3x-ui/Xray updates is not available yet.';

  @override
  String updatesAvailable(String component, String current, String latest) {
    return '$component: update available $current → $latest.';
  }

  @override
  String protocolRestart(String services) {
    return 'Services to restart: $services. Connections may be interrupted. A configuration backup remains with the job journal.';
  }

  @override
  String get protocolPrerequisites =>
      'Installation requires Ubuntu x86_64, Python 3.8+/SQLite, systemd 235+ and ca-certificates. Free space: TrustTunnel — 150 MiB; AmneziaWG — 2000 MiB and an available /dev/net/tun.';

  @override
  String get componentManage => 'Manage / update';

  @override
  String get panelObservedHelp =>
      'Existing panel detected. Its inbounds are shown below; the panel settings and existing clients are preserved.';

  @override
  String get panelDiscoveryFailed =>
      'Some panel settings could not be read. Refresh to retry.';

  @override
  String get vpnInternal => 'Internal use';

  @override
  String get vpnClientAccess => 'Assign to clients';

  @override
  String get vpnInternalHelp =>
      'Keep the inbound enabled, exclude it from client profiles and revoke AntiRKN client access through the plan.';

  @override
  String get vpnObserved => 'Existing · outside client management';

  @override
  String get vpnObservedHelp =>
      'Existing settings and clients are preserved. This inbound is not assigned to AntiRKN clients.';

  @override
  String get panelCliHelp =>
      'Install the official x-ui command from 3x-ui 3.7.0. Panel settings, clients and service remain unchanged.';

  @override
  String get panelCliInstall => 'Install x-ui management menu';

  @override
  String get panelInstallMethod =>
      'Official GitHub release archive and x-ui.sh menu. AntiRKN installs and configures them in recoverable steps; upstream install.sh is not run.';

  @override
  String get vpnConnectionAddress => 'Inbound connection address';

  @override
  String get vpnConnectionAddressHelp =>
      'Uses the server address and listen port by default. Change these only when the inbound is reached through a different address or port (NAT / reverse proxy).';

  @override
  String get xhttpAdvanced => 'XHTTP settings';

  @override
  String get xhttpDefault => 'Default (leave empty)';

  @override
  String get xmuxHelp =>
      'Connection reuse settings shared by this inbound’s client profiles. maxConcurrency and maxConnections cannot both be greater than zero. Ranges use min-max.';

  @override
  String get xhttpHeaders => 'HTTP headers';

  @override
  String get vpnRegenerateReality => 'Regenerate REALITY keys and Short ID';

  @override
  String get vpnRealityAutomatic =>
      'REALITY keys and Short ID are generated automatically and kept when editing.';

  @override
  String get vpnRealityRegenerated =>
      'New REALITY keys and Short ID will be applied with the plan. Client profiles will be rebuilt.';

  @override
  String get vpnRealityKeyPlan =>
      'Apply the selected REALITY key revision and rebuild client profiles.';

  @override
  String get realityScan => 'Scan target';

  @override
  String get realityScanHelp =>
      'Checks TLS and the certificate from this server using 3x-ui. SNI follows Target until you change it.';

  @override
  String get realityScanFailed =>
      'Could not check the target. Connect to the server and verify panel access.';

  @override
  String get realityFeasible => 'Suitable for REALITY';

  @override
  String get realityNotFeasible => 'Not suitable for REALITY';

  @override
  String get realityScanPrivate => 'The target resolves to a private address.';

  @override
  String get realityScanTls => 'TLS 1.3 was not negotiated.';

  @override
  String get realityScanH2 => 'HTTP/2 (h2) was not negotiated.';

  @override
  String get realityScanCurve => 'X25519 key exchange was not negotiated.';

  @override
  String get realityScanCertificate =>
      'The certificate is not valid for this SNI or is not trusted.';

  @override
  String get realityScanUnavailable =>
      'The target could not complete a TLS handshake.';

  @override
  String get realitySniUsed => 'SNI used';

  @override
  String get realityCertificate => 'Certificate';

  @override
  String get realityCertificateExpiry => 'Certificate expires';

  @override
  String get realityKeyExchange => 'Key exchange';

  @override
  String get realityLatency => 'Latency, ms';

  @override
  String get realityCertificateNames =>
      'Names from the certificate — select an SNI, then scan again';

  @override
  String get softwareTitle => 'Server components';

  @override
  String get softwareInstall => 'Install';

  @override
  String get softwareInspect => 'Inspect installation';

  @override
  String get softwareUpdate => 'Update';

  @override
  String get softwareUpdateAvailable => 'Update available';

  @override
  String get softwarePanelAccess => 'Panel access';

  @override
  String get panelAutomaticAddress =>
      'A free port and random panel path are assigned automatically.';

  @override
  String get panelUpdateManual =>
      'A new version is available. Applying 3x-ui/Xray updates in the app is not supported yet; use the x-ui command on the server.';

  @override
  String get aptTitle => 'Ubuntu updates';

  @override
  String get aptUpdate => 'Refresh APT indexes';

  @override
  String get aptUpgrade => 'Upgrade packages';

  @override
  String get aptUpdatePlan =>
      'Refresh available package lists (apt update). Installed packages will stay as they are.';

  @override
  String get aptUpgradePlan =>
      'Upgrade the listed packages using the current APT indexes. Keep local configuration files. No packages are removed; new dependencies and reboot are separate actions. Services may restart.';

  @override
  String get aptCurrent =>
      'No upgrades in the current indexes. Refresh APT indexes to check again.';

  @override
  String aptPackageCount(int count) {
    return 'Packages to upgrade: $count';
  }

  @override
  String get aptReboot =>
      'The server requires a reboot. Restart it when convenient.';

  @override
  String get aptUpdating => 'Refreshing APT indexes…';

  @override
  String get aptUpgrading => 'Upgrading Ubuntu packages…';

  @override
  String get aptRunningHelp =>
      'The job continues after the app closes. Cancellation waits for the current APT command to finish.';

  @override
  String get aptFailed =>
      'APT did not complete the command. Check repositories, disk space and package manager locks, then prepare a new plan.';

  @override
  String get aptConflict =>
      'The package state changed. Prepare a new upgrade plan.';

  @override
  String get aptInterrupted =>
      'The upgrade may be partially applied. Check APT on the server before preparing a new plan; an interrupted command is not repeated automatically.';

  @override
  String get serverDetails => 'Server and network details';

  @override
  String get panelConnectTitle => 'Connect existing panel';

  @override
  String get panelAuthFailed =>
      '3x-ui rejected the panel username or password. Check the panel account; SSH credentials are separate.';

  @override
  String get panelUnreachable =>
      'The runner could not reach the panel API. Check that x-ui is running and that its listening address and HTTPS certificate are valid.';

  @override
  String get panelConnectUnsupported =>
      'Could not identify a unique systemd panel at this port. Docker API connections are not supported yet.';

  @override
  String get panelLoginLimited =>
      '3x-ui temporarily blocked login attempts. Wait before trying again.';

  @override
  String get panelUsername => 'Panel username';

  @override
  String get panelConnectHelp =>
      'Enter the 3x-ui administrator account to view and edit through its API. Access will be saved for future connections.';

  @override
  String get observedClientsKept =>
      'Existing clients and settings outside this plan are preserved.';

  @override
  String get observedFullConfig => 'Full configuration';

  @override
  String get observedEditPlan =>
      'Save changes to the existing inbound and restart Xray. Active connections may be interrupted.';

  @override
  String get componentUpdateUnverified =>
      'This release is not yet included in the app’s verified versions. The installed version is retained.';

  @override
  String get observedTransportJson => 'Transport settings (JSON)';

  @override
  String get panelUpdateSummary =>
      'Save settings and clients, create a backup, and update 3x-ui together with Xray. VPN connections will briefly stop during the restart.';

  @override
  String get panelUpdateRecovery =>
      'On failure, the backup remains on the server. Resume checks files already replaced. The database is not rolled back automatically.';

  @override
  String get panelUpdateCompatibility =>
      'Updates require verified versions of a standard 3x-ui installation with systemd and SQLite. Newer Xray cores are never downgraded.';

  @override
  String get panelUpdatePreparing => 'Checking the installed panel';

  @override
  String get panelUpdateBackup => 'Saving a backup and validating Xray';

  @override
  String get panelUpdateSwitching => 'Updating 3x-ui and Xray, restarting';

  @override
  String get panelLoginOnce =>
      'Sign in to 3x-ui. Your credentials will be saved for future connections.';

  @override
  String get panelLoginRequiredFields =>
      'Enter the panel username and password.';

  @override
  String get panelUpdateCoreCompatibility =>
      'Xray 26.9.8/26.9.9 is incompatible with the verified Mihomo REALITY profiles. This plan uses compatible core 26.7.28; if already installed, its version stays the same.';

  @override
  String get awgAdd => 'Add interface';

  @override
  String get awgRefresh => 'Refresh state';

  @override
  String get awgEmpty => 'No managed AWG interfaces yet.';

  @override
  String get awgConfirmed => 'Configuration confirmed on server';

  @override
  String get awgHandshake => 'Last handshake';

  @override
  String get awgNoHandshake => 'Client has not connected yet';

  @override
  String get awgEndpoint => 'Connection IP or domain';

  @override
  String get awgPort => 'UDP port';

  @override
  String get awgExternalPort => 'External UDP port (NAT)';

  @override
  String get awgEndpointHelp =>
      'Choose the IP for client profiles. AWG listens on the UDP port on all server addresses. The port is checked again before applying.';

  @override
  String get awgAdvanced => 'Advanced settings';

  @override
  String get awgPool => 'Client IPv4 pool (CIDR)';

  @override
  String get awgPool6 => 'IPv6 ULA pool /64 (optional)';

  @override
  String get awgDefaultsHelp =>
      'Defaults follow AmneziaVPN 3.1. Client keys and addresses are generated automatically and retained when profiles are rebuilt. S1–S4 must match when RandomTrailers is enabled.';

  @override
  String get awgCps => 'Initial obfuscation packet I1';

  @override
  String get awgNetworkPlan =>
      'The plan enables IP forwarding and this interface’s UDP, forwarding and NAT rules. Shared settings update all client profiles; connections may briefly stop.';

  @override
  String get awgPrerequisites =>
      'A new interface requires managed AmneziaWG, TUN, iptables/ip6tables and administrator access.';

  @override
  String get awgPoolConflict =>
      'The pool overlaps an existing route or interface. Choose another range.';

  @override
  String get awgPoolFull => 'The pool has insufficient free client addresses.';

  @override
  String get awgObserved => 'Existing installations';

  @override
  String get awgPeersPreserved =>
      'Existing peers, keys and untouched fields will be preserved. Update previously issued client configurations after changing shared parameters.';

  @override
  String get awgExternalUnsupported =>
      'Read-only: this installation has no verified editing adapter yet.';

  @override
  String get awgDockerPortHelp =>
      'Docker publishes this port, so it is preserved when editing. Moving it requires recreating the container with a new port mapping.';

  @override
  String get ttAdd => 'Add endpoint';

  @override
  String get ttEmpty => 'No managed TrustTunnel endpoints yet.';

  @override
  String get ttPort => 'Listening port';

  @override
  String get ttExternalPort => 'Connection port (external port for NAT)';

  @override
  String get ttDomain => 'TLS domain (SNI)';

  @override
  String get ttOutbound => 'Outbound connection';

  @override
  String get ttDirect => 'Direct';

  @override
  String get ttSocksAddress => 'SOCKS5 address and port';

  @override
  String get ttSocksHelp =>
      'For example, 127.0.0.1:1080 on this server. A local SOCKS5 proxy without authentication is supported; UDP also requires UDP support in SOCKS5 and its upstream route.';

  @override
  String get ttQuic => 'QUIC / HTTP/3';

  @override
  String get ttIpv6 => 'Allow outgoing IPv6';

  @override
  String get ttAllowPrivate => 'Allow access to private networks';

  @override
  String get ttRotate => 'Replace passwords for all clients of this endpoint';

  @override
  String get ttCertificates => 'TLS certificates';

  @override
  String get ttAddCertificate => 'Add or issue certificate';

  @override
  String get ttCertificateSource => 'Certificate source';

  @override
  String get ttServerFiles => 'Existing server files';

  @override
  String get ttImportPem => 'Import PEM files';

  @override
  String get ttIssueAcme => 'Issue with ACME HTTP-01';

  @override
  String get ttFilesHelp =>
      'Select discovered files or enter server paths. The existing issuer continues renewal; AntiRKN checks changes and restarts linked TrustTunnel services.';

  @override
  String get ttImportHelp =>
      'Select the full certificate chain and its private key. Files are copied securely to the server. Imported files need a new import when renewed.';

  @override
  String get ttExpectedIps => 'Expected domain IPs, separated by commas';

  @override
  String get ttAcmeEmail => 'Email for ACME registration';

  @override
  String get ttAcmeHelp =>
      'Server IPs are detected automatically. The domain must point to this server, and TCP port 80 must be reachable from the internet. Confirmation issues a Let’s Encrypt certificate and enables automatic renewal. No email is required.';

  @override
  String get ttExpiry => 'Valid until';

  @override
  String get ttLastSuccess => 'Last successful check';

  @override
  String get ttNextCheck => 'Next check';

  @override
  String get ttExpirySoon => 'Certificate expires in less than 21 days.';

  @override
  String get ttRenewAcme => 'Automatic renewal with Certbot';

  @override
  String get ttRenewExternal => 'Renewed by the existing issuer';

  @override
  String get ttRenewImport => 'Update by importing renewed files';

  @override
  String get ttRestartPlan =>
      'After a certificate or configuration change, restart TrustTunnel and verify the service. Active connections may be interrupted briefly.';

  @override
  String get ttDnsChecked => 'DNS matches the selected IPs';

  @override
  String get ttCertbotPresent => 'Installed Certbot';

  @override
  String get ttCertbotInstall =>
      'Install Certbot and its required dependencies';

  @override
  String get ttPreserveUsers =>
      'Existing users, passwords and untouched configuration fields are preserved.';

  @override
  String get ttKeepCertificate => 'Keep existing certificate';

  @override
  String get ttChooseCertificate => 'Select certificate';

  @override
  String get ttNeedCertificate =>
      'Select an existing certificate or issue one for the entered SNI.';

  @override
  String get ttCertificatePending =>
      'Certificate issuance was submitted to the server. The certificate will be selected automatically after it succeeds.';

  @override
  String get ttPrerequisites =>
      'Install the verified TrustTunnel version first.';

  @override
  String get ttUnsupported =>
      'This TrustTunnel installation or configuration is not supported for editing.';

  @override
  String get ttSocksFailed =>
      'SOCKS5 did not accept a connection without authentication. Check its address, port and configuration.';

  @override
  String get ttCertInvalid =>
      'Certificate validation failed: check domain, validity, full chain and matching private key.';

  @override
  String get ttRestartFailed =>
      'TrustTunnel did not start with the expected certificate. The previous certificate was restored where available; check server status.';

  @override
  String get ttDnsFailed => 'Unable to resolve the domain’s A/AAAA records.';

  @override
  String get ttDnsMismatch =>
      'The domain points to a different IP. Set its A/AAAA records to this server’s IPs and try again.';

  @override
  String get ttAcmePortBusy =>
      'TCP port 80 is occupied. HTTP-01 standalone issuance cannot start.';

  @override
  String get ttCertbotRequired =>
      'Certbot cannot be installed from the current APT indexes. Run the manual APT index update and prepare a new plan.';

  @override
  String get ttAcmeFailed =>
      'ACME issuance or renewal failed. Check public DNS, port 80 reachability and the ACME log on the server.';

  @override
  String get backupTitle => 'Backups';

  @override
  String get backupHelp =>
      'Save servers, clients, keys, templates and change history in an encrypted file to restore on another installation.';

  @override
  String get backupExport => 'Create backup';

  @override
  String get backupImport => 'Restore backup';

  @override
  String get backupPassword => 'Backup password';

  @override
  String get backupRepeat => 'Repeat password';

  @override
  String get backupPasswordHelp =>
      'Use a separate password of at least 12 characters. Restoration requires the file and this password. The app does not save it.';

  @override
  String get backupPasswordMismatch =>
      'Enter at least 12 characters; both fields must match when creating a backup.';

  @override
  String get backupShowPassword => 'Show password';

  @override
  String get backupHidePassword => 'Hide password';

  @override
  String get backupInvalid =>
      'Incorrect password or damaged backup. Your data was not replaced.';

  @override
  String get backupVersion =>
      'This app version does not support the backup format.';

  @override
  String get backupTooLarge => 'The backup exceeds 64 MiB.';

  @override
  String get backupChanged =>
      'Data changed after the preview. Select the backup again and review its contents.';

  @override
  String get backupStorage =>
      'Could not read or write storage. Restoration was not applied.';

  @override
  String get backupFileError =>
      'Could not read or save the file. Check access and try again.';

  @override
  String get backupWorking => 'Processing backup…';

  @override
  String get backupSaved => 'Encrypted backup saved.';

  @override
  String backupSummary(
    String date,
    int servers,
    int users,
    int changes,
    int pending,
  ) {
    return 'Created: $date\nServers: $servers\nClients: $users\nChanges: $changes\nQueued: $pending';
  }

  @override
  String get backupReplaceHelp =>
      'Current servers, clients, templates and history will be replaced by the backup. Save a separate backup of your current data first if you need it. SSH connections will close. The app will reopen the restored workspace; unfinished VPN operations will require a new decision. This device’s preferences will be retained.';

  @override
  String get backupActiveWork =>
      'Wait for the current operation or data save to finish, then try again.';

  @override
  String get backupClose => 'Close';

  @override
  String get backupCancel => 'Cancel';

  @override
  String get backupReplace => 'Replace and restore';

  @override
  String get backupSelect => 'Select file';

  @override
  String get backupOperationReview =>
      'This operation came from another device or a backup and is not submitted automatically. Check the server and approve a new plan, or choose to cancel or retry the existing job.';

  @override
  String get backupReviewServer => 'Check server state';

  @override
  String get syncConflictsTitle => 'Change conflicts';

  @override
  String get syncLocalHelp =>
      'Resolve stored conflicts here. Google Drive exchange is not connected yet.';

  @override
  String syncConflictCount(int count) {
    return 'Conflicts: $count';
  }

  @override
  String syncWaitingCount(int groups, int missing) {
    return 'Waiting groups: $groups. Missing earlier changes: $missing.';
  }

  @override
  String syncBlockedCount(int count) {
    return 'Groups with incompatible data: $count. Correct the local data, then retry applying changes.';
  }

  @override
  String get syncChanged =>
      'The conflict has changed. Open it again and review the versions.';

  @override
  String get syncStorageError =>
      'Could not apply the selected version. Refresh the list and check data compatibility.';

  @override
  String get syncEffectsBlocked =>
      'Resolve change conflicts in Settings first. Server actions and profile export are paused.';

  @override
  String get syncRefresh => 'Refresh list';

  @override
  String get syncRetry => 'Retry applying changes';

  @override
  String get syncChooseHelp =>
      'Review the versions and choose one. Contents may include passwords and keys. Your decision is saved as a new change; server operations require a separate action.';

  @override
  String syncVariant(int number) {
    return 'Version $number';
  }

  @override
  String get syncDeleted => 'Resource deletion';

  @override
  String get syncReveal => 'Show contents and secrets';

  @override
  String get syncHide => 'Hide contents';

  @override
  String get syncSelect => 'Choose this version';

  @override
  String get syncResolve => 'Save decision';

  @override
  String get syncKindServer => 'Server';

  @override
  String get syncKindTemplate => 'Base template';

  @override
  String get syncKindUser => 'VPN client';

  @override
  String get syncKindVless => 'VLESS inbound';

  @override
  String get syncKindAwg => 'AmneziaWG interface';

  @override
  String get syncKindTt => 'TrustTunnel endpoint';

  @override
  String get syncKindOperation => 'Server and operation state';

  @override
  String get syncKindProfile => 'Profile history';

  @override
  String get syncKindWorkspace => 'Workspace';

  @override
  String syncRejectedCount(int count) {
    return 'Rejected groups with inconsistent change history: $count. Working data is preserved.';
  }

  @override
  String get googleAccountTitle => 'Google account';

  @override
  String get googleAccountHelp => 'Sign in to Google to connect Google Drive.';

  @override
  String get googleSignIn => 'Sign in to Google';

  @override
  String get googleSwitchAccount => 'Switch account';

  @override
  String get googleSignOut => 'Sign out';

  @override
  String get googleConnected => 'Google Drive connected.';

  @override
  String get googleWorking => 'Connecting to Google…';

  @override
  String get googleConfigurationError =>
      'Google sign-in is not configured for this build. Check the Android client and app certificate.';

  @override
  String get googleDenied =>
      'Google Drive access was not granted. Sign in again and allow access.';

  @override
  String get googleNetworkError =>
      'Could not reach Google. Check your connection and sign in again.';

  @override
  String get googleStorageError =>
      'Could not save the account in secure storage. Try again.';

  @override
  String get googleReauthorize => 'Please sign in to Google again.';

  @override
  String get googleUnavailable =>
      'Google sign-in is unavailable. Check Google Play services and try again.';

  @override
  String get autoSyncTitle => 'Automatic sync';

  @override
  String get autoSyncHelp =>
      'After saving, on opening, and every 30 seconds while the app is in the foreground.';

  @override
  String get autoSyncDisabled => 'Automatic sync is off.';

  @override
  String get autoSyncWaiting => 'Changes are waiting to sync.';

  @override
  String get autoSyncWorking => 'Exchanging data with Google Drive…';

  @override
  String get autoSyncDone => 'Google Drive exchange completed.';

  @override
  String get autoSyncEditing =>
      'Data received. Close the server editor and open settings or the server list to apply it. Current operations must finish first.';

  @override
  String get autoSyncConflict =>
      'Different versions received. Choose a version in the conflicts section below.';

  @override
  String get autoSyncIncomplete =>
      'Some data is waiting for related changes or failed validation. Check the conflicts section.';

  @override
  String get autoSyncError =>
      'The exchange did not finish. Your data is saved; the app will retry automatically.';

  @override
  String get autoSyncNow => 'Sync now';

  @override
  String autoSyncLast(String time) {
    return 'Last exchange: $time';
  }

  @override
  String get autoSyncPairing =>
      'Connect a second device: export an encrypted backup from your main device and restore it here using Backups below. Then sign in to the same Google account. Google sign-in alone does not transfer the encryption key. Only share the backup with trusted devices. Sync runs while the app is open.';

  @override
  String get googleDesktopConfigurationError =>
      'Google sign-in is not configured. Select a Desktop OAuth client JSON from your Google project when prompted.';

  @override
  String get googleDesktopUnavailable =>
      'Could not open Google sign-in in the system browser. Check your default browser and try again.';

  @override
  String get googleDesktopWaiting =>
      'Complete sign-in in your browser, then return here. On first setup, select your Google Desktop client file if prompted.';

  @override
  String get googleCancelSignIn => 'Cancel sign-in';

  @override
  String get autoSyncOtherWorkspaces =>
      'Drive contains another workspace. To use its servers and clients here, restore an encrypted backup from the device that already has them.';

  @override
  String get publicationTitle => 'Profile publication';

  @override
  String get publicationHelp =>
      'Automatically save client YAML profiles to Google Drive and update the same file. Set up the folder on one device, then sync the others.';

  @override
  String get publicationAuthorize => 'Allow publishing to Drive';

  @override
  String get publicationAuthorizeHelp =>
      'To publish, grant access to application files in Google. Sync uses a separate permission.';

  @override
  String get publicationAccess => 'Profile access';

  @override
  String get publicationPrivate => 'Private file';

  @override
  String get publicationLink => 'Anyone with the link';

  @override
  String get publicationLinkHelp =>
      'Anyone with the link can download the profile and its client credentials.';

  @override
  String get publicationPrivateHelp =>
      'The file is saved in Drive. A subscription URL requires access for anyone with the link.';

  @override
  String get publicationFolder => 'Folder';

  @override
  String get publicationNewFolder => 'Create AntiRKN profiles folder';

  @override
  String get publicationChooseFolder => 'Choose a folder accessible to the app';

  @override
  String get publicationEnable => 'Set up publication';

  @override
  String get publicationAuto => 'Automatic publication';

  @override
  String get publicationCompleteSetup => 'Complete folder setup';

  @override
  String get publicationMissing =>
      'The file or folder is unavailable. Check Drive access and trash; the existing binding is preserved.';

  @override
  String get publicationConflict =>
      'The Drive version changed. Sync devices and review the conflict; the file was not overwritten.';

  @override
  String get publicationAccountChanged =>
      'This publication requires the Google account used to select its folder.';

  @override
  String get publicationLinkUnavailable =>
      'The link does not return the expected YAML without Google sign-in. Retry the check later.';

  @override
  String get publicationNetwork =>
      'Drive is temporarily unavailable. Publication remains queued.';

  @override
  String get publicationWaiting => 'Waiting to publish';

  @override
  String get publicationFailed =>
      'Publication is incomplete. Check settings and retry.';

  @override
  String get publicationPublished => 'Profile published';

  @override
  String get publicationCopyLink => 'Copy profile link';

  @override
  String get uiGoogleDrive => 'Google Drive';

  @override
  String get uiAppearance => 'Appearance';

  @override
  String get uiActions => 'Actions';

  @override
  String get uiProtocols => 'Protocols';

  @override
  String get uiMaintenance => 'Maintenance';

  @override
  String get uiConnection => 'Connection';

  @override
  String get uiDisconnectBeforeDelete =>
      'Finish active operations and disconnect SSH before deleting.';

  @override
  String get uiQrCopyHint => 'Tap to copy the link';

  @override
  String get uiLinkCopied => 'Link copied';

  @override
  String get uiCopyFailed =>
      'Could not copy the link. Tap the QR code to retry.';

  @override
  String get uiPreviewYaml => 'Preview YAML';

  @override
  String get uiProfileDetails => 'Profile details';

  @override
  String get uiOperationPending => 'Operation needs attention';

  @override
  String get vpnDeleteUser => 'Delete client';

  @override
  String get vpnDeleteExplanation =>
      'The client will leave the list. Access on unavailable servers will be revoked after reconnecting. The name and login can be used again.';

  @override
  String get vpnDeleteFile =>
      'Also move the configuration file to Google Drive trash';

  @override
  String get vpnRevocationPending => 'Waiting to revoke access';

  @override
  String get vpnDeleteFilePending =>
      'Access revoked. Waiting to delete the file';

  @override
  String get vpnAccessRevoked => 'Access revoked';

  @override
  String get vpnRevocationFailed =>
      'Revocation is incomplete. Check the server and retry.';

  @override
  String get vpnUserDeleted =>
      'This client record was deleted. You can create a new client with the same name and login.';

  @override
  String get vpnNodeName => 'Node name';

  @override
  String get uiDeleteServer => 'Delete server';

  @override
  String get vpnConnectToManage =>
      'Connect to manage inbounds and client access.';

  @override
  String get catalogEdit => 'Edit list';

  @override
  String catalogSelected(int count) {
    return 'Selected: $count';
  }

  @override
  String get catalogDeleteSelected => 'Delete selected';

  @override
  String get catalogSelectAll => 'Select all / clear selection';

  @override
  String get catalogExitEditing => 'Exit editing';

  @override
  String get catalogServerDeleteBlocked =>
      'Could not delete the selection. Disconnect these servers and finish pending operations. A server used as an SSH jump by an unselected server must be kept. If the list changed, select it again.';
}
