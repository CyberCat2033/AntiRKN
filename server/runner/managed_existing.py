"""Take client management of discovered resources without rebuilding them.

The consent fingerprint binds the first operation to the inspected resource.
Every later operation compares the last readback. Root-only intent files retain
both sides of the write so a lost reply can be resumed with the same job ID.
"""
import base64
import hashlib
import hmac
import ipaddress
import json
import re

from awg_network import create_key, key_valid
from panel import PanelError, atomic_file, safe_file
from vless import VlessError, canonical, digest

TABLES = {'vless': 'vless_resources', 'awg': 'awg_resources', 'tt': 'tt_resources'}


def validate_payload(p, protocol):
    sources = [r['adoption']['sourceId'] for r in p['resources'] if 'adoption' in r and not r.get('deleted')]
    if len(set(sources)) != len(sources):
        raise VlessError('vpn_adoption_conflict')


def adapter(protocol):
    if protocol == 'vless':
        import managed_vless
        return managed_vless
    if protocol == 'awg':
        import managed_awg
        return managed_awg
    import managed_tt
    return managed_tt


def validate_spec(r, protocol):
    source = r['adoption']['sourceId']
    if not re.fullmatch(r'[1-9][0-9]{0,9}' if protocol == 'vless' else r'[a-f0-9]{32}', source):
        raise VlessError('vpn_adoption_invalid')
    if not r['endpoint'] or r['deleted'] and r['enabled']:
        raise VlessError('vpn_adoption_invalid')
    try:
        address = ipaddress.ip_address(r['endpoint'])
        if address.is_unspecified or address.is_multicast:
            raise VlessError('vpn_adoption_invalid')
    except ValueError:
        if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?', r['endpoint']):
            raise VlessError('vpn_adoption_invalid')


def records(store, protocol):
    return {row['id']: json.loads(row['data']) for row in
            store.db.execute('SELECT * FROM ' + TABLES[protocol])}


def key(store, preview=False):
    path = store.directory / 'adopted-resources.key'
    # Only a missing or crash-truncated key needs the (registry-wide) check.
    in_use = key_valid(path) or any(r.get('adopted') for protocol in TABLES for r in records(store, protocol).values())
    if preview and not key_valid(path):
        if in_use:
            raise VlessError('vpn_adoption_conflict')
        return bytes(32)
    try:
        return create_key(path, in_use)
    except (OSError, ValueError):
        raise VlessError('vpn_adoption_conflict')


def derive(store, p, r, label, preview=False):
    message = '/'.join(['adopted-v1', p['workspaceId'], r['id'], label])
    return hmac.new(key(store, preview), message.encode(), hashlib.sha256).digest()


def user_enabled(r, user):
    return user['enabled'] and r['enabled'] and not r['deleted'] and not r.get('internal', False)


def guard(store, p, r, old, protocol, snapshot):
    validate_spec(r, protocol)
    if (not old or old.get('deleted')) and r.get('deleted'):
        return
    source = r['adoption']['sourceId']
    if protocol == 'vless' and r['adoption']['panelId'] != p['panelId']:
        raise VlessError('vpn_adoption_conflict')
    for rid, other in records(store, protocol).items():
        if rid == r['id']:
            continue
        if other.get('adopted') and not other.get('deleted') and other['spec']['adoption']['sourceId'] == source and (
                protocol != 'vless' or other.get('panelId') == p['panelId']):
            raise VlessError('vpn_adoption_conflict')
    if old:
        if (not old.get('adopted') or old['workspaceId'] != p['workspaceId'] or
                old['spec']['adoption'] != r['adoption'] or
                protocol == 'vless' and old['panelId'] != p['panelId']):
            raise VlessError('vpn_adoption_conflict')
        if snapshot['fingerprint'] != old['observedHash'] and not r.get('deleted'):
            raise VlessError('vpn_adoption_conflict')
        if old['keyId'] != hashlib.sha256(key(store)).hexdigest():
            raise VlessError('vpn_adoption_conflict')
        # Imported server settings stay authoritative; the compact editor only
        # changes the name, connection address and the app's access switch.
        mutable = {'name', 'endpoint', 'externalPort', 'enabled', 'internal', 'deleted'}
        if {k: v for k, v in r.items() if k not in mutable} != {
                k: v for k, v in old['spec'].items() if k not in mutable}:
            raise VlessError('vpn_adoption_conflict')
    elif snapshot['fingerprint'] != r['adoption']['observedHash'] or r['deleted']:
        raise VlessError('vpn_adoption_conflict')


def preflight(store, p, r, old, protocol, inbounds=None):
    if r.get('deleted') and (not old or old.get('deleted')):
        return old.get('observedHash') if old else None
    a = adapter(protocol)
    current = (a.snapshot(store, p, r, inbounds=inbounds,
                          expected_hash=old['observedHash'] if old else r['adoption']['observedHash'])
               if protocol == 'vless' else a.snapshot(store, p, r))
    guard(store, p, r, old, protocol, current)
    a.build(store, p, r, old, current, preview=True)
    return current['fingerprint']


