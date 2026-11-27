import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:antirkn_app_update/antirkn_app_update.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:test/test.dart';

import 'support.dart';

/// One ustar entry; [type] '0' file, '5' dir, '2' symlink, '1' hard link.
Uint8List entry(
  String name, {
  String type = '0',
  List<int> data = const [],
  int mode = 420,
  String link = '',
}) {
  final header = Uint8List(512);
  void put(int offset, String value) =>
      header.setRange(offset, offset + value.length, utf8.encode(value));
  String octal(int value, int width) =>
      '${value.toRadixString(8).padLeft(width - 1, '0')}\u0000';
  put(0, name);
  put(100, octal(mode, 8));
  put(108, octal(0, 8));
  put(116, octal(0, 8));
  put(124, octal(data.length, 12));
  put(136, octal(0, 12));
  put(148, '        ');
  put(156, type);
  put(157, link);
  put(257, 'ustar\u000000');
  final sum = header.fold<int>(0, (a, b) => a + b);
  put(148, '${sum.toRadixString(8).padLeft(6, '0')}\u0000 ');
  final padded = Uint8List((data.length + 511) ~/ 512 * 512)..setAll(0, data);
  return Uint8List.fromList([...header, ...padded]);
}

List<int> tarGz(List<Uint8List> entries) =>
    gzip.encode([for (final e in entries) ...e, ...Uint8List(1024)]);

final class Exited implements Exception {}

final class FakeSystem extends DesktopSystem {
  FakeSystem(this.env, {this.owner = 1000});
  final Map<String, String> env;
  int owner;
  final started = <(String, List<String>, Map<String, String>?)>[];
  final events = <String>[];
  @override
  Map<String, String> get environment => env;
  @override
  Future<int?> currentUid() async => 1000;
  @override
  Future<int?> ownerUid(String path) async => owner;
  @override
  Future<void> startDetached(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    events.add('start');
    started.add((executable, arguments, environment));
  }

  @override
  Never exitApp() {
    events.add('exit');
    throw Exited();
  }
}

Future<AppUpdateArtifact> fileArtifact(AppUpdateKind kind, File file) async {
  final base = artifact(kind, 'x64');
  return AppUpdateArtifact(
    kind: kind,
    arch: 'x64',
    fileName: base.fileName,
    url: base.url,
    size: await file.length(),
    sha256: await sha256OfFile(file.path),
  );
}

