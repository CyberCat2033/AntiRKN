"""Managed VLESS resources. All panel effects use the pinned session API.

The worker owns serialization/checkpoints. Input contains no credentials; stable
client/key material is derived with HMAC from the existing private runner key.
Only public REALITY material and personal UUIDs leave the server over SSH.
"""
import base64
import copy
import hashlib
import hmac
import ipaddress
import json
from pathlib import Path
import re
import socket
import subprocess
import time
import uuid
from urllib.parse import urlsplit

from panel import KEY, PANEL, PanelError, PanelInstaller, access_for, atomic_file, command, safe_file
from panel_api import PanelApi
from vless_contract import validate_schema


class VlessError(Exception):
    def __init__(self, code='vless_invalid'):
        self.code = code


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def parse_payload(raw):
    def pairs(entries):
        result = {}
        for k, v in entries:
            if k in result: raise VlessError()
            result[k] = v
        return result
    value = json.loads(raw, object_pairs_hook=pairs)
    validate_schema(value)
    for key in ('users', 'resources'):
        if len({x['id'] for x in value[key]}) != len(value[key]): raise VlessError()
    for r in value['resources']:
        try:
            listen = ipaddress.ip_address(r['listen'])
            if listen.is_multicast: raise ValueError()
            if r['endpoint'] in ('0.0.0.0', '::'): raise ValueError()
            if ':' in r['endpoint']: ipaddress.ip_address(r['endpoint'])
            if r['security'] == 'tls' and (r['transport'] != 'xhttp' or not r['certificate'] or not r['certificateKey']): raise ValueError()
            if r['transport'] == 'raw' and r['security'] != 'reality': raise ValueError()
            # REALITY supports the HTTP/2 stream-one client. Other modes are
            # admitted only for TLS and tested individually in the fixture.
            if r['transport'] == 'xhttp' and r['security'] == 'reality' and r['mode'] not in ('auto', 'stream-one'): raise ValueError()
            target = urlsplit('//' + r['target'])
            if not target.hostname or not target.port: raise ValueError()
            if '..' in Path(r['certificate']).parts or '..' in Path(r['certificateKey']).parts: raise ValueError()
            extra = r.get('xhttp', {})
            if extra and r['transport'] != 'xhttp': raise ValueError()
            if any(k.lower() == 'host' for k in extra.get('headers', {})): raise ValueError()
            if (extra.get('uplinkHTTPMethod') == 'GET' or extra.get('uplinkDataPlacement') in ('header','cookie')) and r['mode'] != 'packet-up': raise ValueError()
            lower = lambda v: int(str(v).split('-')[0])
            upper = lambda v: int(str(v).split('-')[-1])
            if 'xPaddingBytes' in extra and lower(extra['xPaddingBytes']) == 0 and upper(extra['xPaddingBytes']) > 0: raise ValueError()
            xmux = extra.get('xmux', {})
            if upper(xmux.get('maxConcurrency',0)) > 0 and upper(xmux.get('maxConnections',0)) > 0: raise ValueError()
            if 'sessionIDTable' in extra and not 10 <= lower(extra.get('sessionIDLength','16-32')) <= upper(extra.get('sessionIDLength','16-32')) <= 128: raise ValueError()
            if r['deleted'] and r['enabled']: raise ValueError()
        except (ValueError, TypeError): raise VlessError()
    return value


def marker(workspace, resource):
    return 'AntiRKN:' + workspace + ':' + resource


def secret(label):
    safe_file(KEY, 32)
    key = KEY.read_bytes()
    if len(key) != 32: raise VlessError('vless_conflict')
    return hmac.new(key, ('vless-v1/' + label).encode(), hashlib.sha256).digest()


def material(workspace, resource, seed=None):
    label = workspace + '/' + resource + ('/' + seed if seed is not None else '')
    private = secret('reality/' + label)
    # PKCS#8 X25519 private key; OpenSSL does the curve operation. No homemade
    # crypto and no private key in process arguments.
    der = bytes.fromhex('302e020100300506032b656e04220420') + private
    public = command(['/usr/bin/openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'], input_data=der)
    if len(public) != 44: raise VlessError()
    b64 = lambda b: base64.urlsafe_b64encode(b).decode().rstrip('=')
    return dict(privateKey=b64(private), publicKey=b64(public[-32:]), shortId=secret('short/' + label).hex()[:16],
        shortIds=[secret('short/' + label + '/' + str(n)).hex()[:2*n] for n in range(1, 8)] + [secret('short/' + label).hex()[:16]])


