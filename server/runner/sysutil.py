"""Shared root-process primitives of the runner: one bounded subprocess call
and the root-file helpers (lock files, master keys, owner-preserving
replacement, port probes).

Standard library only and no other runner import, so the standalone hooks and
watchdogs (awg-quick hooks, the SSH-hardening watchdog) can use it cheaply.
"""
import os
from pathlib import Path
import secrets
import socket
import stat
import subprocess

MAX_OUTPUT = 1048576


def run(argv, *, input=None, timeout=30, check=False, error=None, oversize=None,
        max_output=None, env=None, cwd=None, text=False, stderr=True, capture=True):
    """Run one program without a shell, always bounded by ``timeout``.

    stdin is closed unless ``input`` is given. A non-zero exit raises ``error``
    (or CalledProcessError) when ``check`` is set; output above ``max_output``
    raises ``oversize`` (or ``error``). Neither carries the program's output,
    which may quote configuration or credentials."""
    try:
        result = subprocess.run(argv, input=input,
            stdin=subprocess.DEVNULL if input is None else None,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.PIPE if stderr else subprocess.DEVNULL,
            timeout=timeout, env=env, cwd=cwd, text=text, check=check)
    except subprocess.CalledProcessError:
        if error is None:
            raise
        raise error from None
    if max_output is not None and len(result.stdout or b'') > max_output:
        raise (oversize or error or subprocess.SubprocessError('output'))
    return result


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
