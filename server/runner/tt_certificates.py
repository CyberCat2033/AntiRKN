"""Certificate issuance, imported/server PEM pairs and independent renewal.

External issuers retain ownership. Only valid pairs are activated, and every
active linked TrustTunnel service is RESTARTED after an actual certificate
change. The timer uses the same lock as endpoint jobs.
"""
import sys
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import tempfile
import time
sys.path.insert(0, str(Path(__file__).resolve().parent))

from tt_common import (CERT_ROOT, STATE, TtError, active, address, available,
    canonical, digest, domain, identifier, ip, lock, mkdir, read, run, safe_path)
from panel import atomic_file

SCRIPT = str(Path(__file__).resolve())
UNITS = Path('/etc/systemd/system')


def path_for(cid):
    return CERT_ROOT / identifier(cid)


def record_path(cid):
    return path_for(cid) / 'record.json'


def records():
    return [json.loads(read(p)) for p in sorted(CERT_ROOT.glob('*/record.json'))]


def record(cid):
    return json.loads(read(record_path(cid)))


def dns_check(spec):
    name = domain(spec['domain'])
    listen = ip(spec['listen'], wildcard=True)
    expected = {ip(v) for v in spec['expectedIps']}
    automatic = spec.get('autoDetectIps', False)
    if (not expected and not automatic) or len(expected) > 8:
        raise TtError()
    if not automatic and listen not in ('0.0.0.0', '::') and expected != {listen}:
        raise TtError('tt_dns_mismatch')
    # Resolver isolation gives getaddrinfo a real, bounded timeout.
    source = 'import json,socket,sys; print(json.dumps(sorted({r[4][0] for r in socket.getaddrinfo(sys.argv[1],80,type=socket.SOCK_STREAM)})))'
    result = run(['/usr/bin/python3', '-I', '-c', source, name], timeout=20, check=False)
    if result.returncode:
        raise TtError('tt_dns_failed')
    resolved = {ip(v) for v in json.loads(result.stdout)}
    if not automatic and resolved != expected:
        raise TtError('tt_dns_mismatch')
    local = json.loads(run(['/usr/sbin/ip', '-j', 'address', 'show']).stdout)
    assigned = {ip(a['local'], wildcard=True) for row in local for a in row.get('addr_info', [])}
    if automatic:
        # DNS supplies the domain's addresses, never the trusted server IP set.
        # The SSH peer supplied by the app covers a public NAT address.
        expected |= {v for v in assigned if not (ipaddress.ip_address(v).is_loopback or
            ipaddress.ip_address(v).is_link_local or ipaddress.ip_address(v).is_multicast or
            ipaddress.ip_address(v).is_unspecified)}
        if not resolved or not resolved.issubset(expected):
            raise TtError('tt_dns_mismatch')
    if listen not in ('0.0.0.0', '::') and listen not in assigned:
        raise TtError('tt_dns_mismatch')
    return dict(domain=name, addresses=sorted(resolved), expected=sorted(expected))


def _inspect_pair(cert, key, name):
    """Validate PEM, name, validity, chain and matching public/private keys."""
    cert, key = source_path(cert), source_path(key)
    if cert.stat().st_size > 262144 or key.stat().st_size > 65536:
        raise TtError('tt_certificate_invalid')
    verify = run(['/usr/bin/openssl', 'verify', '-purpose', 'sslserver', '-verify_hostname', domain(name),
                  '-untrusted', str(cert), str(cert)], check=False)
    if verify.returncode:
        raise TtError('tt_certificate_invalid')
    pub = run(['/usr/bin/openssl', 'x509', '-in', str(cert), '-pubkey', '-noout']).stdout
    keypub = run(['/usr/bin/openssl', 'pkey', '-in', str(key), '-passin', 'pass:', '-pubout']).stdout
    if pub != keypub:
        raise TtError('tt_certificate_invalid')
    decoded = ssl._ssl._test_decode_cert(str(cert))
    der = run(['/usr/bin/openssl', 'x509', '-in', str(cert), '-outform', 'DER']).stdout
    return dict(domain=name, expiresAt=ssl.cert_time_to_seconds(decoded['notAfter']),
        notBefore=ssl.cert_time_to_seconds(decoded['notBefore']),
        fingerprint=hashlib.sha256(der).hexdigest(),
        pairHash=digest([cert.read_text(), key.read_text()]))


