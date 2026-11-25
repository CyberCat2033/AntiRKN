"""Owned, checkpointed installation of the pinned 3x-ui distribution.

No API/DB editing of pre-existing panels and no remote install script execution.
"""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import platform
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import time
import urllib.request

from panel_release import RELEASE

PANEL = Path('/usr/local/x-ui')
DATABASE = Path('/etc/x-ui')
UNIT = Path('/etc/systemd/system/x-ui.service')
BOOT_UNIT = Path('/etc/systemd/system/antirkn-x-ui-bootstrap.service')
KEY = Path('/etc/antirkn-runner/panel.key')
CLI = Path('/usr/bin/x-ui')
STEPS = 6


class PanelError(Exception):
    def __init__(self, code):
        self.code = code


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1048576), b''):
            value.update(data)
    return value.hexdigest()


def safe_file(path, max_size=1048576):
    meta = path.lstat()
    if (meta.st_uid != 0 or meta.st_mode & 0o022 or not stat.S_ISREG(meta.st_mode)
            or meta.st_size > max_size):
        raise PanelError('panel_conflict')


def atomic_file(path, data, mode=0o600):
    # A unique, exclusively created name: the RPC process and the daemon may
    # write the same record at once, and a fixed name let them interleave.
    # The suffix stays, staging scans skip files ending with it.
    temp = path.with_name('.' + path.name + '.' + secrets.token_hex(8) + '.antirkn-tmp')
    # All parents are root-owned and never supplied by the RPC caller.
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(str(temp), str(path))
    except BaseException:
        try:
            os.unlink(str(temp))
        except OSError:
            pass
        raise
    fd = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def command(argv, timeout=30, input_data=None):
    result = subprocess.run(argv, input=input_data, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, timeout=timeout, env={
            'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8',
            'XUI_DB_FOLDER': str(DATABASE), 'XUI_BIN_FOLDER': str(PANEL / 'bin'),
            'XUI_LOG_FOLDER': str(DATABASE / 'logs'), 'XUI_ENABLE_FAIL2BAN': 'false'})
    if result.returncode != 0:
        raise PanelError('panel_api_failed')
    return result.stdout


def systemctl(*args):
    return command(['/usr/bin/systemctl', *args])


def port_free(port):
    try:
        with socket.socket() as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(('127.0.0.1', port))
        return True
    except OSError:
        return False


def prerequisites():
    missing = []
    distro = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    if distro.get('ID', '').strip('"') != 'ubuntu' or platform.machine() != 'x86_64':
        missing.append('ubuntu_x64')
    if sys.version_info < (3, 8) or not Path('/run/systemd/system').is_dir():
        missing.append('python_systemd')
    for path in ('/usr/bin/nsenter', '/usr/bin/systemctl'):
        if not Path(path).is_file():
            missing.append('util_linux_systemd')
    if not Path('/etc/ssl/certs/ca-certificates.crt').is_file():
        missing.append('ca_certificates')
    if shutil.disk_usage('/usr/local').free < 600 * 1024 * 1024:
        missing.append('disk_space')
    return sorted(set(missing))


