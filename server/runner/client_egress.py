"""One reversible, durable client-egress transaction per server.

The panel owns Xray configuration. Credentials and recovery records remain in
the runner's root-only state directory; events contain stable codes only.
"""
import copy
import hashlib
import json
from pathlib import Path
import socket
import time

from awg_network import port_available
from panel import atomic_file, safe_file
from vless import canonical, digest, panel_for
from egress_config import EgressError, parse_link, configure, remove_owned, TAG
import egress_network as network
import egress_probe as probe

STATE = Path('/var/lib/antirkn-runner/client-egress.json')
UNIT = Path('/etc/systemd/system/antirkn-client-egress.service')


def load():
    if not STATE.exists(): return None
    safe_file(STATE, 4 * 1024 * 1024)
    return json.loads(STATE.read_text())


def save(info):
    atomic_file(STATE, canonical(info).encode())


def public(info=None):
    info = load() if info is None else info
    if info is None: return dict(enabled=False, observedHash=digest(None))
    result = {k: info[k] for k in ('enabled', 'name', 'host', 'port', 'transport', 'security', 'uri',
                               'socksPort', 'lastCheck', 'phase') if k in info}
    result['observedHash'] = digest(info)
    return result


def effective_forward(vpn):
    """Called by normal TT writers so later client edits keep the common exit."""
    info = load()
    if info and info.get('enabled'):
        vpn['forward_protocol'] = forward(info['socksPort'])
    return vpn



def remember_tt_forward(path, original):
    """Enroll an externally edited TT only after its durable file write.

    The editor's private backup supplies the original on checkpoint replay.
    Existing enrollments retain their settings from before egress activation.
    """
    info = load()
    if info and info.get('enabled') and path not in info['ttOriginal']:
        info['ttOriginal'][path] = original
        save(info)


def forward(port):
    return dict(socks5=dict(address='127.0.0.1:' + str(port), extended_auth=False))


def read_template(api):
    value = api.call('/panel/api/xray/', {}, form=True)
    if isinstance(value, str): value = json.loads(value)
    template = value.get('xraySetting')
    if isinstance(template, str): template = json.loads(template)
    if not isinstance(template, dict) or not isinstance(template.get('outbounds'), list):
        raise EgressError('egress_unsupported')
    return template, value.get('outboundTestUrl', 'https://www.google.com/generate_204')


def write_template(api, template, test_url):
    api.call('/panel/api/xray/update', dict(xraySetting=canonical(template), outboundTestUrl=test_url), form=True)
    observed, _ = read_template(api)
    if observed != template: raise EgressError('egress_conflict')
    api.call('/panel/api/server/restartXrayService', {})
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        from panel_api import xray_status
        if xray_status(api.call('/panel/api/server/status')).get('state') == 'running': return
        time.sleep(.25)
    raise EgressError('egress_config_failed')


def inventory(store):
    import awg
    import awg_external
    import tt
    import tt_external
    from tt_common import read, toml_loads
    interfaces = []
    for saved in awg.owned(store).values():
        spec = saved['spec']
        if not spec.get('deleted') and not saved.get('adopted'):
            interfaces.append(awg.name_for(spec['id']))
    for resource in awg_external.discover_resources():
        if resource.get('container') and resource.get('networkMode') != 'host':
            # Loopback belongs to another namespace. Never claim full coverage
            # or silently route that container's clients directly.
            raise EgressError('egress_namespace')
        interfaces.append(resource['name'])
    records, managed = [], tt.owned(store)
    for rid, saved in managed.items():
        spec = saved['spec']
        if saved.get('adopted') or spec['deleted']: continue
        path = tt.paths(rid)[0]
        if not tt.intact(saved): raise EgressError('egress_conflict')
        records.append(dict(path=str(path), unit=tt.unit_for(rid), owner=0, id=rid,
                            active=tt.active(tt.unit_for(rid)), native=True))
    issues = []
    for resource in tt_external.definitions(issues):
        rid = next((rid for rid, saved in managed.items() if saved.get('adopted') and
                    saved['spec']['adoption']['sourceId'] == resource['id']), None)
        records.append(dict(path=resource['settings'], unit=resource['unit'], owner=resource['ownerUid'],
                            id=rid, active=resource['active'], native=False, sourceId=resource['id']))
    if issues: raise EgressError('egress_unsupported')
    for item in records:
        raw = read(item['path'], item['owner'])
        item['hash'] = hashlib.sha256(raw).hexdigest()
        item['forward'] = toml_loads(raw.decode()).get('forward_protocol')
    return dict(interfaces=network.validate_interfaces(interfaces), tt=records)


def choose_port(preferred, occupied=()):
    candidates = [preferred] if preferred else [1080, *range(1081, 1181)]
    for port in candidates:
        if port not in occupied and port_available('127.0.0.1', port, tcp=True, udp=True):
            return port
    raise EgressError('egress_port_busy')


