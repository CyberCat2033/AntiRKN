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
import sys
import time

# Also run directly as `python3 -I apt.py record ...` by systemd-run, where
# the script directory is not on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from panel import atomic_file, run as run_command  # noqa: E402

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


RUNNING_STATES = ('active', 'activating', 'deactivating', 'reloading')
# Scheduled apt runs of Ubuntu. unattended-upgrades.service is only the
# shutdown helper and is active all the time.
SCHEDULED_UNITS = ('apt-daily.service', 'apt-daily-upgrade.service')
LOCKS = (Path('/var/lib/dpkg/lock-frontend'), Path('/var/lib/dpkg/lock'),
         Path('/var/lib/apt/lists/lock'))
# Longest apt-get run in a transient unit; systemd stops it after that.
RUNTIME_MAX = 7200
# dpkg's journal of a run that did not finish (power loss, killed dpkg).
DPKG_UPDATES = Path('/var/lib/dpkg/updates')
# Package states only `dpkg --configure -a` completes.
UNFINISHED_STATES = ('half-installed', 'unpacked', 'half-configured', 'triggers-awaited', 'triggers-pending')


def unit_properties(unit):
    try:
        result = run_command(['/usr/bin/systemctl', 'show', '--property=LoadState,ActiveState,Result,ExecMainStatus',
                              unit], timeout=20)
    except (OSError, subprocess.SubprocessError):
        return {}
    if result.returncode:
        return {}
    return dict(line.split('=', 1) for line in result.stdout.decode(errors='replace').splitlines() if '=' in line)


def is_unit_active(unit):
    return unit_properties(unit).get('ActiveState') in RUNNING_STATES


