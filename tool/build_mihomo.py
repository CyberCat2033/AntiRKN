#!/usr/bin/env python3
"""Reproducible local native build; outputs and downloaded modules stay out of Git."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'native/mihomo'
VERSION = '1.19.30'
REVISION = 'ac017cdd246ce8bd547653d927e7bf77d7ee73d5'

def notices(destination):
    destination.mkdir(parents=True, exist_ok=True)
    raw = subprocess.check_output(['go', 'list', '-m', '-json', 'all'], cwd=SOURCE, text=True)
    decoder, offset, records = json.JSONDecoder(), 0, []
    while offset < len(raw):
        while offset < len(raw) and raw[offset].isspace(): offset += 1
        if offset == len(raw): break
        module, end = decoder.raw_decode(raw, offset); offset = end
        resolved = module.get('Replace', module)
        directory = Path(resolved.get('Dir', SOURCE))
        name = module['Path']
        licenses = []
        for entry in sorted(directory.iterdir()) if directory.exists() else []:
            if entry.is_file() and entry.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
                target = name.replace('/', '_') + '_' + entry.name
                (destination / target).write_bytes(entry.read_bytes())
                licenses.append(target)
        records.append({'module': name, 'version': module.get('Version'),
                        'replacement': module.get('Replace', {}).get('Path'), 'licenses': licenses})
    (destination / 'modules.json').write_text(json.dumps(records, indent=2) + '\n')
    (destination / 'SOURCE.md').write_bytes((SOURCE / 'README.md').read_bytes())


def build(target, output, abi=None, ndk=None):
    env = dict(os.environ)
    env['GOTOOLCHAIN'] = 'local'
    args = ['go', 'build', '-mod=readonly', '-trimpath', '-tags', 'with_gvisor', '-ldflags', '-s -w', '-o', str(output)]
    compiler = ''
    if target == 'android':
        architectures = {'arm64-v8a': ('arm64', 'aarch64-linux-android23'), 'armeabi-v7a': ('arm', 'armv7a-linux-androideabi23'), 'x86_64': ('amd64', 'x86_64-linux-android23')}
        arch, triple = architectures[abi]
        if ndk is None:
            raise SystemExit('--ndk is required for the Android build')
        clang = ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin' / (triple + '-clang')
        env.update(GOOS='android', GOARCH=arch, CGO_ENABLED='1', CC=str(clang), CGO_LDFLAGS='-Wl,-z,max-page-size=16384')
        if arch == 'arm': env['GOARM'] = '7'
        compiler = subprocess.check_output([str(clang), '--version'], text=True).splitlines()[0]
        args += ['-buildmode=c-shared', './cmd/android']
    else:
        env.update(GOOS=target, GOARCH='amd64', CGO_ENABLED='0')
        args += ['./cmd/worker']
    version = subprocess.check_output(['go', 'version'], text=True).strip()
    inputs = hashlib.sha256()
    for path in sorted(SOURCE.rglob('*')):
        if path.is_file(): inputs.update(str(path.relative_to(SOURCE)).encode()); inputs.update(path.read_bytes())
    inputs.update(Path(__file__).read_bytes())
    inputs.update(f'{version}|{compiler}|{target}|{abi}'.encode())
    notices(output.parent / "notices")
    stamp = output.with_suffix(output.suffix + '.json')
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() and stamp.exists():
        saved = json.loads(stamp.read_text())
        if saved.get('inputHash') == inputs.hexdigest() and saved.get('sha256') == hashlib.sha256(output.read_bytes()).hexdigest():
            print(f'Mihomo {target}/{abi or "x64"}: cached')
            return
    subprocess.run(args, cwd=SOURCE, env=env, check=True)
    record = {'version': VERSION, 'revision': REVISION, 'toolchain': version, 'compiler': compiler,
              'tags': ['with_gvisor'], 'target': target, 'abi': abi, 'inputHash': inputs.hexdigest(),
              'sha256': hashlib.sha256(output.read_bytes()).hexdigest()}
    stamp.write_text(json.dumps(record, indent=2) + '\n')
    print(f'Mihomo {target}/{abi or "x64"}: built')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['linux', 'windows', 'android'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--abi', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'])
    parser.add_argument('--ndk', type=Path)
    options = parser.parse_args()
    if options.target == 'android' and not options.abi: parser.error('--abi is required')
    build(options.target, options.output.resolve(), options.abi, options.ndk)