def client_id(workspace, resource, user):
    return str(uuid.UUID(bytes=secret('client/' + workspace + '/' + resource + '/' + user)[:16], version=4))


def panel_for(store, panel_id):
    row = store.db.execute("SELECT request FROM jobs WHERE id=? AND status='succeeded'", (panel_id,)).fetchone()
    if row is None: raise VlessError('vless_conflict')
    req = json.loads(row[0])
    if req.get('kind') != 'panel_install': raise VlessError('vless_conflict')
    PanelInstaller(store, req).assert_owned()
    access = access_for(panel_id, req['port'])
    api = PanelApi(access['port'])
    api.login(access['username'], access['password'])
    # During an API-triggered core restart the status cache briefly omits the
    # Xray version. A missing value is pending, not evidence of another binary.
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        status = api.call('/panel/api/server/status')
        if isinstance(status, dict) and isinstance(status.get('xray'), dict):
            panel_version, xray_version = status.get('panelVersion'), status['xray'].get('version')
            if panel_version and panel_version != access['panelVersion'] or xray_version and xray_version != access['xrayVersion']:
                raise VlessError('vless_conflict')
            if panel_version == access['panelVersion'] and xray_version == access['xrayVersion']:
                return api
        time.sleep(.25)
    raise VlessError('vless_api_failed')


def normal(row):
    """Semantic fingerprint, excluding counters maintained by the panel."""
    value = {k: copy.deepcopy(v) for k, v in row.items() if k not in
             ('up', 'down', 'total', 'allTime', 'lastTrafficResetTime', 'clientStats', 'userId')}
    for key in ('settings', 'streamSettings', 'sniffing', 'allocate'):
        if isinstance(value.get(key), str):
            try: value[key] = json.loads(value[key])
            except ValueError: pass
    settings = value.get('settings')
    if isinstance(settings, dict):
        for client in settings.get('clients', []):
            if not client.get('flow'): client.pop('flow', None)
            for key in ('created_at', 'updated_at', 'createdAt', 'updatedAt'):
                client.pop(key, None)
        settings['clients'] = sorted(settings.get('clients', []), key=lambda c: c.get('id', ''))
    return value


def subset(wanted, actual):
    if isinstance(wanted, dict):
        return isinstance(actual, dict) and all(k in actual and subset(v, actual[k]) for k, v in wanted.items())
    if isinstance(wanted, list):
        if not isinstance(actual, list) or len(wanted) != len(actual): return False
        if wanted and isinstance(wanted[0], dict) and 'id' in wanted[0]:
            actual = sorted(actual, key=lambda c: c.get('id', ''))
            wanted = sorted(wanted, key=lambda c: c['id'])
        return all(subset(a, b) for a, b in zip(wanted, actual))
    return wanted == actual


def wanted_inbound(payload, r, current=None):
    keys = material(payload['workspaceId'], r['id'], r.get('realitySeed'))
    clients = [dict(id=client_id(payload['workspaceId'], r['id'], u['id']),
        email='ar_' + r['id'] + '_' + u['id'], enable=u['enabled'],
        flow='xtls-rprx-vision' if r['transport'] == 'raw' else '',
        totalGB=0, expiryTime=0, limitIp=0, tgId=0, subId='', reset=0)
        for u in payload['users'] if not r.get('internal', False)]
    stream = dict(network='tcp' if r['transport'] == 'raw' else 'xhttp', security=r['security'])
    if r['security'] == 'reality':
        stream['realitySettings'] = dict(show=False, target=r['target'], xver=0,
            # Mihomo 1.19.30 identifies its REALITY handshake as 1.8.2.
            # Xray 26.7.28 defaults to 26.3.27 and otherwise rejects it.
            # This compatibility tradeoff is shown in the approval plan.
            minClientVer='1.8.2',
            serverNames=[r['sni']], privateKey=keys['privateKey'], shortIds=keys.get('shortIds', [keys['shortId']]),
            settings=dict(publicKey=keys['publicKey'], fingerprint=r.get('fingerprint', 'chrome'), serverName=r['sni'], spiderX='/'))
    else:
        stream['tlsSettings'] = dict(serverName=r['sni'], minVersion='1.2',
            alpn=['h2', 'http/1.1'], certificates=[dict(certificateFile=r['certificate'], keyFile=r['certificateKey'], usage='encipherment')])
    if r['transport'] == 'xhttp':
        stream['xhttpSettings'] = dict(path=r['path'], host=r['host'], mode=r['mode'], **copy.deepcopy(r.get('xhttp', {})))
        if 'sessionIDTable' in stream['xhttpSettings']:
            stream['xhttpSettings'].setdefault('sessionIDLength', '16-32')
    wanted = dict(remark=marker(payload['workspaceId'], r['id']), enable=r['enabled'],
        listen=r['listen'], port=r['port'], protocol='vless', expiryTime=0,
        settings=canonical(dict(clients=clients, decryption='none', fallbacks=[])),
        streamSettings=canonical(stream), sniffing=canonical(dict(enabled=True, destOverride=['http', 'tls', 'quic', 'fakedns'], metadataOnly=False, routeOnly=False)))
    if current:
        # Retain unknown unrelated panel fields. Only managed transport/client
        # configuration is replaced, after comparison with our last observation.
        return {**current, **wanted}
    return {**wanted, 'up': 0, 'down': 0, 'total': 0}


