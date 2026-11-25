import 'package:crypto/crypto.dart';
import 'package:antirkn_mihomo_runtime/antirkn_mihomo_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:antirkn_network_inventory/antirkn_network_inventory.dart';
import 'network/android_ip_probe_transport.dart';
import 'network/socket_ip_probe_transport.dart';
import 'network/ip_diagnostics_controller.dart';
import 'settings_hub.dart';
import 'desktop_back_gesture.dart';
import 'catalog_selection.dart';
import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'publication/publication_controller.dart';
import 'publication/publication_panel.dart';
import 'sync/auto_sync_controller.dart';
import 'sync/google_account_panel.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'template_settings.dart';
import 'appearance_settings.dart';
import 'backup/backup_panel.dart';
import 'runner/component_updates_controller.dart';
import 'runner/component_installation_view.dart';
import 'l10n/app_localizations.dart';
import 'language_controller.dart';
import 'network/network_controller.dart';
import 'network/network_workbench.dart';
import 'network/sample_inventory_reader.dart';
import 'template_controller.dart';
import 'ssh/ssh_controller.dart';
import 'ssh/server_catalog.dart';
import 'ssh/server_catalog_controller.dart';
import 'vpn/vpn_controller.dart';
import 'vpn/users_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WorkspaceLauncher());
}

class WorkspaceLauncher extends StatefulWidget {
  const WorkspaceLauncher({
    this.openWorkspace = openLocalWorkspace,
    this.backupFiles,
    super.key,
  });
  final Future<WorkspaceDatabase> Function() openWorkspace;
  final BackupFileStore? backupFiles;
  @override
  State<WorkspaceLauncher> createState() => _WorkspaceLauncherState();
}

class _WorkspaceLauncherState extends State<WorkspaceLauncher>
    with WidgetsBindingObserver {
  late Future<Widget> _app = _load();
  WorkspaceDatabase? _database;
  AutoSyncController? _sync;
  GoogleSyncAccountService? _google;
  LanguageController? _languages;
  int _generation = 0;
  bool _retrying = false;

  /// Reopens the workspace after an open error. One attempt at a time: a
  /// parallel attempt would open a second database and sync controller.
  void _retryLoad() {
    if (_retrying) return;
    _retrying = true;
    setState(() {
      _app = _load().whenComplete(() => _retrying = false);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _sync?.flushOnExit();
    return AppExitResponse.exit;
  }

  Future<void> _reopen() async {
    final old = _database,
        languages = _languages,
        sync = _sync,
        google = _google;
    Future<Widget> restart() async {
      // Dispose the previous shell and its SSH sessions before reopening data.
      await WidgetsBinding.instance.endOfFrame;
      await sync?.stop();
      sync?.dispose();
      if (google case final CancelableGoogleSignIn lifecycle) {
        await lifecycle.close();
      }
      await old?.close();
      languages?.dispose();
      return _load();
    }

    setState(() {
      _generation++;
      _app = restart();
    });
  }

  Future<Widget> _load() async {
    final database = await widget.openWorkspace();
    try {
      final google = localGoogleAccountService(database);
      if (google.supported &&
          await database.readSetting('googleAutoSync') != 'false') {
        try {
          if (await google.restore() != null &&
              await database.pullCurrentSnapshot(google)) {
            if (google case final CancelableGoogleSignIn lifecycle) {
              await lifecycle.close();
            }
            await database.close();
            return _load();
          }
        } catch (_) {
          // An unavailable or invalid cloud file must not block local data.
        }
      }
      final languages = LanguageController(database);
      await languages.load();
      final source = await database.readDraft() ?? '';
      final theme = await database.readSetting('theme');
      final motion = await database.readSetting('motion');
      _database = database;
      _languages = languages;
      _google = google;
      _sync = google.supported
          ? AutoSyncController(
              accountService: google,
              settings: database,
              changes: database.localChanges,
              openSession: () => database.openAutoSync(google),
              apply: (_) async => false,
            )
          : null;
      return AntiRknApp(
        key: ValueKey(_generation),
        source: source,
        languages: languages,
        settings: database,
        googleAccount: google,
        autoSync: _sync,
        drafts: database,
        servers: database,
        backups: database,
        backupFiles: widget.backupFiles ?? SystemBackupFileStore(),
        onRestored: _reopen,
        initialTheme:
            ThemeMode.values.where((e) => e.name == theme).firstOrNull ??
            ThemeMode.system,
        initialMotion:
            MotionPreference.values
                .where((e) => e.name == motion)
                .firstOrNull ??
            MotionPreference.system,
        pickTemplate: SystemTemplateFilePicker().pick,
        ssh: SshDependencies(
          openVault: openLocalSecretVault,
          connector: const DartSshConnector(),
          picker: SystemPrivateKeyFilePicker(),
          agentAvailable: linuxSshAgentAvailable,
        ),
      );
    } catch (_) {
      await database.close();
      rethrow;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final sync = _sync,
        database = _database,
        languages = _languages,
        google = _google;
    sync?.dispose();
    unawaited(() async {
      if (sync != null) await sync.stop();
      if (google case final CancelableGoogleSignIn lifecycle) {
        await lifecycle.close();
      }
      if (database != null) await database.close();
      languages?.dispose();
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Widget>(
    key: ValueKey(_generation),
    future: _app,
    builder: (context, snapshot) =>
        snapshot.data ??
        MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                // A retry keeps the previous error in the snapshot while it
                // runs; show progress instead of a second Retry button.
                child:
                    snapshot.hasError &&
                        snapshot.connectionState == ConnectionState.done
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(AppLocalizations.of(context).databaseOpenError),
                          FilledButton(
                            key: const ValueKey('database-open-retry'),
                            onPressed: _retryLoad,
                            child: Text(
                              AppLocalizations.of(context).vaultRetry,
                            ),
                          ),
                        ],
                      )
                    : const CircularProgressIndicator(),
              ),
            ),
          ),
        ),
  );
}

