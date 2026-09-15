import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_profile_compiler/antirkn_profile_compiler.dart';
import 'package:antirkn_storage/antirkn_storage.dart';
import 'package:antirkn_ssh_transport/antirkn_ssh_transport.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'app_strings.dart';
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
  const WorkspaceLauncher({super.key});
  @override
  State<WorkspaceLauncher> createState() => _WorkspaceLauncherState();
}

class _WorkspaceLauncherState extends State<WorkspaceLauncher> {
  late Future<Widget> _app = _load();
  Future<Widget> _load() async {
    final database = await openLocalWorkspace();
    try {
      final languages = LanguageController(database);
      await languages.load();
      final source = await database.readDraft() ?? '';
      final theme = await database.readSetting('theme');
      final motion = await database.readSetting('motion');
      return AntiRknApp(
        source: source,
        languages: languages,
        settings: database,
        drafts: database,
        servers: database,
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
  Widget build(BuildContext context) => FutureBuilder<Widget>(
    future: _app,
    builder: (context, snapshot) =>
        snapshot.data ??
        MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: snapshot.hasError
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(AppLocalizations.of(context).databaseOpenError),
                          FilledButton(
                            onPressed: () => setState(() => _app = _load()),
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
    this.drafts,
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
  final TemplateDraftStore? drafts;
  final ThemeMode initialTheme;
  final MotionPreference initialMotion;
  final SshDependencies? ssh;
  @override
  State<AntiRknApp> createState() => _AntiRknAppState();
}

class _AntiRknAppState extends State<AntiRknApp> {
  late ThemeMode _theme = widget.initialTheme;
  late MotionPreference _motion = widget.initialMotion;
  bool _settingsError = false;
  late final ComponentUpdatesController _updates;
  @override
  void initState() {
    super.initState();
    _updates = ComponentUpdatesController(
      source: const GithubComponentReleaseSource(),
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
                  settingsError: _settingsError,
                  theme: _theme,
                  motion: _motion,
                  onTheme: (value) =>
                      _saveSetting('theme', value.name, () => _theme = value),
                  onMotion: (value) =>
                      _saveSetting('motion', value.name, () => _motion = value),
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
    this.settingsError = false,
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
  final bool settingsError;
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
  int _index = 1;
  late final TemplateController _controller;
  late final NetworkController _networkController;
  SshController? _sshController;
  ServerCatalogController? _catalog;
  VpnController? _vpn;
  static const _icons = [
    Icons.space_dashboard_outlined,
    Icons.data_object,
    Icons.dns_outlined,
    Icons.tune,
    Icons.people_outline,
  ];

  @override
  void initState() {
    super.initState();
    _networkController = NetworkController(reader: widget.networkReader);
    if (widget.ssh case final ssh?) {
      WidgetsBinding.instance.addObserver(this);
      if (widget.servers case final repository?) {
        _index = 2;
        _catalog = ServerCatalogController(
          repository: repository,
          connector: ssh.connector,
          picker: ssh.picker,
          reader: widget.networkReader,
          agentAvailable: ssh.agentAvailable,
        )..load();
      } else {
        _sshController = SshController(
          openVault: ssh.openVault,
          connector: ssh.connector,
          picker: ssh.picker,
          agentAvailable: ssh.agentAvailable,
          network: _networkController,
        )..initialise();
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
        repository: widget.servers as VpnRepository,
        template: () => _controller.source,
        serverIds: () =>
            _catalog?.servers.expand(
              (s) => [s.id, awgTarget(s.id), ttTarget(s.id)],
            ) ??
            const <String>[],
        remote: (id) {
          final runner = _catalog?.sessionFor(vpnServerId(id))?.runner;
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
      )..load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _catalog?.dispose();
    _vpn?.dispose();
    _sshController?.dispose();
    _controller.dispose();
    _networkController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _networkController.tick();
      if (!(_sshController?.unlocked ?? true)) _sshController?.initialise();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final l = AppLocalizations.of(context);
      final labels = [
        l.overview,
        l.templates,
        l.server,
        l.settings,
        if (_vpn != null) l.vpnUsers,
      ];
      final rail =
          constraints.maxWidth >= AppLayout.compact &&
          constraints.maxHeight >= 400;
      return Scaffold(
        appBar: AppBar(
          title: Text(AppLocalizations.of(context).appName),
          actions: [
            if (_index == 2 && _catalog != null)
              ListenableBuilder(
                listenable: _catalog!,
                builder: (context, _) => _catalog!.selectedId != null
                    ? const SizedBox.shrink()
                    : IconButton(
                        key: const ValueKey('server-add'),
                        tooltip: l.addServer,
                        onPressed:
                            _catalog!.loading ||
                                (_catalog!.selected?.vaultBusy ?? false) ||
                                (_catalog!.selected?.picking ?? false)
                            ? null
                            : _catalog!.add,
                        icon: const Icon(Icons.add),
                      ),
              ),
            if (_index != 2 || _catalog == null)
              Padding(
                padding: EdgeInsets.only(right: AppLayout.gap),
                child:
                    constraints.maxWidth < AppLayout.compact ||
                        MediaQuery.textScalerOf(context).scale(14) > 20
                    ? Tooltip(
                        message: AppLocalizations.of(context).prototype,
                        child: Semantics(
                          label: AppLocalizations.of(context).prototype,
                          child: Icon(Icons.science_outlined),
                        ),
                      )
                    : StatusChip(
                        label: AppLocalizations.of(context).prototype,
                        icon: Icons.science_outlined,
                      ),
              ),
          ],
        ),
        bottomNavigationBar: rail
            ? null
            : NavigationBar(
                selectedIndex: _index,
                onDestinationSelected: (value) =>
                    setState(() => _index = value),
                destinations: [
                  for (var i = 0; i < labels.length; i++)
                    NavigationDestination(
                      icon: Icon(_icons[i]),
                      label: labels[i],
                    ),
                ],
              ),
        body: Listener(
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
                    onDestinationSelected: (value) =>
                        setState(() => _index = value),
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
                  child: IndexedStack(
                    index: _index,
                    children: [
                      ListView(
                        padding: AppLayout.padding,
                        children: [
                          SectionCard(
                            title: AppLocalizations.of(context).prototype,
                            child: Text(
                              AppLocalizations.of(context).overviewText,
                            ),
                          ),
                          SizedBox(height: AppLayout.gap),
                          SectionCard(
                            title: AppLocalizations.of(context).appName,
                            child: Text(AppLocalizations.of(context).scope),
                          ),
                        ],
                      ),
                      TemplateWorkbench(
                        controller: _controller,
                        motion: widget.motion,
                      ),
                      if (_catalog != null)
                        ServerCatalog(
                          controller: _catalog!,
                          motion: widget.motion,
                          vpn: _vpn,
                        )
                      else
                        NetworkWorkbench(
                          controller: _networkController,
                          motion: widget.motion,
                          ssh: _sshController,
                        ),
                      ListView(
                        padding: AppLayout.padding,
                        children: [
                          if (widget.settingsError) Text(l.settingsSaveError),
                          const ComponentUpdateSettings(),
                          const SizedBox(height: AppLayout.gap),
                          SectionCard(
                            title: l.language,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Wrap(
                                  spacing: AppLayout.smallGap,
                                  children: [
                                    for (final item in [
                                      (AppLanguage.system, l.languageSystem),
                                      (AppLanguage.ru, l.languageRussian),
                                      (AppLanguage.en, l.languageEnglish),
                                    ])
                                      ChoiceChip(
                                        key: ValueKey(
                                          'language-${item.$1.name}',
                                        ),
                                        label: Text(item.$2),
                                        selected:
                                            widget.languages.language ==
                                            item.$1,
                                        onSelected: widget.languages.saving
                                            ? null
                                            : (_) => widget.languages.select(
                                                item.$1,
                                              ),
                                      ),
                                  ],
                                ),
                                SizedBox(height: AppLayout.smallGap),
                                Text(l.languageHelp),
                                if (widget.languages.savingFailed)
                                  Text(l.localeSaveError),
                                if (widget.languages.loadingFailed)
                                  Text(l.localeLoadError),
                              ],
                            ),
                          ),
                          SizedBox(height: AppLayout.gap),
                          SectionCard(
                            title: AppLocalizations.of(context).theme,
                            child: Wrap(
                              spacing: AppLayout.smallGap,
                              children: [
                                for (final item in [
                                  (
                                    ThemeMode.system,
                                    AppLocalizations.of(context).system,
                                  ),
                                  (
                                    ThemeMode.light,
                                    AppLocalizations.of(context).light,
                                  ),
                                  (
                                    ThemeMode.dark,
                                    AppLocalizations.of(context).dark,
                                  ),
                                ])
                                  ChoiceChip(
                                    label: Text(item.$2),
                                    selected: widget.theme == item.$1,
                                    onSelected: (_) => widget.onTheme(item.$1),
                                  ),
                              ],
                            ),
                          ),
                          SizedBox(height: AppLayout.gap),
                          SectionCard(
                            title: AppLocalizations.of(context).motion,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: AppLayout.smallGap,
                                  children: [
                                    for (final item in [
                                      (
                                        MotionPreference.system,
                                        AppLocalizations.of(context).system,
                                      ),
                                      (
                                        MotionPreference.reduced,
                                        AppLocalizations.of(context).reduced,
                                      ),
                                      (
                                        MotionPreference.off,
                                        AppLocalizations.of(context).off,
                                      ),
                                    ])
                                      ChoiceChip(
                                        label: Text(item.$2),
                                        selected: widget.motion == item.$1,
                                        onSelected: (_) =>
                                            widget.onMotion(item.$1),
                                      ),
                                  ],
                                ),
                                SizedBox(height: AppLayout.gap),
                                Text(AppLocalizations.of(context).motionHelp),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_vpn != null)
                        UsersPage(
                          controller: _vpn!,
                          serverName: (id) =>
                              _catalog?.servers
                                  .where((s) => s.id == id)
                                  .firstOrNull
                                  ?.profile
                                  .displayName ??
                              id,
                          exporter: SystemProfileExporter(),
                          motion: widget.motion,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class TemplateWorkbench extends StatefulWidget {
  TemplateWorkbench({
    required this.controller,
    required this.motion,
    super.key,
  });
  final TemplateController controller;
  final MotionPreference motion;

  @override
  State<TemplateWorkbench> createState() => _TemplateWorkbenchState();
}

class _TemplateWorkbenchState extends State<TemplateWorkbench> {
  late final TextEditingController _source;
  final _name = TextEditingController();
  String _type = 'VLESS';
  bool _nameInvalid = false;

  @override
  void initState() {
    super.initState();
    _source = TextEditingController(text: widget.controller.source);
  }

  @override
  void dispose() {
    _source.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final l = AppLocalizations.of(context);
      if (_source.text != controller.source) {
        _source.value = TextEditingValue(
          text: controller.source,
          selection: const TextSelection.collapsed(offset: 0),
        );
      }
      final result = controller.result;
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: AppLayout.contentWidth),
          child: ListView(
            key: PageStorageKey('template-scroll'),
            padding: AppLayout.padding,
            children: [
              Text(
                AppLocalizations.of(context).workbench,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              SizedBox(height: AppLayout.smallGap),
              Text(AppLocalizations.of(context).intro),
              SizedBox(height: AppLayout.gap),
              SectionCard(
                title: AppLocalizations.of(context).source,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        key: const ValueKey('import-template'),
                        onPressed:
                            controller.importing ||
                                controller.busy ||
                                controller.pickTemplate == null
                            ? null
                            : controller.importFile,
                        icon: const Icon(Icons.file_open_outlined),
                        label: Text(
                          AppLocalizations.of(context).selectTemplate,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppLayout.smallGap),
                    if (controller.importedName != null)
                      Text(
                        AppLocalizations.of(
                          context,
                        ).importedTemplate(controller.importedName!),
                      ),
                    if (controller.draftStore != null) ...[
                      Text(
                        controller.draftSaveFailed
                            ? l.draftSaveError
                            : controller.savingDraft
                            ? l.draftSaving
                            : l.draftSaved,
                      ),
                      if (controller.draftSaveFailed)
                        OutlinedButton(
                          onPressed: controller.persistDraft,
                          child: Text(l.vaultRetry),
                        ),
                    ],
                    if (controller.importError != null)
                      Text(
                        controller.importError == 'template_size_limit'
                            ? AppLocalizations.of(
                                context,
                              ).diagnostic('template_size_limit')
                            : AppLocalizations.of(context).templateReadError,
                      ),
                    TextField(
                      key: ValueKey('template-editor'),
                      readOnly: controller.importing,
                      controller: _source,
                      onChanged: controller.edit,
                      minLines: 8,
                      maxLines: 16,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(context).source,
                      ),
                    ),
                    SizedBox(height: AppLayout.smallGap),
                    Text(AppLocalizations.of(context).sourceHelp),
                  ],
                ),
              ),
              SizedBox(height: AppLayout.gap),
              SectionCard(
                title: AppLocalizations.of(context).nodes,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(AppLocalizations.of(context).sampleNotice),
                    SizedBox(height: AppLayout.smallGap),
                    Wrap(
                      spacing: AppLayout.smallGap,
                      runSpacing: AppLayout.smallGap,
                      children: [
                        OutlinedButton(
                          onPressed: () => controller.selectNodes(
                            TemplateController.mixedNodes,
                          ),
                          child: Text(AppLocalizations.of(context).mixed),
                        ),
                        OutlinedButton(
                          onPressed: () => controller.selectNodes([
                            ProxyDescriptor('VLESS_EU', 'VLESS'),
                          ]),
                          child: Text(AppLocalizations.of(context).noRuWg),
                        ),
                      ],
                    ),
                    SizedBox(height: AppLayout.smallGap),
                    for (var i = 0; i < controller.nodes.length; i++)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(controller.nodes[i].name),
                        subtitle: Text(controller.nodes[i].type),
                        trailing: IconButton(
                          tooltip: AppLocalizations.of(context).remove,
                          icon: Icon(Icons.close),
                          onPressed: () => controller.removeNode(i),
                        ),
                      ),
                    SizedBox(height: AppLayout.smallGap),
                    TextField(
                      controller: _name,
                      maxLength: 120,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(context).nodeName,
                        errorText: _nameInvalid
                            ? AppLocalizations.of(context).invalidName
                            : null,
                      ),
                    ),
                    Wrap(
                      spacing: AppLayout.smallGap,
                      children: [
                        for (final type in [
                          'VLESS',
                          'TrustTunnel',
                          'WireGuard',
                        ])
                          ChoiceChip(
                            label: Text(type),
                            selected: _type == type,
                            onSelected: (_) => setState(() => _type = type),
                          ),
                      ],
                    ),
                    SizedBox(height: AppLayout.smallGap),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        icon: Icon(Icons.add),
                        label: Text(AppLocalizations.of(context).add),
                        onPressed: () {
                          final added = controller.addNode(_name.text, _type);
                          setState(() => _nameInvalid = !added);
                          if (added) _name.clear();
                        },
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: AppLayout.gap),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: ValueKey('preview-button'),
                  onPressed:
                      controller.busy ||
                          controller.importing ||
                          controller.source.trim().isEmpty
                      ? null
                      : controller.refresh,
                  icon: Icon(Icons.fact_check_outlined),
                  label: Text(
                    controller.busy
                        ? AppLocalizations.of(context).pending
                        : AppLocalizations.of(context).preview,
                  ),
                ),
              ),
              SizedBox(height: AppLayout.smallGap),
              Semantics(
                liveRegion: true,
                child: AnimatedSwitcher(
                  duration: AppMotion.duration(context, widget.motion),
                  child: Text(
                    controller.failed
                        ? AppLocalizations.of(context).unexpectedError
                        : controller.stale
                        ? AppLocalizations.of(context).stale
                        : AppLocalizations.of(context).coreNotRun,
                    key: ValueKey((controller.failed, controller.stale)),
                  ),
                ),
              ),
              if (result != null && !controller.stale) ...[
                SizedBox(height: AppLayout.gap),
                SectionCard(
                  title: AppLocalizations.of(context).groups,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final group in result.groups)
                        Padding(
                          padding: EdgeInsets.only(bottom: AppLayout.gap),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                group.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              SizedBox(height: AppLayout.smallGap),
                              if (!group.complete)
                                Text(AppLocalizations.of(context).incomplete)
                              else if (group.members.isEmpty)
                                Text(AppLocalizations.of(context).noMembers)
                              else
                                Text(group.members.join(' → ')),
                              if (group.fallback != null)
                                Text(
                                  AppLocalizations.of(
                                    context,
                                  ).fallback(group.fallback!),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: AppLayout.gap),
                SectionCard(
                  title: AppLocalizations.of(context).diagnostics,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (result.diagnostics.isEmpty)
                        Text(AppLocalizations.of(context).noIssues),
                      for (final diagnostic in result.diagnostics)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            diagnostic.severity == DiagnosticSeverity.error
                                ? Icons.error_outline
                                : Icons.info_outline,
                          ),
                          title: Text(
                            AppLocalizations.of(
                              context,
                            ).diagnostic(diagnostic.code),
                          ),
                          subtitle: diagnostic.subject == null
                              ? null
                              : Text(diagnostic.subject!),
                        ),
                      Text(AppLocalizations.of(context).coreNotRun),
                      Text(AppLocalizations.of(context).connectionNotRun),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
