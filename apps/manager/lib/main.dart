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
import 'dart:ui' as ui show Image;
import 'dart:ui' show AppExitResponse;
import 'package:antirkn_integrations/antirkn_integrations.dart';
import 'publication/publication_controller.dart';
import 'publication/publication_panel.dart';
import 'sync/auto_sync_controller.dart';
import 'sync/google_account_panel.dart';
import 'sync/restored_cache_refresh.dart';
import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import 'template_settings.dart';
import 'appearance_settings.dart';
import 'about_settings.dart';
import 'sync/sync_diag.dart';
import 'backup/backup_panel.dart';
import 'runner/component_updates_controller.dart';
import 'l10n/app_localizations.dart';
import 'language_controller.dart';
import 'network/network_controller.dart';
import 'network/network_workbench.dart';
import 'network/sample_inventory_reader.dart';
import 'template_controller.dart';
import 'ssh/ssh_controller.dart';
import 'ssh/server_catalog.dart';
import 'ssh/server_catalog_controller.dart';
import 'vpn/client_traffic_controller.dart';
import 'vpn/vpn_controller.dart';
import 'vpn/users_page.dart';
import 'update/app_update_controller.dart';
import 'update/app_update_platform.dart';
import 'update/app_update_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAppLicenses();
  // The Linux window appears with the first frame and Android keeps its
  // launch background until then: the frame waits for the saved theme, so a
  // dark app on a light system does not open with a light screen.
  WidgetsBinding.instance.deferFirstFrame();
  runApp(const WorkspaceLauncher(firstFrameDeferred: true));
}

/// The launch waits at most this long for the cloud before opening local data.
const startupPullDeadline = Duration(seconds: 4);

/// The first frame waits at most this long for the saved theme.
const launchThemeWait = Duration(seconds: 1);

ThemeMode _themeMode(String? name) =>
    ThemeMode.values.where((e) => e.name == name).firstOrNull ??
    ThemeMode.system;

/// The app's light and dark themes, with the platform's dynamic color where
/// it has one. The launch screen and the app use the same ones.
Widget _appThemes(Widget Function(ThemeData light, ThemeData dark) builder) =>
    DynamicColorBuilder(
      builder: (light, dark) => builder(
        AppTheme.create(Brightness.light, dynamicScheme: light),
        AppTheme.create(Brightness.dark, dynamicScheme: dark),
      ),
    );

/// Where the user is in the shell. Kept by [WorkspaceLauncher], so a reopen
/// of the workspace (a received cloud version, a restored backup) returns to
/// the same page.
class ShellPlacement {
  int destination = 0;

  /// The open settings page; null is the settings menu.
  String? settingsPage;
}

/// Why VPN work cannot use [target]'s server through [session] right now,
/// or null when it can. The single source for both the remote and its
/// blocker; SSH failures keep their own issue as `ssh:<issue>`.
String? _vpnRemoteIssue(SshController? session, String target) {
  final runner = session?.runner;
  if (session == null ||
      runner == null ||
      runner.transport() == null ||
      runner.identity() == null) {
    if (session?.challenge != null) return 'ssh:hostKeyChanged';
    if (session?.needsPrivilegeInput == true) {
      return 'ssh:sudoPasswordRequired';
    }
    if (session?.error case final issue?) return 'ssh:${issue.name}';
    return 'vpn_connection';
  }
  if (runner.busy) return 'vpn_runner_busy';
  if (!runner.installed) return 'vpn_runner_not_ready';
  if (!isAwgTarget(target) &&
      !isTtTarget(target) &&
      (runner.panelAccess == null || runner.panelVerifiedAt == null)) {
    return 'vpn_panel_login';
  }
  return null;
}