class AntiRknApp extends StatefulWidget {
  const AntiRknApp({
    required this.source,
    required this.languages,
    this.pickTemplate,
    this.previewTemplate = previewInBackground,
    this.networkReader = const SampleInventoryReader(),
    this.ssh,
    this.servers,
    this.settings,
    this.googleAccount,
    this.autoSync,
    this.drafts,
    this.backups,
    this.backupFiles,
    this.onRestored,
    this.initialTheme = ThemeMode.system,
    this.initialMotion = MotionPreference.system,
    super.key,
  });
  final String? source;
  final Future<ImportedTemplate?> Function()? pickTemplate;
  final LanguageController languages;
  final PreviewTemplate previewTemplate;
  final NetworkInventoryReader networkReader;
  final ServerRepository? servers;
  final SettingsStore? settings;
  final GoogleAccountService? googleAccount;
  final AutoSyncController? autoSync;
  final TemplateDraftStore? drafts;
  final WorkspaceBackupStore? backups;
  final BackupFileStore? backupFiles;
  final Future<void> Function()? onRestored;
  final ThemeMode initialTheme;
  final MotionPreference initialMotion;
  final SshDependencies? ssh;
  @override
  State<AntiRknApp> createState() => _AntiRknAppState();
}

class _AntiRknAppState extends State<AntiRknApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late ThemeMode _theme = widget.initialTheme;
  final MotionPreference _motion = MotionPreference.system;
  bool _settingsError = false;
  late final ComponentUpdatesController _updates;
  @override
  void initState() {
    super.initState();
    _updates = ComponentUpdatesController(
      source: GithubComponentReleaseSource(
        sha256Hex: (bytes) => sha256.convert(bytes).toString(),
      ),
      settings: widget.settings,
    );
    _updates.load();
  }

  @override
  void dispose() {
    _updates.dispose();
    super.dispose();
  }

  Future<void> _saveSetting(
    String key,
    String value,
    VoidCallback apply,
  ) async {
    try {
      await widget.settings?.writeSetting(key, value);
      if (mounted) {
        setState(() {
          apply();
          _settingsError = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _settingsError = true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.languages,
    builder: (context, _) => DynamicColorBuilder(
      builder: (light, dark) => MaterialApp(
        navigatorKey: _navigatorKey,
        builder: (context, child) => Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            if ((event.buttons & kBackMouseButton) != 0) {
              _navigatorKey.currentState?.maybePop();
            }
          },
          child: child ?? const SizedBox.shrink(),
        ),
        title: 'AntiRKN',
        debugShowCheckedModeBanner: false,
        locale: widget.languages.language == AppLanguage.system
            ? null
            : Locale(widget.languages.language.name),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: AppTheme.create(Brightness.light, dynamicScheme: light),
        darkTheme: AppTheme.create(Brightness.dark, dynamicScheme: dark),
        themeMode: _theme,
        themeAnimationDuration:
            _motion == MotionPreference.off ||
                WidgetsBinding
                    .instance
                    .platformDispatcher
                    .accessibilityFeatures
                    .disableAnimations
            ? Duration.zero
            : _motion == MotionPreference.reduced
            ? AppMotion.reduced
            : AppMotion.standard,
        home: widget.source == null
            ? Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: Text(AppLocalizations.of(context).loadError),
                  ),
                ),
              )
            : ComponentUpdatesScope(
                controller: _updates,
                child: ManagerShell(
                  source: widget.source!,
                  pickTemplate: widget.pickTemplate,
                  languages: widget.languages,
                  previewTemplate: widget.previewTemplate,
                  networkReader: widget.networkReader,
                  ssh: widget.ssh,
                  servers: widget.servers,
                  drafts: widget.drafts,
                  backups: widget.backups,
                  backupFiles: widget.backupFiles,
                  onRestored: widget.onRestored,
                  settingsError: _settingsError,
                  googleAccount: widget.googleAccount,
                  autoSync: widget.autoSync,
                  settings: widget.settings,
                  theme: _theme,
                  motion: _motion,
                  onTheme: (value) =>
                      _saveSetting('theme', value.name, () => _theme = value),
                  onMotion: (_) {},
                ),
              ),
      ),
    ),
  );
}

