"""Managed TrustTunnel 1.1 endpoints and durable personal credentials."""
import base64
from client_revocations import check as check_revocations
import copy
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket

from components import installed, usable
from panel import atomic_file
from tt_common import (ROOT, TtError, active, address, available, canonical, digest,
    domain, hash_file, identifier, ip, lock, mkdir, read, run, split_address,
    toml_bytes, toml_read)
from tt_contract import SCHEMA
from vless_contract import validate_schema
import tt_certificates as certificates

KEY = ROOT / 'master.key'
UNITS = Path('/etc/systemd/system')


def parse_payload(raw):
    try:
        def pairs(entries):
            r = {}
            for k, v in entries:
                if k in r: raise TtError()
                r[k] = v
            return r
        p = json.loads(raw, object_pairs_hook=pairs)
        validate_schema(p, SCHEMA)
        if p['panelId'] != p['workspaceId']:
            raise TtError()
        for key in ('users', 'resources'):
            if len({v['id'] for v in p[key]}) != len(p[key]): raise TtError()
        if len({v['login'].lower() for v in p['users']}) != len(p['users']):
            raise TtError('tt_login_conflict')
        for r in p['resources']: validate_resource(r)
        import managed_existing
        managed_existing.validate_payload(p, 'tt')
        return p
    except (TypeError, ValueError, KeyError):
        raise TtError()


def validate_resource(r):
    validate_schema(r, SCHEMA['properties']['resources']['items'])
    if 'adoption' in r:
        import managed_existing
        managed_existing.validate_spec(r, 'tt')
        return
    ip(r['listen'], wildcard=True); domain(r['domain'])
    try: ip(r['endpoint'])
    except TtError: domain(r['endpoint'])
    if r['deleted'] and r['enabled']: raise TtError()
    if r['outbound'] == 'socks5': split_address(r['socksAddress'])


def unit_for(rid):
    return 'antirkn-tt@' + identifier(rid) + '.service'


def paths(rid):
    base = ROOT / identifier(rid)
    return [base / 'vpn.toml', base / 'hosts.toml', base / 'credentials.toml', UNITS / unit_for(rid)]


def owned(store):
    return {r['id']: json.loads(r['data']) for r in store.db.execute('SELECT * FROM tt_resources')}


def prerequisites():
    r = installed('trusttunnel')
    if not usable('trusttunnel', r):
        raise TtError('tt_prerequisites')
    return r['release']


def defaults(store):
    prerequisites()
    # HTTP/2 is the default. A busy wildcard bind can still be free on the
    # specific address selected in the editor; preflight checks that binding.
    port = next((p for p in (443, 8443) if available('0.0.0.0', p)), 443)
    return dict(id=secrets.token_hex(16), name='TrustTunnel', enabled=True, deleted=False,
        listen='0.0.0.0', endpoint='', port=port, externalPort=port, domain='',
        certificateId='', quic=False, ipv6=False, allowPrivate=False,
        outbound='direct', socksAddress='127.0.0.1:1080', rotation=0)


def check_socks(value):
    host, port = split_address(value)
    try:
        with socket.create_connection((host, port), timeout=5) as sock:
            sock.settimeout(5)
            sock.sendall(b'\x05\x01\x00')
            reply = b''
            while len(reply) < 2:
                chunk = sock.recv(2-len(reply))
                if not chunk: break
                reply += chunk
            if reply != b'\x05\x00': raise TtError('tt_socks_failed')
    except OSError:
        raise TtError('tt_socks_failed')


