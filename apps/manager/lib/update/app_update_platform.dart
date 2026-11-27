import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antirkn_app_update/antirkn_app_update.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_mihomo_runtime/antirkn_mihomo_runtime.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_update_controller.dart';

const _channel = MethodChannel('org.antirkn/app_update');

/// Android: the Kotlin PackageInstaller bridge checks package name,
/// versionCode and signer before it opens a session.
final class AndroidAppUpdateInstaller implements AppUpdateInstaller {
  const AndroidAppUpdateInstaller();

  @override
  Future<AppUpdateInstallMode> mode(AppUpdateArtifact artifact) async =>
      artifact.kind.isAndroid
      ? AppUpdateInstallMode.automatic
      : AppUpdateInstallMode.notifyOnly;

  Map<String, Object?> _arguments(String path, AppUpdateArtifact artifact) => {
    'path': path,
    'versionCode': artifact.versionCode,
    'certSha256': artifact.certSha256,
  };

  @override
  Future<void> verify(String path, AppUpdateArtifact artifact) => _call(
    () => _channel.invokeMethod<void>('verify', _arguments(path, artifact)),
  );

  @override
  Future<AppUpdateInstallResult> install(
    String path,
    AppUpdateArtifact artifact,
    AppUpdatePayload payload,
  ) async {
    final result = await _call(
      () => _channel
          .invokeMethod<String>('install', _arguments(path, artifact))
          .timeout(const Duration(minutes: 15)),
    );
    return switch (result) {
      'permission' => AppUpdateInstallResult.permissionRequired,
      'permission_unavailable' => throw const AppUpdateFailure(
        AppUpdateCode.installPermission,
      ),
      _ => AppUpdateInstallResult.handedToSystem,
    };
  }

  @override
  Future<void> reveal(String path) async {}

  @override
  Future<void> finishStartup({required bool confirmed}) async {}

  static Future<T> _call<T>(Future<T> Function() work) async {
    try {
      return await work();
    } on PlatformException catch (error) {
      throw AppUpdateFailure(
        AppUpdateCode.all.contains(error.code)
            ? error.code
            : AppUpdateCode.installFailed,
      );
    } on TimeoutException {
      throw const AppUpdateFailure(AppUpdateCode.installFailed);
    } on MissingPluginException {
      throw const AppUpdateFailure(AppUpdateCode.installUnsupported);
    }
  }
}

/// `version` and `build_number` of the running build from Flutter's
/// `version.json` asset.
Future<(String, int)> _bundleVersion() async {
  final json =
      jsonDecode(await rootBundle.loadString('version.json'))
          as Map<String, Object?>;
  return (
    json['version'] as String? ?? '0.0.0',
    int.tryParse('${json['build_number']}') ?? 0,
  );
}

/// What is installed here, or null where updates are not supported.
Future<InstalledApp?> readInstalledApp() async {
  final (version, buildNumber) = await _bundleVersion();
  if (Platform.isAndroid) {
    final info = await _channel.invokeMapMethod<String, Object?>('info');
    final versionCode = (info?['versionCode'] as num?)?.toInt() ?? 0;
    final (build, abi) = InstalledApp.fromAndroidVersionCode(versionCode);
    return InstalledApp(
      platform: AppUpdatePlatform.android,
      build: build,
      version: version,
      installKind: AppUpdateKind.androidApk,
      androidAbi: abi,
      supportedAbis: [
        for (final abi in info?['supportedAbis'] as List? ?? const [])
          if (abi is String) abi,
      ],
    );
  }
  if (!Platform.isLinux && !Platform.isWindows) return null;
  var kind = await readInstallKind(Platform.resolvedExecutable);
  if (kind == AppUpdateKind.linuxAppimage &&
      Platform.environment['APPIMAGE'] == null) {
    kind = null;
  }
  return InstalledApp(
    platform: Platform.isLinux
        ? AppUpdatePlatform.linux
        : AppUpdatePlatform.windows,
    build: buildNumber,
    version: version,
    installKind: kind,
  );
}

/// The production controller: GitHub feed, update cache in the temporary
/// directory (never the workspace data directory), committed public keys
/// and the Mihomo worker gate. Unsupported platforms get a controller
/// without a coordinator, which reports updates as unavailable.
///
/// [prepareExit] is the app's own shutdown (sync flush, database close);
/// desktop installers await it, bounded, before they restart the app.
Future<AppUpdateController> createAppUpdateController(
  SettingsStore settings, {
  Future<void> Function()? prepareExit,
}) async {
  Future<void> open(Uri uri) async {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  try {
    final installed = await readInstalledApp();
    if (installed == null) {
      return AppUpdateController(settings: settings, openUrl: open);
    }
    final cache = '${(await getTemporaryDirectory()).path}/antirkn-update';
    return AppUpdateController(
      settings: settings,
      openUrl: open,
      coordinator: AppUpdateCoordinator(
        installed: installed,
        trustedKeys: appUpdateTrustedKeys,
        feed: GithubUpdateFeed(),
        verifier: const Ed25519UpdateVerifier(),
        downloader: GithubArtifactDownloader(cacheDirectory: cache),
        installer: installed.platform == AppUpdatePlatform.android
            ? const AndroidAppUpdateInstaller()
            : DesktopAppUpdateInstaller(
                installKind: installed.installKind,
                executable: Platform.resolvedExecutable,
                prepareExit: prepareExit,
              ),
        store: SettingsAppUpdateStateStore(settings),
        core: MihomoWorkerGate.instance,
      ),
    );
  } catch (_) {
    return AppUpdateController(settings: settings, openUrl: open);
  }
}