def decode(req):
    try:
        p = json.loads(req['payload'])
        if set(p) != {'panelId', 'enabled', 'uri', 'socksPort', 'observedHash'}: raise ValueError()
        if type(p['enabled']) is not bool or type(p['socksPort']) is not int: raise ValueError()
        if p['socksPort'] != 0 and not 1024 <= p['socksPort'] <= 65535: raise ValueError()
        if not isinstance(p['uri'], str) or len(p['uri']) > 16384: raise ValueError()
        from tt_common import identifier
        identifier(p['panelId'])
        if p['enabled']: parse_link(p['uri'])
        return p
    except (ValueError, TypeError, KeyError): raise EgressError() from None


def prepare(store, req):
    p = decode(req)
    old = load()
    if p['observedHash'] != digest(old) or old and old['panelId'] != p['panelId']:
        raise EgressError('egress_conflict')
    if old and old.get('phase') != 'applied': raise EgressError('egress_conflict')
    api = panel_for(store, p['panelId'])
    template, test_url = read_template(api)
    resources = inventory(store)
    connection = parse_link(p['uri']) if p['enabled'] else None
    socks_port = old['socksPort'] if old and old.get('enabled') else choose_port(p['socksPort']) if p['enabled'] else 1080
    # Reconfiguration keeps the existing private listener, avoiding a window
    # where TT points at a port no longer served by the panel.
    if old and old.get('enabled') and p['socksPort'] not in (0, socks_port):
        raise EgressError('egress_port_busy')
    transparent_port = old['transparentPort'] if old and old.get('enabled') else choose_port(0, [socks_port])
    if connection:
        addresses = {x[4][0] for x in socket.getaddrinfo(connection['host'], connection['port'], type=socket.SOCK_STREAM)}
        local = json.loads(network.run(['/usr/sbin/ip', '-j', 'address', 'show']).stdout)
        local_ips = {a['local'] for i in local for a in i.get('addr_info', [])}
        if addresses & (local_ips | {'127.0.0.1', '::1'}): raise EgressError('egress_loop')
        network.check_reservations(bool(old and old.get('enabled')))
    desired, owned = configure(template, connection, socks_port, transparent_port, old.get('owned') if old and old.get('enabled') else None)
    if connection: probe.validate(desired)
    previous = old.get('ttOriginal', {}) if old and old.get('enabled') else {}
    original = dict(previous)
    changes = []
    for item in resources['tt']:
        path = item['path']
        if old and old.get('enabled') and path in original and item['forward'] != forward(old['socksPort']):
            raise EgressError('egress_conflict')
        if path not in original:
            if old and old.get('enabled') and item['id'] and item['forward'] == forward(old['socksPort']):
                saved = json.loads(store.db.execute('SELECT data FROM tt_resources WHERE id=?', (item['id'],)).fetchone()[0])
                spec = saved['spec']
                original[path] = {'direct': {}} if spec['outbound'] == 'direct' else {'socks5': {'address': spec['socksAddress'], 'extended_auth': False}}
            else: original[path] = item['forward']
        changes.append({**item, 'after': forward(socks_port) if connection else original[path]})
    info = dict(enabled=bool(connection), panelId=p['panelId'], socksPort=socks_port,
                transparentPort=transparent_port, interfaces=resources['interfaces'],
                ttOriginal=original if connection else {}, owned=owned, phase='applying', uri=p['uri'] if connection else '',
                previousInterfaces=(old or {}).get('interfaces', []))
    if connection: info.update({k: connection[k] for k in ('name', 'host', 'port', 'transport', 'security')})
    plan = dict(before=template, after=desired, testUrl=test_url, old=old, new=info, tt=changes,
                requestHash=digest(req['payload']))
    plan['fingerprint'] = digest(plan)
    return plan


def plan(store, req):
    value = prepare(store, req)
    return dict(fingerprint=value['fingerprint'], socksPort=value['new']['socksPort'],
                awgCount=len(value['new']['interfaces']), ttCount=len(value['tt']))


def update_tt(store, item, wanted, allowed):
    import tt_external
    from tt_common import read, toml_loads, toml_bytes, active, run
    config = toml_loads(read(item['path'], item['owner']).decode())
    current = config.get('forward_protocol')
    if current not in allowed: raise EgressError('egress_conflict')
    if wanted is None: config.pop('forward_protocol', None)
    else: config['forward_protocol'] = wanted
    tt_external.write_existing(Path(item['path']), toml_bytes(config), item['owner'])
    if item['active']:
        run(['/usr/bin/systemctl', 'restart', item['unit']], timeout=60)
        if not active(item['unit']): raise EgressError('egress_config_failed')
    if item['id']:
        row = store.db.execute('SELECT data FROM tt_resources WHERE id=?', (item['id'],)).fetchone()
        if row:
            saved = json.loads(row[0])
            if item['native']:
                saved['hashes'][0] = hashlib.sha256(read(item['path'], item['owner'])).hexdigest()
            else:
                saved['observedHash'] = tt_external.snapshot(item['sourceId'])[-1]
            with store.db: store.db.execute('UPDATE tt_resources SET data=? WHERE id=?', (canonical(saved), item['id']))