def panel_plan(port):
    if port == 0:
        for _ in range(128):
            candidate = 10000 + secrets.randbelow(55536)
            if port_free(candidate):
                port = candidate
                break
        else:
            raise PanelError('panel_port_busy')
    paths = [PANEL, DATABASE, UNIT, BOOT_UNIT,
        Path('/usr/bin/x-ui'), Path('/usr/local/bin/x-ui'),
        Path('/lib/systemd/system/x-ui.service'), Path('/usr/bin/xray'),
        Path('/usr/local/bin/xray'), Path('/etc/xray'), Path('/usr/local/etc/xray'),
        Path('/etc/systemd/system/xray.service'), Path('/lib/systemd/system/xray.service')]
    snapshot = {}
    for path in paths:
        try:
            st = path.lstat()
            snapshot[str(path)] = [st.st_mode, st.st_uid, st.st_ino, st.st_mtime_ns]
        except FileNotFoundError:
            snapshot[str(path)] = None
    # A normal, stopped Docker installation is also pre-existing software.
    docker = shutil.which('docker')
    containers = []
    if docker:
        try:
            raw = command([docker, 'ps', '-a', '--format', '{{.Image}} {{.Names}}'], timeout=15).decode()
            containers = sorted(line for line in raw.splitlines()
                if any(value in line.lower() for value in ('3x-ui', '3xui', 'x-ui', 'xray')))
        except (PanelError, subprocess.SubprocessError):
            containers = ['unknown']
    snapshot['containers'] = containers
    missing = prerequisites()
    available = port_free(port)
    snapshot.update(port=port, available=available, prerequisites=missing,
                    release=RELEASE['sha256'])
    state = 'missing'
    if any(snapshot[str(p)] for p in paths) or containers:
        state = 'existing'
    fingerprint = hashlib.sha256(json.dumps(snapshot, sort_keys=True).encode()).hexdigest()
    return dict(state=state, supported=not missing, prerequisites=missing,
        port=port, portAvailable=available, fingerprint=fingerprint,
        panelVersion=RELEASE['panelVersion'], xrayVersion=RELEASE['xrayVersion'],
        sha256=RELEASE['sha256'], url=RELEASE['url'], bytes=RELEASE['bytes'])


def access_for(job_id, port):
    # Only a random root key is stored; job/event records never contain passwords.
    safe_file(KEY, 32)
    key = KEY.read_bytes()
    if len(key) != 32:
        raise PanelError('panel_conflict')
    password = base64.urlsafe_b64encode(hmac.new(key,
        ('3x-ui/admin/' + job_id).encode(), hashlib.sha256).digest()).decode().rstrip('=')
    path_file = DATABASE / '.antirkn-webpath'
    base_path = '/'
    if path_file.exists():
        safe_file(path_file, 128)
        base_path = path_file.read_text()
        import re
        if not re.fullmatch(r'/[A-Za-z0-9_-]{24}/', base_path):
            raise PanelError('panel_conflict')
    versions = {k: RELEASE[k] for k in ('panelVersion', 'xrayVersion')}
    version_file = DATABASE / '.antirkn-versions'
    if version_file.exists():
        safe_file(version_file, 1024)
        recorded = json.loads(version_file.read_text())
        if recorded.get('id') != job_id:
            raise PanelError('panel_conflict')
        versions = {k: recorded[k] for k in versions}
    return dict(id=job_id, port=port, basePath=base_path, username='antirkn', password=password, **versions)



