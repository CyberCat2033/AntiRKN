"""Direct exit for selected VLESS inbounds, past the client egress.

A relay inbound serves the owner's own servers, not catalog clients. Its
traffic leaves this server directly: one routing rule per inbound sends it
to a runner-owned freedom outbound, placed before the egress catch-all. One
dedicated service client per inbound (egress_access records) carries the
link; the link is built on request and never stored or logged.
"""
import contextlib
import copy
import json
from pathlib import Path
import re

import vless
from vless import VlessError, canonical, digest, panel_for
from panel import atomic_file, safe_file
from observed_inbounds import object_field
from egress_config import EgressError, TAG as EGRESS_TAG, TAGS as EGRESS_TAGS
import egress_access as access

STATE = Path('/var/lib/antirkn-runner/relay-inbounds.json')
TAG = 'antirkn-relay-direct'
OUTBOUND = dict(tag=TAG, protocol='freedom', settings={})
PREFIX = 'ar_relay_'
# Any syntactically valid public name: the share link check needs a host.
CHECK_HOST = 'relay.invalid'
CODES = ('relay_unsupported', 'relay_client_inbound', 'relay_conflict', 'relay_config_failed',
         'relay_disable_first', 'relay_missing', 'relay_failed')
EVENTS = ('relay_preparing', 'relay_applying', 'relay_checking')


class RelayError(Exception):
    def __init__(self, code='relay_failed'):
        self.code = code


@contextlib.contextmanager
def codes():
    """Shared egress helpers report egress codes; relay callers see their own."""
    try:
        yield
    except EgressError as error:
        code = 'invalid' if error.code == 'egress_invalid' else 'relay_' + error.code[len('egress_'):]
        raise RelayError(code if code in CODES + ('invalid',) else 'relay_failed') from None
    except VlessError as error:
        if error.code == 'relay_disable_first': raise
        raise RelayError('relay_unsupported' if error.code.startswith('vpn_adoption') else 'relay_failed') from None
    except ValueError:
        raise RelayError('relay_failed') from None


def load():
    if not STATE.exists(): return None
    safe_file(STATE)
    return json.loads(STATE.read_text())


def save(info):
    if info: atomic_file(STATE, canonical(info).encode())
    else: STATE.unlink(missing_ok=True)


def entries(info):
    return (info or {}).get('inbounds', [])


def active(panel_id, inbound_id=None):
    return [e for e in entries(load()) if e['panelId'] == panel_id and inbound_id in (None, e['inboundId'])]


def guard(panel_id, inbound_id):
    """A relay inbound must not become client-facing or disappear unnoticed."""
    if active(panel_id, inbound_id): raise VlessError('relay_disable_first')


def key_for(panel_id, inbound_id):
    return digest([panel_id, inbound_id, 'relay'])


def rule(tag):
    return dict(type='field', inboundTag=[tag], outboundTag=TAG)


def configure(template, remove=None, add=None, last=False):
    """Our rule for ``remove`` leaves, one for ``add`` goes right before the
    egress rule (or last). Earlier panel rules keep their priority; foreign
    edits stay. The outbound leaves with the panel's last relay rule.

    ``remove`` is one tag or several: 3x-ui rewrites routing rules when it
    recomputes an inbound tag, so our rule may carry the recorded tag or the
    inbound's current one."""
    if isinstance(remove, str): remove = [remove]
    result = copy.deepcopy(template)
    outbounds = result.setdefault('outbounds', [])
    rules = result.setdefault('routing', {}).setdefault('rules', [])
    found = [x for x in outbounds if x.get('tag') == TAG]
    if found not in ([], [OUTBOUND]): raise RelayError('relay_conflict')
    ours = lambda tag: [x for x in rules if x.get('outboundTag') == TAG and
                        isinstance(x.get('inboundTag'), list) and tag in x['inboundTag']]
    for tag in dict.fromkeys(remove or ()):
        matches = ours(tag)
        # An absent rule is already removed; a changed one is a foreign edit.
        if matches not in ([], [rule(tag)]): raise RelayError('relay_conflict')
        for item in matches: rules.remove(item)
    if add is not None:
        if ours(add): raise RelayError('relay_conflict')
        index = next((i for i, x in enumerate(rules)
                      if x.get('outboundTag') == EGRESS_TAG or x.get('balancerTag') == EGRESS_TAG), len(rules))
        rules.insert(index, rule(add))
        if not found: outbounds.append(copy.deepcopy(OUTBOUND))
    elif last:
        for item in found: outbounds.remove(item)
        if any(x.get('outboundTag') == TAG or x.get('balancerTag') == TAG for x in rules):
            raise RelayError('relay_conflict')
    return result


