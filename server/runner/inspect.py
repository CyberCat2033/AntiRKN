# Shared read-only preflight; known predecessor manifests are bundled.
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
LEGACY_PROGRAMS = ('runner.py', 'contract.py', 'panel.py', 'panel_api.py', 'panel_release.py', 'vless.py', 'vless_contract.py', 'components.py', 'component_releases.py', 'panel_discovery.py', 'apt.py', 'observed_inbounds.py')

V9_PROGRAMS = LEGACY_PROGRAMS + ('panel_update.py', 'panel_update_release.py')
V10_PROGRAMS = V9_PROGRAMS + ('awg.py', 'awg_contract.py', 'awg_network.py', 'awg_external.py')

V11_PROGRAMS = V10_PROGRAMS + ('tt.py', 'tt_common.py', 'tt_external.py', 'tt_certificates.py', 'tt_contract.py', 'tt_tomli_parser.py', 'tt_tomli_re.py', 'tt_tomli_types.py', 'tt_tomli_LICENSE')

V15_PROGRAMS = V11_PROGRAMS + ('client_revocations.py',)
V16_PROGRAMS = V15_PROGRAMS + ('protocol_remove.py',)
V17_PROGRAMS = V16_PROGRAMS
V18_PROGRAMS = V17_PROGRAMS + ('ssh_harden.py',)
V19_PROGRAMS = V18_PROGRAMS
V20_PROGRAMS = V19_PROGRAMS + ('inbound_remove.py',)
V21_PROGRAMS = V20_PROGRAMS
V22_PROGRAMS = V21_PROGRAMS + ('managed_existing.py', 'managed_vless.py', 'managed_awg.py', 'managed_tt.py')

V23_PROGRAMS = V22_PROGRAMS + ('connectivity_probe.py',)
V24_PROGRAMS = V23_PROGRAMS + ('xray_transaction.py', 'xray_upgrade_release.py')
V25_PROGRAMS = V24_PROGRAMS + ('server_reboot.py',)
PROGRAMS = V25_PROGRAMS