def desired(p, spec, old, preview=False):
    key = read(KEY) if KEY.exists() else bytes(32) if preview else None
    if key is None or len(key) != 32: raise TtError('tt_conflict')
    key_id = hashlib.sha256(key).hexdigest()
    if old and old['keyId'] != key_id: raise TtError('tt_conflict')
    clients = []
    for user in sorted(p['users'], key=lambda u: u['id']):
        label = '/'.join(['tt-v1', p['workspaceId'], spec['id'], user['id'], str(spec['rotation'])])
        password = base64.urlsafe_b64encode(hmac.new(key, label.encode(), hashlib.sha256).digest()).decode().rstrip('=')
        clients.append(dict(id=user['id'], enabled=user['enabled'], username=user['login'], password=password))
    base = ROOT / spec['id']
    vpn = dict(listen_address=address(spec['listen'], spec['port']),
        ipv6_available=spec['ipv6'], allow_private_network_connections=spec['allowPrivate'],
        tls_handshake_timeout_secs=10, client_listener_timeout_secs=600,
        connection_establishment_timeout_secs=30, tcp_connections_timeout_secs=604800,
        udp_connections_timeout_secs=300, credentials_file=str(base / 'credentials.toml'),
        listen_protocols=dict(http1={}, http2={}),
        forward_protocol={'direct': {}} if spec['outbound']=='direct' else {'socks5': dict(address=spec['socksAddress'], extended_auth=False)})
    from client_egress import effective_forward
    effective_forward(vpn)
    if spec['quic']: vpn['listen_protocols']['quic'] = {}
    cert, keypath, cr = certificates.certificate_paths(spec['certificateId'])
    if spec['enabled']:
        if cr['domain'] != spec['domain']:
            raise TtError('tt_certificate_invalid')
        certificates.inspect_pair(cert, keypath, spec['domain'])
    hosts = dict(main_hosts=[dict(hostname=spec['domain'], cert_chain_path=cert, private_key_path=keypath)])
    creds = dict(client=[dict(username=c['username'], password=c['password']) for c in clients if c['enabled']])
    if not creds['client']:
        # TT 1.1 requires an actual array of tables. A non-exported,
        # cryptographically unguessable sentinel keeps authentication enabled.
        sentinel = hmac.new(key, ('tt-deny-all/' + p['workspaceId'] + '/' + spec['id']).encode(), hashlib.sha256).hexdigest()
        creds['client'] = [dict(username='_antirkn_no_clients', password=sentinel)]
    service = ('[Unit]\nDescription=AntiRKN TrustTunnel endpoint\nAfter=network-online.target\nWants=network-online.target\n'
        '[Service]\nType=simple\nUMask=0077\nWorkingDirectory=' + str(base) + '\n'
        'ExecStart=/usr/local/bin/trusttunnel_endpoint vpn.toml hosts.toml\nRestart=on-failure\nRestartSec=3\n'
        '[Install]\nWantedBy=multi-user.target\n').encode()
    data = [toml_bytes(vpn), toml_bytes(hosts), toml_bytes(creds), service]
    saved = dict(workspaceId=p['workspaceId'], spec=spec, clients=clients, keyId=key_id,
        revision=digest(p), hashes=[hashlib.sha256(b).hexdigest() for b in data])
    return saved, data


def current_hashes(rid):
    return [hash_file(p) for p in paths(rid)]


def intact(saved):
    r = saved['spec']
    return current_hashes(r['id']) == ([None]*4 if r['deleted'] else saved['hashes'])


def confirmed(saved, probe=True):
    r = saved['spec']
    if not intact(saved): return False
    enabled = r['enabled'] and not r['deleted']
    if active(unit_for(r['id'])) != enabled: return False
    if enabled and probe:
        try:
            cert, key, cr = certificates.certificate_paths(r['certificateId'])
            certificates.verify_service(unit_for(r['id']), r['listen'], r['port'], r['domain'], cr['fingerprint'])
        except (TtError, OSError): return False
    return True


