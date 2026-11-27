#!/usr/bin/env python3
"""Android release steps: collect Flutter APKs, sign them, verify the result.

collect  - copy Flutter outputs to release names, read real versionCodes (aapt2)
sign     - zipalign + apksigner with the release keystore from the environment
verify   - signer certificate SHA-256, zip alignment, versionCodes, package name
previous - versionCodes and build must grow against the previous signed manifest
codes    - write {arch: versionCode} and the certificate digest for the manifest CLI

Secrets come only from the environment and never reach argv or output:
ANTIRKN_ANDROID_KEYSTORE_BASE64, ANTIRKN_ANDROID_KEYSTORE_PASSWORD,
ANTIRKN_ANDROID_KEY_ALIAS, ANTIRKN_ANDROID_KEY_PASSWORD.
"""
import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

PACKAGE = 'org.antirkn.antirkn_manager'
BUILD_TOOLS = '36.0.0'
# Release versionCode = build * 10 + ABI id (set in android/app/build.gradle.kts,
# replacing Flutter's ABI * 1000 + build): every APK of a newer build outranks
# every APK of an older one, whichever variant is installed.
ABIS = {
    'universal': ('app-release.apk', 0),
    'armeabi-v7a': ('app-armeabi-v7a-release.apk', 1),
    'arm64-v8a': ('app-arm64-v8a-release.apk', 2),
    'x86_64': ('app-x86_64-release.apk', 3),
}
MAX_VERSION_CODE = 2_100_000_000  # Android limit
META = 'android-meta.json'
TIMEOUT = 600


class ReleaseError(Exception):
    pass


def tools_dir(explicit=None):
    if explicit:
        return Path(explicit)
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not sdk:
        raise ReleaseError('ANDROID_HOME is not set')
    return Path(sdk) / 'build-tools' / BUILD_TOOLS


def run(args, **kwargs):
    try:
        return subprocess.run(args, check=True, timeout=TIMEOUT, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True, **kwargs).stdout
    except subprocess.CalledProcessError as error:
        raise ReleaseError('%s failed with exit code %d' % (Path(args[0]).name, error.returncode))
    except subprocess.TimeoutExpired:
        raise ReleaseError('%s timed out' % Path(args[0]).name)


def badging(tools, apk):
    output = run([str(tools / 'aapt2'), 'dump', 'badging', str(apk)])
    match = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']*)'", output, re.M)
    if not match:
        raise ReleaseError('cannot read package info of %s' % apk.name)
    return match.group(1), int(match.group(2)), match.group(3)


def expected_code(arch, build):
    code = build * 10 + ABIS[arch][1]
    if build < 1 or code >= MAX_VERSION_CODE:
        raise ReleaseError('build %d gives an invalid versionCode' % build)
    return code


def file_name(version, arch):
    return 'AntiRKN-v%s-android-%s.apk' % (version, arch)


def check_identity(tools, apk, arch, version, build):
    package, code, name = badging(tools, apk)
    if package != PACKAGE:
        raise ReleaseError('%s has package %s' % (apk.name, package))
    if name != version:
        raise ReleaseError('%s has versionName %s, expected %s' % (apk.name, name, version))
    if code != expected_code(arch, build):
        raise ReleaseError('%s has versionCode %d, expected %d' % (apk.name, code, expected_code(arch, build)))
    return code


def collect(flutter_out, version, build, out, tools):
    out.mkdir(parents=True, exist_ok=True)
    meta = {'version': version, 'build': build, 'package': PACKAGE, 'apks': {}}
    for arch, (source_name, _) in sorted(ABIS.items()):
        source = flutter_out / source_name
        if not source.is_file():
            raise ReleaseError('missing Flutter output %s' % source_name)
        target = out / file_name(version, arch)
        shutil.copyfile(str(source), str(target))
        code = check_identity(tools, target, arch, version, build)
        meta['apks'][target.name] = {'arch': arch, 'versionCode': code}
    (out / META).write_text(json.dumps(meta, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    return meta


def normalize_digest(value):
    digest = re.sub(r'[^0-9a-fA-F]', '', value or '').lower()
    if len(digest) != 64:
        raise ReleaseError('expected certificate SHA-256 must be 64 hex digits')
    return digest


def signer_digests(tools, apk):
    output = run([str(tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk)])
    if not re.search(r'^Verified using v2 scheme \(APK Signature Scheme v2\): true$', output, re.M):
        raise ReleaseError('%s is not signed with APK Signature Scheme v2' % apk.name)
    return re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-f]{64})$', output, re.M)


