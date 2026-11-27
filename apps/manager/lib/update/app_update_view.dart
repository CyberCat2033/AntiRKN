import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import 'app_update_controller.dart';

/// What the person reads for an update failure code: a title for the
/// verification failures, and one message per group of codes.
const appUpdateNetworkCodes = {
  AppUpdateCode.network,
  AppUpdateCode.http,
  AppUpdateCode.redirect,
};

({String? title, String message}) appUpdateFailureText(
  AppLocalizations l,
  String code,
) => switch (code) {
  AppUpdateCode.network || AppUpdateCode.http || AppUpdateCode.redirect => (
    title: l.appUpdateErrorNetworkTitle,
    message: l.appUpdateErrorNetwork,
  ),
  AppUpdateCode.unavailable => (title: null, message: l.appUpdateUnavailable),
  AppUpdateCode.storage => (title: null, message: l.appUpdateErrorStorage),
  AppUpdateCode.coreBusy => (title: null, message: l.appUpdateErrorCoreBusy),
  AppUpdateCode.installAborted => (
    title: null,
    message: l.appUpdateErrorAborted,
  ),
  AppUpdateCode.installPermission => (
    title: l.appUpdatePermissionTitle,
    message: l.appUpdateErrorPermission,
  ),
  AppUpdateCode.installFailed ||
  AppUpdateCode.installUnsupported ||
  AppUpdateCode.cancelled => (title: null, message: l.appUpdateErrorInstall),
  _ => (
    title: l.appUpdateErrorVerificationTitle,
    message: l.appUpdateErrorVerification,
  ),
};

String appUpdateSize(BuildContext context, int bytes) {
  final l = AppLocalizations.of(context);
  final locale = Localizations.localeOf(context).toLanguageTag();
  return l.appUpdateMegabytes(
    NumberFormat('0.0', locale).format(bytes / (1024 * 1024)),
  );
}

/// The install button label for this installation.
String appUpdateInstallLabel(AppLocalizations l, UpdateOffered offer) =>
    switch (offer.artifact?.kind) {
      AppUpdateKind.androidApk => l.appUpdateInstall,
      AppUpdateKind.windowsInstaller => l.appUpdateInstallRestart,
      AppUpdateKind.windowsPortable => l.appUpdateShowFile,
      _ => l.appUpdateRestart,
    };

String _how(AppLocalizations l, UpdateOffered offer) =>
    switch (offer.artifact?.kind) {
      AppUpdateKind.androidApk => l.appUpdateHowAndroid,
      AppUpdateKind.windowsInstaller => l.appUpdateHowWindows,
      AppUpdateKind.windowsPortable => l.appUpdateHowPortable,
      AppUpdateKind.linuxAppimage => l.appUpdateHowAppImage,
      _ => l.appUpdateHowTarball,
    };

/// The app's icon tile: a progress ring while downloading, verifying or
/// installing, like the server component cards.
class AppUpdateIcon extends StatelessWidget {
  const AppUpdateIcon({required this.state, this.size = 44, super.key});
  final AppUpdateState state;
  final double size;
  @override
  Widget build(BuildContext context) {
    final (icon, busy, value) = switch (state) {
      AppUpdateChecking() => (Icons.system_update_outlined, true, null),
      AppUpdateDownloading(:final progress) => (
        Icons.download_outlined,
        true,
        progress,
      ),
      AppUpdateVerifying() => (Icons.verified_outlined, true, null),
      AppUpdateInstalling() => (Icons.restart_alt, true, null),
      AppUpdateReadyToInstall(:final permissionRequired) => (
        permissionRequired ? Icons.android : Icons.check,
        false,
        null,
      ),
      AppUpdateFailed(:final code) => (
        appUpdateNetworkCodes.contains(code)
            ? Icons.cloud_off_outlined
            : Icons.gpp_bad_outlined,
        false,
        null,
      ),
      _ => (Icons.system_update_outlined, false, null),
    };
    return AppIconTile(icon: icon, busy: busy, value: value, size: size);
  }
}

/// The shared state view of the app update: the settings card and the
/// details sheet opened from the home banner show this same widget.
class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({
    required this.controller,
    this.embedded = false,
    this.expandedChanges = false,
    super.key,
  });
  final AppUpdateController controller;

  /// Inside a sheet: no card of its own.
  final bool embedded;

  /// The changelog open instead of behind a disclosure.
  final bool expandedChanges;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => SummaryCard(
      key: const ValueKey('app-update-card'),
      embedded: embedded,
      leadingAtTop: true,
      leading: AppUpdateIcon(state: controller.state),
      title: 'AntiRKN',
      subtitle: _AppUpdateBody(
        controller: controller,
        expandedChanges: expandedChanges,
      ),
    ),
  );
}