def preflight(store, p):
    check_revocations(store, p)
    release = prerequisites() if any('adoption' not in r for r in p['resources']) else None
    saved = owned(store)
    adopted = {}
    ids = {r['id'] for r in p['resources']}
    if any(r['workspaceId'] == p['workspaceId'] and rid not in ids for rid, r in saved.items()):
        raise TtError('tt_conflict')
    ports = []
    certs = {}
    for r in p['resources']:
        old = saved.get(r['id'])
        if 'adoption' in r:
            import managed_existing
            adopted[r['id']] = managed_existing.preflight(store, p, r, old, 'tt')
            continue
        if old:
            if old['workspaceId'] != p['workspaceId'] or not intact(old): raise TtError('tt_conflict')
        elif current_hashes(r['id']) != [None]*4: raise TtError('tt_conflict')
        if r['deleted']: continue
        desired(p, r, old, preview=True)
        cr = certificates.record(r['certificateId'])
        certs[cr['id']] = cr['pairHash']
        if r['enabled']:
            for host, port in ports:
                if port == r['port'] and (host == r['listen'] or host in ('0.0.0.0','::') or r['listen'] in ('0.0.0.0','::')):
                    raise TtError('tt_port_busy')
            ports.append((r['listen'], r['port']))
            same = old and active(unit_for(r['id'])) and (old['spec']['listen'],old['spec']['port']) == (r['listen'],r['port'])
            if not same and not available(r['listen'], r['port'], r['quic']): raise TtError('tt_port_busy')
            if same and r['quic'] and not old['spec']['quic'] and not available(r['listen'], r['port'], udp_only=True): raise TtError('tt_port_busy')
            if r['outbound'] == 'socks5': check_socks(r['socksAddress'])
    return dict(fingerprint=digest(dict(payload=p,saved=saved,release=release,certificates=certs,adopted=adopted)),
        resources=len(p['resources']), users=len(p['users']), restart=True,
        creates=sum(r['id'] not in saved and not r['deleted'] for r in p['resources']),
        updates=sum(r['id'] in saved and not r['deleted'] for r in p['resources']),
        deletes=sum(r['deleted'] and r['id'] in saved for r in p['resources']))


def plan(store, req):
    p = parse_payload(req['payload'])
    if p['workspaceId'] != req['id']: raise TtError()
    return preflight(store,p)


def state(store, workspace, pending_job=None):
    result = []
    for rid, saved in owned(store).items():
        if saved['workspaceId'] != workspace: continue
        if saved.get('adopted'):
            import managed_existing
            result.append(managed_existing.state(store, saved, 'tt', pending_job))
            continue
        cr = certificates.record(saved['spec']['certificateId'])
        result.append(dict(id=rid,workspaceId=workspace,confirmed=confirmed(saved),
            spec=saved['spec'],clients=saved['clients'],revision=saved['revision'],certificate=certificates.public(cr)))
    return result


