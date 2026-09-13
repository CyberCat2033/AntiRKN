# This read-only inspector is bundled into both plan preparation and install.
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

def inspect_runner():
    release = None
    hashes = {}
    unsafe = False
    paths = [BASE, BASE / 'v1', BASE / 'v1/runner.py', BASE / 'v1/contract.py', BASE / 'v1/manifest.json', UNIT]
    for path in paths:
        try:
            meta = path.lstat()
            safe = meta.st_uid == 0 and not meta.st_mode & 0o022 and not stat.S_ISLNK(meta.st_mode)
            if path in (BASE, BASE / 'v1'):
                safe = safe and stat.S_ISDIR(meta.st_mode)
                content = b'directory'
            else:
                safe = safe and stat.S_ISREG(meta.st_mode) and meta.st_size < 262144
                content = path.read_bytes() if safe else b'unsafe'
            unsafe = unsafe or not safe
            hashes[str(path)] = hashlib.sha256(content).hexdigest()
        except FileNotFoundError:
            hashes[str(path)] = None
        except (OSError, ValueError):
            unsafe = True
            hashes[str(path)] = 'unreadable'
    if not unsafe and hashes[str(BASE / 'v1/manifest.json')]:
        try:
            manifest = json.loads((BASE / 'v1/manifest.json').read_text())
            if set(manifest) != {'release', 'hashes'}:
                raise ValueError()
            for name in ('runner.py', 'contract.py', 'antirkn-runner.service'):
                path = UNIT if name.endswith('.service') else BASE / 'v1' / name
                if hashes[str(path)] != manifest['hashes'][name]:
                    raise ValueError()
            release = manifest['release']
            if not isinstance(release, str) or len(release) != 64:
                raise ValueError()
        except (ValueError, KeyError, TypeError, OSError):
            unsafe = True
    present = any(hashes.values())
    state = 'conflict' if unsafe or (present and release is None) else 'installed' if release else 'missing'
    distro = {}
    for line in Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            distro[key] = value.strip('"')
    systemd = Path('/run/systemd/system').is_dir()
    if systemd:
        version_text = subprocess.check_output(['/usr/bin/systemctl', '--version'], timeout=10, text=True)
        systemd = int(version_text.splitlines()[0].split()[1]) >= 235
    supported = distro.get('ID') == 'ubuntu' and platform.machine() == 'x86_64' and sys.version_info >= (3, 8) and systemd
    active = subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', 'antirkn-runner.service'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0 if systemd else False
    fingerprint = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    return dict(supported=supported, state=state, release=release, fingerprint=fingerprint, active=active)