/// Connection and runner flags of a server for [syncDiag]; no secrets.
String _sessionDiag(SshController? session) {
  final runner = session?.runner;
  if (session == null) return 'session=none';
  return 'stage=${session.stage.name} ssh=${session.error?.name} '
      'challenge=${session.challenge != null} '
      'sudo=${session.needsPrivilegeInput} '
      'transport=${runner?.transport() != null} '
      'identity=${runner?.identity() != null} '
      'installed=${runner?.installed} alive=${runner?.alive} '
      'runnerBusy=${runner?.busy} runnerError=${runner?.error?.name} '
      'release=${runner?.installation?.release} '
      'bundled=${runner?.bundledRelease} '
      'panel=${runner?.panelAccess != null} '
      'panelVerified=${runner?.panelVerifiedAt != null}';
}

class WorkspaceLauncher extends StatefulWidget {
  const WorkspaceLauncher({
    this.openWorkspace = openLocalWorkspace,
    this.backupFiles,
    this.firstFrameDeferred = false,
    this.backgroundChecks = true,
    super.key,
  });
  final Future<WorkspaceDatabase> Function() openWorkspace;
  final BackupFileStore? backupFiles;

  /// Release checks of the app and the server components at start and
  /// periodically; widget tests turn them off.
  final bool backgroundChecks;

  /// The caller deferred the first frame; the launcher allows it once the
  /// saved theme is known, or after [launchThemeWait].
  final bool firstFrameDeferred;
  @override
  State<WorkspaceLauncher> createState() => _WorkspaceLauncherState();
}

