"""Durable SSH hardening and access protection with auto-rollback.

Provides a safe two-phase transition from root on port 22 to a non-root sudo
user on a hardened port, backed by an independent watchdog with deadline.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import stat
import subprocess
import sys
import time

RUNNER_DIR = Path('/var/lib/antirkn-runner')
BACKUP_DIR = RUNNER_DIR / 'ssh_backups'
CONFIRMED_DIR = RUNNER_DIR / 'ssh_confirmed'


class SshHardenError(Exception):
    def __init__(self, code='ssh_harden_failed', message=None):
        self.code = code
        self.message = message or code
        super().__init__(self.message)


def is_socket_activation():
    try:
        res = subprocess.run(
            ['/usr/bin/systemctl', 'is-active', '--quiet', 'ssh.socket'],
            timeout=5,
        )
        return res.returncode == 0
    except Exception:
        return False


def reload_ssh_service(socket_active=False):
    subprocess.run(['/usr/bin/systemctl', 'daemon-reload'], check=True, timeout=10)
    if socket_active:
        subprocess.run(['/usr/bin/systemctl', 'restart', 'ssh.socket'], check=True, timeout=15)
        try:
            res = subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', 'ssh.service'], timeout=5)
            if res.returncode == 0:
                subprocess.run(['/usr/bin/systemctl', 'reload-or-restart', 'ssh.service'], timeout=15)
        except Exception:
            pass
    else:
        subprocess.run(['/usr/bin/systemctl', 'restart', 'ssh'], check=True, timeout=15)


def active_ssh_ports():
    ports = set()
    for conf in [Path('/etc/ssh/sshd_config')] + sorted(Path('/etc/ssh/sshd_config.d').glob('*.conf')):
        if not conf.is_file():
            continue
        try:
            for line in conf.read_text().splitlines():
                line = line.strip()
                if line.lower().startswith('port ') and not line.startswith('#'):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1].isdigit():
                        ports.add(int(parts[1]))
        except Exception:
            pass
    if not ports:
        ports.add(22)
    return sorted(ports)


def is_root_login_allowed():
    try:
        res = subprocess.run(
            ['/usr/sbin/sshd', '-T'],
            capture_output=True,
            text=True,
            timeout=10,
        )
        for line in res.stdout.splitlines():
            if line.lower().startswith('permitrootlogin '):
                val = line.split(None, 1)[1].strip().lower()
                return val in ('yes', 'without-password', 'prohibit-password')
    except Exception:
        pass
    return True


def user_exists(username):
    try:
        pwd.getpwnam(username)
        return True
    except KeyError:
        return False


def free_port(port):
    sockets = []
    try:
        for family, host in ((socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')):
            s = socket.socket(family, socket.SOCK_STREAM)
            sockets.append(s)
            if family == socket.AF_INET6:
                try:
                    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                except (AttributeError, OSError):
                    pass
            s.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        for s in sockets:
            s.close()


def compute_fingerprint():
    paths = [Path('/etc/ssh/sshd_config')] + sorted(Path('/etc/ssh/sshd_config.d').glob('*.conf'))
    paths += sorted(Path('/etc/sudoers.d').glob('*'))
    items = []
    for p in paths:
        if p.is_file():
            try:
                st = p.stat()
                items.append((str(p), st.st_size, st.st_mtime_ns))
            except Exception:
                pass
    return hashlib.sha256(json.dumps(items, sort_keys=True).encode()).hexdigest()


def plan(store, req):
    payload = req.get('payload', '{}')
    data = json.loads(payload) if isinstance(payload, str) else payload
    proposed_user = data.get('username', 'admin')
    proposed_port = int(data.get('port', 2222))
    ports = active_ssh_ports()
    current_port = ports[0] if ports else 22
    socket_active = is_socket_activation()
    root_allowed = is_root_login_allowed()
    u_avail = not user_exists(proposed_user) and not (Path('/home') / proposed_user).exists()
    p_avail = free_port(proposed_port) or (proposed_port in ports)
    fp = compute_fingerprint()
    return {
        'supported': True,
        'currentPort': current_port,
        'currentRootLogin': 'allowed' if root_allowed else 'disabled',
        'socketActivation': socket_active,
        'proposedPort': proposed_port,
        'proposedUser': proposed_user,
        'portAvailable': p_avail,
        'userAvailable': u_avail,
        'fingerprint': fp,
    }


def backup_path(job_id):
    return BACKUP_DIR / f'ssh_{job_id}'


def confirmed_token(job_id):
    return CONFIRMED_DIR / f'confirmed_{job_id}'


def stop_watchdog(job_id):
    try:
        subprocess.run(
            ['/usr/bin/systemctl', 'stop', f'antirkn-ssh-watchdog-{job_id}'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
        subprocess.run(
            ['/usr/bin/systemctl', 'reset-failed', f'antirkn-ssh-watchdog-{job_id}'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except Exception:
        pass


def rollback(job_id):
    stop_watchdog(job_id)
    bdir = backup_path(job_id)
    info_file = bdir / 'info.json'
    if not info_file.exists():
        return False
    info = json.loads(info_file.read_text())
    username = info.get('username')
    port = info.get('port')
    user_created = info.get('user_created', False)
    socket_active = info.get('socket_activation', False)
    ufw_rule_added = info.get('ufw_rule_added', False)

    # 1. Remove drop-in files created by hardening
    Path('/etc/ssh/sshd_config.d/99-antirkn-harden.conf').unlink(missing_ok=True)
    if username:
        Path(f'/etc/sudoers.d/99-antirkn-{username}').unlink(missing_ok=True)

    # 2. Remove user if created during hardening
    if user_created and username:
        try:
            subprocess.run(['/usr/sbin/userdel', '-r', '-f', username], capture_output=True, timeout=15)
        except Exception:
            pass

    # 3. Remove UFW rule if added
    if ufw_rule_added and port:
        try:
            subprocess.run(['/usr/sbin/ufw', 'delete', 'allow', f'{port}/tcp'], capture_output=True, timeout=10)
        except Exception:
            pass

    # 4. Reload and restart SSH
    try:
        reload_ssh_service(socket_active)
    except Exception:
        pass

    # Record rolled back marker
    (bdir / 'rolled_back').touch()
    return True


class SshHardenJob:
    def __init__(self, store, req):
        self.store = store
        self.req = req
        payload = req.get('payload', '{}')
        self.payload = json.loads(payload) if isinstance(payload, str) else payload
        self.job_id = req['id']
        self.bdir = backup_path(self.job_id)

    def step(self, checkpoint):
        if checkpoint == 0:
            self._step_backup()
        elif checkpoint == 1:
            self._step_user()
        elif checkpoint == 2:
            self._step_sudoers()
        elif checkpoint == 3:
            self._step_dual_ssh()
        elif checkpoint == 4:
            self._step_firewall()
        elif checkpoint == 5:
            self._step_watchdog()
        elif checkpoint == 6:
            # Checkpoint 6: In testing phase.
            # Stays in testing phase until confirm or abort is called.
            pass

    def _step_backup(self):
        current_fp = compute_fingerprint()
        expected_fp = self.req.get('fingerprint')
        if expected_fp and current_fp != expected_fp:
            raise SshHardenError('ssh_harden_conflict', 'Configuration changed since plan')
        username = self.payload.get('username', '').strip()
        if not re.fullmatch(r'^[a-z_][a-z0-9_-]{1,31}$', username):
            raise SshHardenError('ssh_harden_invalid', 'Invalid username')
        if user_exists(username):
            raise SshHardenError('ssh_harden_conflict', f'User {username} already exists')
        port = int(self.payload.get('port', 2222))
        if port < 1024 or port > 65535:
            raise SshHardenError('ssh_harden_invalid', 'Invalid port')
        ports = active_ssh_ports()
        current_port = ports[0] if ports else 22
        if port not in ports and not free_port(port):
            raise SshHardenError('ssh_harden_port_busy', f'Port {port} is occupied')

        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(str(BACKUP_DIR), 0o700)
        self.bdir.mkdir(parents=True, exist_ok=True)
        os.chmod(str(self.bdir), 0o700)

        info = {
            'job_id': self.job_id,
            'username': username,
            'port': port,
            'old_port': current_port,
            'socket_activation': is_socket_activation(),
            'disable_root': self.payload.get('disableRootLogin', True),
            'deadline': int(self.payload.get('deadlineSeconds', 300)),
            'user_created': False,
            'ufw_rule_added': False,
            'created_at': time.time(),
        }
        (self.bdir / 'info.json').write_text(json.dumps(info, indent=2))
        self._advance(1, 'ssh_harden_preparing')

    def _step_user(self):
        info = json.loads((self.bdir / 'info.json').read_text())
        username = info['username']
        # Create user
        cmd = ['/usr/sbin/useradd', '-m', '-s', '/bin/bash', username]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if res.returncode != 0:
            raise SshHardenError('ssh_harden_failed', f'useradd failed: {res.stderr}')
        info['user_created'] = True
        (self.bdir / 'info.json').write_text(json.dumps(info, indent=2))

        # Setup SSH authorized_keys (copy root keys and any provided public key)
        keys = []
        root_auth = Path('/root/.ssh/authorized_keys')
        if root_auth.is_file():
            try:
                keys.extend([k.strip() for k in root_auth.read_text().splitlines() if k.strip()])
            except Exception:
                pass
        public_key = self.payload.get('publicKey', '').strip()
        if public_key and public_key not in keys:
            keys.append(public_key)

        if keys:
            user_home = Path('/home') / username
            ssh_dir = user_home / '.ssh'
            ssh_dir.mkdir(mode=0o700, exist_ok=True)
            auth_file = ssh_dir / 'authorized_keys'
            auth_file.write_text('\n'.join(keys) + '\n')
            auth_file.chmod(0o600)
            u_entry = pwd.getpwnam(username)
            os.chown(str(ssh_dir), u_entry.pw_uid, u_entry.pw_gid)
            os.chown(str(auth_file), u_entry.pw_uid, u_entry.pw_gid)

        # Set user and sudo password
        password = self.payload.get('password') or self.payload.get('sudoPassword')
        if password:
            chp = subprocess.run(
                ['/usr/sbin/chpasswd'],
                input=f'{username}:{password}\n'.encode(),
                capture_output=True,
                timeout=10,
            )
            if chp.returncode != 0:
                rollback(self.job_id)
                raise SshHardenError('ssh_harden_failed', 'chpasswd failed')

        self._advance(2, 'ssh_harden_user_created')

    def _step_sudoers(self):
        info = json.loads((self.bdir / 'info.json').read_text())
        username = info['username']
        sudoers_file = Path(f'/etc/sudoers.d/99-antirkn-{username}')
        sudoers_file.write_text(f'{username} ALL=(ALL:ALL) ALL\n')
        sudoers_file.chmod(0o440)

        # Validate with visudo
        res = subprocess.run(
            ['/usr/sbin/visudo', '-c', '-f', str(sudoers_file)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if res.returncode != 0:
            sudoers_file.unlink(missing_ok=True)
            rollback(self.job_id)
            raise SshHardenError('ssh_harden_failed', f'visudo validation failed: {res.stderr}')

        self._advance(3, 'ssh_harden_sudoers_configured')

    def _step_dual_ssh(self):
        info = json.loads((self.bdir / 'info.json').read_text())
        port = info['port']
        old_port = info['old_port']
        socket_active = info['socket_activation']

        # Setup drop-in sshd configuration
        Path('/etc/ssh/sshd_config.d').mkdir(parents=True, exist_ok=True)
        ports_to_listen = [old_port] if old_port == port else [old_port, port]
        conf_lines = ['# AntiRKN dual-port testing configuration'] + [f'Port {p}' for p in ports_to_listen]
        Path('/etc/ssh/sshd_config.d/99-antirkn-harden.conf').write_text('\n'.join(conf_lines) + '\n')

        # Test sshd syntax
        check = subprocess.run(['/usr/sbin/sshd', '-t'], capture_output=True, text=True, timeout=10)
        if check.returncode != 0:
            rollback(self.job_id)
            raise SshHardenError('ssh_harden_failed', f'sshd -t check failed: {check.stderr}')

        # Reload systemd and restart SSH
        reload_ssh_service(socket_active)

        self._advance(4, 'ssh_harden_ports_configured')

    def _step_firewall(self):
        info = json.loads((self.bdir / 'info.json').read_text())
        port = info['port']
        try:
            res = subprocess.run(['/usr/sbin/ufw', 'status'], capture_output=True, text=True, timeout=5)
            if 'Status: active' in res.stdout:
                subprocess.run(['/usr/sbin/ufw', 'allow', f'{port}/tcp'], capture_output=True, timeout=10)
                info['ufw_rule_added'] = True
                (self.bdir / 'info.json').write_text(json.dumps(info, indent=2))
        except Exception:
            pass

        self._advance(5, 'ssh_harden_firewall_configured')

    def _step_watchdog(self):
        info = json.loads((self.bdir / 'info.json').read_text())
        deadline = info['deadline']
        CONFIRMED_DIR.mkdir(parents=True, exist_ok=True)
        token = confirmed_token(self.job_id)
        token.unlink(missing_ok=True)

        runner_script = Path(__file__).resolve()
        cmd = [
            '/usr/bin/systemd-run',
            '--unit', f'antirkn-ssh-watchdog-{self.job_id}',
            '--description', f'AntiRKN SSH Rollback Watchdog for job {self.job_id}',
            '/usr/bin/python3', '-I', str(runner_script), 'watchdog', self.job_id, str(deadline),
        ]
        try:
            subprocess.run(cmd, capture_output=True, timeout=10, check=True)
        except Exception:
            # Fallback to detached process if systemd-run fails
            subprocess.Popen(
                ['/usr/bin/python3', '-I', str(runner_script), 'watchdog', self.job_id, str(deadline)],
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        self._advance(6, 'ssh_harden_testing')

    def _advance(self, checkpoint, event_code):
        with self.store.db:
            self.store.db.execute(
                'UPDATE jobs SET checkpoint=? WHERE id=?',
                (checkpoint, self.job_id),
            )
            self.store.event(self.job_id, event_code, checkpoint, self.req['count'])

    @staticmethod
    def confirm(store, req):
        job_id = req['id']
        CONFIRMED_DIR.mkdir(parents=True, exist_ok=True)
        confirmed_token(job_id).touch()
        stop_watchdog(job_id)

        bdir = backup_path(job_id)
        info_file = bdir / 'info.json'
        if not info_file.exists():
            raise SshHardenError('ssh_harden_conflict', 'Job backup info missing')
        info = json.loads(info_file.read_text())
        port = info['port']
        old_port = info['old_port']
        socket_active = info['socket_activation']
        disable_root = info['disable_root']
        ufw_rule_added = info.get('ufw_rule_added', False)

        # Finalize sshd configuration
        conf_lines = [
            '# AntiRKN hardened SSH configuration',
            f'Port {port}',
        ]
        if disable_root:
            conf_lines.append('PermitRootLogin no')
        Path('/etc/ssh/sshd_config.d/99-antirkn-harden.conf').write_text('\n'.join(conf_lines) + '\n')

        # Check sshd syntax
        check = subprocess.run(['/usr/sbin/sshd', '-t'], capture_output=True, text=True, timeout=10)
        if check.returncode != 0:
            rollback(job_id)
            raise SshHardenError('ssh_harden_failed', f'Final sshd -t failed: {check.stderr}')

        # Reload systemd and restart SSH
        reload_ssh_service(socket_active)

        # If port changed and UFW active, remove old port
        if ufw_rule_added and port != old_port:
            try:
                subprocess.run(['/usr/sbin/ufw', 'delete', 'allow', f'{old_port}/tcp'], capture_output=True, timeout=10)
            except Exception:
                pass

        # Mark job succeeded in database
        with store.db:
            store.db.execute("UPDATE jobs SET status='succeeded', checkpoint=7 WHERE id=?", (job_id,))
            store.event(job_id, 'ssh_harden_confirmed', 7, 7)

        return {'confirmed': True, 'port': port, 'username': info['username']}

    @staticmethod
    def abort(store, req):
        job_id = req['id']
        rollback(job_id)
        with store.db:
            store.db.execute("UPDATE jobs SET status='failed' WHERE id=?", (job_id,))
            store.event(job_id, 'ssh_harden_aborted', 0, 7)
        return {'aborted': True}


def watchdog_loop(job_id, deadline):
    token = confirmed_token(job_id)
    for _ in range(deadline):
        if token.exists():
            sys.exit(0)
        time.sleep(1)
    if not token.exists():
        rollback(job_id)
    sys.exit(0)


if __name__ == '__main__':
    if len(sys.argv) > 2 and sys.argv[1] == 'watchdog':
        watchdog_loop(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 300)
    elif len(sys.argv) > 2 and sys.argv[1] == 'rollback':
        rollback(sys.argv[2])
