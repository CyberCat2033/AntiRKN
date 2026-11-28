"""Short-lived diagnostic credentials; durable cleanup precedes every mutation.

Private records are separate from managed clients, sync and profile publication.
Each resource remains exclusively leased until cleanup is verified.
"""
from contextlib import contextmanager
import copy
import fcntl
import json
import os
from pathlib import Path
import re
import random
import secrets
import socket
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import awg
import tt
import vless
import managed_awg
import managed_existing
from panel import atomic_file, command, safe_file, PanelError
from tt_common import toml_bytes, toml_loads

TTL = 900
UNITS = Path('/etc/systemd/system')
# FR-SNI: a temporary REALITY inbound for one chosen target. Its remark keeps
# every "AntiRKN:" guard (no edit, removal or adoption as an external row);
# discovery hides it from the app.
TARGET_MARK = 'AntiRKN:probe:'
TARGET_PORTS = (20000, 61000)
_HOST = re.compile(r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+')
# A closed record (no credentials left) answers repeated probe_end calls for a
# while, then goes: every RPC scans this directory.
CLOSED_RETENTION = 24 * 3600


class ProbeError(Exception):
    def __init__(self, code='probe_failed'):
        self.code = code



def client_api(api, path, body, legacy_path, legacy_body):
    """Client routes by what the panel serves, not by a list of versions.

    3x-ui 3.7+ has /panel/api/clients/*, and 3.11 removed the per-inbound
    routes; a fixed version list sent every newer panel to the removed ones.
    """
    import urllib.error
    try:
        return api.call(path, body)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    return api.call(legacy_path, legacy_body)

def identifier(value):
    if not isinstance(value, str) or not re.fullmatch('[a-f0-9]{32}', value):
        raise ProbeError('probe_invalid')
    return value


def directory(store):
    path = store.directory / 'connectivity-probes'
    path.mkdir(mode=0o700, exist_ok=True)
    if path.is_symlink():
        raise ProbeError('probe_invalid')
    return path


@contextmanager
def operation_lock(store, timeout=10):
    fd = os.open(directory(store) / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    deadline = time.monotonic() + timeout
    acquired = False
    try:
        while time.monotonic() < deadline:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except (BlockingIOError, OSError):
                time.sleep(0.05)
        if not acquired:
            raise ProbeError('probe_busy')
        yield
    finally:
        if acquired:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        os.close(fd)


def load(store, key):
    path = directory(store) / (identifier(key) + '.json')
    if not path.exists():
        return None
    try:
        safe_file(path, 4 * 1024 * 1024)
        return json.loads(path.read_text())
    except (PanelError, OSError, ValueError):
        raise ProbeError('probe_invalid') from None


def save(store, info):
    atomic_file(directory(store) / (identifier(info['id']) + '.json'), vless.canonical(info).encode())


def prune(store, now=None):
    """Drop closed records past CLOSED_RETENTION. Open ones always stay."""
    now = time.time() if now is None else now
    for path in directory(store).glob('*.json'):
        try:
            info = load(store, path.stem)
            if info and info.get('status') == 'closed' and now - info.get('closedAt', path.stat().st_mtime) >= CLOSED_RETENTION:
                path.unlink(missing_ok=True)
        except (ProbeError, OSError):
            continue


def active(store):
    for p in directory(store).glob('*.json'):
        try:
            info = load(store, p.stem)
            if info.get('status') != 'closed':
                if info.get('expires', 0) < time.time():
                    continue
                return True
        except Exception:
            continue
    return False


def arm(info):
    source = str(Path(__file__).resolve())
    if not re.fullmatch('/[A-Za-z0-9_./-]+', source):
        raise ProbeError()
    name = 'antirkn-probe-' + identifier(info['id']) + '.service'
    atomic_file(UNITS / name, (
        '[Unit]\nDescription=AntiRKN temporary access cleanup\nAfter=local-fs.target\nStartLimitIntervalSec=0\n'
        '[Service]\nType=simple\nUMask=0077\nRestart=on-failure\nRestartSec=3\n'
        f'ExecStart=/usr/bin/python3 -I {source} watchdog {info["id"]}\n'
        '[Install]\nWantedBy=multi-user.target\n').encode(), 0o644)
    command(['/usr/bin/systemctl', 'daemon-reload'])
    command(['/usr/bin/systemctl', 'enable', '--now', name])
    command(['/usr/bin/systemctl', 'is-active', '--quiet', name])


def retire_unit(name):
    """Remove a watchdog unit; idempotent (disabled, not loaded or gone is fine).

    Never stops it: the watchdog itself runs in that unit's cgroup."""
    path = UNITS / name
    wanted = UNITS / 'multi-user.target.wants' / name
    if not (path.exists() or path.is_symlink() or wanted.is_symlink()):
        return
    try:
        command(['/usr/bin/systemctl', 'disable', name])
    except PanelError:
        pass  # Not loaded any more: removing the files below is all that is left.
    wanted.unlink(missing_ok=True)
    path.unlink(missing_ok=True)
    try:
        command(['/usr/bin/systemctl', 'daemon-reload'])
    except PanelError:
        pass  # The unit file is gone; the next reload forgets it.


def retire(key):
    retire_unit('antirkn-probe-' + identifier(key) + '.service')


def users(saved, key):
    if any(c['id'] == key for c in saved['clients']):
        raise ProbeError('probe_invalid')
    return [dict(id=c['id'], login=c.get('username', 'probe-' + c['id']), enabled=c['enabled'])
            for c in saved['clients']] + [dict(id=key, login='probe-' + key, enabled=True)]


def record(store, payload):
    if set(payload) not in ({'protocol', 'resource', 'workspace', 'spec'}, {'protocol', 'resource', 'workspace', 'spec', 'external'}) or payload['protocol'] not in ('vless', 'awg', 'tt'):
        raise ProbeError('probe_invalid')
    rid = identifier(payload['resource'])
    identifier(payload['workspace'])
    protocol = payload['protocol']
    records = dict(vless=vless.owned_rows, awg=awg.owned, tt=tt.owned)[protocol](store)
    saved = records.get(rid)
    if payload.get('external') is True:
        spec = payload['spec']
        if saved or spec.get('id') != rid or not spec.get('adoption'):
            raise ProbeError('probe_invalid')
        p = dict(version=1, workspaceId=payload['workspace'], panelId=spec['adoption'].get('panelId', payload['workspace']), users=[], resources=[spec])
        if protocol != 'vless': p['protocol'] = protocol
        dict(vless=vless, awg=awg, tt=tt)[protocol].parse_payload(json.dumps(p))
        if not spec['enabled'] or spec['deleted']:
            raise ProbeError('probe_changed')
        return dict(spec=spec, workspaceId=payload['workspace'], panelId=p['panelId'], clients=[], adopted=True, ephemeral=True, revision=spec['adoption']['observedHash'])
    if (not saved or saved['workspaceId'] != payload['workspace'] or saved['spec'] != payload['spec'] or
            saved['spec'].get('deleted') or not saved['spec'].get('enabled')):
        raise ProbeError('probe_changed')
    if protocol == 'vless' and saved['spec'].get('internal'):
        raise ProbeError('probe_route')
    return saved


def target_request(payload):
    """Exactly {protocol, panel, target, sni}; Target is the SNI with a port."""
    if (type(payload) is not dict or set(payload) != {'protocol', 'panel', 'target', 'sni'}
            or payload['protocol'] != 'reality_target'):
        raise ProbeError('probe_invalid')
    sni, target = payload['sni'], payload['target']
    if type(sni) is not str or type(target) is not str or len(sni) > 253 or not _HOST.fullmatch(sni):
        raise ProbeError('probe_invalid')
    host, _, port = target.rpartition(':')
    if host != sni or not port.isdigit() or port != str(int(port)) or not 1 <= int(port) <= 65535:
        raise ProbeError('probe_invalid')
    identifier(payload['panel'])
    return payload


def free_port(rows):
    used = {row.get('port') for row in rows}
    for port in random.SystemRandom().sample(range(*TARGET_PORTS), 64):
        if port in used:
            continue
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.bind(('0.0.0.0', port))
        except OSError:
            continue
        return port
    raise ProbeError('probe_busy')


def prepare_target(store, request):
    payload = target_request(json.loads(request['payload']))
    key = identifier(request['id'])
    api = vless.panel_for(store, payload['panel'])
    rows = api.call('/panel/api/inbounds/list')
    if not isinstance(rows, list):
        raise ProbeError()
    expires = time.time() + TTL
    spec = dict(id=key, enabled=True, listen='', port=free_port(rows), transport='raw', security='reality',
                target=payload['target'], sni=payload['sni'], fingerprint='chrome')
    # The same inbound a managed REALITY resource gets, with probe identity.
    wanted = vless.wanted_inbound(dict(workspaceId='probe', users=[dict(id=key, enabled=True)]), spec)
    settings = json.loads(wanted['settings'])
    client = settings['clients'][0]
    client.update(email='ar_probe_' + key, expiryTime=int(expires * 1000))
    wanted.update(remark=TARGET_MARK + key, settings=vless.canonical(settings))
    keys = vless.material('probe', key)
    observed = dict(spec, endpoint='', externalPort=spec['port'])
    observation = dict(id=key, workspaceId='probe', confirmed=True, spec=observed, revision=vless.digest(wanted),
                       publicKey=keys['publicKey'], shortId=keys['shortId'],
                       clients=[dict(id=key, uuid=client['id'], enabled=True)])
    return dict(id=key, status='prepared', requestHash=vless.digest(payload), protocol='reality_target',
                backend='reality_target', panelId=payload['panel'], wanted=wanted, port=spec['port'],
                email=client['email'], expires=expires, observation=observation)


def target_rows(api, info):
    rows = api.call('/panel/api/inbounds/list')
    if not isinstance(rows, list):
        raise ProbeError()
    return [row for row in rows if row.get('remark') == info['wanted']['remark']]


def listening(port, timeout=8):
    """3x-ui adds an enabled inbound to the running Xray without a restart;
    the probe never restarts Xray, so other clients stay connected."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.5):
                return
        except OSError:
            time.sleep(.25)
    raise ProbeError('probe_failed')


def drop_client_record(api, email):
    """3x-ui 3.7+ keeps clients in their own table; an inbound deletion may
    leave ours there. Older panels have no such table (404)."""
    import urllib.error
    from urllib.parse import quote
    try:
        records = api.call('/panel/api/clients/list')
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return
        raise
    if not isinstance(records, list):
        raise ProbeError('probe_cleanup')
    record = next((r for r in records if isinstance(r, dict) and r.get('email') == email), None)
    if record is None:
        return
    if record.get('inboundIds'):
        raise ProbeError('probe_cleanup')
    api.call('/panel/api/clients/del/' + quote(email, safe=''), {})
    after = api.call('/panel/api/clients/list')
    if not isinstance(after, list) or any(isinstance(r, dict) and r.get('email') == email for r in after):
        raise ProbeError('probe_cleanup')


def prepare(store, request):
    payload = json.loads(request['payload'])
    if type(payload) is dict and payload.get('protocol') == 'reality_target':
        return prepare_target(store, request)
    saved = record(store, payload)
    key, protocol, spec = identifier(request['id']), payload['protocol'], saved['spec']
    p = dict(workspaceId=saved['workspaceId'], panelId=saved.get('panelId', saved['workspaceId']),
             users=users(saved, key), resources=[spec])
    info = dict(id=key, status='prepared', requestHash=vless.digest(payload), protocol=protocol,
                payload=p, saved=saved, expires=time.time() + TTL)
    observation = dict(id=spec['id'], workspaceId=saved['workspaceId'], confirmed=True, spec=spec,
                       revision=saved['revision'])
    if saved.get('adopted'):
        adapter = managed_existing.adapter(protocol)
        before = adapter.snapshot(store, p, spec)
        old = None if saved.get('ephemeral') else saved
        managed_existing.guard(store, p, spec, old, protocol, before)
        plan = adapter.build(store, p, spec, old, before)
        info.update(backend='adopted', plan=plan)
        observation.update(plan['record'])
        if protocol == 'vless':
            settings = json.loads(plan['after']['settings'])
            diagnostic = next(c for c in plan['record']['clients'] if c['id'] == key)
            for client in settings['clients']:
                if client['id'] == diagnostic['uuid']:
                    client['expiryTime'] = int(info['expires'] * 1000)
                    client['email'] = 'ar_probe_' + key
                    info['email'] = client['email']
            plan['after']['settings'] = vless.canonical(settings)
            info['rowId'] = plan['before']['row']['id']
    elif protocol == 'vless':
        api = vless.panel_for(store, saved['panelId'])
        rows = api.call('/panel/api/inbounds/list')
        row = vless.locate(rows, saved['workspaceId'], spec['id'])
        # The same ownership check as a VLESS apply: the saved readback came
        # from /get/:id, and the list of a newer panel (3.11) adds fields.
        if not vless.matches_observation(api, row, saved['workspaceId'], spec['id'], saved['observedHash']):
            raise ProbeError('probe_changed')
        flow = 'xtls-rprx-vision' if spec['transport'] == 'raw' else ''
        client = dict(id=str(uuid.uuid4()), email='ar_probe_' + key, enable=True, flow=flow,
                      totalGB=0, expiryTime=int(info['expires'] * 1000), limitIp=0, tgId=0, subId='', reset=0)
        info.update(backend='vless', rowId=row['id'], email=client['email'], beforeHash=vless.digest(vless.normal(row)), client=client)
        observation.update(publicKey=saved['publicKey'], shortId=saved['shortId'],
                           clients=[dict(id=key, uuid=client['id'], enabled=True)])
    elif protocol == 'awg':
        if not awg.confirmed(saved):
            raise ProbeError('probe_changed')
        after, config, _ = awg.desired(p, spec, saved)
        path = awg.paths(spec['id'])[0]
        info.update(backend='awg', before=path.read_text(), after=config.decode())
        observation.update(publicKey=after['publicKey'], headerProtectionKey=after['headerProtectionKey'], clients=after['clients'])
    else:
        if not tt.confirmed(saved):
            raise ProbeError('probe_changed')
        after, data = tt.desired(p, spec, saved)
        path = tt.paths(spec['id'])[2]
        info.update(backend='tt', before=path.read_text(), after=data[2].decode())
        observation.update(clients=after['clients'])
    observation['clients'] = [c for c in observation['clients'] if c['id'] == key]
    if len(observation['clients']) != 1:
        raise ProbeError()
    info['observation'] = observation
    return info


def vless_row(store, info):
    api = vless.panel_for(store, info['saved']['panelId'])
    row = next((r for r in api.call('/panel/api/inbounds/list') if r['id'] == info['rowId']), None)
    if row is None:
        raise ProbeError('probe_changed')
    return api, row


def sync_awg(rid, data):
    core = b''.join(line for line in data.encode().splitlines(keepends=True)
                    if line.split(b'=', 1)[0].strip() not in managed_awg.QUICK)
    command([awg.AWG, 'syncconf', awg.name_for(rid), '/dev/stdin'], input_data=core)


def fingerprint(store, info):
    if info['backend'] == 'reality_target':
        rows = target_rows(vless.panel_for(store, info['panelId']), info)
        if len(rows) != 1:
            raise ProbeError('probe_changed')
        return vless.digest(vless.normal(rows[0]))
    backend, rid = info['backend'], info['saved']['spec']['id']
    if backend == 'adopted':
        adapter = managed_existing.adapter(info['protocol'])
        snapshot = adapter.snapshot(store, info['payload'], info['saved']['spec'])
        if info['protocol'] == 'vless':
            # The raw panel row includes traffic counters/clientStats which the
            # probe itself changes. Use the adapter's semantic settings hash.
            return snapshot['fingerprint']
        if info['protocol'] == 'awg' and snapshot.get('runtime') is not None:
            snapshot['runtime'] = awg.runtime_config(snapshot['runtime'].encode())
        return vless.digest(snapshot)
    if backend == 'vless':
        return vless.digest(vless.normal(vless_row(store, info)[1]))
    if backend == 'awg':
        return vless.digest([awg.current_hashes(rid), awg.runtime_config(command([awg.AWG, 'showconf', awg.name_for(rid)]))])
    return vless.digest(tt.current_hashes(rid))


def apply(store, info):
    if info['backend'] == 'reality_target':
        api = vless.panel_for(store, info['panelId'])
        rows = target_rows(api, info)
        if not rows:
            listed = api.call('/panel/api/inbounds/list')
            if any(row.get('port') == info['port'] for row in listed):
                raise ProbeError('probe_busy')
            api.call('/panel/api/inbounds/add', info['wanted'])
            rows = target_rows(api, info)
        if len(rows) != 1:
            raise ProbeError()
        listening(info['port'])
        info['afterHash'] = vless.digest(vless.normal(rows[0]))
        info['status'] = 'active'
        save(store, info)
        return
    backend, spec = info['backend'], info['saved']['spec']
    if backend == 'adopted':
        adapter = managed_existing.adapter(info['protocol'])
        adapter.apply(store, info['payload'], spec, info['plan'])
        if not adapter.verify(adapter.snapshot(store, info['payload'], spec), info['plan']):
            raise ProbeError()
    elif backend == 'vless':
        api, row = vless_row(store, info)
        normalized = vless.normal(row)
        clients = normalized['settings']['clients']
        present = any(c['id'] == info['client']['id'] for c in clients)
        normalized['settings']['clients'] = [c for c in clients if c['id'] != info['client']['id']]
        if vless.digest(normalized) != info['beforeHash']:
            raise ProbeError('probe_changed')
        if not present:
            client_api(api, '/panel/api/clients/add', dict(inboundIds=[row['id']], client=info['client']),
                       '/panel/api/inbounds/addClient', dict(id=row['id'], settings=vless.canonical({'clients': [info['client']]})))
        _, row = vless_row(store, info)
        if not any(c['id'] == info['client']['id'] for c in vless.normal(row)['settings']['clients']):
            raise ProbeError()
    else:
        path = awg.paths(spec['id'])[0] if backend == 'awg' else tt.paths(spec['id'])[2]
        if path.read_text() not in (info['before'], info['after']):
            raise ProbeError('probe_changed')
        atomic_file(path, info['after'].encode())
        if backend == 'awg':
            sync_awg(spec['id'], info['after'])
        else:
            command(['/usr/bin/systemctl', 'restart', tt.unit_for(spec['id'])])
    info['afterHash'] = fingerprint(store, info)
    info['status'] = 'active'
    save(store, info)


def begin(store, request):
    key = identifier(request['id'])
    info = load(store, key)
    if info is not None:
        if info.get('requestHash') != vless.digest(json.loads(request['payload'])) or info['status'] == 'closed' or time.time() >= info['expires']:
            raise ProbeError('probe_changed')
        if info['status'] == 'active':
            if fingerprint(store, info) != info['afterHash']:
                raise ProbeError('probe_changed')
            return public(info)
    else:
        if store.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
            raise ProbeError('probe_busy')
        payload = json.loads(request['payload'])
        prune(store)
        leases = [load(store, path.stem) for path in directory(store).glob('*.json')]
        live = [row for row in leases if row['status'] != 'closed']
        if len(live) >= 32 or any(row['protocol'] == payload.get('protocol') and row.get('saved', {}).get('spec', {}).get('id') == payload.get('resource')
                                  for row in live if row['protocol'] != 'reality_target'):
            raise ProbeError('probe_busy')
        info = prepare(store, request)
        save(store, info)
    arm(info)  # Crash-recoverable cleanup is armed BEFORE creating the access.
    apply(store, info)
    return public(info)


def public(info):
    return dict(id=info['id'], expires=info['expires'], observation=info['observation'],
                user=dict(id=info['id'], login='probe-' + info['id'], name='Probe', enabled=True))


def remove_peer(raw, public_key):
    header, peers = managed_awg.peer_blocks(raw)
    return header + ''.join(block for key, _, block in peers if key != public_key)


def remove_user(raw, client):
    config = toml_loads(raw)
    config['client'] = [c for c in config.get('client', []) if c.get('username') != client['username']]
    if not config['client']:
        config['client'] = [dict(username='_antirkn_no_clients', password=secrets.token_hex(32))]
    return toml_bytes(config).decode()


def cleanup(store, info):
    if info['backend'] == 'reality_target':
        # By remark, not id: a crash between the add and the next save
        # leaves no row id, and the remark is unique to this lease.
        api = vless.panel_for(store, info['panelId'])
        for row in target_rows(api, info):
            api.call('/panel/api/inbounds/del/%d' % row['id'], {})
        if target_rows(api, info):
            raise ProbeError('probe_cleanup')
        drop_client_record(api, info['email'])
        return
    spec, client = info['saved']['spec'], info['observation']['clients'][0]
    backend = info['backend']
    if info['protocol'] == 'vless':
        api = vless.panel_for(store, info['saved']['panelId'])
        row = next((r for r in api.call('/panel/api/inbounds/list') if r['id'] == info['rowId']), None)
        if row is None:
            return
        if any(c['id'] == client['uuid'] for c in vless.normal(row)['settings']['clients']):
            client_api(api, '/panel/api/clients/del/' + info['email'], {},
                       '/panel/api/inbounds/%d/delClient/%s' % (row['id'], client['uuid']), {})
        row = next((r for r in api.call('/panel/api/inbounds/list') if r['id'] == info['rowId']), None)
        if row and any(c['id'] == client['uuid'] for c in vless.normal(row)['settings']['clients']):
            raise ProbeError('probe_cleanup')
        return
    if backend == 'adopted':
        adapter = managed_existing.adapter(info['protocol'])
        current = adapter.snapshot(store, info['payload'], spec)
        if info['protocol'] == 'awg':
            raw = current['raw']
            clean = info['plan']['before']['raw'] if raw == info['plan']['after'] else remove_peer(raw, client['publicKey'])
            resource = current['resource']
            if clean != raw:
                managed_awg.external.write_file(resource, clean.encode())
            if resource['active']:
                managed_awg.external.exec_resource(resource, [resource['binary'], 'set', resource['name'], 'peer', client['publicKey'], 'remove'])
            after = adapter.snapshot(store, info['payload'], spec)
            if (client['publicKey'] in awg.runtime_config(after['raw'].encode())[1] or
                    after['runtime'] is not None and client['publicKey'] in awg.runtime_config(after['runtime'].encode())[1]):
                raise ProbeError('probe_cleanup')
            return
        # Adopted TrustTunnel (VLESS returned above, AWG just before).
        plan = copy.deepcopy(info['plan'])
        plan['before'] = current
        raw = current['credentials']
        plan['after'] = info['plan']['before']['credentials'] if raw == info['plan']['after'] else remove_user(raw, client)
        adapter.apply(store, info['payload'], spec, plan)
        if not adapter.verify(adapter.snapshot(store, info['payload'], spec), plan):
            raise ProbeError('probe_cleanup')
        return
    path = awg.paths(spec['id'])[0] if backend == 'awg' else tt.paths(spec['id'])[2]
    raw = path.read_text()
    clean = info['before'] if raw == info['after'] else (
        remove_peer(raw, client['publicKey']) if backend == 'awg' else remove_user(raw, client))
    atomic_file(path, clean.encode())
    if backend == 'awg':
        # Remove only this peer from live state: a concurrent runtime-only peer
        # must survive even when it has not yet been saved to the config file.
        command([awg.AWG, 'set', awg.name_for(spec['id']), 'peer', client['publicKey'], 'remove'])
        if client['publicKey'] in awg.runtime_config(command([awg.AWG, 'showconf', awg.name_for(spec['id'])]))[1]:
            raise ProbeError('probe_cleanup')
    else:
        command(['/usr/bin/systemctl', 'restart', tt.unit_for(spec['id'])])
    if path.read_text() != clean:
        raise ProbeError('probe_cleanup')


def end(store, key):
    info = load(store, key)
    if info is None or info['status'] == 'closed':
        if info is not None:
            retire(key)
        prune(store)
        return dict(closed=True, stable=bool(info and info.get('stable')))
    try:
        stable = info.get('afterHash') == fingerprint(store, info)
    except Exception:
        stable = False
    cleanup(store, info)
    # Drop all credentials/config copies once cleanup has succeeded.
    save(store, dict(id=key, status='closed', stable=stable, requestHash=info['requestHash'], closedAt=time.time()))
    retire(key)
    prune(store)
    return dict(closed=True, stable=stable)


def watchdog(key):
    from runner import Store, STATE
    started = time.monotonic()
    while True:
        store = Store(STATE)
        try:
            with operation_lock(store):
                info = load(store, key)
                if info is None or info['status'] == 'closed':
                    retire(key)
                    return
                if time.time() >= info['expires'] or time.monotonic() - started >= TTL:
                    end(store, key)
                    return
        finally:
            store.db.close()
        time.sleep(1)


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != 'watchdog':
        raise SystemExit(2)
    try:
        watchdog(identifier(sys.argv[2]))
    except Exception:
        raise SystemExit(1) from None
