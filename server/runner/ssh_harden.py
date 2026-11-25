"""Recoverable SSH transition. Final settings remain provisional until a new login commits.

The on-disk journal and a persistent systemd watchdog precede all access changes.
Every worker/RPC/watchdog transition holds the same lock. Passwords never enter
this journal, command arguments, events or error text.
"""
import base64
from contextlib import contextmanager
import fcntl
import glob
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import socket
import stat
import subprocess
import sys
import tempfile
import time

RUNNER_DIR = Path('/var/lib/antirkn-runner')
BACKUP_DIR = RUNNER_DIR / 'ssh_backups'
SSH_CONFIG = Path('/etc/ssh/sshd_config')
SSH_DIRECTORY = Path('/etc/ssh')
SUDO_DIRECTORY = Path('/etc/sudoers.d')
UNIT_DIRECTORY = Path('/etc/systemd/system')
SOCKET_CONFIG = UNIT_DIRECTORY / 'ssh.socket.d/99-antirkn-harden.conf'
UFW_FILES = (Path('/etc/ufw/user.rules'), Path('/etc/ufw/user6.rules'))
BOOT_ID = Path('/proc/sys/kernel/random/boot_id')
HOME_DIRECTORY = Path('/home')
ROOT_AUTH = Path('/root/.ssh/authorized_keys')
TERMINAL = ('committed', 'rolled_back')
ERRORS = (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError)


class SshHardenError(Exception):
    def __init__(self, code='ssh_harden_failed', message=None):
        self.code = code
        super().__init__(code)  # Upstream output may contain secrets.


def run(command, **kwargs):
    options = dict(capture_output=True, text=True, timeout=20,
                   check=True, env={**os.environ, 'LC_ALL': 'C'})
    options.update(kwargs)
    return subprocess.run(command, **options)


def atomic_file(path, data, mode=0o600, uid=None, gid=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.antirkn-ssh-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data if isinstance(data, bytes) else data.encode())
            os.fchmod(stream.fileno(), mode)
            if uid is not None:
                os.fchown(stream.fileno(), uid, gid)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        fd = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextmanager
def harden_lock():
    BACKUP_DIR.mkdir(parents=True, mode=0o700, exist_ok=True)
    with (BACKUP_DIR / 'lock').open('a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        yield


def backup_path(job_id):
    if not re.fullmatch('[a-f0-9]{32}', job_id):
        raise SshHardenError('ssh_harden_invalid')
    return BACKUP_DIR / ('ssh_' + job_id)


def save_info(job_id, info):
    atomic_file(backup_path(job_id) / 'info.json', json.dumps(info, sort_keys=True))


def load_info(job_id):
    path = backup_path(job_id) / 'info.json'
    if not path.is_file():
        raise SshHardenError('ssh_harden_conflict')
    info = json.loads(path.read_text())
    if info.get('version') != 2 or info.get('job_id') != job_id:
        raise SshHardenError('ssh_harden_conflict')
    return info


def snapshot(path):
    path = Path(path)
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise SshHardenError('ssh_harden_conflict')
    try:
        meta = path.stat()
    except FileNotFoundError:
        return {'path': str(path), 'data': None}
    if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.geteuid() or meta.st_mode & 0o022 or meta.st_size > 1048576:
        raise SshHardenError('ssh_harden_conflict')
    return dict(path=str(path), data=base64.b64encode(path.read_bytes()).decode(),
                mode=stat.S_IMODE(meta.st_mode), uid=meta.st_uid, gid=meta.st_gid)


def content(entry):
    return None if entry['data'] is None else base64.b64decode(entry['data'], validate=True)


def digest(data):
    return None if data is None else hashlib.sha256(data).hexdigest()


def restore_file(entry):
    path = Path(entry['path'])
    if entry['data'] is None:
        path.unlink(missing_ok=True)
    else:
        atomic_file(path, content(entry), entry['mode'], entry['uid'], entry['gid'])


def tokens(line):
    # OpenSSH permits both "Port 22" and "Port=22".
    parts = shlex.split(line, comments=True)
    if parts and '=' in parts[0]:
        key, value = parts[0].split('=', 1)
        parts = [key, *([value] if value else []), *parts[1:]]
    return parts


def config_files():
    found, visiting = {}, set()
    def visit(path):
        path = Path(os.path.abspath(str(path)))
        if os.path.commonpath([str(path), str(SSH_DIRECTORY)]) != str(SSH_DIRECTORY) or path in visiting:
            raise SshHardenError('ssh_harden_invalid')
        if path in found:
            return
        if len(found) >= 128:
            raise SshHardenError('ssh_harden_invalid')
        entry = snapshot(path)
        if entry['data'] is None:
            raise SshHardenError('ssh_harden_invalid')
        found[path] = entry
        visiting.add(path)
        for line in content(entry).decode('utf-8').splitlines():
            parts = tokens(line)
            if parts and parts[0].lower() == 'include':
                for pattern in parts[1:]:
                    if '%' in pattern or '~' in pattern:
                        raise SshHardenError('ssh_harden_invalid')
                    pattern = str(SSH_DIRECTORY / pattern) if not os.path.isabs(pattern) else pattern
                    for child in sorted(glob.glob(pattern)):
                        visit(child)
        visiting.remove(path)
    visit(SSH_CONFIG)
    return list(found.values())


def effective(user='root', port=22):
    output = run(['/usr/sbin/sshd', '-T', '-C',
                  f'user={user},host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport={port}']).stdout
    result = {}
    for line in output.splitlines():
        key, _, value = line.partition(' ')
        result.setdefault(key.lower(), []).append(value.strip())
    if not result.get('port') or not result.get('permitrootlogin'):
        raise SshHardenError('ssh_harden_failed')
    return result


def is_socket_activation():
    result = subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', 'ssh.socket'],
                            capture_output=True, timeout=10)
    if result.returncode not in (0, 3, 4):
        raise SshHardenError()
    return result.returncode == 0


