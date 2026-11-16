"""Managed VLESS resources. All panel effects use the pinned session API.

The worker owns serialization/checkpoints. Input contains no credentials; stable
client/key material is derived with HMAC from the existing private runner key.
Only public REALITY material and personal UUIDs leave the server over SSH.
"""
import base64
from client_revocations import check as check_revocations
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
from urllib.error import HTTPError
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
        if 'adoption' in r:
            import managed_existing
            managed_existing.validate_spec(r, 'vless')
            continue
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
    import managed_existing
    managed_existing.validate_payload(value, 'vless')
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


def access_for_panel(store, panel_id):
    row = store.db.execute("SELECT request FROM jobs WHERE id=? AND status='succeeded'", (panel_id,)).fetchone()
    if row is None:
        from panel_discovery import external_access
        access = external_access()
        if not access or access['id'] != panel_id: raise VlessError('vless_conflict')
    else:
        req = json.loads(row[0])
        if req.get('kind') != 'panel_install': raise VlessError('vless_conflict')
        PanelInstaller(store, req).assert_owned()
        access = access_for(panel_id, req['port'])
    return access


def panel_for(store, panel_id, _retry=True):
    access = access_for_panel(store, panel_id)
    sessions = getattr(store, '_panel_sessions', None)
    if sessions is None:
        sessions = store._panel_sessions = {}
    cached = sessions.get(panel_id)
    api = cached[1] if cached and cached[0] == access else None
    using_cached = api is not None
    if api is None:
        api = PanelApi(access['port'], access.get('basePath', '/'), tls=access.get('tls', False),
            certificate=access.get('certificate'), host=access.get('host', '127.0.0.1'))
        api.login(access['username'], access['password'])
        sessions[panel_id] = (access, api)
    # During an API-triggered core restart the status cache briefly omits the
    # Xray version. A missing value is pending, not evidence of another binary.
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            status = api.call('/panel/api/server/status')
        except HTTPError as error:
            if error.code not in (401, 403, 404) or not using_cached or not _retry:
                raise
            sessions.pop(panel_id, None)
            return panel_for(store, panel_id, _retry=False)
        if isinstance(status, dict) and isinstance(status.get('xray'), dict):
            panel_version, xray_version = status.get('panelVersion'), status['xray'].get('version')
            if (panel_version and panel_version != access.get('panelVersion')) or (xray_version and xray_version != access.get('xrayVersion')):
                from panel_discovery import external_access, EXTERNAL_ACCESS
                from panel import atomic_file, DATABASE
                ext = external_access()
                if ext and ext.get('id') == panel_id:
                    if panel_version: ext['panelVersion'] = access['panelVersion'] = panel_version
                    if xray_version: ext['xrayVersion'] = access['xrayVersion'] = xray_version
                    atomic_file(EXTERNAL_ACCESS, json.dumps(ext).encode())
                    sessions[panel_id] = (access, api)
                    return api
                version_file = DATABASE / '.antirkn-versions'
                owner_file = DATABASE / '.antirkn-owner'
                is_owner = False
                if owner_file.exists():
                    try:
                        from panel import safe_file
                        safe_file(owner_file, 64)
                        is_owner = (owner_file.read_text().strip() == panel_id)
                    except Exception:
                        pass
                if is_owner or access.get('id') == panel_id:
                    ver = {}
                    if version_file.exists():
                        try:
                            ver = json.loads(version_file.read_text())
                        except Exception:
                            pass
                    if not ver or ver.get('id') == panel_id:
                        ver['id'] = panel_id
                        if panel_version: ver['panelVersion'] = access['panelVersion'] = panel_version
                        if xray_version: ver['xrayVersion'] = access['xrayVersion'] = xray_version
                        atomic_file(version_file, json.dumps(ver).encode())
                        sessions[panel_id] = (access, api)
                        return api
                raise VlessError('vless_conflict')
            if panel_version == access.get('panelVersion') and xray_version == access.get('xrayVersion'):
                return api
        time.sleep(.25)
    raise VlessError('vless_api_failed')