def inspect_runner():
    hashes, unsafe = {}, False
    names_by_version = {'v1': ('runner.py', 'contract.py'),
        'v2': ('runner.py', 'contract.py', 'panel.py', 'panel_api.py', 'panel_release.py'), 'v3': ('runner.py', 'contract.py', 'panel.py', 'panel_api.py', 'panel_release.py', 'vless.py', 'vless_contract.py'), 'v4': tuple(n for n in LEGACY_PROGRAMS if n not in ('panel_discovery.py', 'apt.py', 'observed_inbounds.py')), 'v5': tuple(n for n in LEGACY_PROGRAMS if n not in ('apt.py', 'observed_inbounds.py')), 'v6': LEGACY_PROGRAMS, 'v7': LEGACY_PROGRAMS, 'v8': V9_PROGRAMS, 'v9': V9_PROGRAMS, 'v10': V10_PROGRAMS, 'v11': V11_PROGRAMS, 'v12': V11_PROGRAMS, 'v13': V11_PROGRAMS, 'v14': V11_PROGRAMS, 'v15': V15_PROGRAMS, 'v16': V16_PROGRAMS, 'v17': V17_PROGRAMS, 'v18': V18_PROGRAMS, 'v19': V19_PROGRAMS, 'v20': V20_PROGRAMS, 'v21': V21_PROGRAMS, 'v22': V22_PROGRAMS, 'v23': V23_PROGRAMS, 'v24': V24_PROGRAMS, 'v25': V25_PROGRAMS, 'v26': PROGRAMS, 'v27': PROGRAMS, 'v28': PROGRAMS, 'v29': PROGRAMS, 'v30': PROGRAMS, 'v31': PROGRAMS, 'v32': PROGRAMS, 'v33': PROGRAMS, 'v34': PROGRAMS}
    directories = {BASE} | {BASE / version for version in names_by_version}
    paths = [BASE, UNIT]
    for version, names in names_by_version.items():
        paths += [BASE / version, BASE / version / 'manifest.json']
        paths += [BASE / version / name for name in names]
    for path in paths:
        try:
            meta = path.lstat()
            safe = meta.st_uid == 0 and not meta.st_mode & 0o022 and not stat.S_ISLNK(meta.st_mode)
            if path in directories:
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
    try:
        predecessors = []
        for version, expected in [('v1', PREDECESSOR), ('v2', PREDECESSOR_V2), ('v3', PREDECESSOR_V3), ('v4', PREDECESSOR_V4), ('v5', PREDECESSOR_V5), ('v6', PREDECESSOR_V6), ('v7', PREDECESSOR_V7), ('v8', PREDECESSOR_V8), ('v9', PREDECESSOR_V9), ('v10', PREDECESSOR_V10), ('v11', PREDECESSOR_V11), ('v12', PREDECESSOR_V12), ('v13', PREDECESSOR_V13), ('v14', PREDECESSOR_V14), ('v15', PREDECESSOR_V15), ('v16', PREDECESSOR_V16), ('v17', PREDECESSOR_V17), ('v18', PREDECESSOR_V18), ('v19', PREDECESSOR_V19), ('v20', PREDECESSOR_V20), ('v21', PREDECESSOR_V21), ('v22', PREDECESSOR_V22), ('v23', PREDECESSOR_V23), ('v24', PREDECESSOR_V24), ('v25', PREDECESSOR_V25), ('v26', PREDECESSOR_V26), ('v27', PREDECESSOR_V27), ('v28', PREDECESSOR_V28), ('v29', PREDECESSOR_V29), ('v30', PREDECESSOR_V30), ('v31', PREDECESSOR_V31), ('v32', PREDECESSOR_V32), ('v33', PREDECESSOR_V33)]:
            if hashes[str(BASE / version)]:
                manifest = json.loads((BASE / version / 'manifest.json').read_text())
                if isinstance(expected, list):
                    if manifest not in expected: raise ValueError()
                    expected = manifest
                if manifest != expected: raise ValueError()
                for name in names_by_version[version]:
                    if hashes[str(BASE / version / name)] != expected['hashes'][name]: raise ValueError()
                predecessors.append(manifest)
        unit_hash = hashes[str(UNIT)]
        if hashes[str(BASE / 'v34')]:
            manifest = json.loads((BASE / 'v34/manifest.json').read_text())
            if set(manifest) != {'release','hashes'} or set(manifest['hashes']) != set(PROGRAMS) | {'antirkn-runner.service'}: raise ValueError()
            for name in PROGRAMS:
                if hashes[str(BASE / 'v34' / name)] != manifest['hashes'][name]: raise ValueError()
            expected = hashlib.sha256(json.dumps(manifest['hashes'], sort_keys=True).encode()).hexdigest()
            if manifest['release'] != expected: raise ValueError()
            release = expected
            if unit_hash == manifest['hashes']['antirkn-runner.service']:
                state = 'installed'
            elif unit_hash is None or any(unit_hash == old['hashes']['antirkn-runner.service'] for old in predecessors):
                state = 'partial'
            else: raise ValueError()
        elif predecessors:
            # The service may still point at any verified predecessor. This is
            # deliberately a set membership check: interrupted or manually
            # repeated upgrades can leave more than one old directory behind,
            # and the newest directory is not necessarily the active one.
            matching = predecessor_for_unit(predecessors, unit_hash)
            if matching is not None:
                release, state, upgradable = matching['release'], 'installed', True
            elif any(hashes.values()):
                raise ValueError()
        elif any(hashes.values()): raise ValueError()
    except (ValueError, KeyError, TypeError, OSError):
        unsafe = True
    if unsafe:
        state, upgradable = 'conflict', False
    distro = dict(line.split('=',1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    systemd = Path('/run/systemd/system').is_dir()
    if systemd:
        version_text = subprocess.check_output(['/usr/bin/systemctl','--version'],timeout=10,text=True)
        systemd = int(version_text.splitlines()[0].split()[1]) >= 235
    supported = distro.get('ID','').strip('"') == 'ubuntu' and platform.machine() == 'x86_64' and sys.version_info >= (3,8) and systemd
    active = subprocess.run(['/usr/bin/systemctl','is-active','--quiet','antirkn-runner.service'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10).returncode == 0 if systemd else False
    return dict(supported=supported,state=state,release=release,fingerprint=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest(),active=active,upgradable=upgradable)


def predecessor_for_unit(predecessors, unit_hash):
    return next((old for old in predecessors
                 if unit_hash == old['hashes']['antirkn-runner.service']), None)
