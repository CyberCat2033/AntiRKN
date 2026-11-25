"""Explicit edits of existing panel inbounds, preserving unmanaged fields/clients."""
import copy
import json
from pathlib import Path
import socket
from panel import PANEL, atomic_file, command, safe_file
from vless import VlessError, canonical, digest, normal, panel_for, subset


def object_field(value):
    return json.loads(value) if isinstance(value, str) else copy.deepcopy(value)


def decode(raw):
    p = json.loads(raw)
    if type(p) is not dict or type(p.get('inboundId')) is not int or p['inboundId'] < 1:
        raise VlessError()
    return p


def read(store, panel_id, inbound_id, rows=None, api=None):
    if api is None:
        api = panel_for(store, panel_id)
    if rows is None:
        rows = api.call('/panel/api/inbounds/list')
    row = next((r for r in rows if r['id'] == inbound_id), None)
    if row is None:
        raise VlessError('vless_conflict')
    return api, row


def snapshot(store, req):
    p = decode(req['payload'])
    _, row = read(store, req['id'], p['inboundId'])
    fingerprint = digest(normal(row))
    row = copy.deepcopy(row)
    for key in ('settings', 'streamSettings', 'sniffing', 'allocate'):
        if isinstance(row.get(key), (dict, list)): row[key] = canonical(row[key])
    return dict(row=row, fingerprint=fingerprint)