class ManagerShell extends StatefulWidget {
  ManagerShell({
    required this.source,
    this.pickTemplate,
    required this.languages,
    required this.previewTemplate,
    required this.networkReader,
    this.ssh,
    this.servers,
    this.drafts,
    this.backups,
    this.backupFiles,
    this.onRestored,
    this.settingsError = false,
    this.googleAccount,
    this.autoSync,
    this.settings,
    required this.theme,
    required this.motion,
    required this.onTheme,
    required this.onMotion,
    super.key,
  });
  final LanguageController languages;
  final String source;
  final Future<ImportedTemplate?> Function()? pickTemplate;
  final PreviewTemplate previewTemplate;
  final NetworkInventoryReader networkReader;
  final ServerRepository? servers;
  final TemplateDraftStore? drafts;
  final WorkspaceBackupStore? backups;
  final BackupFileStore? backupFiles;
  final Future<void> Function()? onRestored;
  final bool settingsError;
  final GoogleAccountService? googleAccount;
  final AutoSyncController? autoSync;
  final SettingsStore? settings;
  final SshDependencies? ssh;
  final ThemeMode theme;
  final MotionPreference motion;
  final ValueChanged<ThemeMode> onTheme;
  final ValueChanged<MotionPreference> onMotion;

  @override
  State<ManagerShell> createState() => _ManagerShellState();
}

