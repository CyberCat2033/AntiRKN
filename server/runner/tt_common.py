"""TrustTunnel shared validation and lossless-by-value TOML serialization."""
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import subprocess

from panel import atomic_file
from vless import VlessError, canonical, digest
from tt_tomli_parser import loads as toml_loads

ROOT = Path('/etc/antirkn-components/trusttunnel')
CERT_ROOT = Path('/etc/antirkn-certificates')
STATE = Path('/var/lib/antirkn-runner')


class TtError(VlessError):
    def __init__(self, code='tt_invalid'):
        self.code = code


def run(argv, data=None, timeout=30, check=True):
    r = subprocess.run(argv, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if len(r.stdout) > 1048576 or check and r.returncode:
        raise TtError('tt_failed')
    return r


def safe_path(value, exists=True, max_bytes=1048576, owner_uid=0):
    """Allow root-controlled certbot symlinks, reject writable ancestors/files."""
    path = Path(value)
    if not path.is_absolute() or '..' in path.parts or any(c in str(path) for c in '\x00\r\n'):
        raise TtError()
    resolved = path.resolve(strict=exists)
    for part in list(path.parents) + list(resolved.parents):
        st = part.stat()
        if st.st_uid not in (0, owner_uid) or st.st_mode & 0o022:
            raise TtError('tt_conflict')
    if exists:
        st = resolved.stat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid not in (0, owner_uid) or st.st_mode & 0o022 or max_bytes is not None and st.st_size > max_bytes:
            raise TtError('tt_conflict')
    return path


def read(path, owner_uid=0):
    return safe_path(path, owner_uid=owner_uid).read_bytes()


def mkdir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
        raise TtError('tt_conflict')


@contextmanager
def lock():
    fd = os.open(str(STATE / 'tt.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise TtError('tt_busy')
        yield
    finally:
        os.close(fd)


def identifier(value):
    if type(value) is not str or re.fullmatch('[a-f0-9]{32}', value) is None:
        raise TtError()
    return value


def domain(value):
    if type(value) is not str or len(value) > 253 or '.' not in value:
        raise TtError()
    try:
        ipaddress.ip_address(value)
    except ValueError:
        pass
    else:
        raise TtError()
    if not all(re.fullmatch('[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', p) for p in value.split('.')):
        raise TtError()
    return value.lower()


def ip(value, wildcard=False):
    try:
        addr = ipaddress.ip_address(value)
        if addr.is_multicast or addr.is_unspecified and not wildcard:
            raise ValueError()
        return str(addr)
    except ValueError:
        raise TtError()


def address(host, port):
    return ('[' + host + ']' if ':' in host else host) + ':' + str(port)


def split_address(value):
    match = re.fullmatch(r'(?:\[([^\]]+)\]|([^:\s]+)):([0-9]{1,5})', value)
    if not match or not 1 <= int(match[3]) <= 65535:
        raise TtError()
    host = match[1] or match[2]
    try:
        host = str(ipaddress.ip_address(host))
    except ValueError:
        host = domain(host)
    return host, int(match[3])


def available(host, port, quic=False, udp_only=False):
    sockets = []
    try:
        targets = [(socket.AF_INET6 if ':' in host else socket.AF_INET, host)]
        # IPv6 wildcard may also receive IPv4, depending on endpoint defaults.
        if host == '::':
            targets.append((socket.AF_INET, '0.0.0.0'))
        for family, bind in targets:
            for kind in ([socket.SOCK_DGRAM] if udp_only else [socket.SOCK_STREAM, socket.SOCK_DGRAM] if quic else [socket.SOCK_STREAM]):
                s = socket.socket(family, kind)
                sockets.append(s)
                if kind == socket.SOCK_STREAM:
                    # Ignore TIME_WAIT left by a previous HTTP-01 challenge;
                    # an active listening socket still makes bind fail.
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


def active(unit):
    return run(['/usr/bin/systemctl', 'is-active', '--quiet', unit], check=False).returncode == 0


def toml_scalar(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if type(value) is bool:
        return 'true' if value else 'false'
    if type(value) in (int, float):
        if type(value) is float and not math.isfinite(value):
            return 'nan' if math.isnan(value) else ('inf' if value > 0 else '-inf')
        return repr(value)
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if type(value) is list:
        return '[' + ', '.join(toml_scalar(v) for v in value) + ']'
    if type(value) is dict:
        return '{' + ', '.join(json.dumps(k) + ' = ' + toml_scalar(v) for k, v in value.items()) + '}'
    raise TtError()


def toml_bytes(value):
    # TT's credentials reader uses toml_edit's array-of-tables API, so emit
    # actual [[client]] sections, not semantically equivalent inline arrays.
    lines = []
    def section(mapping, path=(), header=None):
        if header:
            lines.append(header)
        nested = []
        for key, entry in mapping.items():
            if isinstance(entry, dict) or isinstance(entry, list) and entry and all(isinstance(e, dict) for e in entry):
                nested.append((key, entry))
            else:
                lines.append(json.dumps(key) + ' = ' + toml_scalar(entry))
        for key, entry in nested:
            child = path + (key,)
            name = '.'.join(json.dumps(k) for k in child)
            if isinstance(entry, dict):
                section(entry, child, '[' + name + ']')
            else:
                for item in entry:
                    section(item, child, '[[' + name + ']]')
    section(value)
    text = '\n'.join(lines) + '\n'
    parsed = toml_loads(text)
    if parsed != value:
        raise TtError('tt_unsupported')
    return text.encode()


def toml_read(path):
    return toml_loads(read(path).decode())


def hash_file(path):
    return hashlib.sha256(read(path)).hexdigest() if Path(path).exists() else None
