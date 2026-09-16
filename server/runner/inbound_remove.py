"""Explicit bulk removal of external inbounds, guarded by their full snapshots."""
import json
import re
import time
from panel import atomic_file, safe_file
from vless import VlessError, canonical, digest, normal, panel_for


def decode(raw):
    p = json.loads(raw)
    if type(p) is not dict or set(p) - {'removals', 'panelId'}:
        raise VlessError()
    if 'panelId' in p and (type(p['panelId']) is not str or not re.fullmatch('[a-f0-9]{32}', p['panelId'])):
        raise VlessError()
    entries = p.get('removals')
    if type(entries) is not list or not 1 <= len(entries) <= 1000:
        raise VlessError()
    seen = set()
    for entry in entries:
        if (type(entry) is not dict or set(entry) != {'inboundId', 'observedHash'}
                or type(entry['inboundId']) is not int or entry['inboundId'] < 1
                or entry['inboundId'] in seen or type(entry['observedHash']) is not str
                or not re.fullmatch('[a-f0-9]{64}', entry['observedHash'])):
            raise VlessError()
        seen.add(entry['inboundId'])
    return p


def check(row, entry):
    if (row is None or row.get('remark', '').startswith('AntiRKN:')
            or digest(normal(row)) != entry['observedHash']):
        raise VlessError('vless_conflict')


def preflight(store, panel_id, payload):
    api = panel_for(store, panel_id)
    rows = {row['id']: row for row in api.call('/panel/api/inbounds/list')}
    for entry in payload['removals']:
        check(rows.get(entry['inboundId']), entry)
    return dict(fingerprint=digest(dict(panelId=panel_id, removals=payload['removals'])),
                deletes=len(payload['removals']))


def plan(store, req):
    return preflight(store, req['id'], decode(req['payload']))


class InboundRemove:
    def __init__(self, store, req):
        self.store, self.req = store, req
        self.payload = decode(req['payload'])
        if 'panelId' not in self.payload:
            raise VlessError()
        self.backup = store.directory / ('inbound-removal-' + req['id'] + '.json')

    def step(self, checkpoint):
        p = self.payload
        api = panel_for(self.store, p['panelId'])
        if checkpoint == 0:
            if preflight(self.store, p['panelId'], p)['fingerprint'] != self.req['fingerprint']:
                raise VlessError('vless_conflict')
            # Authorize the exact set before the first effect. No credentials in journal.
            if not self.backup.exists():
                atomic_file(self.backup, canonical(p).encode())
        else:
            safe_file(self.backup, 262144)
            if json.loads(self.backup.read_text()) != p:
                raise VlessError('vless_conflict')
            if checkpoint == 1:
                for entry in p['removals']:
                    rows = {r['id']: r for r in api.call('/panel/api/inbounds/list')}
                    current = rows.get(entry['inboundId'])
                    # A lost reply is reconciled by reading back; never delete a reused ID.
                    if current is not None:
                        check(current, entry)
                        api.call('/panel/api/inbounds/del/%d' % entry['inboundId'], {})
                    if any(r['id'] == entry['inboundId'] for r in api.call('/panel/api/inbounds/list')):
                        raise VlessError('vless_api_failed')
            else:
                api.call('/panel/api/server/restartXrayService', {})
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    if api.call('/panel/api/server/status').get('xray', {}).get('state') == 'running':
                        break
                    time.sleep(.25)
                else:
                    raise VlessError('vless_api_failed')
                ids = {r['id'] for r in api.call('/panel/api/inbounds/list')}
                if any(e['inboundId'] in ids for e in p['removals']):
                    raise VlessError('vless_conflict')
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, self.req['id']))
            self.store.event(self.req['id'], ('vless_preparing', 'vless_applying', 'vless_checking')[checkpoint], checkpoint + 1, 3)
