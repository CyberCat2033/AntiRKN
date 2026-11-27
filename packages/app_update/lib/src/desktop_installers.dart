import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:antirkn_domain/antirkn_domain.dart';

import 'ed25519.dart';
import 'github_http.dart';
import 'tar_extract.dart';

/// Process and OS access of the desktop installers, replaceable in tests.
class DesktopSystem {
  const DesktopSystem();

  Future<void> startDetached(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.detached,
      environment: environment,
      includeParentEnvironment: environment == null,
      workingDirectory: workingDirectory,
    );
  }

  /// Runs a short command; only the exit code and stdout are kept.
  Future<(int, String)> run(String executable, List<String> arguments) async {
    final result = await Process.run(
      executable,
      arguments,
    ).timeout(const Duration(seconds: 10));
    return (result.exitCode, '${result.stdout}');
  }

  Never exitApp() => exit(0);

  /// The real user id of this process (Linux), null when unknown.
  Future<int?> currentUid() async {
    try {
      final status = await File('/proc/self/status').readAsLines();
      final line = status.firstWhere((l) => l.startsWith('Uid:'));
      return int.tryParse(line.split(RegExp(r'\s+'))[1]);
    } catch (_) {
      return null;
    }
  }

  Future<int?> ownerUid(String path) async {
    try {
      final (code, out) = await run('stat', ['-c', '%u', '--', path]);
      return code == 0 ? int.tryParse(out.trim()) : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, String> get environment => Platform.environment;
}

/// Reads the `install-kind` marker next to the executable.
Future<AppUpdateKind?> readInstallKind(String executable) async {
  try {
    final file = File(
      '${File(executable).parent.path}/$appUpdateInstallKindFile',
    );
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > 64) {
      return null;
    }
    final kind = AppUpdateKind.parse((await file.readAsString()).trim());
    return kind == null || kind.isAndroid ? null : kind;
  } catch (_) {
    return null;
  }
}

/// Windows and Linux installs. The kind comes from the `install-kind` marker;
/// AppImage additionally needs `$APPIMAGE`. Whatever cannot be replaced
/// safely by the running user (root-owned, symlinked, read-only) is
/// narrowed to notify-only.
final class DesktopAppUpdateInstaller implements AppUpdateInstaller {
  DesktopAppUpdateInstaller({
    required this.installKind,
    required this.executable,
    this.system = const DesktopSystem(),
    this.prepareExit,
    this.prepareExitTimeout = const Duration(seconds: 10),
    bool? linux,
    bool? windows,
  }) : linux = linux ?? Platform.isLinux,
       windows = windows ?? Platform.isWindows;

  /// Host platform; injectable so the Linux paths are testable anywhere.
  final bool linux;
  final bool windows;

  final AppUpdateKind? installKind;

  /// The running executable, resolved (`Platform.resolvedExecutable`).
  final String executable;
  final DesktopSystem system;

  /// The app's own shutdown (sync flush, workspace database close), awaited
  /// at most [prepareExitTimeout] before the hand-over and exit.
  final Future<void> Function()? prepareExit;
  final Duration prepareExitTimeout;

  String get _installDirectory => File(executable).parent.path;
  String get _journal => '$_installDirectory.update-journal.json';

  @override
  Future<AppUpdateInstallMode> mode(AppUpdateArtifact artifact) async {
    if (artifact.kind != installKind) return AppUpdateInstallMode.notifyOnly;
    switch (artifact.kind) {
      case AppUpdateKind.windowsInstaller:
        return windows
            ? AppUpdateInstallMode.automatic
            : AppUpdateInstallMode.notifyOnly;
      case AppUpdateKind.windowsPortable:
        return AppUpdateInstallMode.downloadOnly;
      case AppUpdateKind.linuxAppimage:
        return await _appImage() != null
            ? AppUpdateInstallMode.automatic
            : AppUpdateInstallMode.notifyOnly;
      case AppUpdateKind.linuxTarball:
        return await _tarballReplaceable()
            ? AppUpdateInstallMode.automatic
            : AppUpdateInstallMode.notifyOnly;
      case AppUpdateKind.androidApk:
        return AppUpdateInstallMode.notifyOnly;
    }
  }

