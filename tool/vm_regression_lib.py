#!/usr/bin/env python3
"""Shared harness of the VM regression suite (tool/vm_regression.py).

Only local disposable QEMU VMs in its own directory and on its own SSH port.
Nothing here prints or stores credentials; diagnostics carry codes only.
"""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import threading
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


def previous_bundle(current, commit=None):
    """Return the newest git bundle whose runner version differs from current."""
    if commit:
        old = bundle_from_git(commit)
        if old['version'] == current['version'] or old['release'] == current['release']:
            raise RuntimeError('--previous %s matches current runner %s (%s)' % (commit, current['version'], current['release'][:12]))
        old['commit'] = commit
        return old
    commits = subprocess.check_output(['git', 'log', '--format=%H', BUNDLE_FILE], cwd=ROOT, text=True).splitlines()
    for rev in commits:
        try:
            old = bundle_from_git(rev)
        except Exception:
            continue
        if old['version'] != current['version']:
            old['commit'] = rev[:12]
            return old
    raise RuntimeError('No previous runner release found in git log of ' + BUNDLE_FILE)


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


def ensure_image(fetch=False):
    image = BASE / 'ubuntu.img'
    if image.exists() and sha256_file(image) == IMAGE_SHA256:
        return image
    if not fetch:
        raise RuntimeError('Missing or invalid Ubuntu image in %s. Run: python3 tool/vm_regression.py --fetch' % image)
    part = BASE / 'ubuntu.download'
    urllib.request.urlretrieve(IMAGE_URL, part)
    if sha256_file(part) != IMAGE_SHA256:
        part.unlink(missing_ok=True)
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

def _download(url, destination, sha256, size=None, fetch=False):
    if destination.exists() and sha256_file(destination) == sha256:
        if size is None or destination.stat().st_size == size:
            return destination
    if not fetch:
        raise RuntimeError('Missing or invalid cached fixture %s. Run: python3 tool/vm_regression.py --fetch' % destination.name)
    part = destination.with_suffix(destination.suffix + '.part')
    try:
        with urllib.request.urlopen(url, timeout=180) as source, open(part, 'wb') as stream:
            shutil.copyfileobj(source, stream)
        if size is not None and part.stat().st_size != size:
            raise RuntimeError('fixture size mismatch: ' + destination.name)
        if sha256_file(part) != sha256:
            raise RuntimeError('fixture checksum mismatch: ' + destination.name)
        os.replace(part, destination)
    finally:
        part.unlink(missing_ok=True)
    return destination