def inbound(api, inbound_id):
    """The panel's detail row, or None once the inbound is gone."""
    rows = api.call('/panel/api/inbounds/list')
    if not isinstance(rows, list): raise RelayError('relay_failed')
    if not any(r.get('id') == inbound_id for r in rows): return None
    row = api.call('/panel/api/inbounds/get/%d' % inbound_id)
    if not isinstance(row, dict) or row.get('id') != inbound_id: raise RelayError('relay_failed')
    return row


def eligible(store, panel_id, row):
    if row is None: raise RelayError('relay_missing')
    tag = row.get('tag')
    if (row.get('protocol') != 'vless' or row.get('enable') is not True or not isinstance(tag, str)
            or not tag or tag == TAG or tag in EGRESS_TAGS):
        raise RelayError('relay_unsupported')
    # Catalog users would leave past the egress too: only internal inbounds.
    for _, saved in access.owners(store, panel_id, row['id'], row):
        if not saved.get('deleted') and not saved['spec'].get('internal', False):
            raise RelayError('relay_client_inbound')


def decode(raw, fields):
    try:
        p = json.loads(raw)
        if type(p) is not dict or set(p) != fields: raise ValueError()
        if not isinstance(p['panelId'], str) or not re.fullmatch('[a-f0-9]{32}', p['panelId']): raise ValueError()
        if type(p['inboundId']) is not int or p['inboundId'] < 1: raise ValueError()
        if 'enabled' in p and type(p['enabled']) is not bool: raise ValueError()
        if 'observedHash' in p and (not isinstance(p['observedHash'], str)
                                    or not re.fullmatch('[a-f0-9]{64}', p['observedHash'])): raise ValueError()
        if 'endpoint' in p and (not isinstance(p['endpoint'], str) or not 1 <= len(p['endpoint']) <= 253): raise ValueError()
        if 'externalPort' in p and (type(p['externalPort']) is not int or not 1 <= p['externalPort'] <= 65535):
            raise ValueError()
        return p
    except (ValueError, TypeError, KeyError):
        raise RelayError('invalid') from None


def prepare(store, req):
    import client_egress as egress
    import egress_probe as probe
    p = decode(req['payload'], {'panelId', 'inboundId', 'enabled', 'observedHash'})
    old = load()
    if p['observedHash'] != digest(old): raise RelayError('relay_conflict')
    current = entries(old)
    entry = next((e for e in current if (e['panelId'], e['inboundId']) == (p['panelId'], p['inboundId'])), None)
    if not p['enabled'] and entry is None: raise RelayError('relay_missing')
    others = [e for e in current if e is not entry]
    key = key_for(p['panelId'], p['inboundId'])
    with codes():
        api = panel_for(store, p['panelId'])
        template, test_url = egress.read_template(api)
        row = inbound(api, p['inboundId'])
        if p['enabled']:
            eligible(store, p['panelId'], row)
            client, saved, after = access.issue(row, key, PREFIX)
            try:
                access.link(row, client, CHECK_HOST, row['port'])
            except (EgressError, VlessError, KeyError, TypeError, ValueError, AttributeError):
                raise RelayError('relay_unsupported') from None
            desired = configure(template, [entry['tag'], row['tag']] if entry else None, row['tag'])
            probe.validate(desired)
            others.append(dict(panelId=p['panelId'], inboundId=p['inboundId'], tag=row['tag'], key=key))
        else:
            saved = access.record(key)
            # A lost record still leaves the deterministic service email.
            listed = object_field(row['settings']).get('clients', []) if row is not None else []
            client = saved['client'] if saved else next((c for c in listed if c.get('email') == PREFIX + key[:40]), None)
            after = access.revoke(row, client) if row is not None and client else row
            if row is not None and vless.normal(after) == vless.normal(row): after = row
            tags = [entry['tag']] + ([row['tag']] if row is not None and isinstance(row.get('tag'), str) else [])
            desired = configure(template, tags, last=not any(e['panelId'] == p['panelId'] for e in others))
    new = dict(inbounds=sorted(others, key=lambda e: (e['panelId'], e['inboundId']))) if others else None
    value = dict(panelId=p['panelId'], inboundId=p['inboundId'], enabled=p['enabled'], key=key, client=client,
                 previous=saved, before=row, after=after, templateBefore=template, templateAfter=desired,
                 testUrl=test_url, old=old, new=new, requestHash=digest(req['payload']))
    # The fingerprint excludes a not-yet-issued random UUID.
    value['fingerprint'] = digest(dict(payload=p, old=old, template=template, existing=saved,
                                       before=vless.normal(row) if row is not None else None))
    return value


def plan(store, req):
    return dict(fingerprint=prepare(store, req)['fingerprint'])