def lock_busy(path):
    """Whether another process holds the dpkg/apt lock. dpkg and apt take
    POSIX (fcntl) locks, which flock() never sees."""
    try:
        fd = os.open(str(path), os.O_RDWR | os.O_NOFOLLOW | getattr(os, 'O_CLOEXEC', 0))
    except FileNotFoundError:
        return False
    try:
        try:
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, PermissionError):
            return True
        fcntl.lockf(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def acquire_dpkg_locks(timeout=60, paths=LOCKS, sleep=time.sleep):
    """Wait (bounded) until dpkg and apt are free. apt itself takes the locks
    afterwards; a scheduled apt run in progress is reported at once."""
    deadline = time.monotonic() + timeout
    backoff = 0.5
    while True:
        busy = [path for path in paths if lock_busy(path)]
        if not busy:
            return
        if any(is_unit_active(unit) for unit in SCHEDULED_UNITS) or time.monotonic() + backoff > deadline:
            raise AptError('apt_lock_busy')
        sleep(backoff)
        backoff = min(backoff * 1.5, 3.0)


def dpkg_interrupted():
    """Whether an earlier dpkg run stopped midway, so apt refuses to work until
    an administrator runs `dpkg --configure -a` (never run here: it executes
    maintainer scripts of whatever was left). Read-only; a dpkg run in
    progress is not judged (its journal and states are transient)."""
    if any(lock_busy(path) for path in LOCKS):
        return False
    try:
        if any(entry.name.isdigit() for entry in DPKG_UPDATES.iterdir()):
            return True
    except FileNotFoundError:
        pass
    result = run_command(['/usr/bin/dpkg-query', '--show', '--showformat=${Status}\\n'], timeout=60)
    if result.returncode:
        raise AptError()
    return any(line.split()[-1:] and line.split()[-1] in UNFINISHED_STATES
               for line in result.stdout.decode(errors='replace').splitlines())


def check_dpkg():
    if dpkg_interrupted():
        raise AptError('apt_dpkg_interrupted')


def run(args, *, capture=False, unit=None, record=None, runtime=RUNTIME_MAX):
    """apt-get with fixed options. A unit run is a transient systemd service
    bounded by RuntimeMaxSec; record, a root-only path, receives its exit
    status even if this worker dies meanwhile."""
    argv = ['/usr/bin/apt-get', *OPTIONS, *args]
    if unit is None:
        timeout = 60 if capture else runtime
    else:
        if record is not None:
            argv = [sys.executable, '-I', str(Path(__file__).resolve()), 'record', str(record), *argv]
        argv = ['/usr/bin/systemd-run', '--quiet', '--wait', '--collect', '--pipe', '--unit=' + unit,
                '--property=StandardOutput=null', '--property=StandardError=null',
                '--property=RuntimeMaxSec=%d' % runtime,
                *['--setenv=' + k + '=' + v for k, v in ENV.items()], *argv]
        timeout = runtime + 120
    result = run_command(argv, timeout=timeout, env=dict(ENV), capture=capture)
    if result.returncode != 0:
        raise AptError()
    return result.stdout.decode() if capture else ''


INTERRUPTED = 'interrupted'


def recorded(path):
    """What a unit run left in its marker: its exit status, INTERRUPTED when
    apt-get was started but its end is unknown, None when it never started."""
    try:
        text = path.read_text().strip()
    except OSError:
        return None
    if text == 'running':
        return INTERRUPTED
    match = re.fullmatch(r'exit (-?[0-9]{1,4})', text)
    return int(match.group(1)) if match else None


def record_exit(path, argv):
    """Inside the transient unit: run apt-get, then record its exit status.

    A SIGTERM (reboot, shutdown, RuntimeMaxSec) stops the whole unit, apt-get
    and dpkg included: the marker stays 'running', so the end is reported
    as unknown (apt_interrupted), not as an apt-get failure."""
    import signal
    def stopped(number, _frame):
        os._exit(128 + number)
    signal.signal(signal.SIGTERM, stopped)
    atomic_file(path, b'running')
    try:
        status = subprocess.call(argv, stdin=subprocess.DEVNULL, timeout=RUNTIME_MAX)
    except subprocess.TimeoutExpired:
        status = 124
    atomic_file(path, b'exit %d' % status)
    return status


def parse_packages(output):
    packages = []
    for line in output.splitlines():
        if line.startswith('Remv '):
            raise AptError('apt_conflict')
        if not line.startswith('Inst '):
            continue
        match = re.match(r'^Inst ([a-z0-9][a-z0-9+.:_-]*)(?: \[([^\]\s]+)\])? \(([^\s()]+)', line)
        if not match:
            raise AptError('apt_conflict')
        name = match.group(1)
        old = match.group(2) if match.group(2) is not None else 'new'
        version = match.group(3)
        if not re.fullmatch(r'[A-Za-z0-9.+:~_-]+', version):
            raise AptError('apt_conflict')
        packages.append(dict(name=name, installed=old, version=version))
    if len(packages) > 2000:
        raise AptError('apt_conflict')
    return sorted(packages, key=lambda p: p['name'])


def plan():
    prerequisites()
    check_disk_and_memory()
    check_dpkg()
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
        self.unit = 'antirkn-apt-' + request['id'] + '-apply'

    def outcome(self):
        """Exit status of this job's apply run: recorded by the run itself,
        else read from a unit systemd still holds; None if it never ran."""
        status = recorded(self.marker)
        if status is not None:
            return status
        properties = unit_properties(self.unit)
        if properties.get('LoadState') == 'loaded' and properties.get('Result'):
            return 0 if (properties['Result'] == 'success' and properties.get('ExecMainStatus') == '0') else 1
        return None

    def abort(self):
        if is_unit_active(self.unit):
            return 'partially_applied'
        if self.started():
            return 'partially_applied'  # apt already ran to its end.
        self.marker.unlink(missing_ok=True)
        return 'cancelled'

    def step(self, checkpoint):
        prerequisites()
        check_disk_and_memory()
        req = self.request
        if checkpoint == 0:
            if self.marker.exists():
                # The worker restarted during the apply run: never start it twice.
                if is_unit_active(self.unit):
                    return False
                status = self.outcome()
                if status == 0:
                    self.advance(0)
                    return True
                if status == INTERRUPTED:
                    # apt-get started and its end is unknown (a reboot): an
                    # administrator decides, nothing is replayed.
                    raise AptError('apt_interrupted')
                if status is not None:
                    raise AptError('apt_failed')
                self.marker.unlink(missing_ok=True)  # apt-get never started.
            acquire_dpkg_locks()
            if req['kind'] == 'apt_upgrade':
                current = plan()  # Also refuses an interrupted dpkg.
                if current['fingerprint'] != req['fingerprint']:
                    raise AptError('apt_conflict')
                packages = current['packages']
                if not packages:
                    raise AptError('apt_conflict')
                args = ['--assume-yes', '--only-upgrade', '--no-install-recommends',
                        'install', *[p['name'] + '=' + p['version'] for p in packages]]
                # The requested packages must all be satisfied in simulation.
                simulated = parse_packages(run(['--simulate', *args], capture=True))
                simulated_map = {p['name']: p['version'] for p in simulated}
                if not all(simulated_map.get(p['name']) == p['version'] for p in packages):
                    raise AptError('apt_conflict')
            else:
                check_dpkg()
                args = ['-o', 'APT::Update::Error-Mode=any', 'update']
            with self.store.db:
                self.store.event(req['id'], 'apt_upgrading' if req['kind'] == 'apt_upgrade' else 'apt_updating', 0, 2)
            atomic_file(self.marker, b'started')
            run(args, unit=self.unit, record=self.marker)
        else:
            run(['check'], unit='antirkn-apt-' + req['id'] + '-check', runtime=600)
            self.marker.unlink(missing_ok=True)
        self.advance(checkpoint)
        return True

    def advance(self, checkpoint):
        req = self.request
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
            self.store.event(req['id'], 'apt_reboot_required' if checkpoint == 1 and Path('/var/run/reboot-required').exists() else 'apt_checked', checkpoint + 1, 2)

    def started(self):
        """Whether apt-get of the apply run really started (its marker says
        running or an exit status, or systemd still holds the finished unit)."""
        return self.marker.exists() and self.outcome() is not None

    def failure_status(self):
        """partially_applied only when packages may have changed: an upgrade
        whose apt-get started. Otherwise failed (a list refresh changes no
        package), and the marker goes, so a resume starts afresh."""
        if self.request['kind'] == 'apt_upgrade' and self.started():
            return 'partially_applied'
        if not is_unit_active(self.unit):
            self.marker.unlink(missing_ok=True)
        return 'failed'


if __name__ == '__main__':
    # systemd-run ... apt.py record <marker> /usr/bin/apt-get ...
    if len(sys.argv) < 4 or sys.argv[1] != 'record' or sys.argv[3] != '/usr/bin/apt-get':
        sys.exit(2)
    sys.exit(record_exit(Path(sys.argv[2]), sys.argv[3:]))