def source_path(path):
    # Existing deployments and their issuer may belong to the SSH admin.
    # Only that owner or root may control each ancestor; writable groups fail.
    return safe_path(path, owner_uid=Path(path).stat().st_uid)


def inspect_pair(cert, key, name):
    try:
        return _inspect_pair(cert, key, name)
    except (TtError, OSError, ValueError, ssl.SSLError):
        raise TtError('tt_certificate_invalid')


def source_pair(spec):
    if spec['mode'] == 'acme':
        base = path_for(spec['id']) / 'acme' / 'live' / 'endpoint'
        return base / 'fullchain.pem', base / 'privkey.pem'
    if spec['mode'] == 'import':
        base = path_for(spec['id']) / 'imported'
        return base / 'fullchain.pem', base / 'privkey.pem'
    return Path(spec['certificate']), Path(spec['privateKey'])


def public(r):
    return {**{k: r.get(k) for k in ('id', 'domain', 'mode', 'expiresAt', 'fingerprint',
        'lastCheck', 'lastSuccess', 'nextCheck', 'lastRenewal', 'error', 'sourceCertificate', 'sourceKey')}, 'configuration': r['spec']}


def candidates():
    result = []
    for pattern, key in [('/root/cert/*/fullchain.pem', 'privkey.pem'),
                         ('/etc/letsencrypt/live/*/fullchain.pem', 'privkey.pem'),
                         ('/root/.acme.sh/*/fullchain.cer', None)]:
        for cert in sorted(Path('/').glob(pattern.lstrip('/')))[:64]:
            keypath = cert.with_name(key or (re.sub('_ecc$', '', cert.parent.name) + '.key'))
            try:
                source_path(cert); source_path(keypath)
                info = ssl._ssl._test_decode_cert(str(cert))
                result.append(dict(certificate=str(cert), privateKey=str(keypath),
                    domains=[v for k, v in info.get('subjectAltName', []) if k == 'DNS'],
                    expiresAt=ssl.cert_time_to_seconds(info['notAfter'])))
            except (OSError, ValueError, ssl.SSLError, TtError):
                continue
    return result


def inventory():
    return dict(certificates=[public(r) for r in records()], candidates=candidates())


def decode(raw):
    p = json.loads(raw)
    fields = {'id', 'domain', 'mode', 'listen', 'expectedIps', 'email', 'certificate', 'privateKey', 'certificatePem', 'privateKeyPem'}
    if type(p) is not dict or set(p) - {'autoDetectIps'} != fields or type(p.get('autoDetectIps', False)) is not bool or p['mode'] not in ('files', 'import', 'acme'):
        raise TtError()
    identifier(p['id']); domain(p['domain']); ip(p['listen'], wildcard=True)
    if type(p['expectedIps']) is not list or len(p['expectedIps']) > 8 or p['mode'] == 'acme' and not p['expectedIps'] and not p.get('autoDetectIps', False):
        raise TtError()
    for v in p['expectedIps']: ip(v)
    for k in fields - {'expectedIps'}:
        if type(p[k]) is not str or '\x00' in p[k]: raise TtError()
    if len(p['certificatePem']) > 196608 or len(p['privateKeyPem']) > 32768:
        raise TtError()
    if p['mode'] == 'acme' and p['email'] and not re.fullmatch(r'[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,63}', p['email']):
        raise TtError()
    if any(p[k] for k in ('certificatePem', 'privateKeyPem')) and p['mode'] != 'import':
        raise TtError()
    return p


