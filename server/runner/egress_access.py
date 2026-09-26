"""Dedicated inter-server VLESS credentials, independent of VPN users."""
import copy
import json
from pathlib import Path
import re
import uuid
from urllib.parse import quote, urlencode

import vless
from observed_inbounds import object_field
from egress_config import EgressError, parse_link
from panel import atomic_file, safe_file

ROOT = Path('/var/lib/antirkn-runner/egress-access')


def records():
    if not ROOT.exists(): return []
    meta = ROOT.lstat()
    if ROOT.is_symlink() or not ROOT.is_dir() or meta.st_uid != 0 or meta.st_mode & 0o022:
        raise EgressError('egress_conflict')
    values = []
    for path in sorted(ROOT.glob('*.json'))[:1024]:
        safe_file(path)
        values.append(json.loads(path.read_text()))
    return values


def clients_for(row):
    if not row: return []
    existing = object_field(row.get('settings') or '{}').get('clients', [])
    ids = {r['client']['id']: r['client']['email'] for r in records() if r['inboundId'] == row['id']}
    return [c for c in existing if ids.get(c.get('id')) == c.get('email')]


def decode(req):
    try:
        p = json.loads(req['payload'])
        if set(p) != {'panelId', 'inboundId', 'source', 'endpoint', 'externalPort'}: raise ValueError()
        if not re.fullmatch('[a-f0-9]{32}', p['panelId']): raise ValueError()
        if type(p['inboundId']) is not int or p['inboundId'] < 1: raise ValueError()
        if not isinstance(p['source'], str) or not re.fullmatch(r'[A-Za-z0-9_:-]{1,128}', p['source']): raise ValueError()
        if type(p['externalPort']) is not int or not 1 <= p['externalPort'] <= 65535: raise ValueError()
        if not isinstance(p['endpoint'], str) or len(p['endpoint']) > 253: raise ValueError()
        return p
    except (ValueError, TypeError, KeyError): raise EgressError() from None


def link(row, client, endpoint, port):
    from managed_vless import proxy_fields
    fields, flow = proxy_fields(row)
    stream = object_field(row['streamSettings'])
    network = stream.get('network', 'tcp')
    query = dict(type=network, security=stream['security'], encryption='none',
                 sni=fields.get('servername', ''), fp=fields.get('client-fingerprint', 'chrome'))
    if flow: query['flow'] = flow
    if query['security'] == 'reality':
        query.update(pbk=fields['reality-opts']['public-key'], sid=fields['reality-opts']['short-id'])
    if network == 'xhttp':
        opts = stream.get('xhttpSettings', {})
        query.update(path=opts.get('path', '/'), host=opts.get('host', ''), mode=opts.get('mode', 'auto'))
        extra = {k: v for k, v in opts.items() if k not in ('path', 'host', 'mode', 'extra')}
        extra.update(opts.get('extra') or {})
        if extra: query['extra'] = vless.canonical(extra)
    elif network in ('ws', 'httpupgrade'):
        opts = stream.get(network + 'Settings', {})
        query.update(path=opts.get('path', '/'), host=opts.get('host', '') or opts.get('headers', {}).get('Host', ''))
    elif network == 'grpc':
        opts = stream.get('grpcSettings', {})
        query.update(serviceName=opts.get('serviceName', ''), authority=opts.get('authority', ''))
    if stream['security'] == 'tls' and fields.get('alpn'): query['alpn'] = ','.join(fields['alpn'])
    host = '[' + endpoint + ']' if ':' in endpoint else endpoint
    result = 'vless://' + client['id'] + '@' + host + ':' + str(port) + '?' + urlencode(query) + '#' + quote(row.get('remark', '')[:128])
    parse_link(result)
    return result


def prepare(store, req):
    p = decode(req)
    api = vless.panel_for(store, p['panelId'])
    row = api.call('/panel/api/inbounds/get/%d' % p['inboundId'])
    if not row or row['protocol'] != 'vless' or row.get('enable') is not True:
        raise EgressError('egress_unsupported')
    from managed_vless import proxy_fields
    _, flow = proxy_fields(row)
    key = vless.digest([p['panelId'], p['inboundId'], p['source']])
    saved = next((r for r in records() if r['key'] == key), None)
    uid = saved['client']['id'] if saved else str(uuid.uuid4())
    client = dict(id=uid, email='ar_egress_' + key[:40], enable=True, flow=flow,
                  totalGB=0, expiryTime=0, limitIp=0, tgId=0, subId='', reset=0)
    desired = copy.deepcopy(row)
    settings = object_field(row['settings'])
    matches = [c for c in settings.get('clients', []) if c.get('email') == client['email'] or c.get('id') == uid]
    if matches and (len(matches) != 1 or saved is None or matches[0]['id'] != uid):
        raise EgressError('egress_conflict')
    settings['clients'] = [c for c in settings.get('clients', []) if c not in matches] + [client]
    desired['settings'] = vless.canonical(settings)
    uri = link(row, client, p['endpoint'], p['externalPort'])
    # The plan fingerprint excludes the not-yet-issued random UUID.
    fingerprint = vless.digest(dict(payload=p, before=vless.normal(row), existing=saved))
    return dict(key=key, inboundId=p['inboundId'], panelId=p['panelId'], client=client, previous=saved,
                before=row, after=desired, uri=uri, fingerprint=fingerprint, requestHash=vless.digest(req['payload']))