class _ManagerShellState extends State<ManagerShell>
    with WidgetsBindingObserver {
  int _index = 0;
  final _settingsKey = GlobalKey<SettingsHubState>();
  final _serverSelection = CatalogSelection();
  final _clientSelection = CatalogSelection();
  CatalogSelection get _selection =>
      _index == 0 ? _serverSelection : _clientSelection;
  late final TemplateController _controller;
  late final NetworkController _networkController;
  SshController? _sshController;
  ServerCatalogController? _catalog;
  VpnController? _vpn;
  PublicationController? _publications;
  bool _applyingSync = false;
  bool _diagnosing = false;
  ComponentUpdatesController? _diagnosticUpdates;
  late final IpDiagnosticsController _diagnostics;
  String _serverNameSnapshot = '';
  static const _icons = [Icons.dns_outlined, Icons.people_outline, Icons.tune];

  @override
  void initState() {
    super.initState();
    Future<void>? catalogReady;
    _diagnostics = IpDiagnosticsController(
      engine: IpDiagnosticEngine(
        transport: defaultTargetPlatform == TargetPlatform.android
            ? AndroidIpProbeTransport()
            : SocketIpProbeTransport(),
        controls: defaultIpControls(),
      ),
      store: widget.settings,
      enter: _enterDiagnostics,
      leave: _leaveDiagnostics,
    )..addListener(_shellChanged);
    _serverSelection.addListener(_shellChanged);
    _clientSelection.addListener(_shellChanged);
    _networkController = NetworkController(reader: widget.networkReader);
    WidgetsBinding.instance.addObserver(this);
    widget.autoSync?.apply = _applyReceived;
    if (widget.ssh case final ssh?) {
      if (widget.servers case final repository?) {
        _catalog = ServerCatalogController(
          repository: repository,
          connector: ssh.connector,
          picker: ssh.picker,
          reader: widget.networkReader,
          agentAvailable: ssh.agentAvailable,
        );
        _catalog!.onServerReplaced = (id, identity) =>
            unawaited(_vpn?.rebindServer(id, identity));
        _catalog!
          ..addListener(_catalogChanged)
          ..addListener(_shellChanged);
        catalogReady = _catalog!.load();
      } else {
        _sshController = SshController(
          openVault: ssh.openVault,
          connector: ssh.connector,
          picker: ssh.picker,
          agentAvailable: ssh.agentAvailable,
          network: _networkController,
        )..initialise();
        _sshController!.onServerReplaced = (identity) =>
            unawaited(_vpn?.rebindServer(SshProfile.serverId, identity));
      }
    }
    _controller = TemplateController(
      source: widget.source,
      draftStore: widget.drafts,
      pickTemplate: widget.pickTemplate,
      previewTemplate: widget.previewTemplate,
    );
    if (widget.source.trim().isNotEmpty) _controller.refresh();
    if (widget.servers is VpnRepository) {
      _vpn = VpnController(
        coreValidator: MihomoConfigValidator(),
        connectionProbe: ConnectionProbeEngine(
          core: MihomoOutboundProbe(),
          network: defaultTargetPlatform == TargetPlatform.android
              ? AndroidIpProbeTransport()
              : SocketIpProbeTransport(),
          controls: defaultIpControls(),
        ),
        probeStore: widget.settings,
        enterConnectionTraffic: _enterConnectionTraffic,
        leaveConnectionTraffic: _leaveConnectionTraffic,
        connectForAction: (id) async =>
            await _catalog?.connectForAction(id) == true,
        connectForDeletion: (id) async =>
            _catalog == null ? false : await _catalog!.connectForDeletion(id),
        repository: widget.servers as VpnRepository,
        recovery: widget.servers is WorkspaceRecoveryStore
            ? widget.servers as WorkspaceRecoveryStore
            : null,
        template: () => _controller.source,
        pickTemplate: widget.pickTemplate,
        serverName: (id) => _catalog?.serverDisplayName(id) ?? id,
        serverIds: () =>
            _catalog?.servers.expand(
              (s) => [s.id, awgTarget(s.id), ttTarget(s.id)],
            ) ??
            const <String>[],
        remote: (id) {
          final server = vpnServerId(id);
          final runner = _catalog?.sessionFor(server)?.runner;
          if (runner != null && _vpn != null) {
            _vpn!.bindRunner(
              server,
              runner,
              () =>
                  !runner.hasUnfinishedJob &&
                  runner.selected == null &&
                  runner.pending == null,
            );
          }
          final transport = runner?.transport();
          final access = runner?.panelAccess;
          final identity = runner?.identity();
          if (runner == null ||
              runner.busy ||
              !runner.installed ||
              transport == null ||
              (!isAwgTarget(id) &&
                  !isTtTarget(id) &&
                  (access == null || runner.panelVerifiedAt == null)) ||
              identity == null) {
            return null;
          }
          return VpnRemote(
            transport: transport,
            panelId: (isAwgTarget(id) || isTtTarget(id))
                ? _vpn!.workspace.id
                : access!.id,
            observationKey:
                '$identity|${runner.panelVerifiedAt?.toIso8601String()}|${identityHashCode(runner.installation)}',
            identity: identity,
            password: runner.password(),
            onSshFailure: runner.accessFailure,
          );
        },
      );
      unawaited(_loadVpnAfterCatalog(catalogReady));
      if (widget.servers is PublicationRepository &&
          widget.googleAccount is GoogleSyncAccountService) {
        final account = widget.googleAccount! as GoogleSyncAccountService;
        _publications = PublicationController(
          repository: widget.servers! as PublicationRepository,
          account: account,
          remote: () => GoogleDrivePublisher(tokens: account),
          picker: createPublicationFilePicker(account),
          vpn: _vpn!,
          sync: widget.autoSync,
          canPublish: () =>
              !_applyingSync &&
              !_diagnosing &&
              !_controller.importing &&
              !_controller.savingDraft &&
              !_controller.draftSaveFailed,
        );
        _vpn!.deletePublishedFile = _publications!.deleteClientFile;
      }
    }
  }

  Future<void> _loadVpnAfterCatalog(Future<void>? catalogReady) async {
    await catalogReady;
    await _vpn?.load();
    await _repairOrphanedVpnState();
    await _vpn?.recoverHiddenPendingAccessChanges();
  }

  void _catalogChanged() {
    final catalog = _catalog;
    if (catalog == null) return;
    final entries = [
      for (final server in catalog.servers)
        '${server.id}\u0000${catalog.serverDisplayName(server.id)}',
    ]..sort();
    final snapshot = entries.join('\u0001');
    if (snapshot == _serverNameSnapshot) return;
    _serverNameSnapshot = snapshot;
    if (_vpn?.loaded == true) unawaited(_vpn!.refreshProfiles());
  }

  Future<void> _repairOrphanedVpnState() async {
    final catalog = _catalog, vpn = _vpn;
    if (catalog == null ||
        vpn == null ||
        catalog.loading ||
        catalog.error != null ||
        !vpn.loaded ||
        vpn.busy) {
      return;
    }
    final orphaned = vpn.orphanedPhysicalServerIds(
      catalog.servers.map((server) => server.id),
    );
    if (orphaned.isNotEmpty) await vpn.forgetServersLocally(orphaned);
  }

  Future<bool> _enterConnectionTraffic() async {
    final updates = ComponentUpdatesScope.of(context);
    if (_diagnosing ||
        _applyingSync ||
        (updates?.busy ?? false) ||
        (_publications?.busy ?? false) ||
        (_vpn?.hasRunning ?? false) ||
        (_catalog?.diagnosticsConflict ?? false)) {
      return false;
    }
    _diagnosing = true;
    _diagnosticUpdates = updates;
    updates?.diagnosticsPaused = true;
    try {
      await widget.autoSync?.pauseDiagnostics(true);
      await _publications?.suspend();
      return true;
    } catch (_) {
      await _leaveConnectionTraffic();
      return false;
    }
  }

  Future<void> _leaveConnectionTraffic() async {
    _diagnosing = false;
    _diagnosticUpdates?.diagnosticsPaused = false;
    _diagnosticUpdates = null;
    await widget.autoSync?.pauseDiagnostics(false);
    if (mounted) _publications?.resume();
  }

  Future<bool> _enterDiagnostics() async {
    final updates = ComponentUpdatesScope.of(context);
    if (_applyingSync ||
        (updates?.busy ?? false) ||
        (_catalog?.diagnosticsConflict ?? false) ||
        (_sshController?.busy ?? false) ||
        (_sshController?.runner.busy ?? false) ||
        (_vpn?.busy ?? false) ||
        (_vpn?.hasRunning ?? false) ||
        (_publications?.busy ?? false) ||
        _networkController.loading ||
        _controller.importing ||
        _controller.savingDraft) {
      return false;
    }
    _diagnosing = true;
    _diagnosticUpdates = updates;
    updates?.diagnosticsPaused = true;
    _vpn?.diagnosticsPaused = true;
    try {
      await widget.autoSync?.pauseDiagnostics(true);
      await _publications?.suspend();
      _catalog?.disconnectForDiagnostics();
      _sshController?.disconnect();
      return true;
    } catch (_) {
      await _leaveDiagnostics();
      rethrow;
    }
  }

  Future<void> _leaveDiagnostics() async {
    _diagnosing = false;
    _diagnosticUpdates?.diagnosticsPaused = false;
    _diagnosticUpdates = null;
    if (!mounted) return;
    _vpn?.diagnosticsPaused = false;
    await widget.autoSync?.pauseDiagnostics(false);
    _publications?.resume();
  }

  @override
  void dispose() {
    _diagnostics.removeListener(_shellChanged);
    _diagnostics.dispose();
    _serverSelection.dispose();
    _clientSelection.dispose();
    WidgetsBinding.instance.removeObserver(this);
    widget.autoSync?.apply = (_) async => false;
    _catalog?.removeListener(_catalogChanged);
    _catalog?.removeListener(_shellChanged);
    _catalog?.dispose();
    _publications?.dispose();
    _vpn?.dispose();
    _sshController?.dispose();
    _controller.dispose();
    _networkController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive &&
            defaultTargetPlatform == TargetPlatform.android) {
      _diagnostics.stop();
      _vpn?.cancelCoreValidation();
      _vpn?.setForeground(false);
    }
    if (state == AppLifecycleState.resumed) {
      _vpn?.setForeground(true);
    }
    // An unfocused desktop window is still visible (e.g. beside a browser).
    // Android retains its existing foreground-only scheduling policy.
    final isDesktop =
        widget.googleAccount is CancelableGoogleSignIn ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
    final inForeground =
        state == AppLifecycleState.resumed ||
        (isDesktop && state != AppLifecycleState.detached);
    final syncForeground =
        state == AppLifecycleState.resumed ||
        (isDesktop && state == AppLifecycleState.inactive);
    widget.autoSync?.foreground(syncForeground);
    _publications?.foreground(inForeground);
    if (state == AppLifecycleState.resumed) {
      _networkController.tick();
      if (!(_sshController?.unlocked ?? true)) _sshController?.initialise();
    }
  }

  /// What [build] reads from the controllers it listens to. Rebuilding the
  /// shell recreates every page (users, settings, the catalogue), so only a
  /// change of these values does it — not a keystroke, a runner poll, an IP
  /// probe or a selection toggle (those widgets listen themselves).
  Object _shellState() => (
    _catalog?.selectedId,
    _catalog?.servers,
    _catalog?.loading,
    _serverSelection.active,
    _clientSelection.active,
    _diagnostics.busy,
  );
  late Object _builtShellState = _shellState();

  void _shellChanged() {
    if (!mounted) return;
    final next = _shellState();
    if (next == _builtShellState) return;
    setState(() => _builtShellState = next);
  }

  Future<bool> _applyReceived(Future<void> Function() receive) async {
    if (!mounted ||
        _applyingSync ||
        _diagnosing ||
        _clientSelection.active ||
        _serverSelection.active ||
        _catalog?.selectedId != null ||
        (_catalog?.hasActiveWork ?? false) ||
        (_catalog?.hasUnsavedEdits ?? false) ||
        (_vpn?.busy ?? false) ||
        (_publications?.busy ?? false) ||
        (_vpn?.hasRunning ?? false) ||
        _controller.savingDraft ||
        _controller.draftSaveFailed ||
        _controller.importing ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    setState(() => _applyingSync = true);
    try {
      // Fence user input before any asynchronous repository mutation.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      await _publications?.suspend();
      await receive();
      await _catalog?.reloadAfterSync();
      final source = await widget.drafts?.readDraft();
      if (source != null && source != _controller.source) {
        _controller.source = source;
        await _controller.refresh();
      }
      await _vpn?.load();
      await _repairOrphanedVpnState();
      await _publications?.reload();
      return true;
    } catch (_) {
      // If refreshing a projection fails, reopen before exposing stale forms.
      unawaited(widget.onRestored?.call());
      rethrow;
    } finally {
      if (mounted) _publications?.resume();
      if (mounted) setState(() => _applyingSync = false);
    }
  }

  bool _canReplace() =>
      !_applyingSync &&
      !_diagnosing &&
      !(_catalog?.hasActiveWork ?? false) &&
      !(_vpn?.busy ?? false) &&
      !(_publications?.busy ?? false) &&
      !_controller.savingDraft &&
      !_controller.importing;

  void _navigate(int value) {
    if (_diagnostics.busy) return;
    if (value == _index) {
      _serverSelection.exit();
      _clientSelection.exit();
      if (value == 0) _catalog?.showList();
      if (value == 2) _settingsKey.currentState?.showRoot();
    }
    if (value != _index) {
      _serverSelection.exit();
      _clientSelection.exit();
    }
    setState(() => _index = value);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final l = AppLocalizations.of(context);
      final labels = [l.server, l.vpnUsers, l.settings];
      final rail =
          constraints.maxWidth >= AppLayout.compact &&
          constraints.maxHeight >= 400;
      _builtShellState = _shellState();
      return Builder(
        builder: (context) => AbsorbPointer(
          absorbing: _applyingSync,
          child: PopScope(
            canPop:
                !_applyingSync &&
                !_diagnostics.busy &&
                !(_index < 2 && _selection.active),
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && _diagnostics.busy) _diagnostics.stop();
              if (!didPop &&
                  !_applyingSync &&
                  _index < 2 &&
                  _selection.active) {
                _selection.exit();
              }
            },
            child: Scaffold(
              appBar: _index == 2 || _index == 0 && _catalog?.selectedId != null
                  ? null
                  : AppBar(
                      title: _index >= 2
                          ? Text(labels[_index])
                          : CatalogTitle(
                              selection: _selection,
                              title: labels[_index],
                            ),
                      actions: [
                        if (_index == 0 && _catalog != null)
                          ListenableBuilder(
                            listenable: Listenable.merge([_catalog!, _vpn]),
                            builder: (context, _) =>
                                _catalog!.selectedId != null
                                ? const SizedBox.shrink()
                                : CatalogActions(
                                    selection: _serverSelection,
                                    available: _catalog!.servers.map(
                                      (s) => s.id,
                                    ),
                                    prefix: 'server',
                                    busy:
                                        _catalog!.loading ||
                                        (_vpn?.busy ?? false),

                                    onAdd: _catalog!.add,
                                    onDelete: () =>
                                        ServerCatalog.deleteSelected(
                                          context,
                                          _catalog!,
                                          _serverSelection,
                                          _vpn,
                                        ),
                                  ),
                          ),
                        if (_index == 1 && _vpn != null)
                          ListenableBuilder(
                            listenable: _vpn!,
                            builder: (context, _) => CatalogActions(
                              selection: _clientSelection,
                              available: _vpn!.workspace.users
                                  .where((u) => !u.deleted)
                                  .map((u) => u.id),
                              prefix: 'vpn-user',
                              busy: _vpn!.busy || !_vpn!.loaded,

                              onAdd: () => UsersPage.edit(
                                context,
                                _vpn!,
                                widget.motion,
                                null,
                                _publications,
                              ),
                              onDelete: () => UsersPage.deleteSelected(
                                context,
                                _vpn!,
                                _clientSelection,
                                _publications,
                              ),
                            ),
                          ),
                      ],
                    ),
              bottomNavigationBar: rail
                  ? null
                  : NavigationBar(
                      selectedIndex: _index,
                      onDestinationSelected: _diagnostics.busy
                          ? null
                          : _navigate,
                      destinations: [
                        for (var i = 0; i < labels.length; i++)
                          NavigationDestination(
                            icon: Icon(_icons[i]),
                            label: labels[i],
                          ),
                      ],
                    ),
              body: DesktopBackGesture(
                canGoBack: () =>
                    !_applyingSync &&
                    (Navigator.of(context).canPop() ||
                        _index == 0 && _catalog?.selectedId != null ||
                        _index == 2 &&
                            (_settingsKey.currentState?.canGoBack ?? false) ||
                        _index < 2 && _selection.active),
                onBack: () => Navigator.of(context).maybePop(),
                motion: widget.motion,
                child: SafeArea(
                  child: Row(
                    children: [
                      if (rail)
                        NavigationRail(
                          selectedIndex: _index,
                          extended: constraints.maxWidth >= AppLayout.large,
                          labelType: constraints.maxWidth >= AppLayout.large
                              ? NavigationRailLabelType.none
                              : NavigationRailLabelType.all,
                          onDestinationSelected: _diagnostics.busy
                              ? null
                              : _navigate,
                          destinations: [
                            for (var i = 0; i < labels.length; i++)
                              NavigationRailDestination(
                                icon: Icon(_icons[i]),
                                label: Text(labels[i]),
                              ),
                          ],
                        ),
                      Expanded(
                        key: ValueKey('content'),
                        child: AppPageSwitch(
                          motion: widget.motion,
                          index: _index,
                          children: [
                            if (_catalog != null)
                              ServerCatalog(
                                controller: _catalog!,
                                diagnostics: _diagnostics,
                                selection: _serverSelection,
                                motion: widget.motion,
                                vpn: _vpn,
                              )
                            else if (_sshController != null)
                              NetworkWorkbench(
                                controller: _networkController,
                                motion: widget.motion,
                                ssh: _sshController,
                              )
                            else
                              Center(child: Text(l.noServers)),
                            if (_vpn != null)
                              UsersPage(
                                controller: _vpn!,
                                showAddAction: false,
                                selection: _clientSelection,
                                publications: _publications,
                                serverName: (id) =>
                                    _catalog?.serverDisplayName(id) ?? id,
                                exporter: SystemProfileExporter(),
                                motion: widget.motion,
                              )
                            else
                              Center(child: Text(l.vpnNoUsers)),
                            SettingsHub(
                              key: _settingsKey,
                              motion: widget.motion,
                              error: widget.settingsError
                                  ? Text(l.settingsSaveError)
                                  : null,
                              statusDestinationId: 'sync',
                              status: widget.autoSync == null
                                  ? null
                                  : ListenableBuilder(
                                      listenable: widget.autoSync!,
                                      builder: (context, _) => ListTile(
                                        leading: const Icon(
                                          Icons.cloud_done_outlined,
                                        ),
                                        title: Text(l.uiPersonalWorkspace),
                                        trailing: const Icon(
                                          Icons.chevron_right,
                                        ),
                                        subtitle: Text(
                                          syncStatusLabel(l, widget.autoSync!),
                                        ),
                                      ),
                                    ),
                              destinations: [
                                SettingsDestination(
                                  id: 'interface',
                                  title: l.uiInterface,
                                  subtitle:
                                      '${switch (widget.theme) {
                                        ThemeMode.system => l.system,
                                        ThemeMode.light => l.light,
                                        ThemeMode.dark => l.dark,
                                      }} · ${switch (widget.languages.language) {
                                        AppLanguage.system => l.languageSystem,
                                        AppLanguage.ru => l.languageRussian,
                                        AppLanguage.en => l.languageEnglish,
                                      }}',
                                  icon: Icons.palette_outlined,
                                  content: AppearanceSettings(
                                    languages: widget.languages,
                                    theme: widget.theme,
                                    motion: widget.motion,
                                    onTheme: widget.onTheme,
                                    onMotion: widget.onMotion,
                                  ),
                                ),
                                if (widget.googleAccount?.supported == true)
                                  SettingsDestination(
                                    id: 'sync',
                                    title: l.uiSynchronization,
                                    subtitle: l.uiSyncHelp,
                                    icon: Icons.sync,
                                    // The page title names the section
                                    // (UI-50).
                                    content: AppSettingsSection(
                                      child: Column(
                                        children: [
                                          GoogleAccountPanel(
                                            showTitle: false,
                                            service: widget.googleAccount!,
                                            sync: widget.autoSync,
                                            beforeAccountChange:
                                                _publications?.suspend,
                                            afterAccountChange: (signedIn) {
                                              _publications?.resume();
                                              if (signedIn) {
                                                _publications
                                                    ?.accountAuthorizationChanged();
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                SettingsDestination(
                                  id: 'profiles',
                                  title: l.uiClientProfiles,
                                  subtitle: l.uiClientProfilesHelp,
                                  icon: Icons.description_outlined,
                                  content: AppSettingsSection(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        TemplateSettings(
                                          controller: _controller,
                                          showTitle: false,
                                        ),
                                        if (_publications != null) ...[
                                          const Divider(
                                            indent: 17,
                                            endIndent: 17,
                                          ),
                                          PublicationSettingsPanel(
                                            controller: _publications!,
                                            showTitle: false,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                if (widget.backups != null &&
                                    widget.backupFiles != null &&
                                    widget.onRestored != null)
                                  SettingsDestination(
                                    id: 'backup',
                                    title: l.backupTitle,
                                    subtitle: l.uiBackupHelp,
                                    icon: Icons.history,
                                    content: BackupPanel(
                                      store: widget.backups!,
                                      files: widget.backupFiles!,
                                      onRestored: widget.onRestored!,
                                      canRestore: _canReplace,
                                    ),
                                  ),
                                SettingsDestination(
                                  id: 'updates',
                                  title: l.uiUpdatesShort,
                                  subtitle: l.uiUpdatesHelp,
                                  icon: Icons.system_update_alt,
                                  content: const ComponentUpdateSettings(),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