def public(store):
    """Relay inbounds; ``stale`` once our rule no longer routes the inbound's
    current tag (the inbound is gone, its tag changed without the panel
    following in routing, or the rule was removed)."""
    import client_egress as egress
    info = load()
    panels, result = {}, []
    for e in entries(info):
        if e['panelId'] not in panels:
            with codes():
                api = panel_for(store, e['panelId'])
                rows = api.call('/panel/api/inbounds/list')
                template, _ = egress.read_template(api)
            if not isinstance(rows, list): raise RelayError('relay_failed')
            panels[e['panelId']] = ({r.get('id'): r for r in rows}, template.get('routing', {}).get('rules', []))
        rows, rules = panels[e['panelId']]
        row = rows.get(e['inboundId'])
        tag = row.get('tag') if row is not None and isinstance(row.get('tag'), str) and row.get('tag') else e['tag']
        stale = row is None or rule(tag) not in rules
        result.append(dict(panelId=e['panelId'], inboundId=e['inboundId'], tag=tag, stale=stale))
    return dict(inbounds=result, observedHash=digest(info))


def link(store, req):
    """The service client's share link; the app supplies address and name."""
    p = decode(req['payload'], {'panelId', 'inboundId', 'endpoint', 'externalPort'})
    if not active(p['panelId'], p['inboundId']): raise RelayError('relay_missing')
    with codes():
        saved = access.record(key_for(p['panelId'], p['inboundId']))
        api = panel_for(store, p['panelId'])
        row = inbound(api, p['inboundId'])
        if saved is None or row is None or saved['client']['id'] not in {c.get('id') for c in access.clients_for(row)}:
            raise RelayError('relay_missing')
        uri = access.link(row, saved['client'], p['endpoint'], p['externalPort'])
    return dict(uri=uri.split('#', 1)[0])


class RelayApply:
    def __init__(self, store, req):
        self.store, self.req = store, req
        self.path = store.directory / ('relay-' + req['id'] + '.json')

    def read(self):
        safe_file(self.path, 16 * 1024 * 1024)
        value = json.loads(self.path.read_text())
        if value['requestHash'] != digest(self.req['payload']): raise RelayError('relay_conflict')
        return value

    def template(self, api, wanted, other):
        import client_egress as egress
        current, url = egress.read_template(api)
        if current == wanted: return
        if current != other: raise RelayError('relay_conflict')
        egress.write_template(api, wanted, url)

    def client(self, api, value):
        if value['before'] is None or value['after'] == value['before']:
            current = None
        else:
            current = access.ensure_inbound(api, value['inboundId'], value['before'], value['after'])
        if value['enabled']: access.save_record(value)
        else: access.restore_record(value['key'], None)
        if current is not None: access.refresh_observation(self.store, value, current)

    def effects(self, value):
        """Idempotent: a replay after any partial effect converges."""
        if digest(load()) not in (digest(value['old']), digest(value['new'])): raise RelayError('relay_conflict')
        api = panel_for(self.store, value['panelId'])
        # Enabling routes first, then issues the user; disabling revokes the
        # user first. The user never exists without its direct route.
        if value['enabled']:
            self.template(api, value['templateAfter'], value['templateBefore'])
            self.client(api, value)
        else:
            self.client(api, value)
            self.template(api, value['templateAfter'], value['templateBefore'])
        save(value['new'])
        return api

    def rollback(self):
        import client_egress as egress
        from panel_api import restart_xray
        value = self.read()
        with codes():
            api = panel_for(self.store, value['panelId'])
            current, url = egress.read_template(api)
            if current != value['templateBefore']:
                if current != value['templateAfter']: raise RelayError('relay_conflict')
                egress.write_template(api, value['templateBefore'], url)
            if value['before'] is not None and value['after'] != value['before']:
                row = access.restore_client(api, value['inboundId'], value['client'], value['before'],
                                            readd=not value['enabled'])
                access.refresh_observation(self.store, value, row)
            access.restore_record(value['key'], value['previous'])
            save(value['old'])
            restart_xray(api)

    def step(self, checkpoint):
        from panel_api import restart_xray
        with codes():
            if checkpoint == 0:
                if not self.path.exists():
                    value = prepare(self.store, self.req)
                    if value['fingerprint'] != self.req['fingerprint']: raise RelayError('relay_conflict')
                    atomic_file(self.path, canonical(value).encode())
                self.read()
            else:
                value = self.read()
                api = self.effects(value)
                if checkpoint == 2:
                    import client_egress as egress
                    if egress.read_template(api)[0] != value['templateAfter']: raise RelayError('relay_conflict')
                    if value['before'] is not None:
                        row = inbound(api, value['inboundId'])
                        if row is None or not vless.subset(vless.normal(value['after']), vless.normal(row)):
                            raise RelayError('relay_conflict')
                    restart_xray(api)
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, self.req['id']))
            self.store.event(self.req['id'], EVENTS[checkpoint], checkpoint + 1, 3)
