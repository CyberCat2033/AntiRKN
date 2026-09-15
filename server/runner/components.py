"""Pinned server software lifecycle. Configuring endpoints/peers is separate.

One owned version directory and an atomic pointer; backups/checkpoints survive
SSH loss. Unknown installations and edits are never adopted automatically.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import tarfile
import time
import urllib.request
import zipfile

from component_releases import RELEASES
from panel import atomic_file, digest, safe_file, PanelError

BASE = Path('/usr/local/lib/antirkn-components')
BIN = Path('/usr/local/bin')
CONFIG = Path('/etc/antirkn-components')
UNITS = Path('/etc/systemd/system')
STEPS = 6


class ComponentError(Exception):
    def __init__(self, code='component_conflict'):
        self.code = code


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def release_hash(component):
    return hashlib.sha256(encode(RELEASES[component])).hexdigest()


def sync_directory(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def names(component):
    return ('trusttunnel_endpoint', 'setup_wizard') if component == 'trusttunnel' else ('amneziawg-go', 'awg', 'awg-quick')


def unit_name(component):
    return 'antirkn-trusttunnel.service' if component == 'trusttunnel' else 'antirkn-awg@.service'


def unit_source(component):
    if component == 'trusttunnel':
        body = ('Type=simple\nWorkingDirectory=/etc/antirkn-components/trusttunnel\n'
            'ExecStart=/usr/local/bin/trusttunnel_endpoint vpn.toml hosts.toml\n'
            'Restart=on-failure\nRestartSec=3\n')
    else:
        body = ('Type=oneshot\nRemainAfterExit=yes\n'
            'Environment=PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
            'Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=/usr/local/bin/amneziawg-go\n'
            'ExecStart=/usr/local/bin/awg-quick up /etc/antirkn-components/amneziawg/%i.conf\n'
            'ExecStop=/usr/local/bin/awg-quick down /etc/antirkn-components/amneziawg/%i.conf\n')
    return ('[Unit]\nDescription=AntiRKN ' + component + '\nAfter=network-online.target\n'
        'Wants=network-online.target\n[Service]\nUMask=0077\n' + body +
        '[Install]\nWantedBy=multi-user.target\n').encode()


def active_units(component):
    patterns = ['antirkn-trusttunnel.service', 'antirkn-tt@*.service'] if component == 'trusttunnel' else ['antirkn-awg@*.service']
    result = subprocess.run(['/usr/bin/systemctl', 'list-units', '--state=active,activating',
        '--type=service', '--no-legend', '--plain', *patterns], capture_output=True, timeout=20)
    if result.returncode:
        raise ComponentError('component_prerequisites')
    units = [line.split()[0] for line in result.stdout.decode().splitlines() if line.strip()]
    if any(not re.fullmatch(r'antirkn-trusttunnel\.service|antirkn-tt@[a-f0-9]{32}\.service|antirkn-awg@[A-Za-z0-9_=+.-]{1,15}\.service', u) for u in units):
        raise ComponentError()
    return sorted(units)


def config_snapshot(component):
    root = CONFIG / component
    if not root.exists() and not root.is_symlink():
        return {}
    safe_directory(CONFIG)
    safe_directory(root)
    result = {}
    for p in root.rglob('*'):
        if len(result) >= 10000:
            raise ComponentError()
        if p.is_symlink():
            raise ComponentError()
        if p.is_dir():
            safe_directory(p)
        else:
            safe_file(p, 1024 * 1024)
        result[str(p.relative_to(root))] = snapshot(p)
    return result


def safe_directory(path):
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
        raise ComponentError()


def snapshot(path):
    if not path.exists() and not path.is_symlink():
        return None
    st = path.lstat()
    if stat.S_ISLNK(st.st_mode):
        return ['link', os.readlink(path)]
    if stat.S_ISREG(st.st_mode):
        if st.st_size > 32 * 1024 * 1024:
            raise ComponentError()
        return ['file', st.st_uid, st.st_mode, digest(path)]
    return ['directory', st.st_uid, st.st_mode, st.st_ino]


def installed(component):
    root = BASE / component
    if not root.exists() and not root.is_symlink():
        return None
    safe_directory(BASE)
    safe_directory(root)
    pointer = root / 'current'
    if not pointer.is_symlink():
        # An interrupted first install has no committed public version yet.
        return None
    target = os.readlink(pointer)
    if not re.fullmatch(r'versions/[a-f0-9]{64}', target):
        raise ComponentError()
    version = root / target
    safe_directory(root / 'versions')
    safe_directory(version)
    safe_file(version / 'manifest.json')
    record = json.loads((version / 'manifest.json').read_text())
    if record['component'] != component or record['release'] != target.split('/')[1]:
        raise ComponentError()
    for name, expected in record['files'].items():
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name):
            raise ComponentError()
        safe_file(version / name, 100 * 1024 * 1024)
        if digest(version / name) != expected:
            raise ComponentError()
    if not set(names(component)) <= set(record['files']):
        raise ComponentError()
    return record


def external_paths(component):
    if component == 'trusttunnel':
        return [Path(p) for p in ('/opt/trusttunnel', '/etc/trusttunnel',
            '/etc/systemd/system/trusttunnel.service', '/lib/systemd/system/trusttunnel.service',
            '/usr/bin/trusttunnel_endpoint')]
    return [Path(p) for p in ('/usr/bin/awg', '/usr/bin/amneziawg-go', '/usr/bin/awg-quick',
        '/opt/amnezia', '/etc/amnezia', '/etc/amneziawg', '/sys/module/amneziawg',
        '/etc/systemd/system/awg-quick@.service', '/lib/systemd/system/awg-quick@.service')]


def component_plan(component):
    if component not in RELEASES:
        raise ComponentError('component_incompatible')
    release = RELEASES[component]
    record, conflict = None, False
    try:
        record = installed(component)
    except (ValueError, KeyError, TypeError, OSError, ComponentError, PanelError):
        conflict = True
    paths = external_paths(component) + [BIN / name for name in names(component)]
    unit = UNITS / unit_name(component)
    if unit.exists() or unit.is_symlink():
        try:
            safe_file(unit)
            conflict |= unit.read_bytes() != unit_source(component) or record is None
        except (OSError, ValueError, PanelError):
            conflict = True
    observed = {str(p): snapshot(p) for p in paths}
    for path in paths:
        value = observed[str(path)]
        own_link = path in [BIN / name for name in names(component)] and value == ['link', str(BASE / component / 'current' / path.name)]
        if value is not None and not own_link:
            conflict = True
    containers = []
    if shutil.which('docker'):
        result = subprocess.run(['docker', 'ps', '-a', '--format', '{{.Image}} {{.Names}}'],
            capture_output=True, timeout=20)
        if result.returncode:
            conflict = True
        else:
            containers = sorted(line for line in result.stdout.decode().splitlines()
                if any(n in line.lower() for n in ('trusttunnel',) if component == 'trusttunnel')
                or component == 'amneziawg' and any(n in line.lower() for n in ('amnezia', 'amneziawg', 'awg')))
            conflict |= bool(containers)
    missing = []
    distro = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    if distro.get('ID', '').strip('"') != 'ubuntu' or platform.machine() != 'x86_64':
        missing.append('ubuntu_x64')
    if not Path('/etc/ssl/certs/ca-certificates.crt').exists():
        missing.append('ca_certificates')
    if component == 'amneziawg' and not Path('/dev/net/tun').exists():
        missing.append('tun')
    required = (2000 if component == 'amneziawg' else 150) * 1024 * 1024
    if min(shutil.disk_usage('/usr/local').free, shutil.disk_usage('/var/lib').free) < required:
        missing.append('disk_space')
    state = 'conflict' if conflict else 'missing' if record is None else 'current' if record['release'] == release_hash(component) else 'update'
    # Never downgrade or cross an unknown generation with a generic updater.
    if state == 'update' and (record['version'].split('.')[0] != release['version'].split('.')[0]
            or tuple(map(int, record['version'].split('.'))) > tuple(map(int, release['version'].split('.')))):
        state = 'incompatible'
    if state == 'update' and component == 'amneziawg' and (
            not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', record.get('toolsVersion') or '')
            or record['toolsVersion'].split('.')[0] != release['toolsVersion'].split('.')[0]
            or tuple(map(int, record['toolsVersion'].split('.'))) > tuple(map(int, release['toolsVersion'].split('.')))):
        state = 'incompatible'
    data = dict(component=component, state=state, supported=not missing,
        prerequisites=missing, version=release['version'], toolsVersion=release.get('toolsVersion'),
        installedVersion=record['version'] if record else None, release=release_hash(component),
        archives=release['archives'], previous=record, paths=observed, containers=containers,
        activeUnits=active_units(component), unit=snapshot(unit), config=config_snapshot(component))
    data['fingerprint'] = hashlib.sha256(encode(data)).hexdigest()
    return data


def extract(archive, destination, kind, maximum=600 * 1024 * 1024):
    """No links/devices/traversal/duplicate entries, including on Python 3.8."""
    destination.mkdir(mode=0o700, exist_ok=True)
    seen, total = set(), 0
    source = zipfile.ZipFile(archive) if kind == 'zip' else tarfile.open(archive, 'r:gz')
    try:
        entries = source.infolist() if kind == 'zip' else source.getmembers()
        if len(entries) > 30000:
            raise ComponentError('component_checksum_failed')
        for item in entries:
            name = item.filename if kind == 'zip' else item.name
            path = PurePosixPath(name)
            size = item.file_size if kind == 'zip' else item.size
            directory = item.is_dir() if kind == 'zip' else item.isdir()
            regular = not stat.S_ISLNK(item.external_attr >> 16) if kind == 'zip' else item.isfile() or directory
            total += size
            if path.is_absolute() or '..' in path.parts or '\\' in name or name in seen or not regular or total > maximum:
                raise ComponentError('component_checksum_failed')
            seen.add(name)
            target = destination.joinpath(*path.parts)
            target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            if directory:
                target.mkdir(mode=0o700, exist_ok=True)
            else:
                if target.is_symlink():
                    raise ComponentError()
                with (source.open(item) if kind == 'zip' else source.extractfile(item)) as src, target.open('wb') as dst:
                    shutil.copyfileobj(src, dst)
                target.chmod(0o755 if kind != 'zip' and item.mode & 0o111 else 0o600)
    finally:
        source.close()


class ComponentInstaller:
    def __init__(self, store, request):
        self.store, self.request = store, request
        self.component = request['component']
        self.release = RELEASES[self.component]
        self.directory = store.directory / ('component-' + request['id'])
        self.root = BASE / self.component

    def checkpoint(self, number, code):
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (number, self.request['id']))
            self.store.event(self.request['id'], code, number, STEPS)

    def cancelled(self):
        return bool(self.store.db.execute('SELECT cancel FROM jobs WHERE id=?', (self.request['id'],)).fetchone()[0])

    def download(self, name, artifact):
        target = self.directory / (name + '.archive')
        if target.exists() and digest(target) == artifact['sha256']:
            return target
        temp = self.directory / (name + '.download')
        deadline, total = time.monotonic() + 900, 0
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with client.open(artifact['url'], timeout=30) as response, temp.open('wb') as output:
                if not response.geturl().startswith('https://'):
                    raise ComponentError('component_download_failed')
                while True:
                    if self.cancelled():
                        raise ComponentError('cancelled')
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > artifact['bytes'] or time.monotonic() > deadline:
                        raise ComponentError('component_download_failed')
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            if total != artifact['bytes'] or digest(temp) != artifact['sha256']:
                raise ComponentError('component_checksum_failed')
            os.replace(temp, target)
            sync_directory(self.directory)
            return target
        except ComponentError:
            raise
        except (OSError, ValueError):
            raise ComponentError('component_download_failed')

    def verify(self, directory):
        for name, expected in (('trusttunnel_endpoint', self.release['version']),) if self.component == 'trusttunnel' else (
                ('amneziawg-go', self.release['version']), ('awg', self.release['toolsVersion'])):
            result = subprocess.run([str(directory / name), '--version'], capture_output=True, timeout=20)
            if result.returncode or expected not in result.stdout.decode(errors='replace'):
                raise ComponentError('component_check_failed')

    def build(self):
        output = self.directory / 'output'
        output.mkdir(mode=0o700, exist_ok=True)
        for name, artifact in self.release['archives'].items():
            extract(self.directory / (name + '.archive'), self.directory / name, 'zip' if name == 'tools' else 'tar')
            for filename, expected in artifact.get('files', {}).items():
                matches = list((self.directory / name).glob('*/' + filename))
                if len(matches) != 1 or digest(matches[0]) != expected:
                    raise ComponentError('component_checksum_failed')
                shutil.copyfile(matches[0], output / filename)
        if self.component == 'amneziawg':
            source = self.directory / 'source' / ('amneziawg-go-' + self.release['commit'])
            (source / 'version.go').write_text('package main\nconst Version = "v' + self.release['version'] + '"\n')
            env = dict(PATH='/usr/bin:/bin', HOME=str(self.directory), CGO_ENABLED='0', GOOS='linux', GOARCH='amd64',
                GOTOOLCHAIN='local', GOPROXY='https://proxy.golang.org', GOSUMDB='sum.golang.org',
                GOCACHE=str(self.directory / 'go-cache'), GOPATH=str(self.directory / 'go-path'), GOMAXPROCS='2')
            # No make/generate hooks; -mod=readonly preserves the upstream sums.
            process = subprocess.Popen([str(self.directory / 'go/go/bin/go'), 'build', '-mod=readonly', '-trimpath',
                '-buildvcs=false', '-o', str(output / 'amneziawg-go'), '.'], cwd=source, env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            deadline = time.monotonic() + 1200
            try:
                while process.poll() is None:
                    if self.cancelled() or time.monotonic() > deadline:
                        import signal
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                        raise ComponentError('cancelled' if self.cancelled() else 'component_build_failed')
                    time.sleep(0.3)
                if process.returncode:
                    raise ComponentError('component_build_failed')
            finally:
                if process.poll() is None:
                    process.terminate()
        for name in names(self.component):
            (output / name).chmod(0o755)
        self.verify(output)
        for path in output.iterdir():
            with path.open('rb') as stream:
                os.fsync(stream.fileno())
        sync_directory(output)

    def step(self, number):
        if number == 0:
            plan = component_plan(self.component)
            if plan['fingerprint'] != self.request['fingerprint'] or plan['state'] not in ('missing', 'update'):
                raise ComponentError()
            if not plan['supported']:
                raise ComponentError('component_prerequisites')
            self.directory.mkdir(mode=0o700, exist_ok=True)
            atomic_file(self.directory / 'plan.json', encode(plan))
            self.checkpoint(1, 'component_prepared')
            return
        safe_directory(self.directory)
        safe_file(self.directory / 'plan.json')
        plan = json.loads((self.directory / 'plan.json').read_text())
        if plan['fingerprint'] != self.request['fingerprint']:
            raise ComponentError()
        if number == 1:
            for name, artifact in self.release['archives'].items():
                self.download(name, artifact)
            self.checkpoint(2, 'component_downloaded')
        elif number == 2:
            self.build()
            self.checkpoint(3, 'component_built')
        elif number == 3:
            # Revalidate before the first public effect. An interrupted staging
            # directory is private; the published pointer is still unchanged.
            if component_plan(self.component)['fingerprint'] != plan['fingerprint']:
                raise ComponentError()
            backup = self.directory / 'config-backup'
            backup.mkdir(mode=0o700, exist_ok=True)
            for name, entry in plan['config'].items():
                if entry[0] == 'file':
                    dest = backup / name
                    dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    atomic_file(dest, (CONFIG / self.component / name).read_bytes())
            for directory in (BASE, self.root, self.root / 'versions'):
                directory.mkdir(mode=0o755, exist_ok=True)
                safe_directory(directory)
            target = self.root / 'versions' / release_hash(self.component)
            staging = self.root / 'versions' / ('.' + self.request['id'])
            staging.mkdir(mode=0o755, exist_ok=True)
            hashes = {}
            for file in (self.directory / 'output').iterdir():
                safe_file(file, 100 * 1024 * 1024)
                atomic_file(staging / file.name, file.read_bytes(), 0o755 if file.name in names(self.component) else 0o644)
                hashes[file.name] = digest(file)
            record = dict(component=self.component, version=self.release['version'],
                toolsVersion=self.release.get('toolsVersion'), release=release_hash(self.component), files=hashes)
            atomic_file(staging / 'manifest.json', encode(record), 0o644)
            atomic_file(self.directory / 'target.json', encode(record))
            if not target.exists():
                os.rename(staging, target)
                sync_directory(target.parent)
            if (target / 'manifest.json').read_bytes() != encode(record):
                raise ComponentError()
            self.checkpoint(4, 'component_staged')
        elif number == 4:
            safe_file(self.directory / 'target.json')
            target = json.loads((self.directory / 'target.json').read_text())
            current = installed(self.component)
            if current not in (plan['previous'], target):
                raise ComponentError()
            if active_units(self.component) != plan['activeUnits']:
                raise ComponentError()
            if config_snapshot(self.component) != plan['config']:
                raise ComponentError()
            # Check all public paths before the pointer change, and tolerate
            # only this operation's exact links when resuming after a crash.
            for path, before in plan['paths'].items():
                now = snapshot(Path(path))
                own = ['link', str(self.root / 'current' / Path(path).name)]
                if now != before and not (Path(path).parent == BIN and now == own):
                    raise ComponentError()
            unit = UNITS / unit_name(self.component)
            if snapshot(unit) != plan['unit']:
                safe_file(unit)
                if unit.read_bytes() != unit_source(self.component):
                    raise ComponentError()
            # Configurations and keys are untouched. The previous complete
            # immutable directory plus this journal is the software backup.
            pointer = self.root / 'current'
            temp = self.root / '.current-next'
            if temp.is_symlink():
                temp.unlink()
            os.symlink('versions/' + release_hash(self.component), temp)
            os.replace(temp, pointer)
            sync_directory(self.root)
            for name in names(self.component):
                link = BIN / name
                expected = str(self.root / 'current' / name)
                if link.exists() or link.is_symlink():
                    if not link.is_symlink() or os.readlink(link) != expected:
                        raise ComponentError()
                else:
                    os.symlink(expected, link)
            sync_directory(BIN)
            CONFIG.mkdir(mode=0o700, exist_ok=True)
            safe_directory(CONFIG)
            (CONFIG / self.component).mkdir(mode=0o700, exist_ok=True)
            atomic_file(unit, unit_source(self.component), 0o644)
            subprocess.run(['/usr/bin/systemctl', 'daemon-reload'], check=True, timeout=30,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.checkpoint(5, 'component_switched')
        elif number == 5:
            record = installed(self.component)
            if record != json.loads((self.directory / 'target.json').read_text()):
                raise ComponentError()
            self.verify(self.root / 'current')
            for unit in plan['activeUnits']:
                subprocess.run(['/usr/bin/systemctl', 'restart', unit], check=True, timeout=90,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', unit], check=True, timeout=20)
            self.checkpoint(6, 'component_checked')

    def abort(self):
        # Staging/pointer change may have completed without its checkpoint.
        return 'partially_applied' if (self.directory / 'target.json').exists() else 'cancelled'