def socket_listeners():
    value = run(['/usr/bin/systemctl', 'show', 'ssh.socket', '-p', 'Listen', '--value']).stdout.strip()
    listeners = re.findall(r'(\S+) \(Stream\)', value)
    if not listeners or ' '.join(f'{v} (Stream)' for v in listeners) != ' '.join(value.split()):
        raise SshHardenError('ssh_harden_invalid')
    for address in listeners:
        split_address(address)
    return listeners


def split_address(address):
    if address.isdigit():
        return '[::]', int(address)
    host, separator, port = address.rpartition(':')
    if not separator or not port.isdigit():
        raise SshHardenError('ssh_harden_invalid')
    if host not in ('*', '[::]'):
        try:
            ipaddress.ip_address(host.strip('[]').split('%')[0])
        except ValueError:
            raise SshHardenError('ssh_harden_invalid')
    return host, int(port)


def active_ssh_ports():
    return sorted({int(p) for p in effective()['port']})


def user_exists(username):
    try:
        return pwd.getpwnam(username)
    except KeyError:
        return None


def free_port(port):
    sockets = []
    try:
        families = [(socket.AF_INET, '0.0.0.0')]
        if socket.has_ipv6 and Path('/proc/net/if_inet6').exists():
            families.append((socket.AF_INET6, '::'))
        for family, host in families:
            s = socket.socket(family, socket.SOCK_STREAM)
            sockets.append(s)
            if family == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            s.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        for s in sockets:
            s.close()


