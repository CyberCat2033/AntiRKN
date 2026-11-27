#!/usr/bin/env python3
"""Release asset checks run by the publish job before anything is uploaded.

expected - list the exact asset names of a version (one per line)
sums     - write SHA256SUMS for the release assets
uploaded - compare GitHub release assets with the local files after upload
check    - cross-check the manifest payload (and the signed envelope) against
           the files on disk, android-meta.json and the release identity
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys

REPOSITORY = 'CyberCat2033/AntiRKN'
ANDROID_ARCHES = ('arm64-v8a', 'armeabi-v7a', 'universal', 'x86_64')
DESKTOP = {
    'windows-installer': 'AntiRKN-v%s-windows-x64-setup.exe',
    'windows-portable': 'AntiRKN-v%s-windows-x64-portable.zip',
    'linux-tarball': 'AntiRKN-v%s-linux-x64.tar.gz',
    'linux-appimage': 'AntiRKN-v%s-linux-x64.AppImage',
}
SUMS = 'SHA256SUMS'


class AssetError(Exception):
    pass


def expected(version):
    names = {'AntiRKN-v%s-android-%s.apk' % (version, arch): ('android-apk', arch) for arch in ANDROID_ARCHES}
    names.update({pattern % version: (kind, 'x64') for kind, pattern in DESKTOP.items()})
    return names


def sha256(path):
    digest = hashlib.sha256()
    with open(str(path), 'rb') as source:
        for chunk in iter(lambda: source.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def present(directory, version):
    names = expected(version)
    missing = sorted(name for name in names if not (directory / name).is_file())
    if missing:
        raise AssetError('missing release assets: %s' % ', '.join(missing))
    return names


def sums(directory, version, extra):
    names = sorted(set(present(directory, version)) | set(extra))
    lines = ['%s  %s' % (sha256(directory / name), name) for name in names]
    (directory / SUMS).write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return lines


def decode_envelope(path):
    envelope = json.loads(path.read_text(encoding='utf-8'))
    if envelope.get('format') != 'antirkn-app-update' or not envelope.get('signatures'):
        raise AssetError('signed manifest has no antirkn-app-update envelope or signatures')
    raw = envelope['payload']
    return base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4))


def check(payload_path, directory, meta_path, tag, commit, build, manifest_path=None):
    version = tag[1:]
    payload = json.loads(payload_path.read_text(encoding='utf-8'))
    meta = json.loads(meta_path.read_text(encoding='utf-8'))
    identity = {'schemaVersion': 1, 'appId': 'org.antirkn.manager', 'channel': 'stable',
                'version': version, 'tag': tag, 'commit': commit, 'build': build}
    for key, value in identity.items():
        if payload.get(key) != value:
            raise AssetError('payload %s is %r, expected %r' % (key, payload.get(key), value))
    if int(payload.get('minSupportedBuild', 0)) > build:
        raise AssetError('payload minSupportedBuild exceeds build')
    names = present(directory, version)
    base = 'https://github.com/%s/releases/download/%s/' % (REPOSITORY, tag)
    seen = set()
    for item in payload.get('artifacts', []):
        name = item.get('fileName', '')
        if name not in names or name in seen:
            raise AssetError('unexpected or duplicate artifact %r' % name)
        seen.add(name)
        kind, arch = names[name]
        path = directory / name
        if (item.get('kind'), item.get('arch')) != (kind, arch):
            raise AssetError('%s has kind/arch %s/%s' % (name, item.get('kind'), item.get('arch')))
        if item.get('url') != base + name:
            raise AssetError('%s has an unexpected url' % name)
        if item.get('size') != path.stat().st_size or item.get('sha256') != sha256(path):
            raise AssetError('%s size or sha256 does not match the file' % name)
        if kind == 'android-apk':
            entry = meta['apks'][name]
            if item.get('versionCode') != entry['versionCode']:
                raise AssetError('%s versionCode %r, APK has %d' % (name, item.get('versionCode'), entry['versionCode']))
            if item.get('certSha256') != meta.get('certSha256'):
                raise AssetError('%s certSha256 does not match the signed APK' % name)
    if seen != set(names):
        raise AssetError('payload lacks artifacts: %s' % ', '.join(sorted(set(names) - seen)))
    if manifest_path is not None:
        if json.loads(decode_envelope(manifest_path).decode('utf-8')) != payload:
            raise AssetError('signed manifest payload differs from payload.json')
    return payload


def uploaded(directory, assets_path):
    """Compare GitHub release assets (one JSON object per line) with local files."""
    remote = {}
    for line in assets_path.read_text(encoding='utf-8').splitlines():
        if line.strip():
            asset = json.loads(line)
            remote[asset['name']] = asset
    local = sorted(path.name for path in directory.iterdir() if path.is_file())
    if sorted(remote) != local:
        raise AssetError('uploaded assets %s differ from local %s' % (sorted(remote), local))
    for name in local:
        asset, path = remote[name], directory / name
        if asset.get('state') != 'uploaded' or asset.get('size') != path.stat().st_size:
            raise AssetError('%s is not fully uploaded' % name)
        digest = asset.get('digest') or ''
        if digest and digest != 'sha256:' + sha256(path):
            raise AssetError('%s digest differs after upload' % name)
        if not digest:
            print('::warning::GitHub reported no digest for %s; size matched' % name)
    return local


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('expected')
    command.add_argument('--version', required=True)
    command = commands.add_parser('sums')
    command.add_argument('--dir', type=Path, required=True)
    command.add_argument('--version', required=True)
    command.add_argument('--extra', action='append', default=[], help='additional file to include')
    command = commands.add_parser('uploaded')
    command.add_argument('--dir', type=Path, required=True)
    command.add_argument('--assets', type=Path, required=True)
    command = commands.add_parser('check')
    command.add_argument('--payload', type=Path, required=True)
    command.add_argument('--manifest', type=Path)
    command.add_argument('--dir', type=Path, required=True)
    command.add_argument('--meta', type=Path, required=True)
    command.add_argument('--tag', required=True)
    command.add_argument('--commit', required=True)
    command.add_argument('--build', type=int, required=True)
    options = parser.parse_args(argv)
    try:
        if options.command == 'expected':
            print('\n'.join(sorted(expected(options.version))))
        elif options.command == 'uploaded':
            uploaded(options.dir, options.assets)
            print('release_assets uploaded: ok')
        elif options.command == 'sums':
            print('\n'.join(sums(options.dir, options.version, options.extra)))
        else:
            check(options.payload, options.dir, options.meta, options.tag, options.commit,
                  options.build, options.manifest)
            print('release_assets check: ok')
    except (AssetError, OSError, KeyError, ValueError) as error:
        print('::error::release_assets %s: %s' % (options.command, error if isinstance(error, AssetError) else type(error).__name__))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