void main() {
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('antirkn-desktop-'),
  );
  tearDown(() => root.delete(recursive: true));

  group('archive extraction', () {
    Future<String> extract(List<Uint8List> entries) async {
      final archive = File('${root.path}/a.tar.gz')
        ..writeAsBytesSync(tarGz(entries));
      try {
        await extractTarGz(archive.path, '${root.path}/out');
        return 'ok';
      } on AppUpdateFailure catch (error) {
        return error.code;
      }
    }

    test(
      'regular files and directories extract with exec bits reported',
      () async {
        final archive = File('${root.path}/a.tar.gz')
          ..writeAsBytesSync(
            tarGz([
              entry('./', type: '5'),
              entry('./top/', type: '5'),
              entry('./top/app', data: [1, 2], mode: 493),
              entry('./top/data/x.txt', data: utf8.encode('x')),
            ]),
          );
        final executables = await extractTarGz(
          archive.path,
          '${root.path}/out',
        );
        expect(executables, ['top/app']);
        expect(File('${root.path}/out/top/data/x.txt').readAsStringSync(), 'x');
      },
    );

    test('a real GNU tar archive extracts', () async {
      final source = Directory('${root.path}/src/AntiRKN-v1.2.3-linux-x64/lib')
        ..createSync(recursive: true);
      File('${source.path}/${'long' * 40}.so').writeAsStringSync('so');
      final result = await Process.run('tar', [
        '-czf',
        '${root.path}/real.tar.gz',
        '-C',
        '${root.path}/src',
        '.',
      ]);
      expect(result.exitCode, 0);
      await extractTarGz('${root.path}/real.tar.gz', '${root.path}/out');
      expect(
        File(
          '${root.path}/out/AntiRKN-v1.2.3-linux-x64/lib/${'long' * 40}.so',
        ).existsSync(),
        isTrue,
      );
    });

    test('unsafe entries are refused', () async {
      final cases = [
        [
          entry('../escape', data: [1]),
        ],
        [
          entry('/etc/passwd', data: [1]),
        ],
        [
          entry('a/../../escape', data: [1]),
        ],
        [entry('link', type: '2', link: '/etc')],
        [entry('hard', type: '1', link: 'a')],
        [entry('fifo', type: '6')],
        [
          entry('dup', data: [1]),
          entry('dup', data: [2]),
        ],
        [
          entry(r'a\b', data: [1]),
        ],
      ];
      for (final entries in cases) {
        if (Directory('${root.path}/out').existsSync()) {
          Directory('${root.path}/out').deleteSync(recursive: true);
        }
        expect(await extract(entries), AppUpdateCode.archiveUnsafe);
      }
      expect(File('${root.path}/escape').existsSync(), isFalse);
    });

    test('a corrupted header checksum and size caps are refused', () async {
      final bad = entry('a', data: [1]);
      bad[0] = 0x62;
      expect(await extract([bad]), AppUpdateCode.archiveUnsafe);
      final archive = File('${root.path}/big.tar.gz')
        ..writeAsBytesSync(tarGz([entry('a', data: List.filled(2000, 1))]));
      expect(
        () => extractTarGz(archive.path, '${root.path}/big', maxBytes: 1000),
        throwsA(isA<AppUpdateFailure>()),
      );
    });

    test('the destination must not exist yet', () async {
      Directory('${root.path}/out').createSync();
      expect(
        await extract([
          entry('a', data: [1]),
        ]),
        AppUpdateCode.archiveUnsafe,
      );
    });
  });

  group('Linux tarball', () {
    late Directory install;
    late FakeSystem system;
    late DesktopAppUpdateInstaller installer;

    setUp(() async {
      install = Directory('${root.path}/apps/AntiRKN')
        ..createSync(recursive: true);
      File('${install.path}/antirkn_manager').writeAsStringSync('old');
      File('${install.path}/install-kind').writeAsStringSync('linux-tarball\n');
      system = FakeSystem({});
      installer = DesktopAppUpdateInstaller(
        installKind: await readInstallKind('${install.path}/antirkn_manager'),
        executable: '${install.path}/antirkn_manager',
        system: system,
        linux: true,
        windows: false,
      );
    });

    Future<File> release(String top) async {
      final file = File('${root.path}/AntiRKN-v1.2.3-linux-x64.tar.gz')
        ..writeAsBytesSync(
          tarGz([
            entry('$top/', type: '5'),
            entry('$top/antirkn_manager', data: utf8.encode('new'), mode: 493),
            entry('$top/install-kind', data: utf8.encode('linux-tarball\n')),
          ]),
        );
      return file;
    }

    test('swaps the install directory, keeps .old until confirmed', () async {
      final file = await release('AntiRKN-v1.2.3-linux-x64');
      final a = await fileArtifact(AppUpdateKind.linuxTarball, file);
      expect(await installer.mode(a), AppUpdateInstallMode.automatic);
      await installer.verify(file.path, a);
      await expectLater(
        installer.install(file.path, a, payload()),
        throwsA(isA<Exited>()),
      );
      expect(File('${install.path}/antirkn_manager').readAsStringSync(), 'new');
      expect(
        File('${install.path}.old/antirkn_manager').readAsStringSync(),
        'old',
      );
      expect(Directory('${install.path}.new').existsSync(), isFalse);
      expect(system.started.single.$1, '${install.path}/antirkn_manager');
      expect(
        jsonDecode(
          File('${install.path}.update-journal.json').readAsStringSync(),
        ),
        containsPair('step', 'done'),
      );
      await installer.finishStartup(confirmed: true);
      expect(Directory('${install.path}.old').existsSync(), isFalse);
      expect(File('${install.path}.update-journal.json').existsSync(), isFalse);
    });

    test('a wrong top-level layout keeps the installation untouched', () async {
      final file = await release('something-else');
      final a = await fileArtifact(AppUpdateKind.linuxTarball, file);
      await expectLater(
        installer.install(file.path, a, payload()),
        throwsA(
          isA<AppUpdateFailure>().having(
            (e) => e.code,
            'code',
            AppUpdateCode.archiveUnsafe,
          ),
        ),
      );
      expect(File('${install.path}/antirkn_manager').readAsStringSync(), 'old');
      expect(Directory('${install.path}.new').existsSync(), isFalse);
      expect(system.started, isEmpty);
    });

    test('a tampered download fails verification', () async {
      final file = await release('AntiRKN-v1.2.3-linux-x64');
      final a = await fileArtifact(AppUpdateKind.linuxTarball, file);
      file.writeAsBytesSync([...file.readAsBytesSync(), 0]);
      await expectLater(
        installer.install(file.path, a, payload()),
        throwsA(isA<AppUpdateFailure>()),
      );
      expect(File('${install.path}/antirkn_manager').readAsStringSync(), 'old');
    });

    test(
      'root-owned, unmarked or other-kind installs are notify-only',
      () async {
        final a = artifact(AppUpdateKind.linuxTarball, 'x64');
        system.owner = 0;
        expect(await installer.mode(a), AppUpdateInstallMode.notifyOnly);
        File('${install.path}/install-kind').deleteSync();
        expect(
          await readInstallKind('${install.path}/antirkn_manager'),
          isNull,
        );
        expect(
          await installer.mode(artifact(AppUpdateKind.linuxAppimage, 'x64')),
          AppUpdateInstallMode.notifyOnly,
        );
      },
    );
  });

  group('Linux AppImage', () {
    late File image;
    late FakeSystem system;
    late DesktopAppUpdateInstaller installer;

    setUp(() {
      image = File('${root.path}/Apps/AntiRKN.AppImage')
        ..createSync(recursive: true)
        ..writeAsStringSync('old-image');
      system = FakeSystem({
        'APPIMAGE': image.path,
        'APPDIR': '/tmp/.mount_x',
        'LD_LIBRARY_PATH': '/tmp/.mount_x/usr/lib',
        'HOME': '/home/u',
      });
      installer = DesktopAppUpdateInstaller(
        installKind: AppUpdateKind.linuxAppimage,
        executable: '/tmp/.mount_x/usr/bin/antirkn_manager',
        system: system,
        linux: true,
        windows: false,
      );
    });

    test('replaces the file atomically, keeps .old, restarts clean', () async {
      final download = File('${root.path}/AntiRKN-v1.2.3-linux-x64.AppImage')
        ..writeAsStringSync('new-image');
      final a = await fileArtifact(AppUpdateKind.linuxAppimage, download);
      expect(await installer.mode(a), AppUpdateInstallMode.automatic);
      await expectLater(
        installer.install(download.path, a, payload()),
        throwsA(isA<Exited>()),
      );
      expect(image.readAsStringSync(), 'new-image');
      expect(File('${image.path}.old').readAsStringSync(), 'old-image');
      expect(File('${image.path}.part').existsSync(), isFalse);
      final (exe, _, env) = system.started.single;
      expect(exe, image.path);
      expect(env!.keys, ['HOME']);
      await installer.finishStartup(confirmed: true);
      expect(File('${image.path}.old').existsSync(), isFalse);
    });

    test('a symlinked or missing APPIMAGE is notify-only', () async {
      final link = Link('${root.path}/link.AppImage')..createSync(image.path);
      system.env['APPIMAGE'] = link.path;
      final a = artifact(AppUpdateKind.linuxAppimage, 'x64');
      expect(await installer.mode(a), AppUpdateInstallMode.notifyOnly);
      system.env.remove('APPIMAGE');
      expect(await installer.mode(a), AppUpdateInstallMode.notifyOnly);
    });
  });

  group('Windows', () {
    test('installer runs silently detached, then the app exits', () async {
      final setup = File('${root.path}/AntiRKN-v1.2.3-windows-x64-setup.exe')
        ..writeAsStringSync('setup');
      final system = FakeSystem({});
      final installer = DesktopAppUpdateInstaller(
        installKind: AppUpdateKind.windowsInstaller,
        executable:
            r'C:\Users\u\AppData\Local\Programs\AntiRKN\antirkn_manager.exe',
        system: system,
        linux: false,
        windows: true,
      );
      final a = await fileArtifact(AppUpdateKind.windowsInstaller, setup);
      expect(await installer.mode(a), AppUpdateInstallMode.automatic);
      await expectLater(
        installer.install(setup.path, a, payload()),
        throwsA(isA<Exited>()),
      );
      expect(system.started.single.$2, [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
        '/relaunch=1',
      ]);
    });

    Future<(FakeSystem, DesktopAppUpdateInstaller, File, AppUpdateArtifact)>
    windowsInstaller(Future<void> Function() hook) async {
      final setup = File('${root.path}/AntiRKN-v1.2.3-windows-x64-setup.exe')
        ..writeAsStringSync('setup');
      final system = FakeSystem({});
      final installer = DesktopAppUpdateInstaller(
        installKind: AppUpdateKind.windowsInstaller,
        executable: r'C:\AntiRKN\antirkn_manager.exe',
        system: system,
        prepareExit: hook,
        prepareExitTimeout: const Duration(milliseconds: 50),
        linux: false,
        windows: true,
      );
      return (
        system,
        installer,
        setup,
        await fileArtifact(AppUpdateKind.windowsInstaller, setup),
      );
    }

    test('the app shutdown hook runs before the hand-over and exit', () async {
      late FakeSystem system;
      final (s, installer, setup, a) = await windowsInstaller(() async {
        system.events.add('prepare');
      });
      system = s;
      await expectLater(
        installer.install(setup.path, a, payload()),
        throwsA(isA<Exited>()),
      );
      expect(system.events, ['prepare', 'start', 'exit']);
    });

    test(
      'a hanging or failing shutdown hook does not block the update',
      () async {
        for (final hook in <Future<void> Function()>[
          () => Completer<void>().future,
          () async => throw StateError('close failed'),
        ]) {
          final (system, installer, setup, a) = await windowsInstaller(hook);
          await expectLater(
            installer.install(setup.path, a, payload()),
            throwsA(isA<Exited>()),
          );
          expect(system.events, ['start', 'exit']);
        }
      },
    );

    test('portable is download-only and never installs', () async {
      final installer = DesktopAppUpdateInstaller(
        installKind: AppUpdateKind.windowsPortable,
        executable: r'C:\AntiRKN\antirkn_manager.exe',
        system: FakeSystem({}),
        linux: false,
        windows: true,
      );
      final a = artifact(AppUpdateKind.windowsPortable, 'x64');
      expect(await installer.mode(a), AppUpdateInstallMode.downloadOnly);
      await expectLater(
        installer.install('/x', a, payload()),
        throwsA(isA<AppUpdateFailure>()),
      );
    });
  });
}