def package_plan():
    binary = Path('/usr/bin/certbot')
    if binary.exists():
        safe_path(binary)
        return dict(installed=True, version=run([str(binary), '--version']).stdout.decode().strip())
    policy = run(['/usr/bin/apt-cache', 'policy', 'certbot']).stdout.decode()
    match = re.search(r'Candidate: ([^\s]+)', policy)
    if not match or match[1] == '(none)' or not re.fullmatch('[A-Za-z0-9.+:~_-]+', match[1]):
        raise TtError('tt_certbot_required')
    return dict(installed=False, version=match[1])


def preview_pair(p):
    if p['mode'] == 'files':
        return inspect_pair(p['certificate'], p['privateKey'], p['domain'])
    if p['mode'] == 'import':
        # These files are private, short-lived validation inputs, never logs.
        with tempfile.TemporaryDirectory(prefix='tt-cert-', dir=STATE) as d:
            cert, key = Path(d) / 'cert.pem', Path(d) / 'key.pem'
            atomic_file(cert, p['certificatePem'].encode()); atomic_file(key, p['privateKeyPem'].encode())
            return inspect_pair(cert, key, p['domain'])
    return None


def plan(req):
    p = decode(req['payload'])
    before = record(p['id']) if record_path(p['id']).exists() else None
    if before: before = {k: before[k] for k in ('id', 'domain', 'mode', 'spec', 'pairHash')}
    if before and (before['domain'] != p['domain'] or before['mode'] != p['mode']):
        raise TtError('tt_conflict')
    # DNS is required BEFORE ACME; imported certificates also verify hostname.
    dns = dns_check(p) if p['mode'] == 'acme' else None
    package = package_plan() if p['mode'] == 'acme' else None
    if p['mode'] == 'acme' and not available('0.0.0.0', 80):
        raise TtError('tt_acme_port_busy')
    info = preview_pair(p)
    return dict(fingerprint=digest(dict(payload=p, before=before, dns=dns, package=package, pair=info)),
        dns=dns, package=package, certificate=info, restart=True, mode=p['mode'])


def certificate_paths(cid):
    r = record(cid)
    base = path_for(cid) / 'current'
    return str(base / 'fullchain.pem'), str(base / 'privkey.pem'), r


def links(cid):
    # Only records established by a confirmed endpoint/edit job are restartable.
    result = []
    for p in (path_for(cid) / 'links').glob('*.json'):
        r = json.loads(read(p))
        if not re.fullmatch(r'[A-Za-z0-9_.@:-]+\.service', r['unit']):
            raise TtError('tt_conflict')
        result.append(r)
    return result


def bind(cid, rid, unit, host, port):
    mkdir(path_for(cid) / 'links')
    atomic_file(path_for(cid) / 'links' / (identifier(rid) + '.json'), canonical(dict(unit=unit, host=host, port=port)).encode())


def unbind(rid):
    for r in records():
        (path_for(r['id']) / 'links' / (identifier(rid) + '.json')).unlink(missing_ok=True)


def move_listener(unit, host, port):
    # A native service may serve several certificates on the same listener.
    for certificate in records():
        for path in (path_for(certificate['id']) / 'links').glob('*.json'):
            r = json.loads(read(path))
            if r['unit'] == unit:
                atomic_file(path, canonical(dict(r, host=host, port=port)).encode())


def verify_service(unit, host, port, name, fingerprint):
    host = '127.0.0.1' if host == '0.0.0.0' else '::1' if host == '::' else host
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        try:
            if active(unit):
                context = ssl.create_default_context()
                context.set_alpn_protocols(['h2'])
                with socket.create_connection((host, port), timeout=2) as sock:
                    with context.wrap_socket(sock, server_hostname=name) as tls:
                        if hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest() == fingerprint:
                            return
        except (OSError, ssl.SSLError):
            pass
        time.sleep(.2)
    raise TtError('tt_restart_failed')