def configure_network(info, previous=None):
    from tt_common import run
    if info.get('enabled'):
        script = Path(__file__).with_name('egress_network.py')
        service = ('[Unit]\nDescription=AntiRKN client egress routes\nAfter=network-pre.target\n'
            'Before=network.target x-ui.service awg-quick.target\nWants=network-pre.target\n'
            '[Service]\nType=oneshot\nRemainAfterExit=yes\n'
            'ExecStart=/usr/bin/python3 -I ' + str(script) + '\n'
            '[Install]\nWantedBy=multi-user.target\n')
        if UNIT.exists():
            safe_file(UNIT)
            if 'Description=AntiRKN client egress routes\n' not in UNIT.read_text():
                raise EgressError('egress_conflict')
        atomic_file(UNIT, service.encode(), 0o644)
        run(['/usr/bin/systemctl', 'daemon-reload'])
        # The worker's systemd sandbox cannot write kernel settings; the fixed
        # root-owned oneshot applies the dedicated routes in the host namespace.
        run(['/usr/bin/systemctl', 'enable', 'antirkn-client-egress.service'])
        run(['/usr/bin/systemctl', 'restart', 'antirkn-client-egress.service'])
    else:
        network.configure(info.get('interfaces', []), info.get('transparentPort', 1081), False,
                          (previous or {}).get('interfaces', []))
        if UNIT.exists():
            run(['/usr/bin/systemctl', 'disable', '--now', 'antirkn-client-egress.service'])
            UNIT.unlink()
            run(['/usr/bin/systemctl', 'daemon-reload'])


def verify_clients(store, info):
    network.intact(info)
    resources = inventory(store)
    if not set(resources['interfaces']) <= set(info['interfaces']):
        raise EgressError('egress_conflict')
    if any(item['forward'] != forward(info['socksPort']) for item in resources['tt']):
        raise EgressError('egress_conflict')


class EgressApply:
    def __init__(self, store, req):
        self.store, self.req = store, req
        self.path = store.directory / ('client-egress-' + req['id'] + '.json')

    def read(self):
        safe_file(self.path, 8 * 1024 * 1024)
        value = json.loads(self.path.read_text())
        if value['requestHash'] != digest(self.req['payload']): raise EgressError('egress_conflict')
        return value

    def rollback(self):
        value = self.read()
        api = panel_for(self.store, value['new']['panelId'])
        current, url = read_template(api)
        if current == value['after']:
            write_template(api, value['before'], url)
        elif current != value['before']:
            raise EgressError('egress_conflict')
        for item in value['tt']:
            update_tt(self.store, item, item['forward'], [item['forward'], item['after']])
        restored = value['old'] or dict(enabled=False, panelId=value['new']['panelId'], phase='applied',
                                      interfaces=value['new']['interfaces'], transparentPort=value['new']['transparentPort'])
        save(restored)
        configure_network(restored, value['new'])
        value['rolledBack'] = True
        atomic_file(self.path, canonical(value).encode())

    def step(self, checkpoint):
        if checkpoint == 0:
            if not self.path.exists():
                value = prepare(self.store, self.req)
                if value['fingerprint'] != self.req['fingerprint']: raise EgressError('egress_conflict')
                if value['new']['enabled']:
                    value['new']['lastCheck'] = probe.outbound(parse_link(value['new']['uri']), self.store.directory)
                # Recheck after the network probe, immediately before saving intent.
                if prepare(self.store, self.req)['fingerprint'] != self.req['fingerprint']:
                    raise EgressError('egress_conflict')
                atomic_file(self.path, canonical(value).encode())
            elif self.read().get('rolledBack'):
                raise EgressError('egress_conflict')
        elif checkpoint == 1:
            value = self.read()
            api = panel_for(self.store, value['new']['panelId'])
            current, _ = read_template(api)
            if current not in (value['before'], value['after']): raise EgressError('egress_conflict')
            if current != value['after']: write_template(api, value['after'], value['testUrl'])
            # Save before switching routes: a machine restart replays the same intent.
            save(value['new'])
            configure_network(value['new'], value['old'])
            for item in value['tt']:
                update_tt(self.store, item, item['after'], [item['forward'], item['after']])
        else:
            value = self.read()
            api = panel_for(self.store, value['new']['panelId'])
            if read_template(api)[0] != value['after']: raise EgressError('egress_conflict')
            info = value['new']
            if info['enabled']:
                verify_clients(self.store, info)
                info['lastCheck'] = probe.check(info['socksPort'])
            info['phase'] = 'applied'
            save(info)
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, self.req['id']))
            self.store.event(self.req['id'], ('egress_preparing', 'egress_applying', 'egress_checking')[checkpoint], checkpoint + 1, 3)


def check(store, panel_id):
    info = load()
    if not info or not info.get('enabled') or info['panelId'] != panel_id or info['phase'] != 'applied':
        raise EgressError('egress_conflict')
    api = panel_for(store, panel_id)
    template, _ = read_template(api)
    remove_owned(template, info['owned'])
    verify_clients(store, info)
    info['lastCheck'] = probe.check(info['socksPort'])
    save(info)
    return public(info)
