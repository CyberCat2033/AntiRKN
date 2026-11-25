#!/usr/bin/env python3
"""Shared harness of the VM regression suite (tool/vm_regression.py).

Only local disposable QEMU VMs in its own directory and on its own SSH port.
Nothing here prints or stores credentials; diagnostics carry codes only.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
BASE = Path(os.environ.get('ANTIRKN_REGRESSION_DIRECTORY', str(ROOT / 'artifacts/regression-vm')))
SSH_PORT = int(os.environ.get('ANTIRKN_REGRESSION_SSH_PORT', '2232'))
# runner_vm reads its directory at import time.
os.environ['ANTIRKN_VM_DIRECTORY'] = str(BASE)
BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
BASE.chmod(0o700)
from runner_vm import ssh_command, IMAGE_URL, IMAGE_SHA256  # noqa: E402

BUNDLE_FILE = 'packages/ssh_transport/lib/src/runner_bundle.g.dart'
# Host ports of the loopback forwards used by the client-side traffic checks.
# TCP host -> guest, then UDP host -> guest. Distinct from every manual stand.
TCP_FORWARDS = {42443: 2443, 42444: 2444, 42445: 2445, 42449: 28443}
UDP_FORWARDS = {42450: 51820}
CACHE = BASE / 'cache'
RUNS = BASE / 'runs'


class CheckFailed(AssertionError):
    """A named check did not hold; .name identifies it in the report."""

    def __init__(self, name):
        super().__init__(name)
        self.name = name


# ---------------------------------------------------------------- bundles

def _extract(source, name):
    return re.search(r'const ' + name + r"\s*=\s*r'''(.*?)''';", source, re.S).group(1)


def bundle_from_source(source):
    """Inspector/installer/bundle of one runner_bundle.g.dart text."""
    parts = {name: _extract(source, name) for name in ('runnerBundle', 'runnerInspector', 'runnerInstaller')}
    parts['bundle'] = json.loads(parts['runnerBundle'])
    parts['release'] = parts['bundle']['release']
    # The version directory comes from the service unit shipped in the bundle.
    unit = base64.b64decode(parts['bundle']['files']['antirkn-runner.service']).decode()
    parts['version'] = re.search(r'/usr/local/lib/antirkn-runner/(v\d+)/runner\.py', unit).group(1)
    try:
        parts['component_inspector'] = _extract(source, 'runnerComponentInspector')
        parts['panel_inspector'] = _extract(source, 'runnerPanelInspector')
    except AttributeError:
        pass
    return parts


def current_bundle():
    return bundle_from_source((ROOT / BUNDLE_FILE).read_text())


def bundle_from_git(commit):
    source = subprocess.check_output(['git', 'show', commit + ':' + BUNDLE_FILE], cwd=ROOT, text=True)
    return bundle_from_source(source)


def git_head():
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()


# ---------------------------------------------------------------- remote access

def remote(command, data=None, timeout=180, check=True):
    result = subprocess.run(ssh_command() + [command], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError('remote command failed: ' + result.stderr.decode(errors='replace')[-400:])
    return result


def python(source, data=None, timeout=180, check=True):
    return remote('/usr/bin/python3 -I -c ' + shlex.quote(source), data=data, timeout=timeout, check=check)


def upload(path_or_bytes, destination, mode='600', timeout=600):
    data = path_or_bytes if isinstance(path_or_bytes, bytes) else Path(path_or_bytes).read_bytes()
    remote('umask 077; cat > ' + shlex.quote(destination) + ' && chmod ' + mode + ' ' + shlex.quote(destination),
           data=data, timeout=timeout)


class Rpc:
    """RPC and job helpers bound to one runner version directory.

    The directory is derived from the bundle under test, never hardcoded.
    """

    def __init__(self, version):
        self.version = version
        self.command = '/usr/bin/python3 -I /usr/local/lib/antirkn-runner/%s/runner.py rpc' % version

    def __call__(self, request, timeout=120):
        result = remote(self.command, json.dumps(request).encode(), timeout=timeout, check=False)
        try:
            return json.loads(result.stdout)
        except ValueError:
            return dict(code='rpc_unparsable')

    def status(self, job_id):
        for _ in range(30):
            response = self(dict(version=1, action='status', id=job_id, cursor=0))
            if response.get('code') == 'busy':
                time.sleep(.5)
                continue
            return response
        return response

    def wait_job(self, job_id, timeout=1200, interval=1.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self.status(job_id)
            if response.get('jobs'):
                job = response['jobs'][0]
                if job['status'] not in ('planned', 'running'):
                    return job
            time.sleep(interval)
        raise TimeoutError('job ' + job_id[:8])

    def run_job(self, request, timeout=1200):
        """Submit and wait. Returns the finished job (status may be failed)."""
        response = self(request)
        if response.get('code') != 'ok':
            raise RuntimeError('submit refused: ' + str(response.get('code')))
        return self.wait_job(request['id'], timeout)


def codes(job):
    return [e['code'] for e in job.get('events', [])]


# ---------------------------------------------------------------- runner install

def inspect_runner(bundle):
    return json.loads(python(bundle['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))').stdout)


def install_runner(bundle, installer=None, check=True):
    """Inspector, then installer with its fingerprint (what the app does).

    ``installer`` overrides the installer source (fault injection in memory)."""
    plan = inspect_runner(bundle)
    result = python(installer or bundle['runnerInstaller'],
                    json.dumps(dict(fingerprint=plan['fingerprint'], bundle=bundle['bundle'])).encode(),
                    check=check)
    if result.returncode:
        return None
    return json.loads(result.stdout)


def main_pid():
    return remote('systemctl show antirkn-runner -p MainPID --value').stdout.decode().strip()


def boot_id():
    return remote('cat /proc/sys/kernel/random/boot_id').stdout.decode().strip()


# ---------------------------------------------------------------- VM lifecycle

def sha256_file(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def ensure_image():
    image = BASE / 'ubuntu.img'
    if not image.exists() or sha256_file(image) != IMAGE_SHA256:
        part = BASE / 'ubuntu.download'
        urllib.request.urlretrieve(IMAGE_URL, part)
        if sha256_file(part) != IMAGE_SHA256:
            raise RuntimeError('Ubuntu image checksum mismatch')
        os.replace(part, image)
    return image


def qemu_img_overlay(overlay, backing, size=None):
    overlay.unlink(missing_ok=True)
    command = ['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(backing), str(overlay)]
    if size:
        command.append(size)
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)


class Vm:
    """One QEMU VM from runner_vm.py on a given disk; stop() is a clean poweroff."""

    def __init__(self):
        self.process = None

    def start(self, disk, timeout=600):
        for name in ('ready', 'console.sock'):
            (BASE / name).unlink(missing_ok=True)
        env = dict(os.environ, ANTIRKN_VM_DIRECTORY=str(BASE), ANTIRKN_VM_REUSE='1',
                   ANTIRKN_VM_SSH_PORT=str(SSH_PORT), ANTIRKN_VM_DISK=str(disk),
                   ANTIRKN_VM_FORWARDS=json.dumps({str(k): v for k, v in TCP_FORWARDS.items()}),
                   ANTIRKN_VM_UDP_FORWARDS=json.dumps({str(k): v for k, v in UDP_FORWARDS.items()}))
        log = open(BASE / 'vm.log', 'wb')
        self.process = subprocess.Popen([sys.executable, str(ROOT / 'tool/runner_vm.py')], env=env,
                                        stdout=log, stderr=log, cwd=str(ROOT))
        deadline = time.monotonic() + timeout
        while not (BASE / 'ready').exists():
            if self.process.poll() is not None:
                raise RuntimeError('VM process exited: see ' + str(BASE / 'vm.log'))
            if time.monotonic() > deadline:
                self.kill()
                raise TimeoutError('VM boot')
            time.sleep(.5)

    def wait_boot(self, previous_boot, timeout=240):
        """Wait for SSH on a new boot after an in-guest reboot."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                result = remote('cat /proc/sys/kernel/random/boot_id', timeout=8, check=False)
                if result.returncode == 0 and result.stdout.decode().strip() != previous_boot:
                    return
            except subprocess.TimeoutExpired:
                pass
            time.sleep(2)
        raise TimeoutError('VM did not come back')

    def stop(self, timeout=180):
        if self.process is None:
            return
        if self.process.poll() is None:
            try:
                remote('sync; systemctl poweroff', timeout=20, check=False)
            except subprocess.TimeoutExpired:
                pass
            try:
                self.process.wait(timeout)
            except subprocess.TimeoutExpired:
                self.kill()
        self.process = None

    def kill(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(30)
            except subprocess.TimeoutExpired:
                self.process.kill()
        pid = BASE / 'pid'
        if pid.exists():
            try:
                os.kill(int(pid.read_text()), signal.SIGKILL)
            except (OSError, ValueError):
                pass
        self.process = None


def ensure_golden(vm, rebuild=False):
    """Clean Ubuntu with finished cloud-init, shut down cleanly, kept as golden."""
    golden = BASE / 'golden.qcow2'
    if golden.exists() and not rebuild:
        return golden, False
    for stale in list(BASE.glob('*.qcow2')) + [BASE / 'protocols.key']:
        stale.unlink(missing_ok=True)
    image = ensure_image()
    building = BASE / 'golden.build.qcow2'
    qemu_img_overlay(building, image, '8G')
    vm.start(building)
    try:
        remote('cloud-init status --wait', timeout=300)
        remote('systemctl is-system-running --wait', timeout=120, check=False)
    finally:
        vm.stop()
    os.replace(building, golden)
    return golden, True


def new_overlay(name, backing):
    overlay = BASE / (name + '.qcow2')
    qemu_img_overlay(overlay, backing)
    return overlay


# ---------------------------------------------------------------- pinned fixtures

def _download(url, destination, sha256, size=None):
    if destination.exists() and sha256_file(destination) == sha256:
        return destination
    part = destination.with_suffix(destination.suffix + '.part')
    with urllib.request.urlopen(url, timeout=120) as source, open(part, 'wb') as stream:
        shutil.copyfileobj(source, stream)
    if sha256_file(part) != sha256:
        part.unlink()
        raise RuntimeError('fixture checksum mismatch: ' + destination.name)
    os.replace(part, destination)
    return destination


def fixture(name):
    """Pinned archive from the cache; fetched once (digest-verified), never at
    test time afterwards. Pins come from the same generated files as the runner."""
    import runpy
    CACHE.mkdir(mode=0o700, exist_ok=True)
    components = json.loads((ROOT / 'schemas/component-releases.json').read_text())
    runner = ROOT / 'server/runner'
    if name == 'panel':
        release = runpy.run_path(str(runner / 'panel_release.py'))['RELEASE']
        return _download(release['url'], CACHE / 'panel.tar.gz', release['sha256'])
    if name == 'xray-candidate':
        target = runpy.run_path(str(runner / 'xray_upgrade_release.py'))['TARGET']
        return _download(target['url'], CACHE / 'xray-candidate.zip', target['sha256'])
    archives = {'tt-endpoint': components['trusttunnel']['archives']['endpoint'],
                'awg-source': components['amneziawg']['archives']['source'],
                'awg-tools': components['amneziawg']['archives']['tools'],
                'awg-go': components['amneziawg']['archives']['go']}
    if name in archives:
        artifact = archives[name]
        return _download(artifact['url'], CACHE / (name + '.archive'), artifact['sha256'])
    if name == 'mihomo':
        # Pinned official Mihomo v1.19.30 (same pin as tool/test_vless_vm.py).
        binary = CACHE / 'mihomo'
        pinned = '8ad44e28fe72be4640254b96741b677f4074991b99186cc4486a1c28ded02b1a'
        if not binary.exists() or sha256_file(binary) != pinned:
            import gzip
            archive = _download('https://github.com/MetaCubeX/mihomo/releases/download/v1.19.30/'
                                'mihomo-linux-amd64-compatible-v1.19.30.gz', CACHE / 'mihomo.gz',
                                'db214c7a2517e63c150d123178d16d102e03a241ccdae4e5e07ffbe9cf56c6f9')
            binary.write_bytes(gzip.decompress(archive.read_bytes()))
            binary.chmod(0o700)
            if sha256_file(binary) != pinned:
                raise RuntimeError('mihomo binary mismatch')
        return binary
    raise KeyError(name)


# ---------------------------------------------------------------- scenario context and diagnostics

class Ctx:
    """Named checks of one scenario, plus the VM/runner handles it works with."""

    def __init__(self, name, run_dir, bundle):
        self.name, self.run_dir, self.bundle = name, run_dir, bundle
        self.checks = []
        self.rpc = Rpc(bundle['version'])

    def check(self, condition, name):
        self.checks.append(dict(name=name, ok=bool(condition)))
        print('  %s %s' % ('PASS' if condition else 'FAIL', name), flush=True)
        if not condition:
            raise CheckFailed(name)


def collect_diagnostics(ctx, error):
    """Short, secret-free diagnostic: codes and states only."""
    lines = ['failure: %s: %s' % (type(error).__name__, str(error)[:300])]
    try:
        lines.append('--- systemctl --failed')
        lines.append(remote('systemctl --failed --no-legend --plain | cut -c1-160', timeout=20, check=False).stdout.decode())
        lines.append('--- runner journal tail (stderr carries only codes)')
        lines.append(remote('journalctl -u antirkn-runner -n 30 --no-pager -o cat | cut -c1-200', timeout=20, check=False).stdout.decode())
        lines.append('--- jobs (kind/status/checkpoint/event codes)')
        response = ctx.rpc(dict(version=1, action='list'))
        for job in (response.get('jobs') or [])[-12:]:
            lines.append('%s %s %s cp=%s %s' % (job['id'][:8], job.get('kind'), job['status'],
                                                  job.get('checkpoint'), codes(job)[-6:]))
    except Exception as diagnostic_error:  # the VM may be gone
        lines.append('diagnostics unavailable: ' + type(diagnostic_error).__name__)
    (ctx.run_dir / (ctx.name + '.diagnostic.txt')).write_text('\n'.join(lines) + '\n')


class Timeout(Exception):
    pass


class hard_timeout:
    """SIGALRM based wall-clock limit for a scenario (main thread only)."""

    def __init__(self, seconds):
        self.seconds = seconds

    def __enter__(self):
        def fire(signum, frame):
            raise Timeout('scenario exceeded %ds' % self.seconds)
        self.previous = signal.signal(signal.SIGALRM, fire)
        signal.alarm(self.seconds)

    def __exit__(self, *exc):
        signal.alarm(0)
        signal.signal(signal.SIGALRM, self.previous)
        return False
