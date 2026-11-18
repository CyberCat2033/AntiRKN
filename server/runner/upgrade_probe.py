"""Real connectivity checks for component upgrades, run on the server itself.

VLESS REALITY: the installed Xray acts as a client against every enabled REALITY
inbound of the live Xray config and fetches PROBE_URL through it. The result is
compared before/after an upgrade; an inbound that worked before and fails after
means the upgrade broke real connections.

TrustTunnel: a TLS handshake to each endpoint listener. AmneziaWG: every
interface that was up still has a listening port.

No dependencies besides the standard library and the installed binaries.
"""
import base64
import json
import os
import socket
import ssl
import struct
import subprocess
import tempfile
import time
from pathlib import Path

XRAY_CONFIG = Path('/usr/local/x-ui/bin/config.json')
XRAY_BINARY = Path('/usr/local/x-ui/bin/xray-linux-amd64')
PROBE_HOST, PROBE_PATH = 'www.gstatic.com', '/generate_204'


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def _public_key(reality):
    settings = reality.get('settings') or {}
    if settings.get('publicKey'):
        return settings['publicKey']
    private = reality.get('privateKey') or ''
    raw = base64.urlsafe_b64decode(private + '=' * (-len(private) % 4))
    der = bytes.fromhex('302e020100300506032b656e04220420') + raw
    public = subprocess.run(['/usr/bin/openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
                            input=der, capture_output=True, timeout=10, check=True).stdout[-32:]
    return base64.urlsafe_b64encode(public).decode().rstrip('=')


def vless_targets(config_path=XRAY_CONFIG):
    """Enabled REALITY VLESS inbounds of the live Xray config, as client parameters."""
    try:
        config = json.loads(Path(config_path).read_text())
    except (OSError, ValueError):
        return {}
    targets = {}
    for inbound in config.get('inbounds') or []:
        if inbound.get('protocol') != 'vless':
            continue
        stream = inbound.get('streamSettings') or {}
        reality = stream.get('realitySettings') or {}
        clients = [c for c in (inbound.get('settings') or {}).get('clients') or [] if c.get('enable', True) and c.get('id')]
        if stream.get('security') != 'reality' or not clients or not reality.get('serverNames'):
            continue
        short_ids = [s for s in reality.get('shortIds') or [] if s] or ['']
        out = dict(network=stream.get('network', 'tcp'), security='reality', realitySettings=dict(
            serverName=reality['serverNames'][0], fingerprint=(reality.get('settings') or {}).get('fingerprint') or 'chrome',
            publicKey=_public_key(reality), shortId=short_ids[0]))
        if out['network'] == 'xhttp':
            xhttp = stream.get('xhttpSettings') or {}
            out['xhttpSettings'] = {k: xhttp[k] for k in ('path', 'host', 'mode') if k in xhttp}
        targets[f"vless:{inbound.get('port')}"] = dict(port=inbound['port'], user=clients[0], stream=out)
    return targets


def _socks_https(port, timeout):
    """GET https://PROBE_HOST/PROBE_PATH through a local SOCKS5 proxy; True on 2xx."""
    with socket.create_connection(('127.0.0.1', port), timeout=timeout) as raw:
        raw.sendall(b'\x05\x01\x00')
        if raw.recv(2) != b'\x05\x00':
            return False
        host = PROBE_HOST.encode()
        raw.sendall(b'\x05\x01\x00\x03' + bytes([len(host)]) + host + struct.pack('>H', 443))
        reply = raw.recv(10)
        if len(reply) < 2 or reply[1] != 0:
            return False
        context = ssl.create_default_context()
        with context.wrap_socket(raw, server_hostname=PROBE_HOST) as tls:
            tls.sendall(b'GET ' + PROBE_PATH.encode() + b' HTTP/1.1\r\nHost: ' + host + b'\r\nConnection: close\r\n\r\n')
            status = tls.recv(64).split(b' ', 2)
            return len(status) > 1 and status[1][:1] == b'2'


def _wait_port(port, deadline):
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def probe_vless(binary=XRAY_BINARY, config_path=XRAY_CONFIG, timeout=10):
    """{target: ok} for every enabled REALITY inbound, using `binary` as the client."""
    results = {}
    for key, target in vless_targets(config_path).items():
        _wait_port(target['port'], time.monotonic() + 15)
        socks = _free_port()
        user = dict(id=target['user']['id'], encryption='none', flow=target['user'].get('flow') or '')
        client = dict(log=dict(loglevel='none'),
                      inbounds=[dict(listen='127.0.0.1', port=socks, protocol='socks', settings=dict(udp=False))],
                      outbounds=[dict(protocol='vless', settings=dict(vnext=[dict(address='127.0.0.1', port=target['port'], users=[user])]),
                                      streamSettings=target['stream'])])
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as handle:
            json.dump(client, handle)
            path = handle.name
        os.chmod(path, 0o600)
        proc = subprocess.Popen([str(binary), 'run', '-c', path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ok = False
        try:
            deadline = time.monotonic() + timeout
            if _wait_port(socks, deadline):
                for _ in range(2):  # one retry absorbs a cold DNS/TLS start on the server
                    try:
                        ok = _socks_https(socks, max(1.0, deadline - time.monotonic()))
                    except (OSError, ssl.SSLError):
                        ok = False
                    if ok:
                        break
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            os.unlink(path)
        results[key] = ok
    return results


def _tls_handshake(host, port, timeout=5):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=timeout) as raw:
            with context.wrap_socket(raw, server_hostname='localhost'):
                return True
    except (OSError, ssl.SSLError):
        return False


def probe_tls_listeners(targets):
    """TrustTunnel endpoints: a TLS handshake on every TCP binding."""
    results = {}
    for target in targets or []:
        for binding in getattr(target, 'expected_bindings', []) or []:
            if getattr(binding, 'protocol', 'tcp') != 'tcp':
                continue
            host = binding.host if binding.host not in ('0.0.0.0', '::', '') else '127.0.0.1'
            results[f'tls:{binding.port}'] = _tls_handshake(host, binding.port)
    return results


def probe_awg():
    """AmneziaWG: every interface still has a listening UDP port."""
    results = {}
    try:
        names = subprocess.run(['/usr/local/bin/awg', 'show', 'interfaces'], capture_output=True, text=True, timeout=10).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return results
    for name in names:
        try:
            port = subprocess.run(['/usr/local/bin/awg', 'show', name, 'listen-port'], capture_output=True, text=True, timeout=10).stdout.strip()
            results[f'awg:{name}'] = port.isdigit() and int(port) > 0
        except (OSError, subprocess.SubprocessError):
            results[f'awg:{name}'] = False
    return results


def compare(before, after):
    """Targets that worked before and do not work after (sorted)."""
    return sorted(k for k, ok in (before or {}).items() if ok and not (after or {}).get(k, False))


if __name__ == '__main__':
    import sys
    binary = Path(sys.argv[1]) if len(sys.argv) > 1 else XRAY_BINARY
    print(json.dumps(probe_vless(binary)))
