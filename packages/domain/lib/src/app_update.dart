import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'app_update_changelog.dart';
import 'app_update_contract.g.dart';
import 'ssh.dart' show CancellationToken;

/// Stable failure codes of the application update. Only codes leave this
/// layer: no upstream text, URLs with tokens or file contents.
abstract final class AppUpdateCode {
  static const unavailable = 'update_unavailable';
  static const network = 'update_network';
  static const http = 'update_http';
  static const redirect = 'update_redirect';
  static const manifestInvalid = 'update_manifest_invalid';
  static const unknownKey = 'update_unknown_key';
  static const signature = 'update_signature';
  static const appMismatch = 'update_app_mismatch';
  static const channelMismatch = 'update_channel_mismatch';
  static const replay = 'update_replay';
  static const size = 'update_size';
  static const checksum = 'update_checksum';
  static const storage = 'update_storage';
  static const cancelled = 'update_cancelled';
  static const coreBusy = 'update_core_busy';
  static const installUnsupported = 'update_install_unsupported';
  static const installPermission = 'update_install_permission';
  static const installAborted = 'update_install_aborted';
  static const installFailed = 'update_install_failed';
  static const packageMismatch = 'update_package_mismatch';
  static const signerMismatch = 'update_signer_mismatch';
  static const versionCode = 'update_version_code';
  static const archiveUnsafe = 'update_archive_unsafe';

  static const all = {
    unavailable, network, http, redirect, manifestInvalid, unknownKey, //
    signature, appMismatch, channelMismatch, replay, size, checksum,
    storage, cancelled, coreBusy, installUnsupported, installPermission,
    installAborted, installFailed, packageMismatch, signerMismatch,
    versionCode, archiveUnsafe,
  };
}

final class AppUpdateFailure implements Exception {
  const AppUpdateFailure(this.code);
  final String code;
  @override
  String toString() => 'AppUpdateFailure($code)';
}