def apply(store, req, p, r, old, protocol, checkpoint):
    if r.get('deleted') and (not old or old.get('deleted')):
        record = dict(old) if old else dict(
            adopted=True, deleted=True, workspaceId=p['workspaceId'],
            spec=r, clients=[], proxy={},
        )
        if protocol == 'vless':
            record['panelId'] = p['panelId']
        record['revision'] = digest(p)
        record['jobId'] = req['id']
        with store.db:
            store.db.execute('INSERT INTO ' + TABLES[protocol] + ' VALUES (?,?) '
                             'ON CONFLICT(id) DO UPDATE SET data=excluded.data', (r['id'], canonical(record)))
            store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
            store.event(req['id'], protocol + '_applying', checkpoint + 1, req['count'])
        return
    a = adapter(protocol)
    path = store.directory / ('adopt-' + req['id'] + '-' + r['id'] + '.json')
    if not path.exists():
        current = (a.snapshot(store, p, r, expected_hash=old['observedHash'] if old else r['adoption']['observedHash'])
                   if protocol == 'vless' else a.snapshot(store, p, r))
        guard(store, p, r, old, protocol, current)
        key(store)
        intent = a.build(store, p, r, old, current)
        if protocol == 'vless' and r['deleted'] and current['row'] is not None:
            from panel_clients import capture
            from vless import panel_for
            api = panel_for(store, p['panelId'])
            intent['cleanupClients'] = capture(current['row'], api.call('/panel/api/clients/list'))
        intent['keyId'] = hashlib.sha256(key(store)).hexdigest()
        intent['requestHash'] = digest(dict(payload=p, protocol=protocol, resource=r['id']))
        atomic_file(path, canonical(intent).encode())
    safe_file(path)
    intent = json.loads(path.read_text())
    if intent['requestHash'] != digest(dict(payload=p, protocol=protocol, resource=r['id'])):
        raise VlessError('vpn_adoption_conflict')
    if intent['keyId'] != hashlib.sha256(key(store)).hexdigest():
        raise VlessError('vpn_adoption_conflict')
    # The registry may only still contain the pre-write version or this job's
    # own committed revision. A stale resumed job cannot overtake another job.
    if digest(old) != intent['oldHash']:
        raise VlessError('vpn_adoption_conflict')
    a.apply(store, p, r, intent, marker=path.with_name(path.stem + '.restart'))
    observed = (a.snapshot(store, p, r, prefer_detail=True) if protocol == 'vless'
                else a.snapshot(store, p, r))
    if not a.verify(observed, intent):
        raise VlessError('vpn_adoption_failed')
    if protocol == 'vless' and r['deleted']:
        from panel_clients import cleanup
        from vless import panel_for
        cleanup(panel_for(store, p['panelId']), intent.get('cleanupClients', []))
    data = dict(intent['record'], adopted=True, deleted=r['deleted'], workspaceId=p['workspaceId'],
                panelId=p['panelId'], spec=r, revision=digest(p),
                keyId=intent['keyId'], jobId=req['id'],
                observedHash=observed['fingerprint'])
    if protocol != 'vless':
        data['source'] = a.locator(observed)
    with store.db:
        store.db.execute('INSERT INTO ' + TABLES[protocol] + ' VALUES (?,?) '
                         'ON CONFLICT(id) DO UPDATE SET data=excluded.data', (r['id'], canonical(data)))
        store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
        store.event(req['id'], protocol + '_applying', checkpoint + 1, req['count'])


def restore(store, req, p, r, old, protocol):
    """Undo a failed adoption step on the server (see the adapters'
    ``restore``). True: the resource is as inspected before the step; None:
    it holds a foreign change and was left alone. Raises if restoring failed."""
    if r.get('deleted') and (not old or old.get('deleted')):
        return True
    path = store.directory / ('adopt-' + req['id'] + '-' + r['id'] + '.json')
    if not path.exists():
        return True  # The intent precedes every write.
    safe_file(path)
    intent = json.loads(path.read_text())
    if intent['requestHash'] != digest(dict(payload=p, protocol=protocol, resource=r['id'])):
        return None
    return adapter(protocol).restore(store, p, r, intent, marker=path.with_name(path.stem + '.restart'))


def source_of(store, saved, protocol):
    """Where an adopted AWG/TT resource lives: recorded since this release,
    or read from the intent of the job the record references."""
    if saved.get('source'):
        return saved['source']
    if not saved.get('jobId'):
        return None
    path = store.directory / ('adopt-' + saved['jobId'] + '-' + saved['spec']['id'] + '.json')
    try:
        safe_file(path)
        return adapter(protocol).locator(json.loads(path.read_text())['before'])
    except (OSError, ValueError, KeyError, TypeError, PanelError):
        return None


