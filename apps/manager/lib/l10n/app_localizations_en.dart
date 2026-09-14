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
  String get intro => 'Check which nodes are selected by your template groups.';

  @override
  String get source => 'Base YAML';

  @override
  String get sourceHelp =>
      'Choose a .yml or .yaml file. The app saves its own copy on this device; the source file is not modified.';

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
      'Manage saved servers over SSH, inspect their software and IP addresses, and edit templates. Server installation, protocol configuration and Google Drive sync are planned for later stages.';

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
  String get componentsJob => 'Installing 3x-ui / Xray';

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
}