def host_state():
    run(['/usr/sbin/sshd', '-t'])
    # Command-line overrides would make sshd -T describe a different daemon.
    command = run(['/usr/bin/systemctl', 'show', 'ssh.service', '-p', 'ExecStart', '--value']).stdout
    if '/usr/sbin/sshd' not in command or re.search(r'(?:^|\s)-(?:f|p|o)(?:\s|\S)', command):
        raise SshHardenError('ssh_harden_invalid')
    for path in (Path('/etc/default/ssh'),):
        if path.exists():
            for line in path.read_text().splitlines():
                if re.match(r'\s*(?:export\s+)?SSHD_OPTS\s*=', line):
                    value = line.split('=', 1)[1].strip()
                    if shlex.split(value, comments=True) not in ([], ['']):
                        raise SshHardenError('ssh_harden_invalid')
    environment = run(['/usr/bin/systemctl', 'show', 'ssh.service', '-p', 'Environment', '--value']).stdout
    if any(v.startswith('SSHD_OPTS=') and v != 'SSHD_OPTS=' for v in shlex.split(environment)):
        raise SshHardenError('ssh_harden_invalid')
    cfg = effective()
    socket_active = is_socket_activation()
    listeners = socket_listeners() if socket_active else cfg.get('listenaddress', [])
    if socket_active and run(['/usr/bin/systemctl', 'show', 'ssh.service', '-p', 'KillMode', '--value']).stdout.strip() != 'process':
        raise SshHardenError('ssh_harden_invalid')
    ports = sorted({split_address(v)[1] for v in listeners})
    if not ports:
        raise SshHardenError('ssh_harden_invalid')
    files = config_files()
    # Check all ListenAddress forms now, before creating a user or touching SSH.
    for entry in files:
        render_config(entry, ports, False)
    return dict(files=files, ports=ports, socket_activation=socket_active,
                listeners=listeners, root=cfg['permitrootlogin'][0])


def compute_fingerprint(state=None):
    state = state or host_state()
    extras = [snapshot(SOCKET_CONFIG)] + [snapshot(p) for p in sorted(SUDO_DIRECTORY.glob('*'))]
    extras += [snapshot(p) for p in UFW_FILES]
    return hashlib.sha256(json.dumps([state, extras], sort_keys=True).encode()).hexdigest()


def parse_payload(req, submission=False):
    data = json.loads(req.get('payload', '{}'))
    if type(data) is not dict or set(data) - {'username', 'port', 'sudoPassword', 'publicKey', 'disableRootLogin', 'deadlineSeconds'}:
        raise SshHardenError('ssh_harden_invalid')
    user, port = data.get('username'), data.get('port')
    if type(user) is not str or not re.fullmatch('[a-z_][a-z0-9_-]{1,31}', user) or type(port) is not int or not 1024 <= port <= 65535:
        raise SshHardenError('ssh_harden_invalid')
    if submission:
        password = data.get('sudoPassword')
        if type(password) is not str or not password or len(password.encode()) > 1024 or re.search(r'[\x00-\x1f\x7f]', password):
            raise SshHardenError('ssh_harden_invalid')
        deadline = data.get('deadlineSeconds', 300)
        if type(deadline) is not int or not 30 <= deadline <= 600 or type(data.get('disableRootLogin', True)) is not bool:
            raise SshHardenError('ssh_harden_invalid')
        key = data.get('publicKey', '')
        if type(key) is not str or len(key) > 16384 or '\n' in key or '\r' in key or '\x00' in key:
            raise SshHardenError('ssh_harden_invalid')
    return data


def plan(store, req):
    data = parse_payload(req)
    state = host_state()
    return dict(supported=True, currentPort=state['ports'][0],
                currentRootLogin='disabled' if state['root'] == 'no' else 'allowed',
                socketActivation=state['socket_activation'], proposedPort=data['port'],
                proposedUser=data['username'],
                portAvailable=data['port'] in state['ports'] or free_port(data['port']),
                userAvailable=not user_exists(data['username']) and not (HOME_DIRECTORY / data['username']).exists(),
                fingerprint=compute_fingerprint(state))


def render_config(entry, ports, disable_root):
    lines = []
    for line in content(entry).decode('utf-8').splitlines():
        parts = tokens(line)
        key = parts[0].lower() if parts else ''
        if key == 'port':
            continue
        if key == 'permitrootlogin' and disable_root:
            lines.append('PermitRootLogin no')  # Also covers every Match branch.
        elif key == 'listenaddress':
            if len(parts) != 2:
                raise SshHardenError('ssh_harden_invalid')
            address = parts[1]
            if address.startswith('[') or address.count(':') == 1:
                host, _ = split_address(address)
                lines.extend(f'ListenAddress {host}:{p}' for p in ports)
            else:
                # Bare IP/hostname without a port inherits the new Port values.
                lines.append(line)
        else:
            lines.append(line)
    if entry['path'] == str(SSH_CONFIG):
        lines = ['# AntiRKN SSH access policy', *[f'Port {p}' for p in ports],
                 *(['PermitRootLogin no'] if disable_root else []), *lines]
    return ('\n'.join(lines) + '\n').encode()