def owned_rows(store):
    return {row['id']: json.loads(row['data']) for row in store.db.execute('SELECT * FROM vless_resources')}


def locate(rows, workspace, resource):
    matches = [r for r in rows if r.get('remark') == marker(workspace, resource)]
    if len(matches) > 1: raise VlessError('vless_conflict')
    return matches[0] if matches else None


def preflight(store, payload, api):
    rows = api.call('/panel/api/inbounds/list')
    if not isinstance(rows, list): raise VlessError('vless_api_failed')
    saved = owned_rows(store)
    for r in payload['resources']:
        current = locate(rows, payload['workspaceId'], r['id'])
        previous = saved.get(r['id'])
        if previous and previous['workspaceId'] != payload['workspaceId']: raise VlessError('vless_conflict')
        if current and (not previous or digest(normal(current)) != previous['observedHash']):
            raise VlessError('vless_conflict')
        if previous and not current and not previous.get('deleted'): raise VlessError('vless_conflict')
    # Every currently managed resource in this workspace must participate, so a
    # stale device cannot silently drop clients/resources through a partial list.
    if any(p['workspaceId'] == payload['workspaceId'] and rid not in {r['id'] for r in payload['resources']} for rid, p in saved.items()):
        raise VlessError('vless_conflict')
    active = [r for r in payload['resources'] if r['enabled'] and not r['deleted']]
    reserved = [(r['listen'], r['port'], r['id']) for r in active]
    for i, (address, port, rid) in enumerate(reserved):
        for other_address, other_port, other_id in reserved[:i]:
            if port == other_port and (address == other_address or address in ('0.0.0.0','::') or other_address in ('0.0.0.0','::')):
                raise VlessError('vless_port_busy')
        current = locate(rows, payload['workspaceId'], rid)
        for other in rows:
            if other.get('enable') and other.get('port') == port and (not current or other['id'] != current['id']):
                # Pinned panel enforces port uniqueness for local inbounds.
                raise VlessError('vless_port_busy')
        if current is None or not current.get('enable') or (current.get('listen'), current.get('port')) != (address, port):
            try:
                with socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET, socket.SOCK_STREAM) as sock:
                    sock.bind((address, port))
            except OSError: raise VlessError('vless_port_busy')
    for r in active:
        if r['security'] == 'tls':
            matched = command(['/usr/bin/openssl','x509','-in',r['certificate'],'-noout','-checkhost',r['sni']])
            if b'does match certificate' not in matched: raise VlessError('vless_invalid')
            command(['/usr/bin/openssl','x509','-in',r['certificate'],'-noout','-checkend','3600'])
            # Xray validates key matching and file readability below.
        config = wanted_inbound(payload, r)
        inbound = dict(listen=r['listen'], port=r['port'], protocol='vless',
            settings=json.loads(config['settings']), streamSettings=json.loads(config['streamSettings']))
        inbound['settings']['clients'] = [c for c in inbound['settings']['clients'] if c['enable']]
        command([str(PANEL / 'bin/xray-linux-amd64'),'run','-test','-config','stdin:'], input_data=canonical(dict(inbounds=[inbound],outbounds=[dict(protocol='freedom')])).encode())
    fingerprint = digest(dict(rows=sorted([normal(r) for r in rows], key=lambda r:r['id']), saved=saved, desired=payload))
    return dict(fingerprint=fingerprint, resources=len(payload['resources']), users=len(payload['users']),
                creates=sum(locate(rows,payload['workspaceId'],r['id']) is None and not r['deleted'] for r in payload['resources']),
                deletes=sum(r['deleted'] and locate(rows,payload['workspaceId'],r['id']) is not None for r in payload['resources']),
                updates=sum(locate(rows,payload['workspaceId'],r['id']) is not None and not r['deleted'] for r in payload['resources']))