/// Unpadded base64url, the only encoding of the envelope fields.
String appUpdateBase64(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

final _base64Url = RegExp(r'^[A-Za-z0-9_-]*$');

Uint8List appUpdateBase64Decode(String value) {
  if (!_base64Url.hasMatch(value) || value.length % 4 == 1) {
    throw const AppUpdateFailure(AppUpdateCode.manifestInvalid);
  }
  return base64Url.decode(base64Url.normalize(value));
}

/// A public key the build trusts; [publicKey] is unpadded base64url of the
/// 32-byte Ed25519 key. Public by nature: committed with the sources.
final class AppUpdateTrustedKey {
  const AppUpdateTrustedKey(this.keyId, this.publicKey);
  final String keyId;
  final String publicKey;
}

final class AppUpdateSignature {
  const AppUpdateSignature(this.keyId, this.signature);
  final String keyId;
  final Uint8List signature;
}

/// The signed file: payload bytes are verified before they are parsed.
final class AppUpdateEnvelope {
  AppUpdateEnvelope(this.payloadBytes, List<AppUpdateSignature> signatures)
    : signatures = List.unmodifiable(signatures);
  final Uint8List payloadBytes;
  final List<AppUpdateSignature> signatures;

  static Uint8List signedMessage(List<int> payload) => Uint8List.fromList([
    ...ascii.encode(appUpdateSignaturePrefix),
    0,
    ...payload,
  ]);

  static AppUpdateEnvelope decode(List<int> bytes) {
    if (bytes.length > appUpdateManifestMaxBytes) {
      throw const AppUpdateFailure(AppUpdateCode.size);
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const AppUpdateFailure(AppUpdateCode.manifestInvalid);
    }
    const invalid = AppUpdateFailure(AppUpdateCode.manifestInvalid);
    if (json is! Map<String, Object?> ||
        json.length != 3 ||
        json['format'] != appUpdateFormat) {
      throw invalid;
    }
    final list = json['signatures'];
    final payload = json['payload'];
    if (list is! List<Object?> ||
        list.isEmpty ||
        list.length > appUpdateMaxSignatures ||
        payload is! String ||
        payload.isEmpty) {
      throw invalid;
    }
    final signatures = <AppUpdateSignature>[];
    for (final item in list) {
      if (item is! Map<String, Object?> || item.length != 2) throw invalid;
      final keyId = item['keyId'];
      final sig = item['sig'];
      if (keyId is! String ||
          !appUpdateKeyId.hasMatch(keyId) ||
          sig is! String ||
          signatures.any((s) => s.keyId == keyId)) {
        throw invalid;
      }
      final bytes = appUpdateBase64Decode(sig);
      if (bytes.length != 64) throw invalid;
      signatures.add(AppUpdateSignature(keyId, bytes));
    }
    return AppUpdateEnvelope(appUpdateBase64Decode(payload), signatures);
  }

  Uint8List encode() => utf8.encode(
    jsonEncode({
      'format': appUpdateFormat,
      'signatures': [
        for (final s in signatures)
          {'keyId': s.keyId, 'sig': appUpdateBase64(s.signature)},
      ],
      'payload': appUpdateBase64(payloadBytes),
    }),
  );
}

/// Ed25519 verification port; implemented outside the domain.
abstract interface class AppUpdateSignatureVerifier {
  Future<bool> verify({
    required List<int> message,
    required List<int> signature,
    required List<int> publicKey,
  });
}

/// Verifies the envelope with the trusted keys, then parses the payload.
Future<AppUpdatePayload> verifyAppUpdateManifest(
  List<int> bytes, {
  required List<AppUpdateTrustedKey> trustedKeys,
  required AppUpdateSignatureVerifier verifier,
}) async {
  if (trustedKeys.isEmpty) {
    throw const AppUpdateFailure(AppUpdateCode.unavailable);
  }
  final envelope = AppUpdateEnvelope.decode(bytes);
  final message = AppUpdateEnvelope.signedMessage(envelope.payloadBytes);
  var known = false;
  var valid = false;
  for (final signature in envelope.signatures) {
    for (final key in trustedKeys.where((k) => k.keyId == signature.keyId)) {
      known = true;
      final Uint8List publicKey;
      try {
        publicKey = appUpdateBase64Decode(key.publicKey);
      } on AppUpdateFailure {
        continue;
      }
      if (publicKey.length == 32 &&
          await verifier.verify(
            message: message,
            signature: signature.signature,
            publicKey: publicKey,
          )) {
        valid = true;
      }
    }
    if (valid) break;
  }
  if (!known) throw const AppUpdateFailure(AppUpdateCode.unknownKey);
  if (!valid) throw const AppUpdateFailure(AppUpdateCode.signature);
  return parseAppUpdatePayload(envelope.payloadBytes);
}

/// Parses verified bytes and checks the rules a schema cannot express.
AppUpdatePayload parseAppUpdatePayload(List<int> bytes) {
  try {
    final payload = AppUpdatePayload.fromJson(jsonDecode(utf8.decode(bytes)));
    validateAppUpdatePayload(payload);
    return payload;
  } on FormatException {
    throw const AppUpdateFailure(AppUpdateCode.manifestInvalid);
  }
}

/// `vX.Y.Z` releases are numbered X*10000 + Y*100 + Z.
int appUpdateBuildOf(String version) {
  final parts = version.split('.').map(int.parse).toList();
  return parts[0] * 10000 + parts[1] * 100 + parts[2];
}

void validateAppUpdatePayload(AppUpdatePayload payload) {
  const invalid = FormatException('update_manifest_invalid');
  if (payload.tag != 'v${payload.version}' ||
      payload.build != appUpdateBuildOf(payload.version) ||
      payload.minSupportedBuild > payload.build ||
      DateTime.tryParse(payload.releasedAt) == null ||
      !appUpdateChangelogValid(payload.changelog, payload.version)) {
    throw invalid;
  }
  final pairs = <String>{};
  final names = <String>{};
  for (final artifact in payload.artifacts) {
    final android = artifact.kind.isAndroid;
    if (!appUpdateKindArches[artifact.kind]!.contains(artifact.arch) ||
        !pairs.add('${artifact.kind.wire}/${artifact.arch}') ||
        !names.add(artifact.fileName) ||
        !artifact.fileName.startsWith('AntiRKN-${payload.tag}-') ||
        artifact.url !=
            '$appUpdateArtifactUrlPrefix${payload.tag}/${artifact.fileName}' ||
        android != (artifact.versionCode != null) ||
        (android &&
            artifact.versionCode !=
                payload.build * 10 + appUpdateAndroidAbiIds[artifact.arch]!) ||
        android != (artifact.certSha256 != null)) {
      throw invalid;
    }
  }
}

enum AppUpdatePlatform { android, windows, linux }

/// How far this installation can take an update by itself.
enum AppUpdateInstallMode {
  /// Download, verify and install from the app.
  automatic,

  /// Download and verify; the user replaces the files (portable builds).
  downloadOnly,

  /// Only point to the release page.
  notifyOnly,
}

/// What is installed now. [installKind] comes from the `install-kind` marker
/// on desktop and is [AppUpdateKind.androidApk] on Android.
final class InstalledApp {
  const InstalledApp({
    required this.platform,
    required this.build,
    required this.version,
    this.channel = 'stable',
    this.installKind,
    this.supportedAbis = const [],
    this.androidAbi,
  });
  final AppUpdatePlatform platform;
  final int build;

  /// `X.Y.Z` of the running build, for the changelog since it.
  final String version;
  final String channel;
  final AppUpdateKind? installKind;

  /// Android ABIs in the device's order of preference.
  final List<String> supportedAbis;

  /// The installed Android variant (`versionCode % 10`), kept on update.
  final String? androidAbi;

  /// Installed build and variant of an Android versionCode
  /// (`build * 10 + abiId`); null variant for an unknown id.
  static (int, String?) fromAndroidVersionCode(int versionCode) {
    final id = versionCode % 10;
    final abi = appUpdateAndroidAbiIds.entries
        .where((e) => e.value == id)
        .firstOrNull
        ?.key;
    return (versionCode ~/ 10, abi);
  }
}

/// The artifact this installation would install, or null.
AppUpdateArtifact? selectAppUpdateArtifact(
  AppUpdatePayload payload,
  InstalledApp installed,
) {
  AppUpdateArtifact? find(AppUpdateKind kind, String arch) => payload.artifacts
      .where((a) => a.kind == kind && a.arch == arch)
      .firstOrNull;
  final kind = installed.installKind;
  switch (installed.platform) {
    case AppUpdatePlatform.android:
      if (kind != AppUpdateKind.androidApk) return null;
      // Keep the installed ABI variant; universal only when it is missing.
      final own = installed.androidAbi;
      for (final abi in own == null ? installed.supportedAbis : [own]) {
        final artifact = find(kind!, abi);
        if (artifact != null) return artifact;
      }
      return find(AppUpdateKind.androidApk, 'universal');
    case AppUpdatePlatform.windows:
      if (kind != AppUpdateKind.windowsInstaller &&
          kind != AppUpdateKind.windowsPortable) {
        return null;
      }
      return find(kind!, 'x64');
    case AppUpdatePlatform.linux:
      if (kind != AppUpdateKind.linuxAppimage &&
          kind != AppUpdateKind.linuxTarball) {
        return null;
      }
      return find(kind!, 'x64');
  }
}

sealed class UpdateDecision {
  const UpdateDecision();
}

final class UpdateUpToDate extends UpdateDecision {
  const UpdateUpToDate(this.payload);
  final AppUpdatePayload payload;
}

final class UpdateOffered extends UpdateDecision {
  const UpdateOffered({
    required this.payload,
    required this.artifact,
    required this.mode,
    required this.mandatory,
  });
  final AppUpdatePayload payload;

  /// Null when only the release page can be offered.
  final AppUpdateArtifact? artifact;
  final AppUpdateInstallMode mode;

  /// The installed build is below the release's minimum supported build.
  final bool mandatory;
}

final class UpdateRejected extends UpdateDecision {
  const UpdateRejected(this.code);
  final String code;
}

/// The update policy: same app and channel, strictly newer than what is
/// installed, never older than the newest manifest already seen (a replayed
/// old manifest cannot move the client backwards), and an artifact that
/// matches this installation.
UpdateDecision decideAppUpdate({
  required AppUpdatePayload payload,
  required InstalledApp installed,
  required int maxSeenBuild,
}) {
  if (payload.appId != appUpdateAppId) {
    return const UpdateRejected(AppUpdateCode.appMismatch);
  }
  if (payload.channel != installed.channel) {
    return const UpdateRejected(AppUpdateCode.channelMismatch);
  }
  if (payload.build < maxSeenBuild) {
    return const UpdateRejected(AppUpdateCode.replay);
  }
  if (payload.build <= installed.build) return UpdateUpToDate(payload);
  final artifact = selectAppUpdateArtifact(payload, installed);
  final mode = artifact == null
      ? AppUpdateInstallMode.notifyOnly
      : artifact.kind == AppUpdateKind.windowsPortable
      ? AppUpdateInstallMode.downloadOnly
      : AppUpdateInstallMode.automatic;
  return UpdateOffered(
    payload: payload,
    artifact: artifact,
    mode: mode,
    mandatory: installed.build < payload.minSupportedBuild,
  );
}

/// What the client remembers between runs.
final class AppUpdateRecord {
  const AppUpdateRecord({
    this.maxSeenBuild = 0,
    this.confirmedBuild = 0,
    this.pendingBuild,
  });
  final int maxSeenBuild;
  final int confirmedBuild;

  /// The build an install was started for, until a start confirms it.
  final int? pendingBuild;

  AppUpdateRecord copyWith({
    int? maxSeenBuild,
    int? confirmedBuild,
    int? Function()? pendingBuild,
  }) => AppUpdateRecord(
    maxSeenBuild: maxSeenBuild ?? this.maxSeenBuild,
    confirmedBuild: confirmedBuild ?? this.confirmedBuild,
    pendingBuild: pendingBuild == null ? this.pendingBuild : pendingBuild(),
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'maxSeenBuild': maxSeenBuild,
    'confirmedBuild': confirmedBuild,
    if (pendingBuild != null) 'pendingBuild': pendingBuild,
  };

  static AppUpdateRecord fromJson(Object? value) {
    int read(Object? v) => v is int && v >= 0 && v <= 2100000000
        ? v
        : throw const FormatException('update_state');
    if (value is! Map<String, Object?> || value['version'] != 1) {
      throw const FormatException('update_state');
    }
    final pending = value['pendingBuild'];
    return AppUpdateRecord(
      maxSeenBuild: read(value['maxSeenBuild']),
      confirmedBuild: read(value['confirmedBuild']),
      pendingBuild: pending == null ? null : read(pending),
    );
  }
}

abstract interface class AppUpdateStateStore {
  Future<AppUpdateRecord> read();
  Future<void> write(AppUpdateRecord record);
}

/// Fetches the raw envelope bytes of a channel's latest manifest.
abstract interface class AppUpdateFeed {
  Future<Uint8List> fetch(String channel, CancellationToken token);
}

/// Downloads an artifact into the update cache and returns its path only
/// after its size and SHA-256 match the signed manifest.
abstract interface class AppUpdateDownloader {
  Future<String> download(
    AppUpdateArtifact artifact, {
    required void Function(int received, int total) onProgress,
    required CancellationToken token,
  });
}

enum AppUpdateInstallResult {
  /// The new version was launched and this process is exiting.
  restarting,

  /// The system installer took over (Android confirmation, Windows setup).
  handedToSystem,

  /// The user has to allow installs first; a system screen was opened.
  permissionRequired,
}

/// The platform part: what can be installed, package checks and the swap.
abstract interface class AppUpdateInstaller {
  /// Narrows the policy mode to what this installation allows right now
  /// (writable location, marker, platform support).
  Future<AppUpdateInstallMode> mode(AppUpdateArtifact artifact);

  /// Platform checks of a downloaded file (Android package name, version
  /// code and signer; desktop re-hash). Throws [AppUpdateFailure].
  Future<void> verify(String path, AppUpdateArtifact artifact);

  Future<AppUpdateInstallResult> install(
    String path,
    AppUpdateArtifact artifact,
    AppUpdatePayload payload,
  );

  /// Shows a downloaded file to the user (download-only builds).
  Future<void> reveal(String path);

  /// Called on start: [confirmed] when the running build is the one an
  /// install was started for; removes or keeps the previous copy.
  Future<void> finishStartup({required bool confirmed});
}

/// Keeps the bundled Mihomo worker from running while files are replaced.
abstract interface class CoreLifecycle {
  /// Blocks new runs and waits for active ones; false (and unblocked) when
  /// they did not finish within [timeout].
  Future<bool> quiesce(Duration timeout);

  void resume();
}

sealed class AppUpdateState {
  const AppUpdateState();
}

final class AppUpdateIdle extends AppUpdateState {
  const AppUpdateIdle();
}

/// This build has no trusted update keys.
final class AppUpdateUnavailable extends AppUpdateState {
  const AppUpdateUnavailable();
}

final class AppUpdateChecking extends AppUpdateState {
  const AppUpdateChecking();
}

final class AppUpdateUpToDate extends AppUpdateState {
  const AppUpdateUpToDate(this.version);
  final String version;
}

/// An offered update with what the app may do about it.
final class AppUpdateAvailable extends AppUpdateState {
  const AppUpdateAvailable(this.offer);
  final UpdateOffered offer;
}

final class AppUpdateDownloading extends AppUpdateState {
  const AppUpdateDownloading(this.offer, this.received, this.total);
  final UpdateOffered offer;
  final int received;
  final int total;
  double get progress => total == 0 ? 0 : (received / total).clamp(0, 1);
}

final class AppUpdateVerifying extends AppUpdateState {
  const AppUpdateVerifying(this.offer);
  final UpdateOffered offer;
}

final class AppUpdateReadyToInstall extends AppUpdateState {
  const AppUpdateReadyToInstall(
    this.offer,
    this.path, {
    this.permissionRequired = false,
  });
  final UpdateOffered offer;
  final String path;
  final bool permissionRequired;
}

final class AppUpdateInstalling extends AppUpdateState {
  const AppUpdateInstalling(this.offer);
  final UpdateOffered offer;
}

final class AppUpdateFailed extends AppUpdateState {
  const AppUpdateFailed(this.code, {this.offer});
  final String code;

  /// Still offered after a download or install failure, for a retry.
  final UpdateOffered? offer;
}

/// The update use case. One operation at a time; state changes are
/// published on [states]. Adapters are injected, so the flow is testable.
final class AppUpdateCoordinator {
  AppUpdateCoordinator({
    required this.installed,
    required this.trustedKeys,
    required this.feed,
    required this.verifier,
    required this.downloader,
    required this.installer,
    required this.store,
    required this.core,
    this.coreTimeout = const Duration(seconds: 30),
  });

  final InstalledApp installed;
  final List<AppUpdateTrustedKey> trustedKeys;
  final AppUpdateFeed feed;
  final AppUpdateSignatureVerifier verifier;
  final AppUpdateDownloader downloader;
  final AppUpdateInstaller installer;
  final AppUpdateStateStore store;
  final CoreLifecycle core;
  final Duration coreTimeout;

  final _states = StreamController<AppUpdateState>.broadcast(sync: true);
  late AppUpdateState _state = trustedKeys.isEmpty
      ? const AppUpdateUnavailable()
      : const AppUpdateIdle();
  CancellationToken? _token;
  bool _busy = false;

  AppUpdateState get state => _state;
  Stream<AppUpdateState> get states => _states.stream;
  bool get busy => _busy;

  void _emit(AppUpdateState state) {
    _state = state;
    _states.add(state);
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    _busy = true;
    try {
      await work();
    } finally {
      _busy = false;
      _token = null;
    }
  }

  /// Records the running build and confirms a finished install.
  Future<void> confirmStartup() => _run(() async {
    try {
      final record = await store.read();
      final pending = record.pendingBuild;
      if (pending != null) {
        await installer.finishStartup(confirmed: installed.build >= pending);
      }
      await store.write(
        record.copyWith(
          maxSeenBuild: _max(record.maxSeenBuild, installed.build),
          confirmedBuild: _max(record.confirmedBuild, installed.build),
          pendingBuild: () => null,
        ),
      );
    } catch (_) {
      // A failed confirmation is retried on the next start.
    }
  });

  Future<void> check() => _run(() async {
    if (trustedKeys.isEmpty) return _emit(const AppUpdateUnavailable());
    final token = _token = CancellationToken();
    _emit(const AppUpdateChecking());
    try {
      final bytes = await feed.fetch(installed.channel, token);
      final payload = await verifyAppUpdateManifest(
        bytes,
        trustedKeys: trustedKeys,
        verifier: verifier,
      );
      final record = await store.read();
      final decision = decideAppUpdate(
        payload: payload,
        installed: installed,
        maxSeenBuild: _max(record.maxSeenBuild, installed.build),
      );
      switch (decision) {
        case UpdateRejected(:final code):
          _emit(AppUpdateFailed(code));
        case UpdateUpToDate(:final payload):
          await _remember(record, payload.build);
          _emit(AppUpdateUpToDate(payload.version));
        case UpdateOffered():
          await _remember(record, payload.build);
          var offer = decision;
          final artifact = decision.artifact;
          if (artifact != null &&
              decision.mode != AppUpdateInstallMode.notifyOnly) {
            final allowed = await installer.mode(artifact);
            offer = UpdateOffered(
              payload: decision.payload,
              artifact: allowed == AppUpdateInstallMode.notifyOnly
                  ? null
                  : artifact,
              mode: _narrow(decision.mode, allowed),
              mandatory: decision.mandatory,
            );
          }
          _emit(AppUpdateAvailable(offer));
      }
    } catch (error) {
      _emit(AppUpdateFailed(_code(error, token)));
    }
  });

  Future<void> download() => _run(() async {
    final current = _state;
    final offer = switch (current) {
      AppUpdateAvailable(:final offer) => offer,
      AppUpdateFailed(:final offer?) => offer,
      _ => null,
    };
    final artifact = offer?.artifact;
    if (offer == null ||
        artifact == null ||
        offer.mode == AppUpdateInstallMode.notifyOnly) {
      return;
    }
    final token = _token = CancellationToken();
    _emit(AppUpdateDownloading(offer, 0, artifact.size));
    try {
      final path = await downloader.download(
        artifact,
        token: token,
        onProgress: (received, total) {
          if (!token.isCancelled) {
            _emit(AppUpdateDownloading(offer, received, total));
          }
        },
      );
      token.check();
      _emit(AppUpdateVerifying(offer));
      await installer.verify(path, artifact);
      _emit(AppUpdateReadyToInstall(offer, path));
    } catch (error) {
      if (token.isCancelled) return _emit(AppUpdateAvailable(offer));
      _emit(AppUpdateFailed(_code(error, token), offer: offer));
    }
  });

  Future<void> install() => _run(() async {
    final current = _state;
    if (current is! AppUpdateReadyToInstall) return;
    final offer = current.offer;
    final artifact = offer.artifact!;
    if (offer.mode == AppUpdateInstallMode.downloadOnly) {
      try {
        await installer.reveal(current.path);
      } catch (_) {}
      return;
    }
    if (offer.mode != AppUpdateInstallMode.automatic) return;
    _emit(AppUpdateInstalling(offer));
    final desktop = installed.platform != AppUpdatePlatform.android;
    var quiesced = false;
    try {
      if (desktop) {
        quiesced = await core.quiesce(coreTimeout);
        if (!quiesced) throw const AppUpdateFailure(AppUpdateCode.coreBusy);
      }
      final record = await store.read();
      await store.write(
        record.copyWith(pendingBuild: () => offer.payload.build),
      );
      final result = await installer.install(
        current.path,
        artifact,
        offer.payload,
      );
      if (result == AppUpdateInstallResult.permissionRequired) {
        await store.write(record.copyWith(pendingBuild: () => null));
        if (quiesced) core.resume();
        return _emit(
          AppUpdateReadyToInstall(
            offer,
            current.path,
            permissionRequired: true,
          ),
        );
      }
      // Restarting or handed over: the process ends with the install. A
      // later start confirms the result by reading the running build.
    } catch (error) {
      try {
        final record = await store.read();
        await store.write(record.copyWith(pendingBuild: () => null));
      } catch (_) {}
      if (quiesced) core.resume();
      _emit(AppUpdateFailed(_code(error, null), offer: offer));
    }
  });

  /// Cancels a running check or download; installs cannot be cancelled.
  void cancel() {
    if (_state is AppUpdateInstalling) return;
    _token?.cancel();
  }

  Future<void> dispose() => _states.close();

  Future<void> _remember(AppUpdateRecord record, int build) async {
    if (build > record.maxSeenBuild) {
      await store.write(record.copyWith(maxSeenBuild: build));
    }
  }

  static AppUpdateInstallMode _narrow(
    AppUpdateInstallMode policy,
    AppUpdateInstallMode allowed,
  ) => AppUpdateInstallMode.values[_max(policy.index, allowed.index)];

  static int _max(int a, int b) => a > b ? a : b;

  static String _code(Object error, CancellationToken? token) {
    if (token?.isCancelled ?? false) return AppUpdateCode.cancelled;
    if (error is AppUpdateFailure) return error.code;
    return AppUpdateCode.installFailed;
  }
}