def unit_name(job_id):
    backup_path(job_id)
    return 'antirkn-ssh-watchdog-' + job_id + '.service'


def arm_watchdog(job_id):
    name = unit_name(job_id)
    source = str(Path(__file__).resolve())
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', source):
        raise SshHardenError()
    atomic_file(UNIT_DIRECTORY / name,
        '[Unit]\nDescription=AntiRKN SSH access recovery\nAfter=local-fs.target\n'
        'StartLimitIntervalSec=0\n'
        '[Service]\nType=simple\nUMask=0077\nRestart=on-failure\nRestartSec=2\n'
        f'ExecStart=/usr/bin/python3 -I {source} watchdog {job_id}\n'
        '[Install]\nWantedBy=multi-user.target\n', 0o644)
    run(['/usr/bin/systemctl', 'daemon-reload'])
    run(['/usr/bin/systemctl', 'enable', '--now', name])
    run(['/usr/bin/systemctl', 'is-active', '--quiet', name])


def retire_watchdog(job_id):
    # Never stop our own cgroup. The watcher observes the terminal journal and
    # exits naturally. Removal/disable does not kill a running service.
    name = unit_name(job_id)
    run(['/usr/bin/systemctl', 'disable', name])
    (UNIT_DIRECTORY / name).unlink(missing_ok=True)
    run(['/usr/bin/systemctl', 'daemon-reload'])


def expired(info):
    return (info['boot_id'] != BOOT_ID.read_text().strip() or
            time.time() >= info['deadline_at'] or time.monotonic() >= info['deadline_monotonic'])


def verify_policy(info, final=False):
    ports = [info['port']] if final else sorted(set(info['old_ports'] + [info['port']]))
    run(['/usr/sbin/sshd', '-t'])
    for user in ('root', info['username']):
        cfg = effective(user, info['port'])
        if sorted({int(p) for p in cfg['port']}) != ports:
            raise SshHardenError()
        if final and info['disable_root'] and cfg['permitrootlogin'] != ['no']:
            raise SshHardenError()
    return ports


def reload_ssh_service(socket_active=False):
    run(['/usr/bin/systemctl', 'daemon-reload'])
    if socket_active:
        # Ubuntu ssh.service uses KillMode=process: authenticated sessions live.
        run(['/usr/bin/systemctl', 'stop', 'ssh.service'])
        run(['/usr/bin/systemctl', 'restart', 'ssh.socket'])
        run(['/usr/bin/systemctl', 'start', 'ssh.service'])
    else:
        run(['/usr/bin/systemctl', 'reload-or-restart', 'ssh.service'])
    run(['/usr/bin/systemctl', 'is-active', '--quiet', 'ssh.service'])


def verify_listeners(ports, socket_active):
    output = run(['/usr/bin/ss', '-H', '-ltnp']).stdout
    actual = set()
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 5 and ('"sshd"' in line or '"sshd-session"' in line):
            actual.add(split_address(fields[3])[1])
    if socket_active:
        actual.update(split_address(v)[1] for v in socket_listeners())
    if actual != set(ports):
        raise SshHardenError()


def check_owned_files(info):
    for entry in info['files']:
        current = snapshot(entry['path'])
        if digest(content(current)) not in entry['allowed']:
            raise SshHardenError('ssh_harden_conflict')
    if {v['path'] for v in config_files()} != set(info['config_paths']):
        raise SshHardenError('ssh_harden_conflict')