def merge_patch(original, patch):
    result = copy.deepcopy(original)
    for key, value in patch.items():
        if value is None:
            result.pop(key, None)
        elif isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge_patch(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def wanted(row, patch):
    if type(patch) is not dict or not set(patch) <= {'remark', 'enable', 'listen', 'port', 'streamSettings'}:
        raise VlessError()
    if row.get('remark', '').startswith('AntiRKN:'):
        raise VlessError('vless_conflict')
    result = copy.deepcopy(row)
    for key in ('remark', 'enable', 'listen', 'port'):
        if key in patch: result[key] = patch[key]
    if (type(result.get('remark')) is not str or len(result['remark']) > 256
            or result['remark'].startswith('AntiRKN:') or type(result.get('enable')) is not bool
            or type(result.get('port')) is not int or not 1 <= result['port'] <= 65535
            or type(result.get('listen')) is not str):
        raise VlessError()
    import ipaddress
    try: ipaddress.ip_address(result['listen'] or '0.0.0.0')
    except ValueError: raise VlessError()
    if 'streamSettings' in patch:
        if type(patch['streamSettings']) is not dict: raise VlessError()
        stream = object_field(row['streamSettings'])
        # Protocol/transport changes need migrations beyond a settings edit.
        if any(k in patch['streamSettings'] and patch['streamSettings'][k] != stream.get(k)
               for k in ('network', 'security')): raise VlessError()
        result['streamSettings'] = canonical(merge_patch(stream, patch['streamSettings']))
    stream = object_field(result['streamSettings'])
    if stream.get('security') == 'reality':
        stream.setdefault('realitySettings', {})['minClientVer'] = '0.0.0'
        result['streamSettings'] = canonical(stream)
    return result


def preflight(store, panel_id, p, rows=None, api=None):
    if api is None:
        api = panel_for(store, panel_id)
    if rows is None:
        rows = api.call('/panel/api/inbounds/list')
    _, current = read(store, panel_id, p['inboundId'], rows=rows, api=api)
    if p.get('observedHash') != digest(normal(current)):
        raise VlessError('vless_conflict')
    desired = wanted(current, p.get('patch'))
    if desired['enable'] and (desired['port'], desired['listen'], desired['enable']) != (current['port'], current['listen'], current['enable']):
        if any(r['id'] != current['id'] and r.get('enable') and r['port'] == desired['port'] for r in rows):
            raise VlessError('vless_port_busy')
        try:
            with socket.socket(socket.AF_INET6 if ':' in desired['listen'] else socket.AF_INET) as sock:
                sock.bind((desired['listen'] or '0.0.0.0', desired['port']))
        except OSError: raise VlessError('vless_port_busy')
    # Native config validation includes TLS files/REALITY and all retained client settings.
    config = {k: desired[k] for k in ('listen', 'port', 'protocol')}
    for key in ('settings', 'streamSettings', 'sniffing'):
        config[key] = object_field(desired.get(key) or '{}')
    settings = config['settings']
    if isinstance(settings.get('clients'), list):
        settings['clients'] = [c for c in settings['clients'] if c.get('enable', True)]
    command([str(PANEL / 'bin/xray-linux-amd64'), 'run', '-test', '-config', 'stdin:'],
        input_data=canonical(dict(inbounds=[config], outbounds=[dict(protocol='freedom')])).encode())
    return dict(fingerprint=digest(dict(panelId=panel_id, desired=normal(desired), observed=p['observedHash'])),
        inboundId=current['id'], name=desired['remark'], clients=len(object_field(current['settings']).get('clients', [])))


def plan(store, req):
    return preflight(store, req['id'], decode(req['payload']))


def stage_payload(store, req):
    # The RPC payload may contain transport secrets. Persist it in a separate
    # root-only file; the journal holds only an opaque content hash.
    p = decode(req['payload'])
    if type(p.get('panelId')) is not str: raise VlessError()
    data = canonical(p).encode()
    path = store.directory / ('inbound-request-' + req['id'] + '.json')
    if path.exists():
        safe_file(path, 262144)
        if path.read_bytes() != data: raise VlessError('vless_conflict')
    else:
        atomic_file(path, data)
    return {**req, 'payload': canonical(dict(sha256=digest(p)))}


class ObservedInboundEdit:
    def __init__(self, store, req):
        self.store, self.req = store, req
        path = store.directory / ('inbound-request-' + req['id'] + '.json')
        safe_file(path, 262144)
        self.payload = decode(path.read_text())
        if digest(self.payload) != json.loads(req['payload'])['sha256']: raise VlessError('vless_conflict')
        self.backup = store.directory / ('inbound-backup-' + req['id'] + '.json')

    def step(self, checkpoint):
        p, req = self.payload, self.req
        # One session (and status check) per step.
        api = panel_for(self.store, p['panelId'])
        if checkpoint == 0:
            rows = api.call('/panel/api/inbounds/list')
            _, current = read(self.store, p['panelId'], p['inboundId'], rows=rows, api=api)
            if preflight(self.store, p['panelId'], p, rows=rows, api=api)['fingerprint'] != req['fingerprint']:
                raise VlessError('vless_conflict')
            if not self.backup.exists(): atomic_file(self.backup, canonical(current).encode())
            code = 'vless_preparing'
        elif checkpoint == 1:
            _, current = read(self.store, p['panelId'], p['inboundId'], api=api)
            safe_file(self.backup, 262144)
            original = json.loads(self.backup.read_text())
            desired = wanted(original, p['patch'])
            if digest(normal(current)) == digest(normal(original)):
                # Merge onto current counters rather than resetting traffic totals.
                api.call('/panel/api/inbounds/update/%d' % current['id'], wanted(current, p['patch']))
            elif not subset(normal(desired), normal(current)):
                raise VlessError('vless_conflict')
            _, observed = read(self.store, p['panelId'], p['inboundId'], api=api)
            if not subset(normal(desired), normal(observed)): raise VlessError('vless_api_failed')
            code = 'vless_applying'
        else:
            _, current = read(self.store, p['panelId'], p['inboundId'], api=api)
            from vless import restart
            restart(api)
            original = json.loads(self.backup.read_text())
            if not subset(normal(wanted(original, p['patch'])), normal(current)): raise VlessError('vless_conflict')
            code = 'vless_checking'
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
            self.store.event(req['id'], code, checkpoint + 1, 3)