def plan(store, req):
    payload = parse_payload(req['payload'])
    if payload['panelId'] != req['id']: raise VlessError()
    return preflight(store, payload, panel_for(store, payload['panelId']))


def state(store, panel_id):
    api = panel_for(store, panel_id)
    rows = api.call('/panel/api/inbounds/list')
    result = []
    for rid, saved in owned_rows(store).items():
        if saved['panelId'] != panel_id: continue
        current = locate(rows, saved['workspaceId'], rid)
        confirmed = (current is None if saved.get('deleted') else current is not None and digest(normal(current)) == saved['observedHash'])
        result.append(dict(id=rid, spec=saved['spec'], workspaceId=saved['workspaceId'],
            confirmed=confirmed, publicKey=saved['publicKey'], shortId=saved['shortId'],
            clients=saved['clients'], revision=saved['revision']))
    return result


class VlessApply:
    def __init__(self, store, req):
        self.store, self.req = store, req
        self.payload = parse_payload(req['payload'])
        if req['count'] != len(self.payload['resources']) + 2 or req['interval'] != 1: raise VlessError()

    def step(self, checkpoint):
        p, db = self.payload, self.store.db
        api = panel_for(self.store, p['panelId'])
        job_id = self.req['id']
        if checkpoint == 0:
            preview = preflight(self.store, p, api)
            if preview['fingerprint'] != self.req['fingerprint']: raise VlessError('vless_conflict')
            backup = self.store.directory / ('vless-backup-' + job_id + '.json')
            if not backup.exists():
                atomic_file(backup, canonical(dict(rows=api.call('/panel/api/inbounds/list'), resources=owned_rows(self.store))).encode())
            code = 'vless_preparing'
        elif checkpoint <= len(p['resources']):
            r = p['resources'][checkpoint - 1]
            rows = api.call('/panel/api/inbounds/list')
            current = locate(rows, p['workspaceId'], r['id'])
            previous = owned_rows(self.store).get(r['id'])
            wanted = wanted_inbound(p, r, current)
            desired = normal(wanted)
            for k in ('id','tag','up','down','total','userId','nodeId'): desired.pop(k,None)
            already = current is None if r['deleted'] else current is not None and subset(desired, normal(current))
            if not already:
                if current and (not previous or digest(normal(current)) != previous['observedHash']): raise VlessError('vless_conflict')
                if not current and previous and not previous.get('deleted'): raise VlessError('vless_conflict')
                if r['deleted']:
                    if current: api.call('/panel/api/inbounds/del/%d' % current['id'], {})
                elif current:
                    api.call('/panel/api/inbounds/update/%d' % current['id'], wanted)
                else:
                    api.call('/panel/api/inbounds/add', wanted)
            observed = locate(api.call('/panel/api/inbounds/list'), p['workspaceId'], r['id'])
            if r['deleted']:
                if observed is not None: raise VlessError('vless_api_failed')
            elif observed is None or not subset(desired, normal(observed)):
                raise VlessError('vless_api_failed')
            keys = material(p['workspaceId'], r['id'], r.get('realitySeed'))
            data = dict(workspaceId=p['workspaceId'], panelId=p['panelId'], spec=r,
                observedHash=digest(normal(observed)) if observed else None, deleted=r['deleted'],
                publicKey=keys['publicKey'], shortId=keys['shortId'], revision=digest(p),
                clients=[dict(id=u['id'], uuid=client_id(p['workspaceId'],r['id'],u['id']),enabled=u['enabled']) for u in p['users'] if not r.get('internal', False)])
            with db:
                db.execute('INSERT INTO vless_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data', (r['id'], canonical(data)))
                db.execute('UPDATE jobs SET checkpoint=? WHERE id=?',(checkpoint+1,job_id))
                self.store.event(job_id,'vless_applying',checkpoint+1,self.req['count'])
            return
        else:
            api.call('/panel/api/server/restartXrayService', {})
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                status = api.call('/panel/api/server/status')
                if isinstance(status, dict) and isinstance(status.get('xray'), dict) and status['xray'].get('state') == 'running': break
                time.sleep(.25)
            else: raise VlessError('vless_api_failed')
            for r in state(self.store, p['panelId']):
                if r['workspaceId'] == p['workspaceId'] and not r['confirmed']: raise VlessError('vless_conflict')
            code = 'vless_checking'
        with db:
            db.execute('UPDATE jobs SET checkpoint=? WHERE id=?',(checkpoint+1,job_id))
            self.store.event(job_id,code,checkpoint+1,self.req['count'])