def apply_policy(job_id, info, final):
    check_owned_files(info)
    ports = [info['port']] if final else sorted(set(info['old_ports'] + [info['port']]))
    writes = []
    for entry in info['files']:
        if entry['path'] in info['config_paths']:
            writes.append((entry, render_config(entry, ports, final and info['disable_root'])))
        elif entry['path'] == str(SOCKET_CONFIG) and info['socket_activation']:
            hosts = sorted({split_address(v)[0] for v in info['listeners']})
            text = '[Socket]\nListenStream=\n' + ''.join(f'ListenStream={h}:{p}\n' for h in hosts for p in ports)
            writes.append((entry, text.encode()))
    # Journal the exact allowed post-images before each atomic write/crash.
    for entry, data in writes:
        entry['allowed'] = sorted(set(entry['allowed'] + [digest(data)]), key=str)
    save_info(job_id, info)
    for entry, data in writes:
        atomic_file(entry['path'], data, entry.get('mode', 0o644), entry.get('uid'), entry.get('gid'))
    verify_policy(info, final)
    reload_ssh_service(info['socket_activation'])
    verify_listeners(ports, info['socket_activation'])


def _rollback(job_id, info):
    if info['phase'] == 'committed':
        raise SshHardenError('ssh_harden_conflict')
    if info['phase'] == 'rolled_back':
        return True
    info['phase'] = 'rolling_back'
    save_info(job_id, info)
    try:
        # Cleanup may have to wait for a PAM/systemd user session to exit.
        # Never keep restarting a restored listener while waiting for userdel.
        if not info.get('access_restored'):
            # Restore and verify the old listener BEFORE removing the new account.
            for entry in info['files']:
                if entry['path'] not in info['config_paths'] and entry['path'] != str(SOCKET_CONFIG):
                    continue
                current = snapshot(entry['path'])
                if digest(content(current)) not in entry['allowed']:
                    raise SshHardenError('ssh_harden_conflict')
                restore_file(entry)
            reload_ssh_service(info['socket_activation'])
            # Starting the service recreates its RuntimeDirectory after boot.
            run(['/usr/sbin/sshd', '-t'])
            verify_listeners(info['old_ports'], info['socket_activation'])
            info['access_restored'] = True
            save_info(job_id, info)
        else:
            verify_listeners(info['old_ports'], info['socket_activation'])
        for entry in info['files']:
            if entry['path'] in info['config_paths'] or entry['path'] == str(SOCKET_CONFIG):
                continue
            current = snapshot(entry['path'])
            if digest(content(current)) not in entry['allowed']:
                raise SshHardenError('ssh_harden_conflict')
            restore_file(entry)
        if info.get('ufw_changed'):
            run(['/usr/sbin/ufw', 'reload'])
        user = user_exists(info['username'])
        if user:
            if user.pw_uid == 0 or user.pw_gecos != info['user_marker']:
                raise SshHardenError('ssh_harden_conflict')
            if os.environ.get('SUDO_UID') != str(user.pw_uid):
                # Kill only sessions of the account created by this transaction.
                # When abort arrived through that account, the watchdog performs
                # this cleanup after the RPC has returned via the old access.
                run(['/usr/bin/loginctl', 'terminate-user', str(user.pw_uid)], check=False, timeout=10)
            run(['/usr/sbin/userdel', '-r', info['username']])
        info['phase'] = 'rolled_back'
        save_info(job_id, info)
        return True
    except (SshHardenError, *ERRORS) as error:
        # userdel may wait for the last SSH/PAM process to leave. The old
        # listener is already verified; the watchdog retries only cleanup.
        pending_user = (isinstance(error, subprocess.CalledProcessError) and
                        error.cmd[:1] == ['/usr/sbin/userdel'] and error.returncode == 8)
        info['phase'] = 'rolling_back' if pending_user else 'rollback_failed'
        save_info(job_id, info)
        return False


def rollback(job_id):
    with harden_lock():
        return _rollback(job_id, load_info(job_id))


def result(info):
    return dict(confirmed=info['phase'] == 'committed', aborted=info['phase'] == 'rolled_back',
                finalized=info['phase'] == 'finalizing', phase=info['phase'],
                port=info['port'], username=info['username'], deadline=info['deadline_at'])