def verify(directory, expected, tools):
    meta = json.loads((directory / META).read_text(encoding='utf-8'))
    expected = normalize_digest(expected)
    if sorted(meta['apks']) != sorted(file_name(meta['version'], arch) for arch in ABIS):
        raise ReleaseError('android-meta.json does not list every ABI')
    for name, entry in sorted(meta['apks'].items()):
        apk = directory / name
        run([str(tools / 'zipalign'), '-c', '-P', '16', '4', str(apk)])
        digests = signer_digests(tools, apk)
        if digests != [expected]:
            raise ReleaseError('%s is not signed by the release certificate only' % name)
        code = check_identity(tools, apk, entry['arch'], meta['version'], meta['build'])
        if code != entry['versionCode']:
            raise ReleaseError('%s versionCode changed during signing' % name)
    meta['certSha256'] = expected
    (directory / META).write_text(json.dumps(meta, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    return meta


def sign(source, out, expected, tools, environ=os.environ):
    names = ('ANTIRKN_ANDROID_KEYSTORE_BASE64', 'ANTIRKN_ANDROID_KEYSTORE_PASSWORD',
             'ANTIRKN_ANDROID_KEY_ALIAS', 'ANTIRKN_ANDROID_KEY_PASSWORD')
    missing = [name for name in names if not environ.get(name)]
    if missing:
        raise ReleaseError('missing signing environment: %s' % ', '.join(missing))
    try:
        keystore = base64.b64decode(environ['ANTIRKN_ANDROID_KEYSTORE_BASE64'], validate=False)
    except (binascii.Error, ValueError):
        raise ReleaseError('ANTIRKN_ANDROID_KEYSTORE_BASE64 is not valid base64')
    if len(keystore) < 256:
        raise ReleaseError('decoded keystore is too small')
    meta = json.loads((source / META).read_text(encoding='utf-8'))
    out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='antirkn-sign-', dir=environ.get('RUNNER_TEMP') or None))
    try:
        os.chmod(str(work), 0o700)
        store = work / 'release.keystore'
        descriptor = os.open(str(store), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(keystore)
        for name in sorted(meta['apks']):
            aligned = work / name
            run([str(tools / 'zipalign'), '-f', '-P', '16', '4', str(source / name), str(aligned)])
            # apksigner replaces the throwaway CI debug signature of the build job.
            run([str(tools / 'apksigner'), 'sign', '--ks', str(store),
                 '--ks-key-alias', environ['ANTIRKN_ANDROID_KEY_ALIAS'],
                 '--ks-pass', 'env:ANTIRKN_ANDROID_KEYSTORE_PASSWORD',
                 '--key-pass', 'env:ANTIRKN_ANDROID_KEY_PASSWORD',
                 '--v1-signing-enabled', 'true', '--v2-signing-enabled', 'true',
                 '--v3-signing-enabled', 'true', '--out', str(out / name), str(aligned)],
                env=dict(environ))
            idsig = out / (name + '.idsig')
            if idsig.exists():
                idsig.unlink()
    finally:
        shutil.rmtree(str(work), ignore_errors=True)
    shutil.copyfile(str(source / META), str(out / META))
    return verify(out, expected, tools)


def decode_payload(manifest):
    envelope = json.loads(manifest.read_text(encoding='utf-8'))
    if envelope.get('format') != 'antirkn-app-update':
        raise ReleaseError('previous manifest has an unknown format')
    raw = envelope.get('payload', '')
    return json.loads(base64.urlsafe_b64decode(raw + '=' * (-len(raw) % 4)).decode('utf-8'))


def previous(meta_path, manifest):
    """The previous manifest is fetched over HTTPS from the latest release."""
    meta = json.loads(meta_path.read_text(encoding='utf-8'))
    if manifest is None or not manifest.is_file():
        print('android_release: no previous manifest, first release')
        return meta
    payload = decode_payload(manifest)
    if int(payload.get('build', 0)) >= meta['build']:
        raise ReleaseError('build %d is not greater than the previous build %s' % (meta['build'], payload.get('build')))
    # Any new APK must outrank every APK of the previous release, so a device
    # can move between split and universal variants without a downgrade.
    old = max([int(item.get('versionCode', 0)) for item in payload.get('artifacts', [])
               if item.get('kind') == 'android-apk'] or [0])
    for name, entry in sorted(meta['apks'].items()):
        if entry['versionCode'] <= old:
            raise ReleaseError('%s versionCode %d does not exceed the previous maximum %d'
                               % (name, entry['versionCode'], old))
    old_cert = {item.get('certSha256') for item in payload.get('artifacts', []) if item.get('certSha256')}
    if meta.get('certSha256') and old_cert and old_cert != {meta['certSha256']}:
        raise ReleaseError('release certificate differs from the previous release')
    return meta


def codes(meta_path, out, cert_out):
    """Inputs of `app_update_manifest.dart build --android-version-codes`."""
    meta = json.loads(meta_path.read_text(encoding='utf-8'))
    if not meta.get('certSha256'):
        raise ReleaseError('android-meta.json has no verified certificate')
    values = {entry['arch']: entry['versionCode'] for entry in meta['apks'].values()}
    if sorted(values) != sorted(ABIS):
        raise ReleaseError('android-meta.json does not list every ABI')
    out.write_text(json.dumps(values, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    cert_out.write_text(normalize_digest(meta['certSha256']) + '\n', encoding='utf-8')
    return values


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--build-tools', help='Android build-tools directory (default: $ANDROID_HOME/build-tools/%s)' % BUILD_TOOLS)
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('collect')
    command.add_argument('--flutter-out', type=Path, required=True)
    command.add_argument('--version', required=True)
    command.add_argument('--build', type=int, required=True)
    command.add_argument('--out', type=Path, required=True)
    command = commands.add_parser('sign')
    command.add_argument('--in', dest='source', type=Path, required=True)
    command.add_argument('--out', type=Path, required=True)
    command.add_argument('--expected-cert-sha256', required=True)
    command = commands.add_parser('verify')
    command.add_argument('--dir', type=Path, required=True)
    command.add_argument('--expected-cert-sha256', required=True)
    command = commands.add_parser('previous')
    command.add_argument('--meta', type=Path, required=True)
    command.add_argument('--manifest', type=Path)
    command = commands.add_parser('codes')
    command.add_argument('--meta', type=Path, required=True)
    command.add_argument('--out', type=Path, required=True)
    command.add_argument('--cert-out', type=Path, required=True)
    options = parser.parse_args(argv)
    try:
        if options.command == 'previous':
            previous(options.meta, options.manifest)
        elif options.command == 'codes':
            codes(options.meta, options.out, options.cert_out)
        else:
            tools = tools_dir(options.build_tools)
            if options.command == 'collect':
                collect(options.flutter_out, options.version, options.build, options.out, tools)
            elif options.command == 'sign':
                sign(options.source, options.out, options.expected_cert_sha256, tools)
            else:
                verify(options.dir, options.expected_cert_sha256, tools)
    except (ReleaseError, OSError, KeyError, ValueError) as error:
        print('::error::android_release %s: %s' % (options.command, error if isinstance(error, ReleaseError) else type(error).__name__))
        return 1
    print('android_release %s: ok' % options.command)
    return 0


if __name__ == '__main__':
    sys.exit(main())