def set_current(base, target):
    temporary = base / ('.current-' + secrets.token_hex(8))
    temporary.symlink_to(target)
    os.replace(temporary, base / 'current')
    fd = os.open(str(base), os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def activate(spec, old=None):
    cert, key = source_pair(spec)
    info = inspect_pair(cert, key, spec['domain'])
    base = path_for(spec['id'])
    mkdir(base)
    generation = base / ('pair-' + info['pairHash'])
    if not generation.exists():
        mkdir(generation)
        atomic_file(generation / 'fullchain.pem', source_path(cert).read_bytes())
        atomic_file(generation / 'privkey.pem', source_path(key).read_bytes())
    copied = inspect_pair(generation / 'fullchain.pem', generation / 'privkey.pem', spec['domain'])
    if copied != info:
        raise TtError('tt_conflict')  # Issuer changed a file during the read.
    current = base / 'current'
    previous = os.readlink(current) if current.is_symlink() else None
    if current.exists() and not current.is_symlink():
        raise TtError('tt_conflict')
    pending = base / 'activation.json'
    recovery = json.loads(read(pending)) if pending.exists() else None
    if recovery and recovery['after'] != generation.name:
        raise TtError('tt_conflict')
    changed = previous != generation.name or recovery is not None
    restarting = [r for r in links(spec['id']) if active(r['unit'])]
    if changed:
        if recovery is None:
            recovery = dict(before=previous, after=generation.name, services=restarting)
            atomic_file(pending, canonical(recovery).encode())
        restarting = recovery['services']
        set_current(base, generation.name)
        try:
            for r in restarting:
                run(['/usr/bin/systemctl', 'restart', r['unit']], timeout=60)
                verify_service(r['unit'], r['host'], r['port'], spec['domain'], info['fingerprint'])
        except Exception:
            if recovery['before']:
                set_current(base, recovery['before'])
                for r in restarting:
                    run(['/usr/bin/systemctl', 'restart', r['unit']], timeout=60, check=False)
            raise
    now = time.time()
    saved = dict(old or {}, **info, id=spec['id'], mode=spec['mode'], spec={k:v for k,v in spec.items() if k not in ('certificatePem', 'privateKeyPem')},
        sourceCertificate=str(cert), sourceKey=str(key), lastCheck=now, lastSuccess=now,
        nextCheck=now+60, error=None)
    atomic_file(record_path(spec['id']), canonical(saved).encode())
    pending.unlink(missing_ok=True)
    return saved


def timer_sources():
    return {
        'antirkn-tt-certificates.service': ('[Unit]\nDescription=AntiRKN TrustTunnel certificate renewal and restart\nAfter=network-online.target\n'
            '[Service]\nType=oneshot\nUMask=0077\nExecStart=/usr/bin/python3 -I ' + SCRIPT + ' watch\nTimeoutStartSec=900\n').encode(),
        'antirkn-tt-certificates.timer': b'[Unit]\nDescription=Check TrustTunnel certificates\n[Timer]\nOnBootSec=1min\nOnUnitInactiveSec=1min\n[Install]\nWantedBy=timers.target\n',
    }


def install_timer():
    for name, source in timer_sources().items():
        p = UNITS / name
        if p.exists() and read(p) not in (source, *(source.replace(str(Path(SCRIPT).parent).encode(), ('/usr/local/lib/antirkn-runner/v%d' % version).encode()) for version in range(11, 24))):
            raise TtError('tt_conflict')
        atomic_file(p, source, 0o644)
    run(['/usr/bin/systemctl', 'daemon-reload'])
    run(['/usr/bin/systemctl', 'enable', '--now', 'antirkn-tt-certificates.timer'])


def issue(p, renew=False):
    dns_check(p)
    if not available('0.0.0.0', 80):
        raise TtError('tt_acme_port_busy')
    base = path_for(p['id'])
    args = ['/usr/bin/certbot', 'renew' if renew else 'certonly', '--non-interactive',
        '--config-dir', str(base / 'acme'), '--work-dir', str(base / 'work'),
        '--logs-dir', str(base / 'logs'), '--cert-name', 'endpoint']
    if not renew:
        args += ['--standalone', '--preferred-challenges', 'http', '--agree-tos',
            '-d', p['domain'], '--keep-until-expiring']
        args += ['--email', p['email']] if p['email'] else ['--register-unsafely-without-email']
    result = run(args, timeout=600, check=False)
    if result.returncode:
        raise TtError('tt_acme_failed')


class CertificateJob:
    def __init__(self, store, req):
        self.store, self.req, self.p = store, req, decode(req['payload'])
        self.intent = store.directory / ('tt-certificate-' + req['id'] + '.json')

    def step(self, checkpoint):
        with lock():
            p = self.p
            if checkpoint == 0:
                preview = plan(self.req)
                if preview['fingerprint'] != self.req['fingerprint']:
                    raise TtError('tt_conflict')
                if not self.intent.exists():
                    atomic_file(self.intent, canonical(dict(payloadHash=digest(p), package=preview['package'])).encode())
                code = 'tt_preparing'
            else:
                intent = json.loads(read(self.intent))
                if intent['payloadHash'] != digest(p): raise TtError('tt_conflict')
                base = path_for(p['id']); mkdir(base)
                if checkpoint == 1:
                    if p['mode'] == 'acme':
                        dns_check(p)
                        package = intent['package']
                        if not package['installed'] and not Path('/usr/bin/certbot').exists():
                            if package_plan() != package: raise TtError('tt_conflict')
                            # APT needs the host package directories. Run in a
                            # dedicated unit, outside the runner mount sandbox.
                            result = run(['/usr/bin/systemd-run', '--quiet', '--wait', '--pipe', '--collect',
                                '--unit=antirkn-tt-certbot-' + self.req['id'],
                                '--property=UMask=0077', '--property=TimeoutStartSec=600',
                                '/usr/bin/apt-get', '-y', '--no-install-recommends',
                                '-o', 'Dpkg::Options::=--force-confold', 'install', 'certbot=' + package['version']], timeout=600, check=False)
                            if result.returncode: raise TtError('tt_certbot_required')
                        issue(p)
                    elif p['mode'] == 'import':
                        mkdir(base / 'imported')
                        atomic_file(base / 'imported/fullchain.pem', p['certificatePem'].encode())
                        atomic_file(base / 'imported/privkey.pem', p['privateKeyPem'].encode())
                    code = 'tt_certificate_ready'
                elif checkpoint == 2:
                    old = record(p['id']) if record_path(p['id']).exists() else None
                    activate(p, old)
                    install_timer()
                    code = 'tt_restarting'
                else:
                    cert, key, saved = certificate_paths(p['id'])
                    if inspect_pair(cert, key, p['domain'])['fingerprint'] != saved['fingerprint']:
                        raise TtError('tt_certificate_invalid')
                    code = 'tt_checking'
            with self.store.db:
                self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint+1, self.req['id']))
                self.store.event(self.req['id'], code, checkpoint+1, self.req['count'])


def watch():
    with lock():
        # Let admitted endpoint jobs finish their preconditions and bindings.
        import sqlite3
        if (STATE / 'jobs.sqlite').exists():
            db = sqlite3.connect('file:' + str(STATE / 'jobs.sqlite') + '?mode=ro', uri=True)
            try:
                if db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
                    return
            finally:
                db.close()
        for r in records():
            try:
                now = time.time()
                if r['mode'] == 'acme' and now - r.get('lastRenewal', 0) >= 43200:
                    issue(r['spec'], renew=True)
                    r['lastRenewal'] = now
                activate(r['spec'], r)
            except Exception as e:
                r.update(lastCheck=time.time(), nextCheck=time.time()+60,
                    error=e.code if isinstance(e, TtError) else 'tt_certificate_invalid')
                atomic_file(record_path(r['id']), canonical(r).encode())


if __name__ == '__main__':
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    if sys.argv[1:] != ['watch']:
        raise SystemExit(2)
    try:
        watch()
    except TtError:
        raise SystemExit(1)