def _fetch_awg_gomod(source_archive, go_archive, source_sha, go_sha, commit):
    """Download and go.sum-verify AmneziaWG Go modules on the host, then pack for offline VM builds."""
    import tarfile
    import tempfile
    archive = CACHE / 'awg-gomod.tar.gz'
    stamp = CACHE / 'awg-gomod.json'
    if archive.exists() and stamp.exists():
        try:
            meta = json.loads(stamp.read_text())
            if (meta.get('sourceSha256') == source_sha and meta.get('goSha256') == go_sha
                    and sha256_file(archive) == meta.get('gomodSha256')):
                return archive
        except (OSError, ValueError):
            pass
    with tempfile.TemporaryDirectory(prefix='.awg-gomod-', dir=CACHE) as tmp:
        tmp_path = Path(tmp)
        with tarfile.open(go_archive, 'r:gz') as tf:
            tf.extractall(tmp_path / 'go')
        with tarfile.open(source_archive, 'r:gz') as tf:
            tf.extractall(tmp_path / 'src')
        go_bin = tmp_path / 'go/go/bin/go'
        src_dir = tmp_path / 'src' / ('amneziawg-go-' + commit)
        gopath = tmp_path / 'go-path'
        env = dict(os.environ, PATH='/usr/bin:/bin', HOME=str(tmp_path), CGO_ENABLED='0',
                   GOOS='linux', GOARCH='amd64', GOTOOLCHAIN='local',
                   GOPROXY='https://proxy.golang.org', GOSUMDB='sum.golang.org',
                   GOCACHE=str(tmp_path / 'go-cache'), GOPATH=str(gopath))
        subprocess.run([str(go_bin), 'mod', 'download'], cwd=src_dir, env=env, check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(go_bin), 'mod', 'verify'], cwd=src_dir, env=env, check=True, stdout=subprocess.DEVNULL)
        # Prove offline build works inside an isolated network namespace with GOPROXY still pointing upstream.
        offline_env = {k: v for k, v in env.items() if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
        offline_env['GOCACHE'] = str(tmp_path / 'go-cache-offline')
        subprocess.run(['unshare', '-rn', 'sh', '-c', 'ip link set lo up && exec "$@"', 'sh',
                        str(go_bin), 'build', '-mod=readonly', '-trimpath', '-buildvcs=false',
                        '-o', str(tmp_path / 'awg-test-bin'), '.'],
                       cwd=src_dir, env=offline_env, check=True, stdout=subprocess.DEVNULL)
        part = archive.with_suffix('.tar.gz.part')
        mod_dir = gopath / 'pkg/mod'
        try:
            with tarfile.open(part, 'w:gz') as tf:
                tf.add(mod_dir, arcname='mod')
            digest = sha256_file(part)
            os.replace(part, archive)
            stamp.write_text(json.dumps(dict(sourceSha256=source_sha, goSha256=go_sha, gomodSha256=digest), indent=2) + '\n')
        finally:
            part.unlink(missing_ok=True)
    return archive


ALL_FIXTURES = ('panel', 'xray-candidate', 'tt-endpoint', 'awg-source', 'awg-tools', 'awg-go', 'mihomo', 'awg-gomod')


def fixture(name, fetch=False):
    """Pinned archive from the cache; fetched once (digest-verified), never at
    test time afterwards. Pins come from the same generated files as the runner."""
    import runpy
    CACHE.mkdir(mode=0o700, exist_ok=True)
    components = json.loads((ROOT / 'schemas/component-releases.json').read_text())
    runner = ROOT / 'server/runner'
    if name == 'panel':
        release = runpy.run_path(str(runner / 'panel_release.py'))['RELEASE']
        return _download(release['url'], CACHE / 'panel.tar.gz', release['sha256'], release.get('bytes'), fetch=fetch)
    if name == 'xray-candidate':
        target = runpy.run_path(str(runner / 'xray_upgrade_release.py'))['TARGET']
        return _download(target['url'], CACHE / 'xray-candidate.zip', target['sha256'], target.get('bytes'), fetch=fetch)
    archives = {'tt-endpoint': components['trusttunnel']['archives']['endpoint'],
                'awg-source': components['amneziawg']['archives']['source'],
                'awg-tools': components['amneziawg']['archives']['tools'],
                'awg-go': components['amneziawg']['archives']['go']}
    if name in archives:
        artifact = archives[name]
        return _download(artifact['url'], CACHE / (name + '.archive'), artifact['sha256'], artifact.get('bytes'), fetch=fetch)
    if name == 'awg-gomod':
        awg = components['amneziawg']
        src_sha = awg['archives']['source']['sha256']
        go_sha = awg['archives']['go']['sha256']
        if fetch:
            src_arc = fixture('awg-source', fetch=True)
            go_arc = fixture('awg-go', fetch=True)
            return _fetch_awg_gomod(src_arc, go_arc, src_sha, go_sha, awg['commit'])
        archive = CACHE / 'awg-gomod.tar.gz'
        stamp = CACHE / 'awg-gomod.json'
        if not archive.exists() or not stamp.exists():
            raise RuntimeError('Missing AWG Go module cache. Run: python3 tool/vm_regression.py --fetch')
        meta = json.loads(stamp.read_text())
        if (meta.get('sourceSha256') != src_sha or meta.get('goSha256') != go_sha
                or sha256_file(archive) != meta.get('gomodSha256')):
            raise RuntimeError('Invalid/stale AWG Go module cache. Run: python3 tool/vm_regression.py --fetch')
        return archive
    if name == 'mihomo':
        # Pinned official Mihomo v1.19.34 (same pin as tool/test_vless_vm.py).
        binary = CACHE / 'mihomo'
        pinned = '5b6644c487e5dffae86b0e0e9bb5cec445579a3a9d03977c09576fee2aeefc01'
        if binary.exists() and sha256_file(binary) == pinned:
            return binary
        if not fetch:
            raise RuntimeError('Missing or invalid cached mihomo binary. Run: python3 tool/vm_regression.py --fetch')
        import gzip
        archive = _download('https://github.com/MetaCubeX/mihomo/releases/download/v1.19.34/'
                            'mihomo-linux-amd64-compatible-v1.19.34.gz', CACHE / 'mihomo.gz',
                            '2763f5b414527f7baf6dc57e3f82f3ab561eedf34bfd7c2f2cde1f7e592efe06', fetch=True)
        binary.write_bytes(gzip.decompress(archive.read_bytes()))
        binary.chmod(0o700)
        if sha256_file(binary) != pinned:
            binary.unlink(missing_ok=True)
            raise RuntimeError('mihomo binary mismatch')
        return binary
    raise KeyError(name)


def fetch_all():
    """Download and digest-verify the Ubuntu image and every pinned offline fixture."""
    img = ensure_image(fetch=True)
    print('OK ubuntu.img (%s)' % sha256_file(img)[:12], flush=True)
    for name in ALL_FIXTURES:
        path = fixture(name, fetch=True)
        print('OK %s (%s)' % (name, sha256_file(path)[:12]), flush=True)


def verify_cache():
    """Fail fast if any required offline cache item is missing or corrupted."""
    ensure_image(fetch=False)
    for name in ALL_FIXTURES:
        fixture(name, fetch=False)


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
        lines.append('--- protocol units (state/restarts/exit status)')
        lines.append(remote("for u in $(systemctl list-units --all --plain --no-legend 'antirkn-*' 'x-ui*' 'awg-quick@*' | awk '{print $1}'); "
                            "do echo \"$u $(systemctl show -p ActiveState,SubState,NRestarts,ExecMainStatus --value $u | tr '\\n' ' ')\"; done",
                            timeout=20, check=False).stdout.decode())
        lines.append('--- listening sockets (ports only)')
        lines.append(remote("ss -Hltnu | awk '{print $1, $5}' | sort -u", timeout=20, check=False).stdout.decode())
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


# ---------------------------------------------------------------- local echo & Mihomo traffic helpers

_XHTTP_DEFAULTS = None


def _run_dart(args):
    res = subprocess.run(['dart', 'run'] + args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, timeout=60)
    if res.returncode != 0:
        raise RuntimeError('dart run failed: ' + (res.stderr or res.stdout)[-400:])
    return res.stdout


def xhttp_defaults():
    global _XHTTP_DEFAULTS
    if _XHTTP_DEFAULTS is None:
        _XHTTP_DEFAULTS = json.loads(_run_dart(['tool/compile_vless_fixture.dart', '--xhttp-defaults']))
    return dict(_XHTTP_DEFAULTS)


def ensure_tls_material(tls_dir):
    """Create isolated self-signed test CA + server cert for vless.test / tt.fixture.test."""
    tls_dir = Path(tls_dir)
    tls_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    tls_dir.chmod(0o700)

    def openssl(args):
        subprocess.run(['openssl'] + args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    if not (tls_dir / 'ca.crt').exists() or not (tls_dir / 'server.crt').exists():
        openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(tls_dir / 'ca.key'),
                 '-out', str(tls_dir / 'ca.crt'), '-days', '10', '-subj', '/CN=AntiRKN regression test CA'])
        openssl(['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(tls_dir / 'server.key'),
                 '-out', str(tls_dir / 'server.csr'), '-subj', '/CN=vless.test'])
        (tls_dir / 'extensions').write_text(
            'subjectAltName=DNS:vless.test,DNS:tt.fixture.test\n'
            'keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
        openssl(['x509', '-req', '-in', str(tls_dir / 'server.csr'), '-CA', str(tls_dir / 'ca.crt'),
                 '-CAkey', str(tls_dir / 'ca.key'), '-CAcreateserial', '-out', str(tls_dir / 'server.crt'),
                 '-days', '10', '-extfile', str(tls_dir / 'extensions')])
    for f in tls_dir.iterdir():
        if f.is_file():
            f.chmod(0o600)
    return tls_dir


class _QuietHttp(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'antirkn-vless-tcp-fixture'
        # /bytes/N: N bytes (up to 1 MiB) for transfer checks (FR-SNI 100 KB).
        match = re.fullmatch(r'/bytes/([0-9]{1,7})', self.path)
        if match and int(match.group(1)) <= 1 << 20:
            body = b'\0' * int(match.group(1))
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class _ReuseTcpServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


class EchoFixtures:
    """Host-side TCP echo (29880), UDP echo (29881), and TLS 1.3 REALITY target (29443)."""

    def __init__(self, tls_dir):
        self.tls_dir = ensure_tls_material(tls_dir)
        self.http_server = None
        self.udp = None
        self.tls = None
        self.stop = threading.Event()

    def __enter__(self):
        self.http_server = _ReuseTcpServer(('127.0.0.1', 29880), _QuietHttp)
        threading.Thread(target=self.http_server.serve_forever, daemon=True).start()

        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.udp.bind(('127.0.0.1', 29881))
        self.udp.settimeout(0.5)

        def udp_echo():
            while not self.stop.is_set():
                try:
                    data, addr = self.udp.recvfrom(65535)
                    self.udp.sendto(data, addr)
                except socket.timeout:
                    pass
                except OSError:
                    break

        threading.Thread(target=udp_echo, daemon=True).start()

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        context.load_cert_chain(self.tls_dir / 'server.crt', self.tls_dir / 'server.key')
        context.set_ecdh_curve('X25519')
        context.set_alpn_protocols(['h2', 'http/1.1'])

        class TlsHandler(socketserver.BaseRequestHandler):
            def handle(self_h):
                self_h.request.settimeout(8)
                try:
                    with context.wrap_socket(self_h.request, server_side=True) as conn:
                        if conn.selected_alpn_protocol() == 'h2':
                            conn.sendall(bytes.fromhex('000000040000000000'))
                        conn.recv(4096)
                except (OSError, ssl.SSLError):
                    pass

        self.tls = _ReuseTcpServer(('127.0.0.1', 29443), TlsHandler)
        threading.Thread(target=self.tls.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.stop.set()
        if self.tls:
            self.tls.shutdown()
            self.tls.server_close()
        if self.http_server:
            self.http_server.shutdown()
            self.http_server.server_close()
        if self.udp:
            self.udp.close()
        return False


def _free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def _recv_exact(sock, count):
    buf = b''
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise RuntimeError('SOCKS connection closed')
        buf += chunk
    return buf


def _socks5(port, command, host, remote_port, timeout=10.0):
    sock = socket.create_connection(('127.0.0.1', port), timeout=timeout)
    sock.settimeout(timeout)
    sock.sendall(b'\x05\x01\x00')
    if _recv_exact(sock, 2) != b'\x05\x00':
        sock.close()
        raise RuntimeError('SOCKS greeting failed')
    sock.sendall(bytes([5, command, 0, 1]) + socket.inet_aton(host) + struct.pack('!H', remote_port))
    resp = _recv_exact(sock, 4)
    if resp[1] != 0:
        sock.close()
        raise RuntimeError('SOCKS request failed: %d' % resp[1])
    size = {1: 4, 4: 16}.get(resp[3])
    address = _recv_exact(sock, size)
    bound_port = struct.unpack('!H', _recv_exact(sock, 2))[0]
    return sock, (socket.inet_ntop(socket.AF_INET if size == 4 else socket.AF_INET6, address), bound_port)


def compile_mihomo_config(workspace, user_id, resource_id, ca_crt, work_dir):
    """Compile a single-resource Mihomo YAML config using the production Dart compiler."""
    work_dir = Path(work_dir)
    work_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    port = _free_port()
    template = {
        'mixed-port': port,
        'allow-lan': False,
        'mode': 'rule',
        'log-level': 'silent',
        'ipv6': False,
        'dns': {'enable': False},
        'proxies': [],
        'proxy-groups': [{'name': 'TEST', 'type': 'select', 'include-all-proxies': True}],
        'rules': ['MATCH,TEST'],
    }
    input_path = work_dir / 'input.json'
    input_path.write_text(json.dumps(dict(workspace=workspace, userId=user_id, resourceId=resource_id, template=template)))
    input_path.chmod(0o600)
    config_path = work_dir / 'config.yaml'
    _run_dart(['tool/compile_vless_fixture.dart', str(input_path), str(config_path)])
    config_path.chmod(0o600)
    return port, config_path


def _proxy_download(mixed_port, size, timeout):
    """Exactly size body bytes from the host echo through the proxy."""
    sock, _ = _socks5(mixed_port, 1, '10.0.2.2', 29880, timeout=timeout)
    with sock:
        sock.sendall(('GET /bytes/%d HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n' % size).encode())
        data = b''
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    head, _, body = data.partition(b'\r\n\r\n')
    return head.startswith(b'HTTP/1.0 200') and len(body) == size


def test_mihomo_traffic(mihomo_bin, ca_crt, config_path, mixed_port, work_dir, timeout=10.0, retries=0, download=0):
    """Run Mihomo with the compiled config and verify real TCP and UDP traffic;
    with download, TCP also needs that many bytes through the proxy."""
    env = {**os.environ, 'SSL_CERT_FILE': str(ca_crt)}
    checked = subprocess.run([str(mihomo_bin), '-t', '-d', str(work_dir), '-f', str(config_path)],
                             capture_output=True, env=env, timeout=20)
    if checked.returncode != 0:
        return False, False
    log_path = Path(work_dir) / 'mihomo.log'
    with log_path.open('wb') as log_file:
        log_path.chmod(0o600)
        proc = subprocess.Popen([str(mihomo_bin), '-d', str(work_dir), '-f', str(config_path)],
                                stdout=log_file, stderr=log_file, env=env)
        try:
            for _ in range(50):
                try:
                    with socket.create_connection(('127.0.0.1', mixed_port), timeout=0.2):
                        break
                except OSError:
                    time.sleep(0.1)
            tcp_ok, udp_ok = False, False
            for attempt in range(retries + 1):
                if not tcp_ok:
                    try:
                        sock, _ = _socks5(mixed_port, 1, '10.0.2.2', 29880, timeout=timeout)
                        with sock:
                            sock.sendall(b'GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n')
                            data = b''
                            while True:
                                chunk = sock.recv(4096)
                                if not chunk:
                                    break
                                data += chunk
                                if b'antirkn-vless-tcp-fixture' in data:
                                    break
                            tcp_ok = b'antirkn-vless-tcp-fixture' in data
                        if tcp_ok and download:
                            tcp_ok = _proxy_download(mixed_port, download, timeout)
                    except (OSError, RuntimeError):
                        tcp_ok = False
                if not udp_ok:
                    try:
                        control, (_, bound_port) = _socks5(mixed_port, 3, '0.0.0.0', 0, timeout=timeout)
                        with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                            udp.settimeout(timeout)
                            message = secrets.token_bytes(48)
                            packet = b'\x00\x00\x00\x01' + socket.inet_aton('10.0.2.2') + struct.pack('!H', 29881) + message
                            udp.sendto(packet, ('127.0.0.1', bound_port))
                            reply, _ = udp.recvfrom(65535)
                            udp_ok = reply.endswith(message)
                    except (OSError, RuntimeError):
                        udp_ok = False
                if tcp_ok and udp_ok:
                    break
                if attempt < retries:
                    time.sleep(1.0)
            # Which half failed and on which attempt, for diagnosing flaky probes.
            (Path(work_dir) / 'result.json').write_text(json.dumps(dict(tcp=tcp_ok, udp=udp_ok, attempts=attempt + 1)))
            if tcp_ok and udp_ok and attempt:
                # Passed only after waiting: surfaced, not hidden (slow convergence after a state change).
                print('  SLOW %s converged on attempt %d' % (Path(work_dir).name, attempt + 1), flush=True)
            return tcp_ok, udp_ok
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()


def check_proxy_traffic(workspace, user_id, resource_id, ca_crt, mihomo_bin, work_dir, timeout=10.0, retries=0, download=0):
    port, config_path = compile_mihomo_config(workspace, user_id, resource_id, ca_crt, work_dir)
    return test_mihomo_traffic(mihomo_bin, ca_crt, config_path, port, work_dir, timeout=timeout, retries=retries,
                               download=download)