def check_job(store, job_id):
    row = store.db.execute('SELECT request,status,checkpoint,cancel FROM jobs WHERE id=?', (job_id,)).fetchone()
    if row is None or json.loads(row['request']).get('kind') != 'ssh_harden':
        raise SshHardenError('ssh_harden_conflict')
    return row


def record_terminal(store, job_id, info):
    if info['phase'] not in (*TERMINAL, 'rollback_failed'):
        return
    state = 'succeeded' if info['phase'] == 'committed' else 'failed' if info['phase'] == 'rolled_back' else 'needs_attention'
    event = 'ssh_harden_confirmed' if state == 'succeeded' else 'ssh_harden_aborted' if state == 'failed' else 'ssh_harden_failed'
    row = check_job(store, job_id)
    if row['status'] != state:
        with store.db:
            store.db.execute('UPDATE jobs SET status=?,checkpoint=? WHERE id=?', (state, 7 if state == 'succeeded' else row['checkpoint'], job_id))
            store.event(job_id, event, 7 if state == 'succeeded' else row['checkpoint'], 7)


class SshHardenJob:
    def __init__(self, store, req):
        self.store, self.req, self.job_id = store, req, req['id']
        self.bdir = backup_path(self.job_id)

    def advance(self, checkpoint, code):
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint, self.job_id))
            self.store.event(self.job_id, code, checkpoint, 7)

    def tick(self):
        with harden_lock():
            row = check_job(self.store, self.job_id)
            info = load_info(self.job_id) if (self.bdir / 'info.json').exists() else None
            if info and info['phase'] in TERMINAL:
                record_terminal(self.store, self.job_id, info)
                return
            try:
                if row['cancel'] or info and (expired(info) or info['phase'] in ('rolling_back', 'rollback_failed')):
                    if info:
                        _rollback(self.job_id, info)
                        record_terminal(self.store, self.job_id, info)
                    else:
                        with self.store.db:
                            self.store.db.execute("UPDATE jobs SET status='cancelled' WHERE id=?", (self.job_id,))
                            self.store.event(self.job_id, 'cancelled', 0, 7)
                    return
                checkpoint = row['checkpoint']
                if checkpoint == 0:
                    if info is None:
                        info = self.prepare()
                    arm_watchdog(self.job_id)
                    self.advance(1, 'ssh_harden_preparing')
                elif checkpoint == 1:
                    self.create_user(info)
                    self.advance(2, 'ssh_harden_user_created')
                elif checkpoint == 2:
                    self.sudoers(info)
                    self.advance(3, 'ssh_harden_sudoers_configured')
                elif checkpoint == 3:
                    self.firewall(info)
                    self.advance(4, 'ssh_harden_firewall_configured')
                elif checkpoint == 4:
                    apply_policy(self.job_id, info, False)
                    self.advance(5, 'ssh_harden_ports_configured')
                elif checkpoint == 5:
                    info['phase'] = 'testing'
                    save_info(self.job_id, info)
                    self.advance(6, 'ssh_harden_testing')
            except (SshHardenError, *ERRORS):
                if info:
                    _rollback(self.job_id, info)
                    record_terminal(self.store, self.job_id, info)
                else:
                    with self.store.db:
                        self.store.db.execute("UPDATE jobs SET status='failed' WHERE id=?", (self.job_id,))
                        self.store.event(self.job_id, 'ssh_harden_failed', 0, 7)

    def prepare(self):
        data = parse_payload(self.req, True)
        state = host_state()
        if self.req['fingerprint'] != compute_fingerprint(state):
            raise SshHardenError('ssh_harden_conflict')
        for path in BACKUP_DIR.glob('ssh_*/info.json'):
            previous = json.loads(path.read_text())
            if previous.get('phase') in TERMINAL:
                continue
            if previous.get('version') != 2:
                previous_id = path.parent.name[len('ssh_'):] if path.parent.name.startswith('ssh_') else path.parent.name
                row = self.store.db.execute('SELECT status FROM jobs WHERE id=?', (previous_id,)).fetchone()
                if row and ((row['status'] == 'succeeded' and
                             (RUNNER_DIR / 'ssh_confirmed' / ('confirmed_' + previous_id)).is_file()) or
                            (row['status'] in ('failed', 'cancelled') and (path.parent / 'rolled_back').is_file())):
                    continue
            raise SshHardenError('ssh_harden_conflict')
        username = data['username']
        if user_exists(username) or (HOME_DIRECTORY / username).exists():
            raise SshHardenError('ssh_harden_conflict')
        if data['port'] not in state['ports'] and not free_port(data['port']):
            raise SshHardenError('ssh_harden_port_busy')
        sudo = snapshot(SUDO_DIRECTORY / ('99-antirkn-' + username))
        if sudo['data'] is not None:
            raise SshHardenError('ssh_harden_conflict')
        files = state['files'] + [snapshot(SOCKET_CONFIG), sudo] + [snapshot(p) for p in UFW_FILES]
        for entry in files:
            entry['allowed'] = [digest(content(entry))]
        self.bdir.mkdir(mode=0o700, parents=True, exist_ok=True)
        deadline = data.get('deadlineSeconds', 300)
        info = dict(version=2, job_id=self.job_id, username=username, port=data['port'],
                    old_ports=state['ports'], socket_activation=state['socket_activation'],
                    listeners=state['listeners'], disable_root=data.get('disableRootLogin', True),
                    deadline_at=time.time() + deadline, deadline_monotonic=time.monotonic() + deadline,
                    boot_id=BOOT_ID.read_text().strip(), phase='staging', files=files,
                    config_paths=[e['path'] for e in state['files']], user_marker='AntiRKN SSH ' + self.job_id)
        save_info(self.job_id, info)
        return info

    def create_user(self, info):
        data = parse_payload(self.req, True)
        user = user_exists(info['username'])
        if user is None:
            run(['/usr/sbin/useradd', '-m', '-s', '/bin/bash', '-c', info['user_marker'], info['username']])
            user = user_exists(info['username'])
        if not user or user.pw_uid == 0 or user.pw_gecos != info['user_marker'] or user.pw_dir != str(HOME_DIRECTORY / info['username']):
            raise SshHardenError('ssh_harden_conflict')
        keys = []
        root_keys = ROOT_AUTH
        if root_keys.exists():
            keys = content(snapshot(root_keys)).decode().splitlines()
        if data.get('publicKey'):
            keys.append(data['publicKey'])
        if keys:
            directory = Path(user.pw_dir) / '.ssh'
            if directory.is_symlink():
                raise SshHardenError('ssh_harden_conflict')
            directory.mkdir(mode=0o700, exist_ok=True)
            os.chmod(directory, 0o700)
            os.chown(directory, user.pw_uid, user.pw_gid)
            atomic_file(directory / 'authorized_keys', '\n'.join(keys) + '\n', 0o600, user.pw_uid, user.pw_gid)
        run(['/usr/sbin/chpasswd'], input=info['username'] + ':' + data['sudoPassword'] + '\n')

    def sudoers(self, info):
        entry = next(e for e in info['files'] if e['path'] == str(SUDO_DIRECTORY / ('99-antirkn-' + info['username'])))
        data = f"{info['username']} ALL=(ALL:ALL) PASSWD: ALL\n".encode()
        entry['allowed'] = list(set(entry['allowed'] + [digest(data)]))
        save_info(self.job_id, info)
        atomic_file(entry['path'], data, 0o440)
        run(['/usr/sbin/visudo', '-c'])

    def firewall(self, info):
        if not Path('/usr/sbin/ufw').exists():
            return
        if 'Status: active' not in run(['/usr/sbin/ufw', 'status']).stdout:
            return
        # Whole-file snapshots preserve pre-existing rules. Only exact owned
        # post-images may be restored; concurrent firewall edits are a conflict.
        run(['/usr/sbin/ufw', 'allow', f"{info['port']}/tcp", 'comment', 'antirkn-ssh-' + self.job_id])
        for entry in info['files']:
            if entry['path'] in map(str, UFW_FILES):
                current = digest(content(snapshot(entry['path'])))
                if current != digest(content(entry)):
                    entry['allowed'].append(current)
                    info['ufw_changed'] = True
        save_info(self.job_id, info)

    @staticmethod
    def status(store, req):
        with harden_lock():
            if store.db.execute('SELECT 1 FROM jobs WHERE id=?', (req['id'],)).fetchone() is None:
                return dict(phase='missing')
            row = check_job(store, req['id'])
            if not (backup_path(req['id']) / 'info.json').exists():
                return dict(phase='staging' if row['status'] in ('planned', 'running') else row['status'])
            info = load_info(req['id'])
            if info['phase'] not in TERMINAL and expired(info):
                _rollback(req['id'], info)
                record_terminal(store, req['id'], info)
            return result(info)

    @staticmethod
    def confirm(store, req):
        with harden_lock():
            row = check_job(store, req['id'])
            info = load_info(req['id'])
            if info['phase'] == 'committed':
                return result(info)
            if row['status'] != 'running' or row['checkpoint'] != 6 or row['cancel'] or info['phase'] not in ('testing', 'finalizing'):
                raise SshHardenError('ssh_harden_conflict')
            if expired(info):
                _rollback(req['id'], info)
                record_terminal(store, req['id'], info)
                raise SshHardenError('ssh_harden_conflict')
            try:
                if info['phase'] == 'testing':
                    apply_policy(req['id'], info, True)
                    info['phase'] = 'finalizing'
                    save_info(req['id'], info)
                return result(info)
            except (SshHardenError, *ERRORS):
                _rollback(req['id'], info)
                record_terminal(store, req['id'], info)
                raise SshHardenError()

    @staticmethod
    def commit(store, req):
        with harden_lock():
            row = check_job(store, req['id'])
            info = load_info(req['id'])
            if info['phase'] == 'committed':
                record_terminal(store, req['id'], info)
                return result(info)
            if row['status'] != 'running' or row['cancel'] or info['phase'] != 'finalizing' or expired(info):
                raise SshHardenError('ssh_harden_conflict')
            user = user_exists(info['username'])
            # Commit is sent through the NEW authenticated user's sudo channel.
            if (not user or user.pw_uid == 0 or user.pw_gecos != info['user_marker'] or
                    os.environ.get('SUDO_USER') != info['username'] or os.environ.get('SUDO_UID') != str(user.pw_uid)):
                raise SshHardenError('ssh_harden_conflict')
            check_owned_files(info)
            verify_policy(info, True)
            verify_listeners([info['port']], info['socket_activation'])
            info['phase'] = 'committed'
            save_info(req['id'], info)  # Durable before replying or disarming.
            record_terminal(store, req['id'], info)
            return result(info)

    @staticmethod
    def abort(store, req):
        with harden_lock():
            row = check_job(store, req['id'])
            if not (backup_path(req['id']) / 'info.json').exists():
                if row['status'] in ('planned', 'running', 'cancelled') and row['checkpoint'] == 0:
                    with store.db:
                        store.db.execute("UPDATE jobs SET status='cancelled',cancel=1 WHERE id=?", (req['id'],))
                    return dict(aborted=True, phase='rolled_back')
                raise SshHardenError('ssh_harden_conflict')
            info = load_info(req['id'])
            if info['phase'] == 'committed':
                raise SshHardenError('ssh_harden_conflict')
            _rollback(req['id'], info)
            record_terminal(store, req['id'], info)
            if info['phase'] not in ('rolled_back', 'rolling_back'):
                raise SshHardenError()
            return result(info)


def watchdog_loop(job_id):
    while True:
        with harden_lock():
            info = load_info(job_id)
            if info['phase'] not in TERMINAL and (expired(info) or info['phase'] in ('rolling_back', 'rollback_failed')):
                _rollback(job_id, info)
            terminal = info['phase'] in TERMINAL
        if terminal:
            retire_watchdog(job_id)
            return
        time.sleep(1)


if __name__ == '__main__':
    os.umask(0o077)
    if os.geteuid() != 0 or len(sys.argv) != 3 or sys.argv[1] != 'watchdog':
        sys.exit(1)
    watchdog_loop(sys.argv[2])