def install_cli():
    """Install the unmodified, pinned upstream menu without running install.sh."""
    if CLI.exists() or CLI.is_symlink():
        safe_file(CLI, 1024 * 1024)
        if not os.access(CLI, os.X_OK): raise PanelError('panel_conflict')
        return  # Preserve any administrator-installed menu.
    if not (PANEL / 'x-ui').is_file(): raise PanelError('panel_existing')
    bundled = PANEL / 'x-ui.sh'
    if bundled.is_file():
        safe_file(bundled, RELEASE['cli']['bytes'])
        raw = bundled.read_bytes()
    else:
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with client.open(RELEASE['cli']['url'], timeout=30) as response:
                if not response.geturl().startswith('https://'): raise PanelError('panel_download_failed')
                raw = response.read(RELEASE['cli']['bytes'] + 1)
        except OSError as error:
            raise PanelError('panel_download_failed') from error
    if len(raw) != RELEASE['cli']['bytes'] or hashlib.sha256(raw).hexdigest() != RELEASE['cli']['sha256']:
        raise PanelError('panel_checksum_failed')
    import tempfile
    fd, temporary = tempfile.mkstemp(prefix='.antirkn-x-ui-', dir=str(CLI.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw); stream.flush(); os.fsync(stream.fileno())
        os.chmod(temporary, 0o755)
        os.link(temporary, str(CLI))  # Exclusive: never replace another writer.
        parent = os.open(str(CLI.parent), os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(parent)
        finally: os.close(parent)
    finally:
        os.unlink(temporary)


def unit_source(private=False):
    return ('[Unit]\nDescription=AntiRKN managed 3x-ui\nAfter=network.target\n'
        '[Service]\nType=simple\nWorkingDirectory=/usr/local/x-ui\n'
        'ExecStart=/usr/local/x-ui/x-ui\nRestart=on-failure\nRestartSec=3\n'
        'UMask=0077\nEnvironment=XUI_DB_FOLDER=/etc/x-ui\n'
        'Environment=XUI_BIN_FOLDER=/usr/local/x-ui/bin\n'
        'Environment=XUI_LOG_FOLDER=/etc/x-ui/logs\n'
        'Environment=XUI_ENABLE_FAIL2BAN=false\n'
        'StandardOutput=null\nStandardError=null\n'
        + ('PrivateNetwork=yes\n' if private else '')
        + '[Install]\nWantedBy=multi-user.target\n').encode()


class PanelInstaller:
    release = RELEASE
    def __init__(self, store, request):
        self.store, self.request = store, request
        self.directory = store.directory / ('panel-' + request['id'])
        self.ownership = self.directory / 'ownership.json'

    def pulse(self):
        self.store.heartbeat()

    def cancelled(self):
        return bool(self.store.db.execute('SELECT cancel FROM jobs WHERE id=?',
            (self.request['id'],)).fetchone()[0])

    def owns(self):
        if not self.ownership.is_file():
            return False
        safe_file(self.ownership)
        record = json.loads(self.ownership.read_text())
        return record == dict(id=self.request['id'], fingerprint=self.request['fingerprint'])

    def checkpoint(self, number, code):
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (number, self.request['id']))
            self.store.event(self.request['id'], code, number, STEPS)

    def assert_owned(self):
        if not self.owns():
            raise PanelError('panel_conflict')
        # A fresh installation only: changes by an administrator block resume.
        for path in (PANEL, DATABASE):
            if path.exists():
                st = path.lstat()
                if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
                    raise PanelError('panel_conflict')
                marker = path / '.antirkn-owner'
                safe_file(marker, 32)
                if marker.read_text() != self.request['id']:
                    raise PanelError('panel_conflict')
        for path, private in ((UNIT, False), (BOOT_UNIT, True)):
            if path.exists() or path.is_symlink():
                safe_file(path)
                if path.read_bytes() != unit_source(private):
                    raise PanelError('panel_conflict')

    def download(self):
        release = self.release
        archive = self.directory / 'release.tar.gz'
        if archive.is_file() and digest(archive) == release['sha256']:
            return archive
        temp = self.directory / 'download.tmp'
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        total = 0
        deadline = time.monotonic() + 900
        try:
            with client.open(release['url'], timeout=30) as response, temp.open('wb') as output:
                if not response.geturl().startswith('https://'):
                    raise PanelError('panel_download_failed')
                while True:
                    self.pulse()
                    if self.cancelled():
                        raise PanelError('cancelled')
                    data = response.read(262144)
                    if not data:
                        break
                    total += len(data)
                    if total > release['bytes'] or time.monotonic() > deadline:
                        raise PanelError('panel_download_failed')
                    output.write(data)
                output.flush()
                os.fsync(output.fileno())
        except (OSError, ValueError) as error:
            raise PanelError('panel_download_failed') from error
        if total != release['bytes'] or digest(temp) != release['sha256']:
            raise PanelError('panel_checksum_failed')
        os.replace(str(temp), str(archive))
        return archive

    def unpack(self, archive):
        release = self.release
        if digest(archive) != release['sha256']:
            raise PanelError('panel_checksum_failed')
        target = self.directory / 'extracted'
        target.mkdir(mode=0o700, exist_ok=True)
        with tarfile.open(str(archive), 'r:gz') as bundle:
            seen, expanded = set(), 0
            for entry in bundle.getmembers():
                name = PurePosixPath(entry.name)
                if name.is_absolute() or '..' in name.parts or not (entry.isfile() or entry.isdir()):
                    raise PanelError('panel_checksum_failed')
                relative = str(name)[5:] if str(name).startswith('x-ui/') else ''
                if relative not in release['files']:
                    continue
                if relative in seen or entry.size > 200 * 1024 * 1024:
                    raise PanelError('panel_checksum_failed')
                seen.add(relative)
                expanded += entry.size
                if expanded > 500 * 1024 * 1024:
                    raise PanelError('panel_checksum_failed')
                path = target / relative
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with bundle.extractfile(entry) as src, path.open('wb') as dst:
                    shutil.copyfileobj(src, dst)
                    dst.flush(); os.fsync(dst.fileno())
                if digest(path) != release['files'][relative]:
                    raise PanelError('panel_checksum_failed')
                path.chmod(0o755 if relative in ('x-ui', 'x-ui.sh', 'bin/xray-linux-amd64') else 0o644)
                self.pulse()
            if seen != set(release['files']):
                raise PanelError('panel_checksum_failed')
        return target

    def extract(self, archive):
        target = self.unpack(archive)
        # Only after a complete verified extraction do we reserve the destinations.
        if not self.owns():
            current = panel_plan(self.request['port'])
            if current['fingerprint'] != self.request['fingerprint']:
                raise PanelError('panel_conflict')
            atomic_file(self.ownership, json.dumps(dict(id=self.request['id'],
                fingerprint=self.request['fingerprint'])).encode())
        self.assert_owned()
        if not PANEL.exists():
            # Atomic rename on the same filesystem: staging lives under /usr/local.
            staging = PANEL.with_name('.x-ui-antirkn-' + self.request['id'])
            if staging.exists():
                shutil.rmtree(str(staging))
            shutil.copytree(str(target), str(staging))
            atomic_file(staging / '.antirkn-owner', self.request['id'].encode())
            staging.chmod(0o755)
            (staging / 'bin').chmod(0o755)
            os.rename(str(staging), str(PANEL))
        if not (PANEL / 'x-ui.sh').exists():
            atomic_file(PANEL / 'x-ui.sh', (target / 'x-ui.sh').read_bytes(), 0o755)
        for name, expected in RELEASE['files'].items():
            path = PANEL / name
            safe_file(path, 200 * 1024 * 1024)
            if digest(path) != expected:
                raise PanelError('panel_conflict')
        if not DATABASE.exists():
            staging_db = DATABASE.with_name('.x-ui-antirkn-' + self.request['id'])
            staging_db.mkdir(mode=0o700, exist_ok=True)
            atomic_file(staging_db / '.antirkn-owner', self.request['id'].encode())
            os.rename(str(staging_db), str(DATABASE))
        if not KEY.exists():
            KEY.parent.mkdir(mode=0o700, exist_ok=True)
            meta = KEY.parent.lstat()
            if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != 0 or meta.st_mode & 0o077:
                raise PanelError('panel_conflict')
            atomic_file(KEY, secrets.token_bytes(32))

    def configure(self):
        self.assert_owned()
        path_file = DATABASE / '.antirkn-webpath'
        if not path_file.exists():
            atomic_file(path_file, ('/' + secrets.token_urlsafe(18) + '/').encode())
        access = access_for(self.request['id'], self.request['port'])
        command([str(PANEL / 'x-ui'), 'setting', '-listenIP', '127.0.0.1',
                 '-port', str(self.request['port']), '-webBasePath', access['basePath']], timeout=90)
        atomic_file(BOOT_UNIT, unit_source(True), 0o644)
        systemctl('daemon-reload')
        systemctl('start', BOOT_UNIT.name)
        access = access_for(self.request['id'], self.request['port'])
        helper = Path(__file__).with_name('panel_api.py')
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            self.pulse()
            pid = systemctl('show', '-p', 'MainPID', '--value', BOOT_UNIT.name).decode().strip()
            if pid.isdecimal() and int(pid) > 1:
                try:
                    command(['/usr/bin/nsenter', '--target', pid, '--net',
                             '/usr/bin/python3', '-I', str(helper)], timeout=60,
                            input_data=json.dumps(access).encode())
                    break
                except (PanelError, subprocess.SubprocessError):
                    pass
            time.sleep(1)
        else:
            raise PanelError('panel_api_failed')
        systemctl('stop', BOOT_UNIT.name)

    def start(self):
        self.assert_owned()
        install_cli()
        if not UNIT.exists():
            if not port_free(self.request['port']):
                raise PanelError('panel_port_busy')
            atomic_file(UNIT, unit_source(False), 0o644)
        systemctl('daemon-reload')
        systemctl('enable', '--now', UNIT.name)

    def verify(self):
        from panel_api import PanelApi
        self.assert_owned()
        access = access_for(self.request['id'], self.request['port'])
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            self.pulse()
            try:
                api = PanelApi(access['port'], access.get('basePath', '/'))
                api.login(access['username'], access['password'])
                settings = api.call('/panel/api/setting/all', {})
                inbounds = api.call('/panel/api/inbounds/list')
                status = api.call('/panel/api/server/status')
                # Right after start 3x-ui answers success with an empty
                # status (obj null, xray null) until its collector runs: not
                # ready yet, retry. An AttributeError here used to crash the
                # runner daemon on every fresh panel install.
                xray = status.get('xray') if isinstance(status, dict) else None
                if not isinstance(settings, dict) or not isinstance(xray, dict):
                    raise ValueError('panel_api_failed')
                if (settings.get('webListen') != '127.0.0.1'
                        or settings.get('webPort') != access['port']
                        or settings.get('webBasePath') != access['basePath']
                        or settings.get('subEnable') is not False
                        or inbounds != []):
                    raise PanelError('panel_conflict')
                if (xray.get('state') != 'running'
                        or xray.get('version') != RELEASE['xrayVersion']
                        or status.get('panelVersion') != RELEASE['panelVersion']):
                    raise ValueError('panel_api_failed')
                if command([str(PANEL / 'x-ui'), '-v']).decode().strip() != RELEASE['panelVersion']:
                    raise PanelError('panel_conflict')
                version = command([str(PANEL / 'bin/xray-linux-amd64'), 'version']).decode()
                if not version.startswith('Xray ' + RELEASE['xrayVersion'] + ' '):
                    raise PanelError('panel_conflict')
                systemctl('is-active', '--quiet', UNIT.name)
                return
            except (OSError, ValueError, subprocess.SubprocessError):
                time.sleep(1)
        raise PanelError('panel_api_failed')

    def step(self, checkpoint):
        if prerequisites():
            raise PanelError('panel_prerequisites')
        if checkpoint > 0:
            with self.store.db:
                self.store.event(self.request['id'], ['running', 'panel_downloading',
                    'panel_extracting', 'panel_configuring', 'panel_starting',
                    'panel_checking'][checkpoint], checkpoint, STEPS)
        if checkpoint == 0:
            current = panel_plan(self.request['port'])
            if not current['supported']:
                raise PanelError('panel_prerequisites')
            if current['state'] != 'missing':
                raise PanelError('panel_existing')
            if not current['portAvailable']:
                raise PanelError('panel_port_busy')
            if current['fingerprint'] != self.request['fingerprint']:
                raise PanelError('panel_conflict')
            self.directory.mkdir(mode=0o700, exist_ok=True)
        elif checkpoint == 1:
            self.download()
        elif checkpoint == 2:
            self.extract(self.directory / 'release.tar.gz')
        elif checkpoint == 3:
            self.configure()
        elif checkpoint == 4:
            self.start()
        elif checkpoint == 5:
            self.verify()
        self.checkpoint(checkpoint + 1, ['running', 'panel_download', 'panel_extract',
            'panel_configure', 'panel_start', 'panel_check'][checkpoint])

    def abort(self):
        # The durable result retains applied files. Never claim cancellation undid them.
        if self.owns():
            try:
                systemctl('stop', BOOT_UNIT.name)
            except (PanelError, OSError, subprocess.SubprocessError):
                pass
            return 'partially_applied'
        return 'cancelled'
