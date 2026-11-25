"""TCP and UDP probes through a private temporary Xray instance on the VPS."""
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import tempfile
import time

from egress_config import EgressError
from sysutil import run as sysutil_run

BINARY = Path('/usr/local/x-ui/bin/xray-linux-amd64')


def receive(sock, count):
    data = b''
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part: raise EgressError('egress_probe_failed')
        data += part
    return data


def socks(port, command, host, destination):
    connection = socket.create_connection(('127.0.0.1', port), timeout=8)
    try:
        connection.settimeout(8)
        connection.sendall(b'\x05\x01\x00')
        if receive(connection, 2) != b'\x05\x00': raise EgressError('egress_probe_failed')
        encoded = host.encode('idna')
        address = b'\x03' + bytes([len(encoded)]) + encoded
        connection.sendall(b'\x05' + bytes([command]) + b'\x00' + address + struct.pack('!H', destination))
        header = receive(connection, 4)
        if header[:3] != b'\x05\x00\x00': raise EgressError('egress_probe_failed')
        if header[3] == 1: bound = socket.inet_ntop(socket.AF_INET, receive(connection, 4))
        elif header[3] == 4: bound = socket.inet_ntop(socket.AF_INET6, receive(connection, 16))
        elif header[3] == 3: bound = receive(connection, receive(connection, 1)[0]).decode('ascii')
        else: raise EgressError('egress_probe_failed')
        return connection, (bound, struct.unpack('!H', receive(connection, 2))[0])
    except Exception:
        connection.close()
        raise


def check(port):
    started = time.monotonic()
    connection, _ = socks(port, 1, 'www.gstatic.com', 80)
    with connection:
        connection.sendall(b'GET /generate_204 HTTP/1.1\r\nHost: www.gstatic.com\r\nConnection: close\r\n\r\n')
        status = b''
        while b'\r\n' not in status and len(status) < 4096:
            part = connection.recv(512)
            if not part: break
            status += part
        if not status.startswith(b'HTTP/1.1 204') and not status.startswith(b'HTTP/1.0 204'):
            raise EgressError('egress_probe_failed')
    tcp_ms = round((time.monotonic() - started) * 1000)
    connection, bound = socks(port, 3, '0.0.0.0', 0)
    with connection, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.settimeout(8)
        nonce = secrets.token_bytes(2)
        query = nonce + b'\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00' + b'\x07example\x03com\x00\x00\x01\x00\x01'
        udp.sendto(b'\x00\x00\x00\x01' + socket.inet_aton('1.1.1.1') + b'\x00\x35' + query,
                   ('127.0.0.1' if bound[0] in ('0.0.0.0', '::') else bound[0], bound[1]))
        reply, _ = udp.recvfrom(4096)
        if len(reply) < 22 or reply[:4] != b'\x00\x00\x00\x01' or reply[4:10] != socket.inet_aton('1.1.1.1') + b'\x00\x35':
            raise EgressError('egress_probe_failed')
        dns = reply[10:]
        if dns[:2] != nonce or not dns[2] & 0x80 or dns[3] & 15 or dns[6:8] == b'\x00\x00':
            raise EgressError('egress_probe_failed')
    return dict(tcp=True, udp=True, tcpMs=tcp_ms, checkedAt=time.time())


def validate(config):
    from panel import safe_file
    safe_file(BINARY, 200 * 1024 * 1024)
    result = sysutil_run([str(BINARY), 'run', '-test', '-config', 'stdin:'], input=json.dumps(config).encode(), timeout=20)
    if result.returncode: raise EgressError('egress_config_failed')


def outbound(connection, directory):
    from egress_config import SOCKS
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    config = dict(log=dict(loglevel='none'), inbounds=[dict(tag=SOCKS, listen='127.0.0.1', port=port,
        protocol='socks', settings=dict(auth='noauth', udp=True, ip='127.0.0.1'))], outbounds=[connection['outbound']])
    validate(config)
    with tempfile.TemporaryDirectory(prefix='egress-probe-', dir=directory) as temp:
        path = Path(temp) / 'config.json'
        path.write_text(json.dumps(config)); path.chmod(0o600)
        process = subprocess.Popen([str(BINARY), 'run', '-config', str(path)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env={**os.environ, 'XRAY_LOCATION_ASSET': str(BINARY.parent)})
        try:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if process.poll() is not None: raise EgressError('egress_probe_failed')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.2): break
                except OSError: time.sleep(.1)
            return check(port)
        except (OSError, ValueError, subprocess.SubprocessError):
            raise EgressError('egress_probe_failed') from None
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)