def normal(row):
    """Semantic fingerprint, excluding counters maintained by the panel."""
    # /inbounds/list annotates these read-only fields, while /get/:id does
    # not. They cannot participate in the saved readback fingerprint: doing so
    # makes a successful point readback look like drift on the next list call.
    value = {k: copy.deepcopy(v) for k, v in row.items() if k not in
             ('up', 'down', 'total', 'allTime', 'lastTrafficResetTime', 'clientStats', 'userId',
              'originNodeGuid', 'fallbackParent')}
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
    from egress_access import clients_for
    for service_client in clients_for(current):
        clients.append({**service_client, 'flow': 'xtls-rprx-vision' if r['transport'] == 'raw' else ''})
    stream = dict(network='tcp' if r['transport'] == 'raw' else 'xhttp', security=r['security'])
    if r['security'] == 'reality':
        stream['realitySettings'] = dict(show=False, target=r['target'], xver=0,
            # Owner policy: never gate REALITY clients by their reported version.
            minClientVer='0.0.0',
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


def matches_observation(api, row, workspace, resource, observed_hash):
    """Confirm drift against the same endpoint used for saved readback.

    The list API may enrich a row with read-only fields absent from /get/:id.
    Only fetch the detail when the cheap list comparison differs; a genuine
    change in the persisted row must still fail the ownership check.
    """
    if row is None or observed_hash is None:
        return False
    normalized = normal(row)
    if digest(normalized) == observed_hash:
        return True
    # v41 and older saved /list fingerprints before originNodeGuid and
    # fallbackParent became read-only annotations in the current normalizer.
    # Accept that exact legacy representation during upgrade; the next
    # successful write replaces it with the current detail fingerprint.
    annotated = copy.deepcopy(normalized)
    for key in ('originNodeGuid', 'fallbackParent'):
        if key in row:
            annotated[key] = copy.deepcopy(row[key])
    if annotated != normalized and digest(annotated) == observed_hash:
        return True
    detail = api.call('/panel/api/inbounds/get/%d' % row['id'])
    if not isinstance(detail, dict) or detail.get('id') != row['id'] or detail.get('remark') != marker(workspace, resource):
        raise VlessError('vless_api_failed')
    return digest(normal(detail)) == observed_hash


def preflight(store, payload, api, rows=None):
    check_revocations(store, payload)
    if rows is None:
        rows = api.call('/panel/api/inbounds/list')
    if not isinstance(rows, list): raise VlessError('vless_api_failed')
    saved = owned_rows(store)
    adopted = {}
    for r in payload['resources']:
        if 'adoption' in r:
            import managed_existing
            adopted[r['id']] = managed_existing.preflight(store, payload, r, saved.get(r['id']), 'vless', inbounds=rows)
            continue
        current = locate(rows, payload['workspaceId'], r['id'])
        previous = saved.get(r['id'])
        if previous and previous['workspaceId'] != payload['workspaceId']: raise VlessError('vless_conflict')
        if current:
            matched = False
            if previous and previous.get('observedHash'):
                matched = matches_observation(api, current, payload['workspaceId'], r['id'], previous['observedHash'])
            if not matched:
                wanted = wanted_inbound(payload, r, current)
                desired = normal(wanted)
                actual = normal(current)
                for k in ('id', 'tag', 'up', 'down', 'total', 'userId', 'nodeId'):
                    desired.pop(k, None)
                    actual.pop(k, None)
                if desired == actual and not r.get('deleted'):
                    matched = True
            if not matched:
                raise VlessError('vless_conflict')
        if previous and not current and not (previous.get('deleted') or r.get('deleted')): raise VlessError('vless_conflict')
    # Every currently managed resource in this workspace must participate, so a
    # stale device cannot silently drop clients/resources through a partial list.
    if any(p['workspaceId'] == payload['workspaceId'] and not p.get('deleted') and locate(rows, p['workspaceId'], rid) is not None and rid not in {r['id'] for r in payload['resources']} for rid, p in saved.items()):
        raise VlessError('vless_conflict')
    active = [r for r in payload['resources'] if r['enabled'] and not r['deleted'] and 'adoption' not in r]
    reserved = [(r['listen'], r['port'], r['id']) for r in active]
    for i, (address, port, rid) in enumerate(reserved):
        for other_address, other_port, other_id in reserved[:i]:
            if port == other_port and (address == other_address or address in ('0.0.0.0','::') or other_address in ('0.0.0.0','::')):
                raise VlessError('vless_port_busy')
        current = locate(rows, payload['workspaceId'], rid)
        for other in rows:
            if other.get('enable') and other.get('port') == port and (not current or other['id'] != current['id']):
                other_listen = other.get('listen') or ''
                # Two specific non-wildcard addresses on the same port can coexist.
                if other_listen not in ('', '0.0.0.0', '::') and address not in ('0.0.0.0', '::') and other_listen != address:
                    continue
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
    fingerprint = digest(dict(rows=sorted([normal(r) for r in rows], key=lambda r:r['id']), saved=saved, desired=payload, adopted=adopted))
    return dict(fingerprint=fingerprint, resources=len(payload['resources']), users=len(payload['users']),
                creates=sum(locate(rows,payload['workspaceId'],r['id']) is None and not r['deleted'] for r in payload['resources']),
                deletes=sum(r['deleted'] and locate(rows,payload['workspaceId'],r['id']) is not None for r in payload['resources']),
                updates=sum(locate(rows,payload['workspaceId'],r['id']) is not None and not r['deleted'] for r in payload['resources']))


def plan(store, req):
    payload = parse_payload(req['payload'])
    if payload['panelId'] != req['id']: raise VlessError()
    return preflight(store, payload, panel_for(store, payload['panelId']))


def state(store, panel_id, pending_job=None):
    api = panel_for(store, panel_id)
    rows = api.call('/panel/api/inbounds/list')
    result = []
    for rid, saved in owned_rows(store).items():
        if saved.get('adopted'):
            import managed_existing
            result.append(managed_existing.state(store, saved, 'vless', pending_job, inbounds=rows))
            continue
        panel_updated = False
        if saved.get('panelId') != panel_id:
            saved['panelId'] = panel_id
            panel_updated = True
        current = locate(rows, saved['workspaceId'], rid)
        if current is None:
            if not saved.get('deleted'):
                saved['deleted'] = True
                saved['observedHash'] = None
                with store.db:
                    store.db.execute('INSERT INTO vless_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data',
                        (rid, canonical(saved)))
            confirmed = True
        else:
            deleted_changed = False
            if saved.get('deleted'):
                saved['deleted'] = False
                deleted_changed = True
            confirmed = matches_observation(api, current, saved['workspaceId'], rid, saved.get('observedHash'))
            if not confirmed:
                try:
                    payload = dict(
                        workspaceId=saved['workspaceId'],
                        resources=[saved['spec']],
                        users=[{'id': c['id'], 'enabled': c.get('enable', c.get('enabled', True))} for c in saved.get('clients', [])]
                    )
                    wanted = wanted_inbound(payload, saved['spec'], current)
                    desired = normal(wanted)
                    actual = normal(current)
                    for k in ('id', 'tag', 'up', 'down', 'total', 'userId', 'nodeId'):
                        desired.pop(k, None)
                        actual.pop(k, None)
                    if desired == actual:
                        try:
                            detail = api.call('/panel/api/inbounds/get/%d' % current['id'])
                            detail_row = detail if isinstance(detail, dict) and detail.get('id') == current['id'] and detail.get('remark') == marker(saved['workspaceId'], rid) else current
                        except Exception:
                            detail_row = current
                        saved['observedHash'] = digest(normal(detail_row))
                        saved['deleted'] = False
                        saved['panelId'] = panel_id
                        with store.db:
                            store.db.execute('INSERT INTO vless_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data',
                                (rid, canonical(saved)))
                        confirmed = True
                except Exception:
                    pass
            elif panel_updated or deleted_changed:
                with store.db:
                    store.db.execute('INSERT INTO vless_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data',
                        (rid, canonical(saved)))
        result.append(dict(id=rid, spec=saved['spec'], workspaceId=saved['workspaceId'],
            confirmed=confirmed, deleted=bool(saved.get('deleted')), exists=(current is not None),
            publicKey=saved['publicKey'], shortId=saved['shortId'],
            clients=saved['clients'], revision=saved['revision']))
    return result


class VlessApply:
    def __init__(self, store, req):
        self.store, self.req = store, req
        self.payload = parse_payload(req['payload'])
        if req['count'] != len(self.payload['resources']) + 2 or req['interval'] != 1: raise VlessError()

    def step(self, checkpoint):
        p, db = self.payload, self.store.db
        check_revocations(self.store, p)
        api = panel_for(self.store, p['panelId'])
        job_id = self.req['id']
        if checkpoint == 0:
            rows = api.call('/panel/api/inbounds/list')
            preview = preflight(self.store, p, api, rows=rows)
            if preview['fingerprint'] != self.req['fingerprint']: raise VlessError('vless_conflict')
            check_revocations(self.store, p, persist=True)
            backup = self.store.directory / ('vless-backup-' + job_id + '.json')
            if not backup.exists():
                from panel_clients import capture
                deleted = [r for r in p['resources'] if r['deleted'] and 'adoption' not in r]
                listed = api.call('/panel/api/clients/list') if deleted else []
                refs = {r['id']: capture(row, listed) for r in deleted
                        if (row := locate(rows, p['workspaceId'], r['id'])) is not None}
                atomic_file(backup, canonical(dict(rows=rows, resources=owned_rows(self.store), clientRefs=refs)).encode())
            code = 'vless_preparing'
        elif checkpoint <= len(p['resources']):
            r = p['resources'][checkpoint - 1]
            if 'adoption' in r:
                import managed_existing
                managed_existing.apply(self.store, self.req, p, r, owned_rows(self.store).get(r['id']), 'vless', checkpoint)
                return
            rows = api.call('/panel/api/inbounds/list')
            current = locate(rows, p['workspaceId'], r['id'])
            previous = owned_rows(self.store).get(r['id'])
            wanted = wanted_inbound(p, r, current)
            desired = normal(wanted)
            for k in ('id','tag','up','down','total','userId','nodeId'): desired.pop(k,None)
            already = current is None if r['deleted'] else current is not None and subset(desired, normal(current))
            created_id = None
            if not already:
                if current and (not previous or not matches_observation(api, current, p['workspaceId'], r['id'], previous['observedHash'])): raise VlessError('vless_conflict')
                if not current and previous and not (previous.get('deleted') or r.get('deleted')): raise VlessError('vless_conflict')
                if r['deleted']:
                    if current: api.call('/panel/api/inbounds/del/%d' % current['id'], {})
                elif current:
                    api.call('/panel/api/inbounds/update/%d' % current['id'], wanted)
                else:
                    created = api.call('/panel/api/inbounds/add', wanted)
                    if isinstance(created, dict) and isinstance(created.get('id'), int):
                        created_id = created['id']
            readback_id = current['id'] if current and not r['deleted'] else created_id
            if readback_id is not None:
                observed = api.call('/panel/api/inbounds/get/%d' % readback_id)
                if not isinstance(observed, dict) or observed.get('remark') != marker(p['workspaceId'], r['id']):
                    raise VlessError('vless_api_failed')
            else:
                observed = locate(api.call('/panel/api/inbounds/list'), p['workspaceId'], r['id'])
            if r['deleted']:
                if observed is not None: raise VlessError('vless_api_failed')
                from panel_clients import cleanup
                backup = self.store.directory / ('vless-backup-' + job_id + '.json')
                safe_file(backup, 16777216)
                refs = json.loads(backup.read_text()).get('clientRefs', {}).get(r['id'], [])
                cleanup(api, refs)
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
            for r in state(self.store, p['panelId'], pending_job=job_id):
                if r['workspaceId'] == p['workspaceId'] and not r['confirmed']: raise VlessError('vless_conflict')
            code = 'vless_checking'
        with db:
            db.execute('UPDATE jobs SET checkpoint=? WHERE id=?',(checkpoint+1,job_id))
            self.store.event(job_id,code,checkpoint+1,self.req['count'])

    def rollback(self):
        job_id = self.req['id']
        backup_file = self.store.directory / ('vless-backup-' + job_id + '.json')
        if not backup_file.exists():
            return
        try:
            if backup_file.stat().st_size > 16777216:
                return
            data = json.loads(backup_file.read_text())
            with self.store.db:
                self.store.db.execute("DELETE FROM vless_resources WHERE data LIKE ?", (f'%"workspaceId":"{self.payload["workspaceId"]}"%',))
                for r_id, r_data in data.get('resources', {}).items():
                    self.store.db.execute("INSERT OR REPLACE INTO vless_resources VALUES (?,?)", (r_id, canonical(r_data)))
            try:
                api = panel_for(self.store, self.payload['panelId'])
                current_inbounds = api.call('/panel/api/inbounds/list')
                backup_rows = data.get('rows', [])
                backup_by_id = {row['id']: row for row in backup_rows}
                for cur in current_inbounds:
                    if cur['id'] not in backup_by_id and marker(self.payload['workspaceId'], '') in cur.get('remark', ''):
                        try: api.call('/panel/api/inbounds/del/%d' % cur['id'], {})
                        except Exception: pass
                for old_row in backup_rows:
                    cur = next((c for c in current_inbounds if c['id'] == old_row['id']), None)
                    if cur and normal(cur) != normal(old_row):
                        try: api.call('/panel/api/inbounds/update/%d' % old_row['id'], old_row)
                        except Exception: pass
                try: api.call('/panel/api/server/restartXrayService', {})
                except Exception: pass
            except Exception:
                pass
        finally:
            backup_file.unlink(missing_ok=True)