def plan(store, req):
    return dict(fingerprint=prepare(store, req)['fingerprint'])


class AccessApply:
    def __init__(self, store, req):
        self.store, self.req = store, req
        self.intent = store.directory / ('egress-access-' + req['id'] + '.json')
        self.path = self.intent

    def rollback(self):
        safe_file(self.intent)
        value = json.loads(self.intent.read_text())
        api = vless.panel_for(self.store, value['panelId'])
        current = api.call('/panel/api/inbounds/get/%d' % value['inboundId'])
        if current is None: raise EgressError('egress_conflict')
        settings = object_field(current['settings'])
        entries = settings.get('clients', [])
        matches = [x for x in entries if x.get('id') == value['client']['id'] or x.get('email') == value['client']['email']]
        original = object_field(value['before']['settings']).get('clients', [])
        prior = [x for x in original if x.get('id') == value['client']['id']]
        if matches != prior:
            if len(matches) != 1 or not vless.subset(value['client'], matches[0]):
                raise EgressError('egress_conflict')
            settings['clients'] = [x for x in entries if x not in matches] + prior
            current['settings'] = vless.canonical(settings)
            api.call('/panel/api/inbounds/update/%d' % value['inboundId'], current)
            current = api.call('/panel/api/inbounds/get/%d' % value['inboundId'])
            if not vless.subset(settings, object_field(current['settings'])):
                raise EgressError('egress_conflict')
        record = ROOT / (value['key'] + '.json')
        if value['previous'] is None: record.unlink(missing_ok=True)
        else: atomic_file(record, vless.canonical(value['previous']).encode())
        refresh_observation(self.store, value, current)
        api.call('/panel/api/server/restartXrayService', {})

    def step(self, checkpoint):
        if checkpoint == 0:
            if not self.intent.exists():
                value = prepare(self.store, self.req)
                if value['fingerprint'] != self.req['fingerprint']: raise EgressError('egress_conflict')
                atomic_file(self.intent, vless.canonical(value).encode())
        safe_file(self.intent)
        value = json.loads(self.intent.read_text())
        if value['requestHash'] != vless.digest(self.req['payload']): raise EgressError('egress_conflict')
        if checkpoint > 0:
            api = vless.panel_for(self.store, value['panelId'])
            current = api.call('/panel/api/inbounds/get/%d' % value['inboundId'])
            if not vless.subset(vless.normal(value['after']), vless.normal(current)):
                if vless.normal(current) != vless.normal(value['before']): raise EgressError('egress_conflict')
                api.call('/panel/api/inbounds/update/%d' % value['inboundId'], value['after'])
                current = api.call('/panel/api/inbounds/get/%d' % value['inboundId'])
                if not vless.subset(vless.normal(value['after']), vless.normal(current)):
                    raise EgressError('egress_config_failed')
            ROOT.mkdir(mode=0o700, exist_ok=True)
            atomic_file(ROOT / (value['key'] + '.json'), vless.canonical(
                {k: value[k] for k in ('key', 'panelId', 'inboundId', 'client')}).encode())
            # Record our authorized addition so normal client reconciliation
            # keeps using the same observation and preserves this service user.
            refresh_observation(self.store, value, current)
            if checkpoint == 2: api.call('/panel/api/server/restartXrayService', {})
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, self.req['id']))
            self.store.event(self.req['id'], ('egress_preparing', 'egress_applying', 'egress_checking')[checkpoint], checkpoint + 1, 3)


def refresh_observation(store, value, current):
    for rid, saved in vless.owned_rows(store).items():
        if saved.get('panelId') != value['panelId']: continue
        spec = saved['spec']
        same = (str(value['inboundId']) == spec.get('adoption', {}).get('sourceId') if saved.get('adopted')
                else current.get('remark') == vless.marker(saved['workspaceId'], rid))
        if same:
            saved['observedHash'] = vless.digest(vless.normal(current))
            with store.db:
                store.db.execute('UPDATE vless_resources SET data=? WHERE id=?', (vless.canonical(saved), rid))


def result(store, key):
    row = store.db.execute("SELECT status FROM jobs WHERE id=? AND status='succeeded'", (key,)).fetchone()
    if row is None: raise EgressError('egress_conflict')
    path = store.directory / ('egress-access-' + key + '.json')
    safe_file(path)
    value = json.loads(path.read_text())
    return dict(uri=value['uri'])