def state(store, saved, protocol, pending_job=None, inbounds=None, found=None):
    """``inbounds`` (VLESS) and ``found`` (AWG/TT discovery) are shared by all
    resources of one poll instead of being read again for each of them."""
    p = {'workspaceId': saved['workspaceId'], 'panelId': saved.get('panelId')}
    row = None
    gone = False
    try:
        a = adapter(protocol)
        if protocol == 'vless':
            observed = a.snapshot(store, p, saved['spec'], inbounds=inbounds, expected_hash=saved.get('observedHash'))
        elif found is None:
            observed = a.snapshot(store, p, saved['spec'])
        else:
            observed = a.snapshot(store, p, saved['spec'], found=found)
        row = observed.get('row') if protocol == 'vless' else observed.get('resource')
    except VlessError as error:
        if getattr(error, 'code', None) not in ('vpn_adoption_conflict', 'awg_conflict', 'tt_conflict'):
            raise
        # The panel list is authoritative for VLESS. AWG/TT discovery also
        # misses a stopped container or an unsupported binary: only a resource
        # positively gone is forgotten, otherwise it is merely unconfirmed.
        gone = (protocol == 'vless' or bool(saved.get('deleted')) or
                adapter(protocol).absent(source_of(store, saved, protocol)))
    if row is None and gone and not saved.get('deleted'):
        saved['deleted'] = True
        saved['observedHash'] = None
        with store.db:
            store.db.execute('INSERT INTO ' + TABLES[protocol] + ' VALUES (?,?) '
                             'ON CONFLICT(id) DO UPDATE SET data=excluded.data',
                             (saved['spec']['id'], canonical(saved)))
    if saved.get('deleted'):
        confirmed = (row is None)
        if not confirmed and saved.get('jobId'):
            job = store.db.execute('SELECT status FROM jobs WHERE id=?', (saved['jobId'],)).fetchone()
            confirmed = job is not None and (
                job['status'] == 'succeeded' or saved['jobId'] == pending_job)
    elif row is None:
        confirmed = False  # Not readable now, not known to be gone.
    else:
        try:
            if protocol == 'vless' and observed['fingerprint'] != saved['observedHash']:
                observed = recover_vless_readback(store, saved, observed)
            confirmed = observed['fingerprint'] == saved['observedHash']
            confirmed = confirmed and adapter(protocol).healthy(observed)
            job = store.db.execute('SELECT status FROM jobs WHERE id=?', (saved['jobId'],)).fetchone()
            # Public readback must wait for the enclosing job's final restart and
            # verification, including when another device first discovers this row.
            confirmed = confirmed and job is not None and (
                job['status'] == 'succeeded' or saved['jobId'] == pending_job)
        except (VlessError, OSError, ValueError, KeyError):
            confirmed = False
    return dict(id=saved['spec']['id'], workspaceId=saved['workspaceId'],
                spec=saved['spec'], confirmed=confirmed,
                deleted=bool(saved.get('deleted')), exists=(row is not None or not gone and not saved.get('deleted')),
                clients=saved.get('clients', []),
                proxy=saved.get('proxy', {}), revision=saved.get('revision', ''))


def recover_vless_readback(store, saved, observed):
    """Rebind an older list fingerprint only to this job's verified intent."""
    if observed['row'] is None or not saved.get('jobId'):
        return observed
    job = store.db.execute('SELECT request, status FROM jobs WHERE id=?', (saved['jobId'],)).fetchone()
    if job is None or job['status'] not in ('running', 'partially_applied', 'succeeded'):
        return observed
    try:
        request = json.loads(job['request'])
        if request.get('kind') != 'vless_apply':
            return observed
        import vless
        payload = vless.parse_payload(request['payload'])
        resource = next((r for r in payload['resources'] if r['id'] == saved['spec']['id']), None)
        if (resource != saved['spec'] or payload['workspaceId'] != saved['workspaceId']
                or payload['panelId'] != saved['panelId'] or digest(payload) != saved['revision']):
            return observed
        path = store.directory / ('adopt-' + saved['jobId'] + '-' + resource['id'] + '.json')
        safe_file(path)
        intent = json.loads(path.read_text())
        if (intent['requestHash'] != digest(dict(payload=payload, protocol='vless', resource=resource['id']))
                or intent['keyId'] != saved['keyId']
                or intent['record']['clients'] != saved['clients']
                or intent['record']['proxy'] != saved['proxy']):
            return observed
        detail = adapter('vless').snapshot(store, payload, resource, prefer_detail=True)
        if not adapter('vless').verify(detail, intent):
            return observed
        saved['observedHash'] = detail['fingerprint']
        with store.db:
            store.db.execute('INSERT INTO vless_resources VALUES (?,?) '
                             'ON CONFLICT(id) DO UPDATE SET data=excluded.data',
                             (resource['id'], canonical(saved)))
        return detail
    except (OSError, ValueError, KeyError, TypeError, PanelError, VlessError):
        return observed


def intent(old, snapshot, after, clients, proxy):
    return dict(oldHash=digest(old), before=snapshot, after=after,
                record=dict(clients=clients, proxy=proxy))


def b64(value):
    return base64.b64encode(value).decode()
