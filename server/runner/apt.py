"""Manual Ubuntu maintenance with a read-only, fingerprinted upgrade preview.

Never run from inventory or release checks. Do not interrupt dpkg mid-command;
uncertain execution after worker recovery needs a fresh administrator decision.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from panel import atomic_file

ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C',
       'DEBIAN_FRONTEND': 'noninteractive', 'NEEDRESTART_MODE': 'l',
       'APT_LISTCHANGES_FRONTEND': 'none', 'UCF_FORCE_CONFFOLD': '1'}
OPTIONS = ['-o', 'DPkg::Lock::Timeout=60', '-o', 'Dpkg::Options::=--force-confdef',
           '-o', 'Dpkg::Options::=--force-confold', '--no-remove']


class AptError(Exception):
    def __init__(self, code='apt_failed'):
        self.code = code
        super().__init__(code)


def prerequisites():
    distro = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    if distro.get('ID', '').strip('"') != 'ubuntu' or not Path('/usr/bin/apt-get').is_file():
        raise AptError('apt_prerequisites')


def check_disk_and_memory():
    archives = Path('/var/cache/apt/archives')
    if archives.exists():
        if shutil.disk_usage(str(archives)).free < 200 * 1024 * 1024:
            raise AptError('apt_disk_full')
    boot = Path('/boot')
    if boot.exists():
        if shutil.disk_usage(str(boot)).free < 50 * 1024 * 1024:
            raise AptError('apt_disk_full')
    root = Path('/')
    if root.exists():
        if shutil.disk_usage(str(root)).free < 300 * 1024 * 1024:
            raise AptError('apt_disk_full')

    meminfo = Path('/proc/meminfo')
    if meminfo.exists():
        try:
            for line in meminfo.read_text().splitlines():
                if line.startswith('MemAvailable:'):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        if int(parts[1]) < 40 * 1024:
                            raise AptError('apt_memory_low')
                    break
        except OSError:
            pass


def acquire_dpkg_locks(timeout=10):
    lock_paths = [
        Path('/var/lib/dpkg/lock-frontend'),
        Path('/var/lib/dpkg/lock'),
        Path('/var/lib/apt/lists/lock')
    ]
    deadline = time.monotonic() + timeout
    backoff = 0.5
    for lock_path in lock_paths:
        if not lock_path.exists():
            continue
        acquired = False
        while time.monotonic() < deadline:
            try:
                fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o640)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(fd, fcntl.LOCK_UN)
                    acquired = True
                    break
                except (BlockingIOError, OSError):
                    time.sleep(backoff)
                    backoff = min(backoff * 1.5, 3.0)
                finally:
                    os.close(fd)
            except OSError:
                break
        if not acquired and lock_path.exists():
            raise AptError('apt_lock_busy')


def run(args, *, capture=False, unit=None):
    # Only simulations/read-only checks have a timeout. Killing apt while dpkg
    # owns its database would make cancellation unsafe.
    argv = ['/usr/bin/apt-get', *OPTIONS, *args]
    if unit is not None:
        argv = ['/usr/bin/systemd-run', '--quiet', '--wait', '--collect', '--pipe', '--unit=' + unit,
                '--property=StandardOutput=null', '--property=StandardError=null',
                *['--setenv=' + k + '=' + v for k, v in ENV.items()], *argv]
    result = subprocess.run(argv, env=ENV,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, timeout=60 if capture else None)
    if result.returncode != 0:
        raise AptError()
    return result.stdout.decode() if capture else ''


def parse_packages(output):
    packages = []
    for line in output.splitlines():
        if line.startswith('Remv '):
            raise AptError('apt_conflict')
        if not line.startswith('Inst '):
            continue
        match = re.match(r'^Inst ([a-z0-9][a-z0-9+.:_-]*) \[([^\]\s]+)\] \(([^\s()]+)', line)
        if not match:
            raise AptError('apt_conflict')  # New packages are outside plain upgrade.
        name, old, version = match.groups()
        if not re.fullmatch(r'[A-Za-z0-9.+:~_-]+', version):
            raise AptError('apt_conflict')
        packages.append(dict(name=name, installed=old, version=version))
    if len(packages) > 2000:
        raise AptError('apt_conflict')
    return sorted(packages, key=lambda p: p['name'])


def plan():
    prerequisites()
    check_disk_and_memory()
    packages = parse_packages(run(['--simulate', 'upgrade'], capture=True))
    # Include dpkg and apt inputs, so manual changes or a subsequent index
    # refresh invalidate the confirmation even if the visible list looks alike.
    paths = [Path('/var/lib/dpkg/status'), Path('/var/lib/apt/extended_states')]
    paths += sorted(Path('/var/lib/apt/lists').glob('*'))
    state = []
    for path in paths:
        if not path.is_file():
            continue
        st = path.stat()
        state.append((str(path), st.st_size, st.st_mtime_ns))
    fingerprint = hashlib.sha256(json.dumps([packages, state], sort_keys=True).encode()).hexdigest()
    return dict(packages=packages, fingerprint=fingerprint,
                rebootRequired=Path('/var/run/reboot-required').exists())


class AptJob:
    def __init__(self, store, request):
        self.store, self.request = store, request
        self.marker = store.directory / ('apt-' + request['id'] + '.started')

    def step(self, checkpoint):
        prerequisites()
        check_disk_and_memory()
        req = self.request
        if checkpoint == 0:
            if self.marker.exists():
                raise AptError('apt_interrupted')
            acquire_dpkg_locks()
            if req['kind'] == 'apt_upgrade':
                current = plan()
                if current['fingerprint'] != req['fingerprint']:
                    raise AptError('apt_conflict')
                packages = current['packages']
                if not packages:
                    raise AptError('apt_conflict')
                args = ['--assume-yes', '--only-upgrade', '--no-install-recommends',
                        'install', *[p['name'] + '=' + p['version'] for p in packages]]
                # The exact request must resolve to precisely the shown changes.
                if parse_packages(run(['--simulate', *args], capture=True)) != packages:
                    raise AptError('apt_conflict')
            else:
                args = ['-o', 'APT::Update::Error-Mode=any', 'update']
            with self.store.db:
                self.store.event(req['id'], 'apt_upgrading' if req['kind'] == 'apt_upgrade' else 'apt_updating', 0, 2)
            atomic_file(self.marker, b'started')
            run(args, unit='antirkn-apt-' + req['id'] + '-apply')
        else:
            run(['check'], unit='antirkn-apt-' + req['id'] + '-check')
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
            self.store.event(req['id'], 'apt_reboot_required' if checkpoint == 1 and Path('/var/run/reboot-required').exists() else 'apt_checked', checkpoint + 1, 2)

    def failure_status(self):
        return 'partially_applied' if self.marker.exists() else 'failed'
