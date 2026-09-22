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
import os
import re
import secrets

from panel import atomic_file, safe_file
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
    if not path.exists():
        if any(r.get('adopted') for protocol in TABLES for r in records(store, protocol).values()):
            raise VlessError('vpn_adoption_conflict')
        if preview:
            return bytes(32)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(secrets.token_bytes(32))
            stream.flush()
            os.fsync(stream.fileno())
    safe_file(path, 32)
    result = path.read_bytes()
    if len(result) != 32:
        raise VlessError('vpn_adoption_conflict')
    return result


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


def preflight(store, p, r, old, protocol):
    if r.get('deleted') and (not old or old.get('deleted')):
        return old.get('observedHash') if old else None
    a = adapter(protocol)
    current = a.snapshot(store, p, r)
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
        current = a.snapshot(store, p, r)
        guard(store, p, r, old, protocol, current)
        key(store)
        intent = a.build(store, p, r, old, current)
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
    a.apply(store, p, r, intent)
    observed = a.snapshot(store, p, r)
    if not a.verify(observed, intent):
        raise VlessError('vpn_adoption_failed')
    data = dict(intent['record'], adopted=True, deleted=r['deleted'], workspaceId=p['workspaceId'],
                panelId=p['panelId'], spec=r, revision=digest(p),
                keyId=intent['keyId'], jobId=req['id'],
                observedHash=observed['fingerprint'])
    with store.db:
        store.db.execute('INSERT INTO ' + TABLES[protocol] + ' VALUES (?,?) '
                         'ON CONFLICT(id) DO UPDATE SET data=excluded.data', (r['id'], canonical(data)))
        store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
        store.event(req['id'], protocol + '_applying', checkpoint + 1, req['count'])


def state(store, saved, protocol, pending_job=None):
    p = {'workspaceId': saved['workspaceId'], 'panelId': saved.get('panelId')}
    row = None
    try:
        observed = adapter(protocol).snapshot(store, p, saved['spec'])
        row = observed.get('row') if protocol == 'vless' else observed.get('resource')
    except VlessError as error:
        if getattr(error, 'code', None) in ('vpn_adoption_conflict', 'awg_conflict', 'tt_conflict'):
            row = None
        else:
            raise
    if row is None and not saved.get('deleted'):
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
    else:
        try:
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
                deleted=bool(saved.get('deleted')), exists=(row is not None),
                clients=saved.get('clients', []),
                proxy=saved.get('proxy', {}), revision=saved.get('revision', ''))


def intent(old, snapshot, after, clients, proxy):
    return dict(oldHash=digest(old), before=snapshot, after=after,
                record=dict(clients=clients, proxy=proxy))


def b64(value):
    return base64.b64encode(value).decode()
