# Shared read-only preflight; PREDECESSOR is injected by the bundle generator.
import hashlib
import json
import os
from pathlib import Path
import platform
import sqlite3
import stat
import subprocess
import sys

BASE = Path('/usr/local/lib/antirkn-runner')
UNIT = Path('/etc/systemd/system/antirkn-runner.service')
PROGRAMS = ('runner.py', 'contract.py', 'panel.py', 'panel_api.py', 'panel_release.py')


def inspect_runner():
    hashes, unsafe = {}, False
    paths = [BASE, UNIT]
    for folder, names in [('v1', ('runner.py', 'contract.py')), ('v2', PROGRAMS)]:
        paths += [BASE / folder, BASE / folder / 'manifest.json']
        paths += [BASE / folder / name for name in names]
    for path in paths:
        try:
            meta = path.lstat()
            safe = meta.st_uid == 0 and not meta.st_mode & 0o022 and not stat.S_ISLNK(meta.st_mode)
            if path in (BASE, BASE / 'v1', BASE / 'v2'):
                safe = safe and stat.S_ISDIR(meta.st_mode)
                content = b'directory'
            else:
                safe = safe and stat.S_ISREG(meta.st_mode) and meta.st_size < 1048576
                content = path.read_bytes() if safe else b'unsafe'
            unsafe |= not safe
            hashes[str(path)] = hashlib.sha256(content).hexdigest()
        except FileNotFoundError:
            hashes[str(path)] = None
        except (OSError, ValueError):
            unsafe = True
            hashes[str(path)] = 'unreadable'
    release, state, upgradable = None, 'missing', False
    old = None
    try:
        if hashes[str(BASE / 'v1')]:
            old = json.loads((BASE / 'v1/manifest.json').read_text())
            if old != PREDECESSOR:
                raise ValueError()
            for name in ('runner.py', 'contract.py'):
                if hashes[str(BASE / 'v1' / name)] != old['hashes'][name]:
                    raise ValueError()
        if hashes[str(BASE / 'v2')]:
            manifest = json.loads((BASE / 'v2/manifest.json').read_text())
            if set(manifest) != {'release', 'hashes'} or set(manifest['hashes']) != set(PROGRAMS) | {'antirkn-runner.service'}:
                raise ValueError()
            for name in PROGRAMS:
                if hashes[str(BASE / 'v2' / name)] != manifest['hashes'][name]:
                    raise ValueError()
            expected = hashlib.sha256(json.dumps(manifest['hashes'], sort_keys=True).encode()).hexdigest()
            if manifest['release'] != expected:
                raise ValueError()
            release = expected
            unit_hash = hashes[str(UNIT)]
            if unit_hash == manifest['hashes']['antirkn-runner.service']:
                state = 'installed'
            elif unit_hash is None or (old and unit_hash == old['hashes']['antirkn-runner.service']):
                state = 'partial'
            else:
                raise ValueError()
        elif old and hashes[str(UNIT)] == old['hashes']['antirkn-runner.service']:
            release, state, upgradable = old['release'], 'installed', True
        elif any(hashes.values()):
            raise ValueError()
    except (ValueError, KeyError, TypeError, OSError):
        unsafe = True
    if unsafe:
        state, upgradable = 'conflict', False
    distro = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    systemd = Path('/run/systemd/system').is_dir()
    if systemd:
        version_text = subprocess.check_output(['/usr/bin/systemctl', '--version'], timeout=10, text=True)
        systemd = int(version_text.splitlines()[0].split()[1]) >= 235
    supported = distro.get('ID', '').strip('"') == 'ubuntu' and platform.machine() == 'x86_64' and sys.version_info >= (3, 8) and systemd
    active = subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', 'antirkn-runner.service'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0 if systemd else False
    fingerprint = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    return dict(supported=supported, state=state, release=release,
                fingerprint=fingerprint, active=active, upgradable=upgradable)