class TtApply:
    def __init__(self, store, req):
        self.store,self.req,self.p = store,req,parse_payload(req['payload'])
        if req['count'] != len(self.p['resources'])+2 or req['interval'] != 1: raise TtError()

    def step(self, checkpoint):
        with lock():
            p,req,db = self.p,self.req,self.store.db
            check_revocations(self.store, p)
            native = [r for r in p['resources'] if 'adoption' not in r]
            if native: prerequisites()
            if checkpoint == 0:
                if preflight(self.store,p)['fingerprint'] != req['fingerprint']: raise TtError('tt_conflict')
                check_revocations(self.store, p, persist=True)
                backup = self.store.directory / ('tt-backup-'+req['id']+'.json')
                if not backup.exists():
                    atomic_file(backup,canonical(dict(records=owned(self.store),files={r['id']:[base64.b64encode(read(f)).decode() if f.exists() else None for f in paths(r['id'])] for r in native})).encode())
                if native: mkdir(ROOT)
                if native and not KEY.exists():
                    if any(not r.get('adopted') for r in owned(self.store).values()): raise TtError('tt_conflict')
                    fd=os.open(str(KEY),os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
                    with os.fdopen(fd,'wb') as stream:
                        stream.write(secrets.token_bytes(32));stream.flush();os.fsync(stream.fileno())
                code='tt_preparing'
            elif checkpoint <= len(p['resources']):
                r=p['resources'][checkpoint-1]
                old=owned(self.store).get(r['id'])
                if 'adoption' in r:
                    import managed_existing
                    managed_existing.apply(self.store, req, p, r, old, 'tt', checkpoint)
                    return
                if r['deleted']:
                    if old is None: raise TtError('tt_conflict')
                    wanted={**old,'spec':r,'revision':digest(p)};data=[]
                else: wanted,data=desired(p,r,old)
                before=current_hashes(r['id'])
                after=[None]*4 if r['deleted'] else wanted['hashes']
                intent=self.store.directory/('tt-intent-'+req['id']+'-'+r['id']+'.json')
                if not intent.exists():
                    if old and not intact(old) or not old and before != [None]*4: raise TtError('tt_conflict')
                    atomic_file(intent,canonical(dict(before=before,after=after)).encode())
                allowed=json.loads(read(intent))
                if allowed['after'] != after or any(v not in (allowed['before'][i],after[i]) for i,v in enumerate(before)):
                    raise TtError('tt_conflict')
                if not (before == after and confirmed(wanted)):
                    unit=unit_for(r['id'])
                    if active(unit): run(['/usr/bin/systemctl','stop',unit],timeout=60)
                    if r['deleted']:
                        run(['/usr/bin/systemctl','disable',unit],check=False)
                        for f in paths(r['id']): f.unlink(missing_ok=True)
                        certificates.unbind(r['id'])
                    else:
                        mkdir(ROOT/r['id'])
                        for f,b in zip(paths(r['id']),data): atomic_file(f,b,0o644 if f.suffix=='.service' else 0o600)
                        run(['/usr/bin/systemctl','daemon-reload'])
                        certificates.unbind(r['id'])
                        certificates.bind(r['certificateId'],r['id'],unit,r['listen'],r['port'])
                        if r['enabled']:
                            if not available(r['listen'],r['port'],r['quic']): raise TtError('tt_port_busy')
                            run(['/usr/bin/systemctl','enable',unit])
                            run(['/usr/bin/systemctl','restart',unit],timeout=60)
                        else: run(['/usr/bin/systemctl','disable',unit])
                    if not confirmed(wanted): raise TtError('tt_failed')
                with db:
                    db.execute('INSERT INTO tt_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data',(r['id'],canonical(wanted)))
                    db.execute('UPDATE jobs SET checkpoint=? WHERE id=?',(checkpoint+1,req['id']))
                    self.store.event(req['id'],'tt_applying',checkpoint+1,req['count'])
                return
            else:
                if any(not r['confirmed'] or r['revision'] != digest(p) for r in state(self.store,p['workspaceId'],pending_job=req['id'])): raise TtError('tt_conflict')
                code='tt_checking'
            with db:
                db.execute('UPDATE jobs SET checkpoint=? WHERE id=?',(checkpoint+1,req['id']))
                self.store.event(req['id'],code,checkpoint+1,req['count'])

    def rollback(self):
        req_id = self.req['id']
        backup_file = self.store.directory / ('tt-backup-' + req_id + '.json')
        if not backup_file.exists():
            return
        try:
            if backup_file.stat().st_size > 16777216:
                return
            data = json.loads(backup_file.read_text())
            with self.store.db:
                self.store.db.execute("DELETE FROM tt_resources WHERE data LIKE ?", (f'%"workspaceId":"{self.p["workspaceId"]}"%',))
                for r_id, r_data in data.get('records', {}).items():
                    self.store.db.execute("INSERT OR REPLACE INTO tt_resources VALUES (?,?)", (r_id, canonical(r_data)))
            files_backup = data.get('files', {})
            native = [r for r in self.p['resources'] if 'adoption' not in r]
            for r in native:
                res_id = r['id']
                unit = unit_for(res_id)
                flist = paths(res_id)
                if res_id not in files_backup or all(v is None for v in files_backup[res_id]):
                    try: run(['/usr/bin/systemctl', 'stop', unit], timeout=30)
                    except Exception: pass
                    try: run(['/usr/bin/systemctl', 'disable', unit], check=False)
                    except Exception: pass
                    for f in flist: f.unlink(missing_ok=True)
                    certificates.unbind(res_id)
                else:
                    for f, b64 in zip(flist, files_backup[res_id]):
                        if b64 is not None:
                            atomic_file(f, base64.b64decode(b64), 0o644 if f.suffix == '.service' else 0o600)
                        else:
                            f.unlink(missing_ok=True)
                    try:
                        run(['/usr/bin/systemctl', 'daemon-reload'])
                        run(['/usr/bin/systemctl', 'restart', unit], timeout=30)
                    except Exception: pass
                (self.store.directory / ('tt-intent-' + req_id + '-' + res_id + '.json')).unlink(missing_ok=True)
        finally:
            backup_file.unlink(missing_ok=True)
