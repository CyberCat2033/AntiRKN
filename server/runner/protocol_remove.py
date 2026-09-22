"""Confirmed, durable removal of discovered protocol services.

The caller supplies only a protocol and a preflight fingerprint. Commands and
paths come from server-side discovery. Removed native files are quarantined in
the root-only job directory, so an interrupted step can be resumed safely.
"""
import hashlib
import errno
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess

from panel import atomic_file
from vless import VlessError


class RemovalError(VlessError):
    def __init__(self, code='protocol_remove_conflict'):
        self.code = code


def run(args, check=True):
    result = subprocess.run(args, capture_output=True, timeout=90)
    if len(result.stdout) > 4 * 1024 * 1024 or check and result.returncode:
        raise RemovalError('protocol_remove_failed')
    return result


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def prune_quarantines(directory, keep=2):
    try:
        entries = []
        for p in directory.iterdir():
            if p.is_dir() and p.name.startswith('remove-'):
                entries.append(p)
        entries.sort(key=lambda p: p.stat().st_mtime)
        while len(entries) > keep:
            oldest = entries.pop(0)
            shutil.rmtree(oldest, ignore_errors=True)
    except Exception:
        pass


def exists(path):
    return path.exists() or path.is_symlink()


def path_state(path):
    if not exists(path):
        return None
    # Do not follow links in a removed tree, or accept user-writable parents.
    for parent in path.parents:
        meta = parent.stat()
        if meta.st_uid != 0 or meta.st_mode & 0o022:
            raise RemovalError('protocol_remove_unsupported')
    result = []
    todo = [path]
    while todo:
        p = todo.pop()
        st = p.lstat()
        if len(result) >= 20000 or st.st_uid != 0 or (not stat.S_ISLNK(st.st_mode) and st.st_mode & 0o022):
            raise RemovalError('protocol_remove_unsupported')
        kind = stat.S_IFMT(st.st_mode)
        if stat.S_ISLNK(st.st_mode):
            value = os.readlink(p)
        elif stat.S_ISDIR(st.st_mode):
            value = None
            todo.extend(sorted(p.iterdir(), reverse=True))
        elif stat.S_ISREG(st.st_mode):
            # Metadata plus a content digest: never send configuration bytes.
            h = hashlib.sha256()
            with p.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    h.update(block)
            value = h.hexdigest()
        else:
            raise RemovalError('protocol_remove_unsupported')
        result.append([str(p.relative_to(path)), kind, value])
    return digest(result)


