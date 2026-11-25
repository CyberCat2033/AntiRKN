"""Owned AWG firewall rules. Called only by our root-owned awg-quick hooks.

It is also the leaf module (stdlib and ``panel.safe_file`` only) that holds the
root-file primitives shared by the AWG, TT, adoption and reboot code: lock
files, master keys, owner-preserving replacement and port probes.
"""
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import stat
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from panel import safe_file

ROOT = Path('/etc/antirkn-components/amneziawg')


def run(args, check=True):
    return subprocess.run(args, check=check, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=30)


def open_lock(path, owner_uid=0):
    """Open a lock file without following links; return its descriptor.

    A lock in a directory another account may write must not become a link to
    some other file, a FIFO, or a file that account owns. Any doubt raises
    OSError: the caller fails closed instead of continuing unlocked."""
    fd = os.open(str(path), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
    try:
        meta = os.fstat(fd)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != owner_uid or meta.st_nlink != 1
                or meta.st_mode & 0o022):
            raise OSError('lock')
        return fd
    except BaseException:
        os.close(fd)
        raise


def fsync_directory(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def create_key(path, in_use, size=32):
    """Read a root-only master key, creating it atomically when absent.

    The key is written to a temporary file, synced and linked to its final
    name, which never replaces an existing key. An empty or short file (left
    by the earlier non-atomic writer after a power loss) is recreated only when
    nothing derived from it exists yet; otherwise this fails closed."""
    path = Path(path)
    try:
        meta = os.lstat(str(path))
    except FileNotFoundError:
        meta = None
    if meta is not None:
        if not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0 or meta.st_mode & 0o022:
            raise ValueError('key')
        data = path.read_bytes()
        if len(data) == size:
            return data
        if in_use or meta.st_size > size:
            raise ValueError('key')
        path.unlink()
    elif in_use:
        raise ValueError('key')
    temp = path.with_name('.' + path.name + '.' + secrets.token_hex(8) + '.antirkn-tmp')
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(secrets.token_bytes(size))
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(str(temp), str(path))
        except FileExistsError:
            pass  # A concurrent creator won; its key is read below.
    finally:
        try:
            os.unlink(str(temp))
        except FileNotFoundError:
            pass
    fsync_directory(path.parent)
    data = path.read_bytes()
    if len(data) != size:
        raise ValueError('key')
    return data


def key_valid(path, size=32):
    """A complete key file, as create_key leaves it (read-only check)."""
    try:
        meta = os.lstat(str(path))
    except FileNotFoundError:
        return False
    return stat.S_ISREG(meta.st_mode) and meta.st_size == size


def replace_preserving(path, data):
    """Atomically replace one existing file, keeping its owner, group and mode.

    The temporary name is created exclusively inside the opened parent
    directory, so a link swapped into the path cannot redirect the write."""
    path = Path(path)
    before = os.lstat(str(path))
    if not stat.S_ISREG(before.st_mode):
        raise OSError('replace')
    directory = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    temporary = '.antirkn-' + secrets.token_hex(16)
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchown(stream.fileno(), before.st_uid, before.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(before.st_mode))
            os.fsync(stream.fileno())
        os.rename(temporary, path.name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
        os.close(directory)


def port_available(host, port, tcp=True, udp=False):
    """Whether ``host:port`` can be bound now. The IPv6 wildcard also covers
    IPv4, because services may bind both families."""
    sockets = []
    try:
        targets = [(socket.AF_INET6 if ':' in host else socket.AF_INET, host)]
        if host == '::':
            targets.append((socket.AF_INET, '0.0.0.0'))
        kinds = ([socket.SOCK_STREAM] if tcp else []) + ([socket.SOCK_DGRAM] if udp else [])
        for family, bind in targets:
            for kind in kinds:
                s = socket.socket(family, kind)
                sockets.append(s)
                if kind == socket.SOCK_STREAM:
                    # TIME_WAIT left by an earlier connection is not a listener.
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if family == socket.AF_INET6:
                    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                s.bind((bind, port))
        return True
    except OSError:
        return False
    finally:
        for s in sockets:
            s.close()


def rules(data, name):
    for family, pool in ((4, data['pool']), (6, data['pool6'])):
        if not pool:
            continue
        network = ipaddress.ip_network(pool)
        if network.version != family:
            raise ValueError('awg_invalid')
        binary = '/usr/sbin/iptables' if family == 4 else '/usr/sbin/ip6tables'
        comment = ['-m', 'comment', '--comment', 'antirkn-' + name]
        yield binary, 'filter', 'FORWARD', ['-i', name, '-s', pool, *comment, '-j', 'ACCEPT']
        yield binary, 'filter', 'FORWARD', ['-o', name, '-d', pool, '-m', 'conntrack', '--ctstate', 'RELATED,ESTABLISHED', *comment, '-j', 'ACCEPT']
        yield binary, 'nat', 'POSTROUTING', ['-s', pool, '!', '-o', name, *comment, '-j', 'MASQUERADE']
    # AWG has a wildcard UDP socket; endpoint selection does not imply bind-IP.
    for binary in ('/usr/sbin/iptables', '/usr/sbin/ip6tables'):
        if Path(binary).exists():
            yield binary, 'filter', 'INPUT', ['-p', 'udp', '--dport', str(data['port']), '-m', 'comment', '--comment', 'antirkn-' + name, '-j', 'ACCEPT']


def configure(action, name):
    if action not in ('up', 'down') or not re.fullmatch(r'ar[a-f0-9]{12}', name):
        raise ValueError('awg_invalid')
    path = ROOT / (name + '.network.json')
    safe_file(path)
    data = json.loads(path.read_text())
    if type(data['port']) is not int or not 1 <= data['port'] <= 65535:
        raise ValueError('awg_invalid')
    lock = open_lock(ROOT / '.network.lock')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if action == 'up':
            from egress_network import register_interface
            register_interface(name)
            run(['/usr/sbin/sysctl', '-w', 'net.ipv4.ip_forward=1'])
            if data['pool6']:
                run(['/usr/sbin/sysctl', '-w', 'net.ipv6.conf.all.forwarding=1'])
        for binary, table, chain, rule in rules(data, name):
            prefix = [binary, '-w', '10', '-t', table]
            present = run([*prefix, '-C', chain, *rule], check=False).returncode == 0
            if action == 'up' and not present:
                run([*prefix, '-I', chain, '1', *rule])
            elif action == 'down' and present:
                run([*prefix, '-D', chain, *rule])
    finally:
        os.close(lock)


if __name__ == '__main__':
    os.umask(0o077)
    try:
        if os.geteuid() != 0 or len(sys.argv) != 3:
            raise ValueError('awg_invalid')
        configure(sys.argv[1], sys.argv[2])
    except Exception:
        # No firewall/config/key material in journal output.
        print('awg_network_failed', file=sys.stderr)
        sys.exit(1)
