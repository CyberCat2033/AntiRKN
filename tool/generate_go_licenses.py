#!/usr/bin/env python3
"""Collect the licenses of the Go code linked into the Mihomo core.

The app embeds native/mihomo built for Linux, Windows and Android; their
MIT/BSD/Apache dependencies require shipping their notices. This lists the
modules each release build links (`go list -deps`, same tags as
tool/build_mihomo.py), reads their license files from the module cache and
writes apps/manager/assets/legal/go_licenses.json, which the app shows on its
licenses page. Identical texts are stored once.

  python3 tool/generate_go_licenses.py          write the asset
  python3 tool/generate_go_licenses.py --check  fail if it is stale
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'native/mihomo'
OUTPUT = ROOT / 'apps/manager/assets/legal/go_licenses.json'
TAGS = 'with_gvisor'
# (GOOS, GOARCH, CGO_ENABLED, package) as in tool/build_mihomo.py.
TARGETS = (
    ('linux', 'amd64', '0', './cmd/worker'),
    ('windows', 'amd64', '0', './cmd/worker'),
    ('android', 'arm64', '1', './cmd/android'),
    ('android', 'arm', '1', './cmd/android'),
    ('android', 'amd64', '1', './cmd/android'),
)
# Modules that ship no license file: a committed notice with the upstream text.
OVERRIDES = {
    'github.com/metacubex/chacha': ROOT / 'tool/legal/metacubex-chacha.LICENSE',
}
LICENSE_FILE = re.compile(r'^(LICEN[CS]E|COPYING|NOTICE|PATENTS)([._-].*)?$', re.IGNORECASE)


def go(args, env=None):
    result = subprocess.run(
        ['go'] + args, cwd=str(MODULE), env=env, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=600, check=False,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode('utf-8', 'replace'))
        raise SystemExit('go %s failed' % args[0])
    return result.stdout.decode('utf-8')


def linked_modules():
    modules = {}
    for goos, goarch, cgo, package in TARGETS:
        env = dict(os.environ, GOOS=goos, GOARCH=goarch, CGO_ENABLED=cgo,
                   GOFLAGS='-mod=readonly', GOTOOLCHAIN='local')
        out = go(['list', '-deps', '-tags', TAGS, '-json=Module', package], env)
        for item in _objects(out):
            module = item.get('Module')
            if not module or module.get('Main'):
                continue
            source = module.get('Replace') or module
            modules[module['Path']] = (source.get('Path', module['Path']), source.get('Version', ''), source['Dir'])
    return modules


def _objects(text):
    decoder, index = json.JSONDecoder(), 0
    while True:
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            return
        value, index = decoder.raw_decode(text, index)
        yield value


def license_text(directory):
    names = sorted(n for n in os.listdir(directory) if LICENSE_FILE.match(n) and (Path(directory) / n).is_file())
    parts = [(Path(directory) / n).read_text(encoding='utf-8', errors='replace').strip() for n in names]
    return '\n\n'.join(p for p in parts if p)


def build():
    texts, entries, missing = [], [], []

    def add(name, version, text):
        if text not in texts:
            texts.append(text)
        entries.append({'module': name, 'version': version, 'text': texts.index(text)})

    goroot = go(['env', 'GOROOT'], dict(os.environ, GOTOOLCHAIN='local')).strip()
    add('Go standard library', '', license_text(goroot))
    for path, (source, version, directory) in sorted(linked_modules().items()):
        override = OVERRIDES.get(path)
        text = override.read_text(encoding='utf-8').strip() if override else license_text(directory)
        if not text:
            missing.append(path)
            continue
        name = path if source == path else '%s (%s)' % (path, source)
        add(name, version, text)
    if missing:
        raise SystemExit('no license file in: %s' % ', '.join(missing))
    return json.dumps({'texts': texts, 'modules': entries}, ensure_ascii=False, indent=1) + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args(argv)
    content = build()
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding='utf-8') != content:
            raise SystemExit('%s is stale: run tool/generate_go_licenses.py' % OUTPUT.relative_to(ROOT))
        print('Go licenses: up to date')
        return
    OUTPUT.write_text(content, encoding='utf-8')
    print('wrote %s' % OUTPUT.relative_to(ROOT))


if __name__ == '__main__':
    main()
