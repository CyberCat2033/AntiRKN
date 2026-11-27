# Appended after runner_inspect.py, invoked as trusted code with JSON on stdin.
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import py_compile
import shutil
import sqlite3
import subprocess
import sys
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


def _records(paths):
    for path in paths:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue  # Unreadable records are not evidence of work in progress.
        if isinstance(data, dict):
            yield data


def transactions_busy(state, now):
    """An Xray replacement or a temporary probe access is in progress.

    A transaction counts until it is final (recovery_required needs a person,
    not a blocked runner) or long past its window; a probe until it is closed
    or expired."""
    for data in _records((state / 'xray-upgrades').glob('*/state.json')):
        if (data.get('phase') not in ('committed', 'rolled_back', 'not_changed', 'recovery_required')
                and data.get('deadline', 0) > now - 900):
            return True
    for data in _records((state / 'connectivity-probes').glob('*.json')):
        if data.get('status') != 'closed' and data.get('expires', 0) > now:
            return True
    return False


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
        alive = False
        if changing and Path('/var/lib/antirkn-runner/jobs.sqlite').exists():
            db = sqlite3.connect('file:/var/lib/antirkn-runner/jobs.sqlite?mode=ro', uri=True)
            try:
                health_row = db.execute("SELECT heartbeat FROM health WHERE id=1").fetchone()
                alive = health_row is not None and 0 <= (time.time() - health_row[0]) < 30
                if alive and db.execute("SELECT 1 FROM jobs WHERE status='running' AND cancel=0").fetchone():
                    raise ValueError('busy')
            finally:
                db.close()
            rw_db = sqlite3.connect('/var/lib/antirkn-runner/jobs.sqlite')
            rw_db.row_factory = sqlite3.Row  # Rows are read by column name below.
            try:
                with rw_db:
                    for row in rw_db.execute("SELECT * FROM jobs WHERE status IN ('planned','running')").fetchall():
                        if not alive:
                            applied = row['checkpoint'] > 0 and json.loads(row['request']).get('kind') != 'diagnostic'
                            status = 'partially_applied' if applied else 'cancelled' if row['cancel'] else 'failed'
                            rw_db.execute("UPDATE jobs SET status=? WHERE id=?", (status, row['id']))
                        elif row['cancel'] and row['status'] == 'planned':
                            rw_db.execute("UPDATE jobs SET status='cancelled' WHERE id=?", (row['id'],))
            finally:
                rw_db.close()
        if changing and alive and transactions_busy(Path('/var/lib/antirkn-runner'), time.time()):
            raise ValueError('busy')
        if not (BASE / 'v77').exists():
            temp = Path(tempfile.mkdtemp(prefix='.antirkn-', dir='/usr/local/lib'))
            try:
                temp.chmod(0o755)
                version = temp / 'v77'
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
                    os.rename(str(version), str(BASE / 'v77'))
                else:
                    os.rename(str(temp), str(BASE))
            finally:
                if temp.exists():
                    shutil.rmtree(str(temp))
        # Validate syntax and bytecode generation for all Python programs in the bundle
        target_dir = BASE / 'v77'
        for name in PROGRAMS:
            if name.endswith('.py'):
                py_file = target_dir / name
                if py_file.exists():
                    try:
                        py_compile.compile(str(py_file), doraise=True)
                    except Exception:
                        raise ValueError('bundle_syntax_error')
        previous_unit = UNIT.read_bytes() if UNIT.exists() else None
        try:
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
        except Exception:
            if changing and previous_unit is not None:
                try:
                    temp_rb = UNIT.with_name('.antirkn-runner.service.rollback')
                    fd = os.open(str(temp_rb), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
                    with os.fdopen(fd, 'wb') as stream:
                        stream.write(previous_unit); stream.flush(); os.fsync(stream.fileno())
                    temp_rb.chmod(0o644)
                    os.replace(str(temp_rb), str(UNIT))
                    subprocess.run(['/usr/bin/systemctl', 'daemon-reload'], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
                    subprocess.run(['/usr/bin/systemctl', 'restart', 'antirkn-runner.service'], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
                except Exception:
                    pass
            raise


# The request is the whole runner bundle (base64 files); tool/generate_runner.py
# refuses a bundle that does not fit with room to spare.
MAX_INPUT = 4 * 1024 * 1024


def installer_main():
    os.umask(0o077)
    print('__ANTIRKN_RUNNER_INPUT__', file=sys.stderr, flush=True)
    raw = sys.stdin.buffer.read(MAX_INPUT + 1)
    if len(raw) > MAX_INPUT:
        raise ValueError('bundle')
    print(json.dumps(install_runner(json.loads(raw))), flush=True)


if __name__ == '__main__':
    try:
        installer_main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError):
        print('{"error":"install_failed"}', flush=True)
        sys.exit(1)