  @override
  Future<void> verify(String path, AppUpdateArtifact artifact) async {
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file ||
          await File(path).length() != artifact.size) {
        throw const AppUpdateFailure(AppUpdateCode.size);
      }
      if (await sha256OfFile(path) != artifact.sha256) {
        throw const AppUpdateFailure(AppUpdateCode.checksum);
      }
    } on FileSystemException {
      throw const AppUpdateFailure(AppUpdateCode.storage);
    }
  }

  @override
  Future<AppUpdateInstallResult> install(
    String path,
    AppUpdateArtifact artifact,
    AppUpdatePayload payload,
  ) async {
    if (await mode(artifact) != AppUpdateInstallMode.automatic) {
      throw const AppUpdateFailure(AppUpdateCode.installUnsupported);
    }
    try {
      switch (artifact.kind) {
        case AppUpdateKind.windowsInstaller:
          await verify(path, artifact);
          return _handOver(path, const [
            '/VERYSILENT',
            '/SUPPRESSMSGBOXES',
            '/NORESTART',
            '/CLOSEAPPLICATIONS',
            '/relaunch=1',
          ]);
        case AppUpdateKind.linuxAppimage:
          final target = await _appImage();
          if (target == null) {
            throw const AppUpdateFailure(AppUpdateCode.installUnsupported);
          }
          await _replaceAppImage(path, artifact, target);
          return _handOver(target, const [], environment: _cleanEnvironment());
        case AppUpdateKind.linuxTarball:
          await _replaceTarball(path, artifact, payload);
          return _handOver(
            executable,
            const [],
            workingDirectory: _installDirectory,
          );
        case AppUpdateKind.windowsPortable:
        case AppUpdateKind.androidApk:
          throw const AppUpdateFailure(AppUpdateCode.installUnsupported);
      }
    } on AppUpdateFailure {
      rethrow;
    } on FileSystemException {
      throw const AppUpdateFailure(AppUpdateCode.storage);
    } on ProcessException {
      throw const AppUpdateFailure(AppUpdateCode.installFailed);
    }
  }

  /// Closes the app's state, launches [executable] and exits. Past this
  /// point the workspace is closed, so a failed launch still exits: the
  /// files are already replaced (or the old version stays installed) and
  /// the next start confirms the build that actually runs.
  Future<Never> _handOver(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    try {
      await prepareExit?.call().timeout(prepareExitTimeout);
    } catch (_) {
      // A slow or failing shutdown must not keep the update from finishing.
    }
    try {
      await system.startDetached(
        executable,
        arguments,
        environment: environment,
        workingDirectory: workingDirectory,
      );
    } finally {
      system.exitApp();
    }
  }

  @override
  Future<void> reveal(String path) async {
    final directory = File(path).parent.path;
    if (windows) {
      await system.startDetached('explorer.exe', ['/select,', path]);
    } else {
      await system.startDetached('xdg-open', [directory]);
    }
  }

  @override
  Future<void> finishStartup({required bool confirmed}) async {
    switch (installKind) {
      case AppUpdateKind.linuxAppimage:
        final target = await _appImage(requireWritable: false);
        if (target != null) await _deleteFile('$target.old');
      case AppUpdateKind.linuxTarball:
        if (confirmed) await _deleteTree('$_installDirectory.old');
        await _deleteTree('$_installDirectory.new');
        await _deleteFile(_journal);
      default:
        break;
    }
  }

  /// `$APPIMAGE` when it is a regular file of this (non-root) user in a
  /// writable directory; the swap then stays in that real directory.
  Future<String?> _appImage({bool requireWritable = true}) async {
    if (!linux) return null;
    final path = system.environment['APPIMAGE'];
    if (path == null || !path.startsWith('/')) return null;
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    if (!requireWritable) return path;
    if (!await _ownedByUser(path)) return null;
    return await _writable(File(path).parent.path) ? path : null;
  }

  Future<bool> _tarballReplaceable() async {
    if (!linux) return false;
    final directory = _installDirectory;
    if (await FileSystemEntity.type(directory, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    return await _ownedByUser(directory) &&
        await _writable(directory) &&
        await _writable(Directory(directory).parent.path);
  }

  Future<bool> _ownedByUser(String path) async {
    final uid = await system.currentUid();
    final owner = await system.ownerUid(path);
    return uid != null && owner != null && owner != 0 && owner == uid;
  }

  static Future<bool> _writable(String directory) async {
    final probe = File('$directory/.antirkn-update-probe-$pid');
    try {
      await probe.create(exclusive: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _replaceAppImage(
    String source,
    AppUpdateArtifact artifact,
    String target,
  ) async {
    final part = '$target.part';
    final backup = '$target.old';
    try {
      await _deleteFile(part);
      await _copyVerified(source, part, sha256: artifact.sha256);
      await _chmod(part, '755');
      // The previous AppImage stays as .old until the new one confirms a
      // start; the target path is replaced atomically and never missing.
      await _deleteFile('$backup.part');
      await _copyVerified(target, '$backup.part');
      await File('$backup.part').rename(backup);
      await File(part).rename(target);
    } catch (_) {
      await _deleteFile(part);
      await _deleteFile('$backup.part');
      rethrow;
    }
  }

  /// The tarball holds one top-level `AntiRKN-vX.Y.Z-linux-x64/` directory
  /// with the bundle and its `install-kind` marker. It is extracted into the
  /// sibling `<install>.new`, the install directory is renamed to `.old`
  /// (kept until the new build confirms a start) and the new tree takes its
  /// place. A journal next to it records the step for the next start.
  Future<void> _replaceTarball(
    String source,
    AppUpdateArtifact artifact,
    AppUpdatePayload payload,
  ) async {
    final current = _installDirectory;
    final container = '$current.new';
    final top = 'AntiRKN-${payload.tag}-linux-x64';
    final fresh = '$container/$top';
    final previous = '$current.old';
    final name = File(executable).uri.pathSegments.last;
    await verify(source, artifact);
    await _writeJournal('extract', payload.build);
    await _deleteTree(container);
    try {
      final executables = await extractTarGz(source, container);
      final entries = await Directory(container).list().toList();
      if (entries.length != 1 ||
          entries.single is! Directory ||
          entries.single.path != fresh ||
          await FileSystemEntity.type('$fresh/$name', followLinks: false) !=
              FileSystemEntityType.file ||
          await readInstallKind('$fresh/$name') != AppUpdateKind.linuxTarball) {
        throw const AppUpdateFailure(AppUpdateCode.archiveUnsafe);
      }
      for (var i = 0; i < executables.length; i += 64) {
        await _chmod(
          null,
          '755',
          paths: [
            for (final e in executables.skip(i).take(64)) '$container/$e',
          ],
        );
      }
      await _deleteTree(previous);
      await _writeJournal('swap', payload.build);
      await Directory(current).rename(previous);
      try {
        await Directory(fresh).rename(current);
      } catch (_) {
        await Directory(previous).rename(current);
        rethrow;
      }
      await _writeJournal('done', payload.build);
      await _deleteTree(container);
    } catch (_) {
      await _deleteTree(container);
      await _deleteFile(_journal);
      rethrow;
    }
  }

  Future<void> _writeJournal(String step, int build) async {
    final file = File('$_journal.part');
    await file.writeAsString(
      jsonEncode({'version': 1, 'step': step, 'build': build}),
      flush: true,
    );
    await file.rename(_journal);
  }

  Future<void> _chmod(String? path, String mode, {List<String>? paths}) async {
    final targets = paths ?? [path!];
    if (targets.isEmpty) return;
    final (code, _) = await system.run('chmod', [mode, '--', ...targets]);
    if (code != 0) throw const AppUpdateFailure(AppUpdateCode.installFailed);
  }

  /// Copies durably; with [sha256] the written bytes must match it.
  static Future<void> _copyVerified(
    String source,
    String target, {
    String? sha256,
  }) async {
    final hash = Sha256Stream();
    final output = await File(target).open(mode: FileMode.writeOnly);
    try {
      await for (final chunk in File(source).openRead()) {
        hash.add(chunk);
        await output.writeFrom(chunk);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (sha256 != null && hash.close() != sha256) {
      await _deleteFile(target);
      throw const AppUpdateFailure(AppUpdateCode.checksum);
    }
  }

  static Future<void> _deleteFile(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) await File(path).delete();
    if (type == FileSystemEntityType.link) await Link(path).delete();
  }

  /// Deletes a directory tree without following links in it.
  static Future<void> _deleteTree(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type != FileSystemEntityType.notFound) {
      await _deleteFile(path);
    }
  }

  /// The new AppImage sets these itself; inheriting them from the old
  /// mount would point it at a directory that disappears on exit.
  Map<String, String> _cleanEnvironment() {
    final env = Map.of(system.environment);
    final appDir = env['APPDIR'];
    for (final key in const ['APPDIR', 'APPIMAGE', 'ARGV0', 'OWD']) {
      env.remove(key);
    }
    final library = env['LD_LIBRARY_PATH'];
    if (appDir != null && library != null && library.contains(appDir)) {
      env.remove('LD_LIBRARY_PATH');
    }
    return env;
  }
}