class _AppUpdateBody extends StatelessWidget {
  const _AppUpdateBody({
    required this.controller,
    required this.expandedChanges,
  });
  final AppUpdateController controller;
  final bool expandedChanges;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final c = controller, state = c.state, offer = c.offer;
    final installed = c.installed;
    final lines = <Widget>[];
    final actions = <Widget>[];
    void step(String text) => lines.add(
      Text(
        text,
        key: const ValueKey('app-update-step'),
        style: TextStyle(color: colors.primary),
      ),
    );
    void notice(Widget child) => lines.add(
      Padding(
        padding: const EdgeInsets.only(top: AppLayout.smallGap),
        child: child,
      ),
    );
    final versions = offer == null
        ? null
        : l.appUpdateVersions(
            installed?.version ?? '',
            offer.payload.version,
            offer.artifact == null
                ? '—'
                : appUpdateSize(context, offer.artifact!.size),
          );
    final checkButton = FilledButton.tonal(
      key: const ValueKey('app-update-check'),
      onPressed: c.busy ? null : c.check,
      child: Text(l.updatesCheck),
    );
    switch (state) {
      case AppUpdateUnavailable():
        lines.add(Text(l.appUpdateUnavailable));
      case AppUpdateIdle():
        if (installed != null) {
          lines.add(Text(l.appUpdateInstalledVersion(installed.version)));
        }
        actions.add(checkButton);
      case AppUpdateChecking():
        step(l.appUpdateChecking);
      case AppUpdateUpToDate(:final version):
        lines.add(Text(l.appUpdateUpToDate(installed?.version ?? version)));
        actions.add(checkButton);
      case AppUpdateAvailable(:final offer):
        lines.add(Text(versions!));
        if (offer.mandatory) {
          notice(
            AppNotice(message: l.appUpdateMandatory, margin: EdgeInsets.zero),
          );
        }
        if (offer.mode == AppUpdateInstallMode.notifyOnly) {
          notice(
            AppNotice(message: l.appUpdateNotifyOnly, margin: EdgeInsets.zero),
          );
          actions.add(
            FilledButton.tonal(
              key: const ValueKey('app-update-release-page'),
              onPressed: c.openReleasePage,
              child: Text(l.appUpdateReleasePage),
            ),
          );
        } else {
          actions.addAll([
            TextButton(
              key: const ValueKey('app-update-skip'),
              onPressed: c.skip,
              child: Text(l.appUpdateSkip),
            ),
            FilledButton.tonal(
              key: const ValueKey('app-update-download'),
              onPressed: c.download,
              child: Text(l.appUpdateUpdate),
            ),
          ]);
        }
      case AppUpdateDownloading(:final received, :final total):
        lines.add(Text(versions!));
        step(
          l.appUpdateDownloadingStep(
            appUpdateSize(context, received),
            appUpdateSize(context, total),
          ),
        );
        actions.add(
          OutlinedButton(
            key: const ValueKey('app-update-stop'),
            onPressed: c.cancel,
            child: Text(l.appUpdateStop),
          ),
        );
      case AppUpdateVerifying():
        lines.add(Text(versions!));
        step(l.appUpdateVerifyingStep);
      case AppUpdateReadyToInstall(:final offer, :final permissionRequired):
        lines.add(
          Text(
            '${l.appUpdateReadyStep(offer.payload.version)} ${_how(l, offer)}',
          ),
        );
        if (permissionRequired) {
          step(l.appUpdatePermissionWaiting);
          notice(
            AppNotice(
              key: const ValueKey('app-update-permission'),
              title: l.appUpdatePermissionTitle,
              message: [
                l.appUpdatePermission,
                l.appUpdatePermissionStep1,
                l.appUpdatePermissionStep2,
                l.appUpdatePermissionStep3,
              ].join('\n'),
              margin: EdgeInsets.zero,
            ),
          );
        } else if (offer.mode == AppUpdateInstallMode.automatic &&
            installed?.platform != AppUpdatePlatform.android) {
          notice(
            AppNotice(
              key: const ValueKey('app-update-restart-warning'),
              icon: Icons.restart_alt,
              message: l.appUpdateRestartWarning,
              margin: EdgeInsets.zero,
            ),
          );
        }
        actions.add(
          FilledButton(
            key: const ValueKey('app-update-install'),
            onPressed: c.install,
            child: Text(appUpdateInstallLabel(l, offer)),
          ),
        );
      case AppUpdateInstalling():
        lines.add(Text(versions!));
        step(l.appUpdateInstalling);
      case AppUpdateFailed(:final code, :final offer):
        lines.add(
          Text(
            versions ?? l.appUpdateInstalledVersion(installed?.version ?? ''),
          ),
        );
        final text = appUpdateFailureText(l, code);
        notice(
          AppNotice(
            key: const ValueKey('app-update-error'),
            error: true,
            title: text.title,
            message: text.message,
            margin: EdgeInsets.zero,
          ),
        );
        actions.addAll([
          TextButton(
            key: const ValueKey('app-update-details'),
            onPressed: () => _technical(context, code),
            child: Text(l.appUpdateDetails),
          ),
          FilledButton.tonal(
            key: const ValueKey('app-update-retry'),
            onPressed: offer?.artifact != null ? c.download : c.check,
            child: Text(
              offer?.artifact != null
                  ? l.appUpdateDownloadAgain
                  : l.appUpdateRetry,
            ),
          ),
        ]);
    }
    final changes = c.changes(Localizations.localeOf(context).languageCode);
    final showChanges =
        changes.isNotEmpty && (state is AppUpdateAvailable || expandedChanges);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...lines,
        if (showChanges)
          Padding(
            padding: const EdgeInsets.only(top: AppLayout.smallGap),
            child: expandedChanges
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l.appUpdateWhatsNew(offer!.payload.version),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      AppUpdateChangelog(entries: changes),
                    ],
                  )
                : AppExpansionTile(
                    key: const ValueKey('app-update-changes'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                    title: Text(l.appUpdateWhatsNew(offer!.payload.version)),
                    children: [AppUpdateChangelog(entries: changes)],
                  ),
          ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppLayout.smallGap),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: actions,
            ),
          ),
      ],
    );
  }

  void _technical(BuildContext context, String code) {
    final l = AppLocalizations.of(context);
    final offer = controller.offer;
    final artifact = offer?.artifact;
    ListTile row(String title, String value) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: SelectableText(value),
    );
    showAppDetails(
      context,
      title: l.appUpdateDetails,
      children: [
        row(l.appUpdateDetailCode, code),
        if (offer != null) ...[
          row(l.appUpdateDetailBuild, '${offer.payload.build}'),
          row(l.appUpdateDetailCommit, offer.payload.commit),
        ],
        if (artifact != null) ...[
          row(l.appUpdateDetailFile, artifact.fileName),
          row(l.appUpdateDetailChecksum, artifact.sha256),
        ],
      ],
    );
  }
}