class _WorkspaceLauncherState extends State<WorkspaceLauncher>
    with WidgetsBindingObserver {
  late Future<Widget> _app = _load().whenComplete(_allowFirstFrame);
  WorkspaceDatabase? _database;
  AutoSyncController? _sync;
  GoogleSyncAccountService? _google;
  LanguageController? _languages;
  int _generation = 0;
  bool _retrying = false, _reopening = false;

  /// The saved theme, for the screens shown before the app opens.
  ThemeMode _theme = ThemeMode.system;
  final _placement = ShellPlacement();
  final _surface = GlobalKey();

  /// The last frame of the previous shell, shown while a reopen runs.
  ui.Image? _frozen;
  Timer? _firstFrameWait;
  late bool _firstFrameHeld = widget.firstFrameDeferred;

  void _allowFirstFrame() {
    if (!_firstFrameHeld) return;
    _firstFrameHeld = false;
    _firstFrameWait?.cancel();
    WidgetsBinding.instance.allowFirstFrame();
  }

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
    if (_firstFrameHeld) {
      _firstFrameWait = Timer(launchThemeWait, _allowFirstFrame);
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _sync?.flushOnExit();
    return AppExitResponse.exit;
  }

  /// Before an app update restarts the process: the same flush as a window
  /// close, then the sync session, Google sign-in and workspace database are
  /// closed so no write is cut off by the exit. Each step is independent.
  Future<void> _prepareExit() async {
    final sync = _sync, google = _google, database = _database;
    Future<void> step(Future<void> Function() work) async {
      try {
        await work();
      } catch (_) {}
    }

    await step(() async => sync?.flushOnExit());
    await step(() async => sync?.stop());
    if (google case final CancelableGoogleSignIn lifecycle) {
      await step(lifecycle.close);
    }
    await step(() async => database?.close());
  }

  /// The shell as it was last painted, or null when there is none.
  ui.Image? _capture() {
    final boundary = _surface.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return null;
    var painted = true;
    assert(() {
      painted = !boundary.debugNeedsPaint;
      return true;
    }());
    if (!painted) return null;
    try {
      return boundary.toImageSync(
        pixelRatio: View.of(context).devicePixelRatio,
      );
    } catch (_) {
      return null;
    }
  }

  /// Replaces the shell over newly opened data: after a received cloud
  /// version or a restored backup. The last frame of the shell stays on
  /// screen with a progress bar until the new shell replaces it, on the same
  /// page; nothing blinks to a loading screen.
  ///
  /// One reopen at a time: a request while one runs is answered by it, since
  /// that reopen reads the data after the request's change.
  Future<void> _reopen() async {
    if (_reopening) return;
    _reopening = true;
    // The frame being captured must be painted.
    await WidgetsBinding.instance.endOfFrame;
    // Unmounted meanwhile: dispose closed everything.
    if (!mounted) return;
    // The restart owns the previous workspace from here on.
    final old = _database,
        languages = _languages,
        sync = _sync,
        google = _google;
    _database = null;
    _languages = null;
    _sync = null;
    _google = null;
    final frozen = _capture();
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
      if (!mounted) throw StateError('launcher disposed');
      // This shell's sync checks the cloud as soon as it starts.
      return _load(pull: false);
    }

    setState(() {
      _generation++;
      _frozen?.dispose();
      _frozen = frozen;
      _app = restart().whenComplete(() {
        _reopening = false;
        // The next frame shows the new shell (or the error); the image is
        // released after it, unless dispose already released it.
        if (frozen == null || !identical(_frozen, frozen)) return;
        _frozen = null;
        WidgetsBinding.instance.addPostFrameCallback((_) => frozen.dispose());
      });
    });
  }

  /// Opens the workspace for the shell of the current generation. A result
  /// that arrives after the launcher was disposed or moved on is closed, not
  /// installed.
  Future<Widget> _load({bool pull = true}) async {
    final generation = _generation;
    bool stale() => !mounted || generation != _generation;
    final database = await widget.openWorkspace();
    try {
      if (stale()) throw StateError('stale workspace load');
      final theme = _themeMode(await database.readSetting('theme'));
      if (mounted && theme != _theme) setState(() => _theme = theme);
      _allowFirstFrame();
      final google = localGoogleAccountService(database);
      if (pull &&
          google.supported &&
          await database.readSetting('googleAutoSync') != 'false') {
        try {
          // Unreachable Google or a slow link must not hold the launch: past
          // the deadline local data opens and the next launch pulls again.
          final waited = Stopwatch()..start();
          if (await google.restore().timeout(startupPullDeadline) != null &&
              await database.pullCurrentSnapshot(
                google,
                deadline: startupPullDeadline - waited.elapsed,
              )) {
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
      final motion = await database.readSetting('motion');
      if (stale()) {
        languages.dispose();
        if (google case final CancelableGoogleSignIn lifecycle) {
          await lifecycle.close();
        }
        throw StateError('stale workspace load');
      }
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
        placement: _placement,
        initialTheme: theme,
        onThemeChanged: (value) => _theme = value,
        initialMotion:
            MotionPreference.values
                .where((e) => e.name == motion)
                .firstOrNull ??
            MotionPreference.system,
        pickTemplate: SystemTemplateFilePicker().pick,
        templateValidator: MihomoConfigValidator(),
        backgroundChecks: widget.backgroundChecks,
        appUpdates: widget.backgroundChecks
            ? (settings) =>
                  createAppUpdateController(settings, prepareExit: _prepareExit)
            : null,
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
    _allowFirstFrame();
    _frozen?.dispose();
    _frozen = null;
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

  /// What shows until the app opens: themed like the app (saved theme mode,
  /// dynamic color), so a dark app never shows a light screen (UI-64).
  Widget _placeholder(AsyncSnapshot<Widget> snapshot) => _appThemes(
    (light, dark) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: light,
      darkTheme: dark,
      themeMode: _theme,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Builder(
        builder: (context) {
          final failed =
              snapshot.hasError &&
              snapshot.connectionState == ConnectionState.done;
          final frozen = _frozen;
          if (frozen != null && !failed) {
            // A reopen: the previous shell as it was, not a blank screen.
            return Scaffold(
              key: const ValueKey('workspace-reopening'),
              body: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(
                    image: frozen,
                    scale: View.of(context).devicePixelRatio,
                    fit: BoxFit.none,
                    alignment: Alignment.topLeft,
                  ),
                  const Align(
                    alignment: Alignment.topCenter,
                    child: LinearProgressIndicator(),
                  ),
                ],
              ),
            );
          }
          return Scaffold(
            body: Center(
              // A retry keeps the previous error in the snapshot while it
              // runs; show progress instead of a second Retry button.
              child: failed
                  ? Padding(
                      padding: const EdgeInsets.all(AppLayout.gap),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: AppNotice(
                          message: AppLocalizations.of(
                            context,
                          ).databaseOpenError,
                          error: true,
                          margin: EdgeInsets.zero,
                          action: FilledButton(
                            key: const ValueKey('database-open-retry'),
                            onPressed: _retryLoad,
                            child: Text(
                              AppLocalizations.of(context).vaultRetry,
                            ),
                          ),
                        ),
                      ),
                    )
                  : const CircularProgressIndicator(),
            ),
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _surface,
    child: FutureBuilder<Widget>(
      key: ValueKey(_generation),
      future: _app,
      builder: (context, snapshot) => snapshot.data ?? _placeholder(snapshot),
    ),
  );
}

class AntiRknApp extends StatefulWidget {
  const AntiRknApp({
    required this.source,
    required this.languages,
    this.pickTemplate,
    this.templateValidator,
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
    this.placement,
    this.initialTheme = ThemeMode.system,
    this.onThemeChanged,
    this.initialMotion = MotionPreference.system,
    this.backgroundChecks = false,
    this.appUpdates,
    super.key,
  });
  final String? source;

  /// Component release checks at start and periodically.
  final bool backgroundChecks;

  /// Creates the app updater for [settings]; null hides app updates.
  final Future<AppUpdateController> Function(SettingsStore settings)?
  appUpdates;
  final Future<ImportedTemplate?> Function()? pickTemplate;

  /// Checks an added base config with the client core.
  final CoreConfigValidator? templateValidator;
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
  final ShellPlacement? placement;
  final ThemeMode initialTheme;

  /// A newly saved theme mode.
  final ValueChanged<ThemeMode>? onThemeChanged;
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
  AppUpdateController? _appUpdates;
  bool _disposed = false;
  @override
  void initState() {
    super.initState();
    _updates = ComponentUpdatesController(
      source: GithubComponentReleaseSource(
        sha256Hex: (bytes) => sha256.convert(bytes).toString(),
      ),
      settings: widget.settings,
      automatic: widget.backgroundChecks,
    );
    _updates.load();
    final settings = widget.settings, create = widget.appUpdates;
    if (settings != null && create != null) {
      unawaited(
        create(settings).then((controller) async {
          if (_disposed) return controller.dispose();
          setState(() => _appUpdates = controller);
          await controller.load();
        }),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _updates.dispose();
    _appUpdates?.dispose();
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
    builder: (context, _) => _appThemes(
      (light, dark) => MaterialApp(
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
        theme: light,
        darkTheme: dark,
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
                    child: Padding(
                      padding: const EdgeInsets.all(AppLayout.gap),
                      child: AppNotice(
                        message: AppLocalizations.of(context).loadError,
                        error: true,
                        margin: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              )
            : ComponentUpdatesScope(
                controller: _updates,
                child: _withAppUpdates(
                  ManagerShell(
                    source: widget.source!,
                    pickTemplate: widget.pickTemplate,
                    templateValidator: widget.templateValidator,
                    languages: widget.languages,
                    previewTemplate: widget.previewTemplate,
                    networkReader: widget.networkReader,
                    ssh: widget.ssh,
                    servers: widget.servers,
                    drafts: widget.drafts,
                    backups: widget.backups,
                    backupFiles: widget.backupFiles,
                    onRestored: widget.onRestored,
                    placement: widget.placement,
                    settingsError: _settingsError,
                    googleAccount: widget.googleAccount,
                    autoSync: widget.autoSync,
                    settings: widget.settings,
                    theme: _theme,
                    motion: _motion,
                    onTheme: (value) => _saveSetting('theme', value.name, () {
                      _theme = value;
                      widget.onThemeChanged?.call(value);
                    }),
                    onMotion: (_) {},
                  ),
                ),
              ),
      ),
    ),
  );

  Widget _withAppUpdates(Widget child) => _appUpdates == null
      ? child
      : AppUpdateScope(controller: _appUpdates!, child: child);
}

class ManagerShell extends StatefulWidget {
  ManagerShell({
    required this.source,
    this.pickTemplate,
    this.templateValidator,
    required this.languages,
    required this.previewTemplate,
    required this.networkReader,
    this.ssh,
    this.servers,
    this.drafts,
    this.backups,
    this.backupFiles,
    this.onRestored,
    this.placement,
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
  final CoreConfigValidator? templateValidator;
  final PreviewTemplate previewTemplate;
  final NetworkInventoryReader networkReader;
  final ServerRepository? servers;
  final TemplateDraftStore? drafts;
  final WorkspaceBackupStore? backups;
  final BackupFileStore? backupFiles;
  final Future<void> Function()? onRestored;

  /// Updated as the user navigates; the shell opens where it says.
  final ShellPlacement? placement;
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
  late int _index = (widget.placement?.destination ?? 0).clamp(0, 2);
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
  ClientTrafficController? _traffic;
  PublicationController? _publications;
  RestoredCacheRefresh? _cacheRefresh;
  bool _applyingSync = false;
  bool _diagnosing = false;
  ComponentUpdatesController? _diagnosticUpdates;
  late final IpDiagnosticsController _diagnostics;
  String _serverNameSnapshot = '';
  static const _icons = [Icons.dns_outlined, Icons.people_outline, Icons.tune];

  /// Filled variants for the selected destination, as M3 expects (UI-68).
  static const _selectedIcons = [Icons.dns, Icons.people, Icons.tune];

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
    widget.autoSync?.addListener(_divergenceChanged);
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
      coreValidator: widget.templateValidator,
    );
    if (widget.source.trim().isNotEmpty) _controller.refresh();
    if (widget.servers is VpnRepository) {
      _vpn = VpnController(
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
        tlsScanner: MihomoTlsScanner(),
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
        templateValidator: widget.templateValidator,
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
          if (_vpnRemoteIssue(_catalog?.sessionFor(server), id) != null) {
            return null;
          }
          final identity = runner!.identity()!;
          return VpnRemote(
            transport: runner.transport()!,
            panelId: (isAwgTarget(id) || isTtTarget(id))
                ? _vpn!.workspace.id
                : runner.panelAccess!.id,
            observationKey:
                '$identity|${runner.panelVerifiedAt?.toIso8601String()}|${identityHashCode(runner.installation)}',
            identity: identity,
            password: runner.password(),
            onSshFailure: runner.accessFailure,
          );
        },
        remoteIssue: (id) =>
            _vpnRemoteIssue(_catalog?.sessionFor(vpnServerId(id)), id),
      );
      final vpn = _vpn!;
      _traffic = ClientTrafficController(
        servers: () => vpn.trafficServerIds,
        read: vpn.readTraffic,
        store: widget.settings,
      );
      if (widget.settings case final settings? when _catalog != null) {
        final catalog = _catalog!, vpn = _vpn!;
        _cacheRefresh = RestoredCacheRefresh(
          settings: settings,
          connect: catalog.connectForAction,
          refresh: vpn.refreshConnectedInBackground,
          observedSince: vpn.serverObservedSince,
          observedAt: vpn.serverObservedAt,
          known: (id) => catalog.servers.any((server) => server.id == id),
          serverName: catalog.serverDisplayName,
          diagnose: (id) => _sessionDiag(catalog.sessionFor(id)),
        );
      }
      unawaited(_loadVpnAfterCatalog(catalogReady));
      if (widget.servers is PublicationRepository &&
          widget.googleAccount is GoogleSyncAccountService) {
        final account = widget.googleAccount! as GoogleSyncAccountService;
        _publications = PublicationController(
          repository: widget.servers! as PublicationRepository,
          account: account,
          remote: () => GoogleDrivePublisher(tokens: account),
          picker: createPublicationFilePicker(account),
          openExternal: openExternalUrl,
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
    // After a cloud pull, servers without cache here are read in background.
    if (mounted) unawaited(_cacheRefresh?.start());
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
    widget.autoSync?.removeListener(_divergenceChanged);
    widget.autoSync?.apply = (_) async => false;
    _catalog?.removeListener(_catalogChanged);
    _catalog?.removeListener(_shellChanged);
    _catalog?.dispose();
    _publications?.dispose();
    _cacheRefresh?.dispose();
    _traffic?.dispose();
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
    final syncForeground = AutoSyncController.lifecycleForeground(
      state,
      desktop: isDesktop,
    );
    if (syncForeground != null) widget.autoSync?.foreground(syncForeground);
    if (state == AppLifecycleState.resumed) widget.autoSync?.resumed();
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

  String? _announcedDivergence;

  /// A divergence is announced once, unobtrusively; the choice itself stays
  /// in the synchronization settings.
  void _divergenceChanged() {
    final sync = widget.autoSync;
    final divergence = sync?.divergence;
    final key = divergence == null
        ? null
        : '${divergence.cloud.savedAt}|${divergence.cloud.deviceName}';
    if (key == _announcedDivergence || !mounted) return;
    _announcedDivergence = key;
    if (key == null) return;
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        key: const ValueKey('sync-divergence-snackbar'),
        behavior: SnackBarBehavior.floating,
        content: Text(l.autoSyncDivergedShort),
        action: SnackBarAction(
          label: l.autoSyncChooseVersion,
          onPressed: () => chooseSyncVersion(context, sync!),
        ),
      ),
    );
  }

  String? _lastApplyBlockers;

  Future<bool> _applyReceived(Future<void> Function() receive) async {
    if (!mounted) return false;
    final vpn = _vpn;
    final blockers = [
      if (_applyingSync) 'applyingSync',
      if (_diagnosing) 'diagnosing',
      if (_clientSelection.active) 'clientSelection',
      if (_serverSelection.active) 'serverSelection',
      if (_catalog?.selectedId != null) 'serverOpen',
      if (_catalog?.loading ?? false) 'catalogLoading',
      if (_catalog?.hasActiveWork ?? false) 'catalogActiveWork',
      if (_catalog?.hasUnsavedEdits ?? false) 'catalogUnsaved',
      if (vpn?.workspaceBusy ?? false) 'vpnWorkspaceBusy',
      if (vpn?.upgradeBusy ?? false) 'vpnUpgradeBusy',
      if (vpn?.connections.busy ?? false) 'vpnConnectionChecks',
      if (_publications?.editing ?? false) 'publicationEditing',
      if (_publications?.busy ?? false) 'publicationBusy',
      if (vpn?.hasRunning ?? false) 'vpnRunning',
      if (_controller.savingDraft) 'savingDraft',
      if (_controller.draftSaveFailed) 'draftSaveFailed',
      if (_controller.importing) 'importing',
      if (ModalRoute.of(context)?.isCurrent != true) 'routeNotCurrent',
    ];
    final summary = blockers.join(',');
    if (summary != _lastApplyBlockers) {
      _lastApplyBlockers = summary;
      syncDiag('apply_gate blockers=[$summary]');
    }
    if (blockers.isNotEmpty) return false;
    setState(() => _applyingSync = true);
    var replacing = false;
    try {
      // Fence user input before any asynchronous repository mutation.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      await _publications?.suspend();
      replacing = true;
      await receive();
      return true;
    } finally {
      if (replacing) {
        // The workspace was replaced (or a failed restore may have touched
        // it): reopen everything, as after restoring a backup. Input stays
        // fenced until the new shell replaces this one.
        unawaited(widget.onRestored?.call());
      } else if (mounted) {
        _publications?.resume();
        setState(() => _applyingSync = false);
      }
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
    widget.placement?.destination = value;
    setState(() => _index = value);
  }

  /// A top-level page under its own title row, as in Settings: the row sits
  /// beside the navigation and changes with its page.
  Widget _withHeader(
    String title,
    Widget page, {
    CatalogSelection? selection,
    List<Widget> actions = const [],
  }) => Column(
    children: [
      AppPageHeader(
        title: selection == null
            ? Text(title)
            : CatalogTitle(selection: selection, title: title),
        actions: actions,
      ),
      Expanded(child: page),
    ],
  );

  Widget _catalogHeader(String title) => Builder(
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _catalogTitle(title),
        Padding(
          padding: AppLayout.screenPadding(context).copyWith(top: 0, bottom: 0),
          child: const AppUpdateBanner(),
        ),
      ],
    ),
  );

  Widget _catalogTitle(String title) => Builder(
    builder: (context) => AppPageHeader(
      title: CatalogTitle(selection: _serverSelection, title: title),
      actions: [
        ListenableBuilder(
          listenable: Listenable.merge([_catalog!, _vpn]),
          builder: (context, _) => CatalogActions(
            selection: _serverSelection,
            available: _catalog!.servers.map((s) => s.id),
            prefix: 'server',
            busy: _catalog!.loading || (_vpn?.busy ?? false),
            onAdd: _catalog!.add,
            onDelete: () => ServerCatalog.deleteSelected(
              context,
              _catalog!,
              _serverSelection,
              _vpn,
            ),
          ),
        ),
      ],
    ),
  );

  List<Widget> _clientActions() => [
    if (_vpn != null)
      Builder(
        builder: (context) => ListenableBuilder(
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
      ),
  ];

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
                            selectedIcon: Icon(_selectedIcons[i]),
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
                                selectedIcon: Icon(_selectedIcons[i]),
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
                                cacheRefresh: _cacheRefresh,
                                header: _catalogHeader(labels[0]),
                              )
                            else
                              _withHeader(
                                labels[0],
                                _sshController != null
                                    ? NetworkWorkbench(
                                        controller: _networkController,
                                        motion: widget.motion,
                                        ssh: _sshController,
                                      )
                                    : Center(child: Text(l.noServers)),
                              ),
                            _withHeader(
                              labels[1],
                              _vpn != null
                                  ? UsersPage(
                                      controller: _vpn!,
                                      traffic: _traffic,
                                      showAddAction: false,
                                      selection: _clientSelection,
                                      publications: _publications,
                                      serverName: (id) =>
                                          _catalog?.serverDisplayName(id) ?? id,
                                      exporter: SystemProfileExporter(),
                                      motion: widget.motion,
                                      onOpenServer: (id) {
                                        _navigate(0);
                                        _catalog?.select(id);
                                      },
                                    )
                                  : Center(child: Text(l.vpnNoUsers)),
                              selection: _vpn != null ? _clientSelection : null,
                              actions: _clientActions(),
                            ),
                            SettingsHub(
                              key: _settingsKey,
                              motion: widget.motion,
                              initialId: widget.placement?.settingsPage,
                              onOpened: (id) =>
                                  widget.placement?.settingsPage = id,
                              error: widget.settingsError
                                  ? AppNotice(
                                      message: l.settingsSaveError,
                                      error: true,
                                    )
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
                                        title: Text(l.uiSynchronization),
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
                                  // Base YAML and its publication are two
                                  // things: two headed groups (Profiles A).
                                  content: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      // The row names the file, so the
                                      // heading names what it is.
                                      AppSettingsSection(
                                        title: l.source,
                                        child: TemplateSettings(
                                          controller: _controller,
                                          grouped: true,
                                        ),
                                      ),
                                      if (_publications != null)
                                        AppSettingsSection(
                                          title: l.publicationDriveTitle,
                                          child: PublicationSettingsPanel(
                                            controller: _publications!,
                                            showTitle: false,
                                          ),
                                        ),
                                    ],
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
                                  content: const AppUpdateSettings(),
                                ),
                                SettingsDestination(
                                  id: 'about',
                                  title: l.uiAbout,
                                  subtitle: l.uiAboutHelp,
                                  icon: Icons.info_outline,
                                  content: AboutSettings(motion: widget.motion),
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
