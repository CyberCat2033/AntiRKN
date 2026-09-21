# Appended after inspect.py, invoked as trusted code with JSON on stdin.
import base64
import fcntl
import shutil
import tempfile
import time
from contextlib import contextmanager


@contextmanager
def install_lock():
    fd = os.open('/usr/local/lib', os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def install_runner(request):
    if os.geteuid() != 0:
        raise ValueError('permissions')
    # flock on an existing, fixed root-owned directory does not create files
    # before the preview's preconditions have been rechecked.
    with install_lock():
        before = inspect_runner()
        if not before['supported'] or before['fingerprint'] != request['fingerprint'] or before['state'] == 'conflict':
            raise ValueError('precondition')
        bundle = request['bundle']
        expected = set(PROGRAMS) | {'antirkn-runner.service'}
        if set(bundle['files']) != expected or set(bundle['hashes']) != expected:
            raise ValueError('bundle')
        files = {name: base64.b64decode(value, validate=True) for name, value in bundle['files'].items()}
        hashes = {name: hashlib.sha256(value).hexdigest() for name, value in files.items()}
        release = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
        if hashes != bundle['hashes'] or release != bundle['release']:
            raise ValueError('bundle')
        if before['release'] not in (None, release) and not before['upgradable']:
            raise ValueError('incompatible')
        changing = before['release'] != release or before['state'] == 'partial'
        if changing and Path('/var/lib/antirkn-runner/jobs.sqlite').exists():
            db = sqlite3.connect('file:/var/lib/antirkn-runner/jobs.sqlite?mode=ro', uri=True)
            try:
                if db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
                    raise ValueError('busy')
            finally:
                db.close()
        if changing:
            state=Path('/var/lib/antirkn-runner')
            for record in (state/'xray-upgrades').glob('*/state.json'):
                if json.loads(record.read_text()).get('phase') not in ('committed','rolled_back','not_changed'):raise ValueError('busy')
            for record in (state/'connectivity-probes').glob('*.json'):
                if json.loads(record.read_text()).get('status')!='closed':raise ValueError('busy')
        if not (BASE / 'v36').exists():
            temp = Path(tempfile.mkdtemp(prefix='.antirkn-', dir='/usr/local/lib'))
            try:
                temp.chmod(0o755)
                version = temp / 'v36'
                version.mkdir(mode=0o755)
                version.chmod(0o755)
                for name in PROGRAMS:
                    path = version / name
                    with path.open('wb') as stream:
                        stream.write(files[name]); stream.flush(); os.fsync(stream.fileno())
                    path.chmod(0o644)
                (version / 'manifest.json').write_text(json.dumps(dict(release=release, hashes=hashes), sort_keys=True))
                (version / 'manifest.json').chmod(0o644)
                if BASE.exists():
                    os.rename(str(version), str(BASE / 'v36'))
                else:
                    os.rename(str(temp), str(BASE))
            finally:
                if temp.exists():
                    shutil.rmtree(str(temp))
        if changing:
            # A known predecessor can be replaced only through this explicit plan.
            # Its source directory and job DB are retained. RPC registration takes
            # the same directory lock, so no job can race the stop/update.
            subprocess.run(['/usr/bin/systemctl', 'stop', 'antirkn-runner.service'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
            temp_unit = UNIT.with_name('.antirkn-runner.service.tmp')
            fd = os.open(str(temp_unit), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(files['antirkn-runner.service']); stream.flush(); os.fsync(stream.fileno())
            temp_unit.chmod(0o644)
            os.replace(str(temp_unit), str(UNIT))
        starting_at = time.time() if changing or not before['active'] else 0
        for argv in (['/usr/bin/systemctl', 'daemon-reload'], ['/usr/bin/systemctl', 'enable', '--now', 'antirkn-runner.service']):
            subprocess.run(argv, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        # Confirm an actual worker heartbeat, not just systemctl's active state.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                db = sqlite3.connect('file:/var/lib/antirkn-runner/jobs.sqlite?mode=ro', uri=True)
                try:
                    row = db.execute('SELECT heartbeat FROM health WHERE id=1').fetchone()
                finally:
                    db.close()
                if row and row[0] >= starting_at and 0 <= time.time() - row[0] < 5:
                    after = inspect_runner()
                    if after['release'] == release and after['active']:
                        return after
            except sqlite3.Error:
                pass
            time.sleep(0.1)
        raise ValueError('worker_unavailable')


def installer_main():
    os.umask(0o077)
    print('__ANTIRKN_RUNNER_INPUT__', file=sys.stderr, flush=True)
    raw = sys.stdin.buffer.read(1048577)
    if len(raw) > 1048576:
        raise ValueError('bundle')
    print(json.dumps(install_runner(json.loads(raw))), flush=True)

try:
    installer_main()
except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
    print('{"error":"install_failed"}', flush=True)
    sys.exit(1)