/// CHANGELOG sections from the signed payload: headings, bullets and text.
/// Markdown emphasis and code marks are shown as plain text.
class AppUpdateChangelog extends StatelessWidget {
  const AppUpdateChangelog({required this.entries, super.key});
  final List<AppUpdateChangelogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String plain(String text) => text.replaceAll('**', '').replaceAll('`', '');
    final children = <Widget>[];
    for (final entry in entries) {
      if (entries.length > 1) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              '${entry.version} · ${entry.date}',
              style: theme.textTheme.titleSmall,
            ),
          ),
        );
      }
      for (final line in entry.markdown.split('\n')) {
        final text = line.trim();
        if (text.isEmpty) continue;
        if (text.startsWith('#')) {
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: Text(
                plain(text.replaceFirst(RegExp(r'^#+\s*'), '')),
                style: theme.textTheme.labelLarge,
              ),
            ),
          );
        } else if (text.startsWith('- ')) {
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  '),
                  Expanded(child: Text(plain(text.substring(2)))),
                ],
              ),
            ),
          );
        } else {
          children.add(Text(plain(text)));
        }
      }
    }
    return DefaultTextStyle.merge(
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// Opens the shared state view: a bottom sheet on compact widths, a dialog
/// on wider ones; it follows the controller while open.
Future<void> showAppUpdateDetails(
  BuildContext context,
  AppUpdateController controller,
) => showAppAdaptiveDetails(
  context,
  title: AppLocalizations.of(context).appUpdateSection,
  builder: (context) => AppUpdateCard(
    controller: controller,
    embedded: true,
    expandedChanges: true,
  ),
);

/// The home screen notice above the server list (variant Б): only while
/// an update is offered, suggestions are on and the version is not skipped.
class AppUpdateBanner extends StatelessWidget {
  const AppUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppUpdateScope.of(context);
    if (c == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    Widget? banner;
    final offer = c.offer;
    if (c.showOnHome && offer != null) {
      final version = offer.payload.version;
      void details() => showAppUpdateDetails(context, c);
      final more = TextButton(
        key: const ValueKey('app-update-banner-more'),
        onPressed: details,
        child: Text(l.appUpdateMore),
      );
      banner = switch (c.state) {
        AppUpdateDownloading(:final progress, :final received, :final total) =>
          AppStatusBanner(
            icon: Icons.download_outlined,
            title: l.appUpdateDownloadingTitle(
              version,
              '${total == 0 ? 0 : received * 100 ~/ total}',
            ),
            progress: progress,
            onTap: details,
            actions: [
              TextButton(onPressed: c.cancel, child: Text(l.appUpdateStop)),
            ],
          ),
        AppUpdateVerifying() || AppUpdateInstalling() => AppStatusBanner(
          icon: Icons.verified_outlined,
          title: l.appUpdateVerifyingTitle,
          onTap: details,
        ),
        AppUpdateReadyToInstall() => AppStatusBanner(
          tone: AppStatusTone.attention,
          icon: Icons.restart_alt,
          title: l.appUpdateReadyTitle(version),
          message: _how(l, offer),
          onTap: details,
          actions: [
            more,
            FilledButton(
              key: const ValueKey('app-update-banner-install'),
              onPressed: c.install,
              child: Text(appUpdateInstallLabel(l, offer)),
            ),
          ],
        ),
        AppUpdateFailed(:final code) => AppStatusBanner(
          tone: AppStatusTone.error,
          title:
              appUpdateFailureText(l, code).title ??
              appUpdateFailureText(l, code).message,
          message: appUpdateFailureText(l, code).title == null
              ? null
              : appUpdateFailureText(l, code).message,
          onTap: details,
          actions: [more],
        ),
        _ => AppStatusBanner(
          tone: AppStatusTone.attention,
          icon: Icons.system_update_outlined,
          title: l.appUpdateAvailableTitle(version),
          message: l.appUpdateBannerText(
            c.installed?.version ?? '',
            offer.artifact == null
                ? '—'
                : appUpdateSize(context, offer.artifact!.size),
          ),
          onTap: details,
          actions: [
            TextButton(
              key: const ValueKey('app-update-banner-skip'),
              onPressed: c.skip,
              child: Text(l.appUpdateSkip),
            ),
            more,
          ],
        ),
      };
    }
    return AppAnimatedSize(
      motion: MotionPreference.system,
      child: banner == null
          ? const SizedBox.shrink(key: ValueKey('app-update-banner-none'))
          : Padding(
              key: const ValueKey('app-update-banner'),
              padding: const EdgeInsets.only(bottom: 12),
              child: banner,
            ),
    );
  }
}

/// The Settings → Updates page: the app card first, then the switches
/// that govern it (UI-61).
class AppUpdateSettings extends StatelessWidget {
  const AppUpdateSettings({super.key});
  @override
  Widget build(BuildContext context) {
    final c = AppUpdateScope.of(context), l = AppLocalizations.of(context);
    if (c == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionHeading(title: l.appUpdateSection),
        AppUpdateCard(controller: c),
        const SizedBox(height: AppLayout.gap),
        AppSettingsSection(
          child: Column(
            children: [
              SwitchListTile(
                key: const ValueKey('app-update-automatic'),
                title: Text(l.updatesAutomatic),
                subtitle: Text(l.uiUpdatesAutomaticHelp),
                value: c.automatic,
                onChanged: (v) => c.setPreference(automatic: v),
              ),
              SwitchListTile(
                key: const ValueKey('app-update-suggestions'),
                title: Text(l.updatesSuggestions),
                subtitle: Text(l.uiUpdatesSuggestionsHelp),
                value: c.suggestions,
                onChanged: (v) => c.setPreference(suggestions: v),
              ),
              if (c.storageFailed)
                AppNotice(message: l.settingsSaveError, error: true),
            ],
          ),
        ),
      ],
    );
  }
}
