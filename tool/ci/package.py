#!/usr/bin/env python3
"""Package Flutter desktop bundles into release artifacts.

Archives hold one top-level directory named like the artifact and an
`install-kind` marker next to the executable, so the in-app updater knows how
it was installed. Entries are sorted and timestamped from SOURCE_DATE_EPOCH
(or --epoch) to keep archives reproducible for the same bundle.
"""
import argparse
import gzip
import io
import os
from pathlib import Path
import shutil
import stat
import sys
import tarfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PACKAGING = ROOT / 'packaging'
MARKER = 'install-kind'
LINUX_EXECUTABLE = 'antirkn_manager'
WINDOWS_EXECUTABLE = 'antirkn_manager.exe'
VC_RUNTIME = ('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
APP_ID = 'org.antirkn.antirkn_manager'
# License and disclaimer ship next to the executable in every package.
LEGAL = ('LICENSE', 'DISCLAIMER.md')


NAMES = {
    'linux-tarball': 'AntiRKN-v%s-linux-x64.tar.gz',
    'linux-appimage': 'AntiRKN-v%s-linux-x64.AppImage',
    'windows-portable': 'AntiRKN-v%s-windows-x64-portable.zip',
    'windows-installer': 'AntiRKN-v%s-windows-x64-setup.exe',
}


def artifact_name(version, kind):
    return NAMES[kind] % version


def bundle_files(bundle, executable):
    if not (bundle / executable).is_file():
        raise ValueError('bundle has no %s' % executable)
    files = []
    for path in sorted(bundle.rglob('*')):
        relative = path.relative_to(bundle).as_posix()
        if path.is_symlink():
            raise ValueError('bundle contains a symlink: %s' % relative)
        if relative == MARKER:
            raise ValueError('bundle already contains an install-kind marker')
        if relative in LEGAL:
            raise ValueError('bundle already contains %s' % relative)
        files.append((relative, path))
    return files


def mode_of(path):
    return 0o755 if path.is_dir() or os.access(str(path), os.X_OK) else 0o644


def epoch_of(value):
    if value is None:
        value = os.environ.get('SOURCE_DATE_EPOCH', '')
    return int(value) if str(value).strip() else int(time.time())


def tarball(bundle, version, out, epoch):
    top = artifact_name(version, 'linux-tarball')[:-len('.tar.gz')]
    target = out / (top + '.tar.gz')
    out.mkdir(parents=True, exist_ok=True)

    def add(archive, name, mode, data=None, directory=False):
        info = tarfile.TarInfo(name)
        info.mtime, info.mode, info.uid, info.gid, info.uname, info.gname = epoch, mode, 0, 0, '', ''
        if directory:
            info.type = tarfile.DIRTYPE
            archive.addfile(info)
        else:
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))

    with open(str(target), 'wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=epoch) as packed:
        with tarfile.open(fileobj=packed, mode='w', format=tarfile.PAX_FORMAT) as archive:
            add(archive, top, 0o755, directory=True)
            for relative, path in bundle_files(bundle, LINUX_EXECUTABLE):
                name = top + '/' + relative
                if path.is_dir():
                    add(archive, name, 0o755, directory=True)
                else:
                    mode = 0o755 if relative in (LINUX_EXECUTABLE, 'lib/antirkn-mihomo') else mode_of(path)
                    add(archive, name, mode, path.read_bytes())
            for name in LEGAL:
                add(archive, top + '/' + name, 0o644, (ROOT / name).read_bytes())
            add(archive, top + '/' + MARKER, 0o644, b'linux-tarball\n')
    return target


def portable(bundle, version, out, epoch):
    top = artifact_name(version, 'windows-portable')[:-len('.zip')]
    target = out / (top + '.zip')
    out.mkdir(parents=True, exist_ok=True)
    stamp = time.gmtime(max(epoch, 315532800))[:6]

    def entry(name, mode, directory=False):
        info = zipfile.ZipInfo(name + ('/' if directory else ''), date_time=stamp)
        info.create_system = 3
        info.external_attr = ((stat.S_IFDIR if directory else stat.S_IFREG) | mode) << 16
        if directory:
            info.external_attr |= 0x10
        info.compress_type = zipfile.ZIP_STORED if directory else zipfile.ZIP_DEFLATED
        return info

    with zipfile.ZipFile(str(target), 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(entry(top, 0o755, True), b'')
        for relative, path in bundle_files(bundle, WINDOWS_EXECUTABLE):
            if path.is_dir():
                archive.writestr(entry(top + '/' + relative, 0o755, True), b'')
            else:
                archive.writestr(entry(top + '/' + relative, 0o644), path.read_bytes())
        for name in LEGAL:
            archive.writestr(entry(top + '/' + name, 0o644), (ROOT / name).read_bytes())
        archive.writestr(entry(top + '/' + MARKER, 0o644), b'windows-portable\n')
    return target


def appdir(bundle, out):
    """Assemble an AppDir; appimagetool turns it into the AppImage."""
    if out.exists():
        raise ValueError('AppDir output already exists')
    bundle_files(bundle, LINUX_EXECUTABLE)
    shutil.copytree(str(bundle), str(out), symlinks=False)
    os.chmod(str(out / LINUX_EXECUTABLE), 0o755)
    mihomo = out / 'lib/antirkn-mihomo'
    if mihomo.exists():
        os.chmod(str(mihomo), 0o755)
    shutil.copyfile(str(PACKAGING / 'linux/AppRun'), str(out / 'AppRun'))
    os.chmod(str(out / 'AppRun'), 0o755)
    shutil.copyfile(str(PACKAGING / 'linux' / (APP_ID + '.desktop')), str(out / (APP_ID + '.desktop')))
    shutil.copyfile(str(ROOT / 'apps/manager/assets/branding/app_icon.png'), str(out / (APP_ID + '.png')))
    os.symlink(APP_ID + '.png', str(out / '.DirIcon'))
    for name in LEGAL:
        shutil.copyfile(str(ROOT / name), str(out / name))
    (out / MARKER).write_bytes(b'linux-appimage\n')
    return out


def vcruntime(bundle, source):
    """Copy the MSVC runtime next to the executable (app-local deployment)."""
    if not (bundle / WINDOWS_EXECUTABLE).is_file():
        raise ValueError('bundle has no %s' % WINDOWS_EXECUTABLE)
    for name in VC_RUNTIME:
        if not (source / name).is_file():
            raise ValueError('missing %s in %s' % (name, source))
        shutil.copyfile(str(source / name), str(bundle / name))
    return bundle


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('tarball', 'portable'):
        command = commands.add_parser(name)
        command.add_argument('--bundle', type=Path, required=True)
        command.add_argument('--version', required=True)
        command.add_argument('--out', type=Path, required=True)
        command.add_argument('--epoch')
    command = commands.add_parser('appdir')
    command.add_argument('--bundle', type=Path, required=True)
    command.add_argument('--out', type=Path, required=True)
    command = commands.add_parser('vcruntime')
    command.add_argument('--bundle', type=Path, required=True)
    command.add_argument('--from', dest='source', type=Path,
                         default=Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32')
    command = commands.add_parser('name')
    command.add_argument('--version', required=True)
    command.add_argument('--kind', choices=sorted(NAMES), required=True)
    options = parser.parse_args(argv)
    try:
        if options.command == 'tarball':
            result = tarball(options.bundle, options.version, options.out, epoch_of(options.epoch))
        elif options.command == 'portable':
            result = portable(options.bundle, options.version, options.out, epoch_of(options.epoch))
        elif options.command == 'appdir':
            result = appdir(options.bundle, options.out)
        elif options.command == 'vcruntime':
            result = vcruntime(options.bundle, options.source)
        else:
            result = artifact_name(options.version, options.kind)
    except (OSError, ValueError) as error:
        print('::error::package: %s' % error)
        return 1
    print(result)
    return 0


if __name__ == '__main__':
    sys.exit(main())