def quarantine(path, backup):
    marker = backup.with_name(backup.name + '.copied')
    if exists(backup):
        if exists(path):
            # A completed cross-mount copy may survive a crash before unlink.
            if not marker.exists() or marker.read_text() != path_state(path) or path_state(backup) != marker.read_text():
                raise RemovalError()
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
        return
    if not exists(path):
        return
    expected = path_state(path)
    try:
        os.rename(path, backup)
        return
    except OSError as error:
        if error.errno != errno.EXDEV:
            raise
    # ProtectSystem/ReadWritePaths give /etc and /var separate bind mounts,
    # even on a single disk. Preserve a verified copy before removing source.
    staging = backup.with_name(backup.name + '.copying')
    if exists(staging):
        if staging.is_dir() and not staging.is_symlink():
            shutil.rmtree(staging)
        else:
            staging.unlink()
    if path.is_dir() and not path.is_symlink():
        shutil.copytree(path, staging, symlinks=True)
    else:
        shutil.copy2(path, staging, follow_symlinks=False)
    if path_state(path) != expected or path_state(staging) != expected:
        raise RemovalError()
    items = [staging]
    if staging.is_dir() and not staging.is_symlink():
        items.extend(staging.rglob('*'))
    for item in reversed(items):
        if item.is_file() and not item.is_symlink():
            with item.open('rb') as stream:
                os.fsync(stream.fileno())
        elif item.is_dir() and not item.is_symlink():
            fd = os.open(item, os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
    atomic_file(marker, expected.encode(), 0o600)
    os.rename(staging, backup)
    fd = os.open(backup.parent, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    quarantine(path, backup)


def unit_matches(protocol, name):
    patterns = {
        'vless': r'(?:x-ui|3x-ui|xray|antirkn-x-ui-bootstrap)\.service',
        'amneziawg': r'(?:antirkn-awg|awg-quick)@[^/]*\.service',
        'trusttunnel': r'(?:antirkn-trusttunnel|antirkn-tt@[^/]*|trusttunnel[^/]*)\.service',
    }
    return re.fullmatch(patterns[protocol], name) is not None


def unit_fragment(unit):
    # systemctl show rejects uninstantiated templates (e.g. antirkn-awg@).
    # Read their fixed unit-file locations in systemd's precedence order.
    if '@.service' in unit:
        for base in ('/etc/systemd/system', '/run/systemd/system', '/usr/local/lib/systemd/system', '/usr/lib/systemd/system'):
            path = Path(base) / unit
            if exists(path):
                return path
        return None
    raw = run(['/usr/bin/systemctl', 'show', unit, '--property=FragmentPath', '--value']).stdout.decode().strip()
    return Path(raw) if raw else None


def discover(protocol):
    if protocol not in ('vless', 'amneziawg', 'trusttunnel'):
        raise RemovalError('protocol_remove_unsupported')
    fixed = {
        'vless': ['/usr/local/x-ui', '/etc/x-ui', '/usr/bin/x-ui',
                  '/usr/local/bin/x-ui', '/usr/local/bin/xray', '/usr/local/etc/xray',
                  '/etc/xray', '/etc/antirkn-runner/panel.key'],
        'amneziawg': ['/usr/local/lib/antirkn-components/amneziawg',
                     '/etc/antirkn-components/amneziawg', '/etc/amneziawg',
                     '/etc/amnezia/amneziawg', '/opt/amnezia/awg',
                     '/usr/local/bin/amneziawg-go', '/usr/local/bin/awg', '/usr/local/bin/awg-quick'],
        'trusttunnel': ['/usr/local/lib/antirkn-components/trusttunnel',
                       '/etc/antirkn-components/trusttunnel', '/opt/trusttunnel', '/etc/trusttunnel',
                       '/usr/local/bin/trusttunnel_endpoint', '/usr/local/bin/setup_wizard'],
    }[protocol]
    paths = {Path(p) for p in fixed if exists(Path(p))}
    units = set()
    for command in ('list-units', 'list-unit-files'):
        raw = run(['/usr/bin/systemctl', command, '--all', '--type=service', '--no-legend', '--plain']).stdout.decode()
        for line in raw.splitlines():
            name = line.split()[0] if line.split() else ''
            if unit_matches(protocol, name):
                units.add(name)
    # Also catch disabled template units and per-endpoint services.
    for p in Path('/etc/systemd/system').glob('*.service'):
        if unit_matches(protocol, p.name):
            units.add(p.name)
    for unit in sorted(units):
        p = unit_fragment(unit)
        if p is not None:
            if p.parent.resolve() not in (Path('/etc/systemd/system'), Path('/usr/lib/systemd/system')):
                raise RemovalError('protocol_remove_unsupported')
            paths.add(p)
        dropin = Path('/etc/systemd/system') / (unit + '.d')
        if exists(dropin):
            paths.add(dropin)
    interfaces = []
    if protocol == 'amneziawg':
        from awg_external import discover_resources
        for resource in discover_resources():
            if resource['source'] == 'native':
                paths.add(Path(resource['path']))
                interfaces.append(dict(name=resource['name'], path=resource['path']))
        from awg_network import ROOT
        for p in ROOT.glob('*.conf'):
            interfaces.append(dict(name=p.stem, path=str(p)))
    elif protocol == 'trusttunnel':
        from tt_external import definitions
        issues = []
        for resource in definitions(issues):
            units.add(resource['unit'])
            for key in ('settings', 'hosts', 'binary', 'fragment'):
                paths.add(Path(resource[key]))
            from tt_common import toml_loads
            settings = toml_loads(Path(resource['settings']).read_text())
            for key in ('credentials_file', 'rules_file'):
                if settings.get(key):
                    p = Path(settings[key])
                    p = p if p.is_absolute() else Path(resource['base']) / p
                    if '..' in p.parts or len(p.parts) < 4:
                        raise RemovalError('protocol_remove_unsupported')
                    paths.add(p)
        if issues:
            raise RemovalError('protocol_remove_unsupported')
    elif protocol == 'vless':
        from panel_discovery import databases
        for path, source in databases():
            if source == 'systemd' and exists(path):
                # A nonstandard DB directory may hold unrelated files.
                paths.update(p for p in (path, Path(str(path)+'-wal'), Path(str(path)+'-shm')) if exists(p))
    containers = []
    docker = shutil.which('docker')
    if docker:
        ids = run([docker, 'ps', '-aq', '--no-trunc']).stdout.decode().split()
        for cid in ids:
            if not re.fullmatch('[a-f0-9]{64}', cid):
                raise RemovalError()
            meta = json.loads(run([docker, 'inspect', cid]).stdout)[0]
            image = meta['Config']['Image'].lower().split('@')[0].split(':')[0].split('/')[-1]
            names = {'vless': ('3x-ui', '3xui', 'x-ui', 'xray'),
                     'amneziawg': ('amnezia-awg', 'amnezia-awg2', 'amneziawg', 'awg'),
                     'trusttunnel': ('trusttunnel', 'trusttunnel-endpoint')}
            name = meta['Name'].lstrip('/')
            if image in names[protocol] or name.lower() in names[protocol]:
                if meta.get('HostConfig', {}).get('NetworkMode') == 'host' and protocol == 'amneziawg':
                    raise RemovalError('protocol_remove_unsupported')
                containers.append(dict(id=cid, name=name, image=meta['Image'], mounts=meta.get('Mounts', [])))
                # Remove only recognized configuration files in shared mounts;
                # never remove an entire host mount or a shared Docker volume.
                configs = {'vless': ['/etc/x-ui/x-ui.db', '/etc/x-ui/x-ui.db-wal', '/etc/x-ui/x-ui.db-shm'],
                           'amneziawg': ['/opt/amnezia/awg/awg0.conf', '/opt/amnezia/awg/wg0.conf'],
                           'trusttunnel': ['/opt/trusttunnel/vpn.toml', '/opt/trusttunnel/hosts.toml', '/opt/trusttunnel/credentials.toml']}
                for mount in meta.get('Mounts', []):
                    destination = Path(mount['Destination'])
                    for config in configs[protocol]:
                        config = Path(config)
                        if config == destination or destination in config.parents:
                            paths.add(Path(mount['Source']) / config.relative_to(destination))
    # Keep only outermost paths; shared directories are never removed by glob.
    paths = {p for p in paths if exists(p)}
    paths = sorted(p for p in paths if not any(parent in paths for parent in p.parents))
    record = dict(protocol=protocol, units=sorted(units), containers=containers,
                  paths={str(p): path_state(p) for p in paths}, interfaces=interfaces)
    record['fingerprint'] = digest(record)
    return record


def plan(protocol):
    record = discover(protocol)
    return dict(protocol=protocol, fingerprint=record['fingerprint'],
                services=record['units'], containers=[c['name'] for c in record['containers']],
                found=bool(record['paths'] or record['units'] or record['containers']))


class ProtocolRemoval:
    def __init__(self, store, request):
        self.store, self.request = store, request
        self.directory = store.directory / ('remove-' + request['id'])
        self.record_file = self.directory / 'plan.json'

    def step(self, checkpoint):
        if checkpoint == 0:
            prune_quarantines(self.store.directory, keep=2)
            record = discover(self.request['protocol'])
            if record['fingerprint'] != self.request['fingerprint']:
                raise RemovalError()
            self.directory.mkdir(mode=0o700, exist_ok=True)
            atomic_file(self.record_file, json.dumps(record).encode(), 0o600)
        else:
            record = json.loads(self.record_file.read_text())
            if record['fingerprint'] != self.request['fingerprint']:
                raise RemovalError()
            if checkpoint == 1:
                started = self.directory / 'started'
                if not started.exists():
                    if discover(record['protocol'])['fingerprint'] != record['fingerprint']:
                        raise RemovalError()
                    atomic_file(started, b'1', 0o600)
                for unit in record['units']:
                    if '@.service' not in unit:
                        run(['/usr/bin/systemctl', 'stop', unit])
                    run(['/usr/bin/systemctl', 'disable', unit], check=False)
                    enabled = run(['/usr/bin/systemctl', 'is-enabled', unit], check=False).stdout.decode().strip()
                    if enabled in ('enabled', 'enabled-runtime'):
                        raise RemovalError('protocol_remove_failed')
                for interface in record['interfaces']:
                    if Path('/sys/class/net', interface['name']).exists():
                        quick = shutil.which('awg-quick')
                        if quick is None:
                            raise RemovalError('protocol_remove_unsupported')
                        run([quick, 'down', interface['path']])
                    if re.fullmatch(r'ar[a-f0-9]{12}', interface['name']):
                        from awg_network import configure, ROOT
                        if (ROOT / (interface['name'] + '.network.json')).exists():
                            configure('down', interface['name'])
                for container in record['containers']:
                    ids = run(['docker', 'ps', '-aq', '--no-trunc']).stdout.decode().split()
                    if container['id'] in ids:
                        run(['docker', 'rm', '-f', container['id']])
            elif checkpoint == 2:
                for index, source in enumerate(record['paths']):
                    path, backup = Path(source), self.directory / ('data-' + str(index))
                    quarantine(path, backup)
                run(['/usr/bin/systemctl', 'daemon-reload'])
            elif checkpoint == 3:
                if any(exists(Path(p)) for p in record['paths']):
                    raise RemovalError()
                for unit in record['units']:
                    state = run(['/usr/bin/systemctl', 'is-active', unit], check=False).stdout.decode().strip()
                    if state in ('active', 'activating', 'deactivating', 'reloading'):
                        raise RemovalError('protocol_remove_failed')
                if record['containers']:
                    ids = run(['docker', 'ps', '-aq', '--no-trunc']).stdout.decode().split()
                    if any(c['id'] in ids for c in record['containers']):
                        raise RemovalError('protocol_remove_failed')
                if any(Path('/sys/class/net', i['name']).exists() for i in record['interfaces']):
                    raise RemovalError('protocol_remove_failed')
                table = {'vless':'vless_resources','amneziawg':'awg_resources','trusttunnel':'tt_resources'}[record['protocol']]
                with self.store.db:
                    self.store.db.execute('DELETE FROM ' + table)
                for unit in record['units']:
                    run(['/usr/bin/systemctl', 'reset-failed', unit], check=False)
                prune_quarantines(self.store.directory, keep=2)
            else:
                raise RemovalError()
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint+1, self.request['id']))
            self.store.event(self.request['id'], 'running', checkpoint+1, 4)
