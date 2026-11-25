"""Merge personal peers into native or Docker AWG without replacing its keys."""
import base64
import ipaddress
import re

import awg
import awg_external as external
import vless
from managed_existing import b64, derive, intent, user_enabled
from vless import VlessError, digest


def public_key(private):
    raw = base64.b64decode(private, validate=True)
    if len(raw) != 32:
        raise VlessError('vpn_adoption_invalid')
    public = vless.command(['/usr/bin/openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
                           input_data=bytes.fromhex('302e020100300506032b656e04220420') + raw)
    if len(public) != 44:
        raise VlessError('vpn_adoption_invalid')
    return b64(public[-32:])


def snapshot(store, p, r, found=None):
    """``found``: the discovery of the same poll, shared by its resources."""
    source = r['adoption']['sourceId']
    resource, raw, values, peers, fingerprint = (external.read_resource(source) if found is None
                                                 else external.read_resource(source, found))
    runtime = None
    if resource['active']:
        runtime = external.exec_resource(resource, [resource['binary'], 'showconf', resource['name']]).stdout.decode()
    return dict(resource=resource, raw=raw.decode(), values=values, runtime=runtime,
                fingerprint=fingerprint)


def addresses(values):
    try:
        result = [ipaddress.ip_interface(v.strip()) for v in values.get('Address', '').split(',') if v.strip()]
        if not any(v.version == 4 for v in result):
            raise ValueError()
        return result
    except ValueError:
        raise VlessError('vpn_adoption_unsupported')


def peer_blocks(raw):
    chunks = re.split(r'(?m)(?=^[ \t]*\[Peer\][ \t]*\r?$)', raw)
    if not chunks or '[Interface]' not in chunks[0]:
        raise VlessError('vpn_adoption_invalid')
    peers = []
    for block in chunks[1:]:
        _, parsed = awg.runtime_config(('[Interface]\n' + block).encode())
        if len(parsed) != 1:
            raise VlessError('vpn_adoption_invalid')
        pub, values = next(iter(parsed.items()))
        peers.append((pub, values, block))
    if len({pub for pub, _, _ in peers}) != len(peers):
        raise VlessError('vpn_adoption_invalid')
    return chunks[0], peers


def options(values):
    result = {}
    for k, rule in awg.OPTIONS.items():
        if rule['config'] in values:
            v = values[rule['config']]
            result[k] = int(v) if rule['type'] == 'integer' else v == 'on' if rule['type'] == 'boolean' else v
    for key in [*(f'H{i}' for i in range(1, 5)), *(f'I{i}' for i in range(1, 6)), *(f'J{i}' for i in range(1, 4))]:
        if key in values:
            result[key.lower()] = values[key]
    if 'Itime' in values:
        result['itime'] = int(values['Itime'])
    if 'HeaderProtectionKey' in values:
        result['version'] = 3
        result['header-protection-key'] = values['HeaderProtectionKey']
    return result


def build(store, p, r, old, current, preview=False):
    if not healthy(current):
        raise VlessError('vpn_adoption_conflict')
    values = current['values']
    server_addresses = addresses(values)
    v4 = next(a for a in server_addresses if a.version == 4)
    v6 = next((a for a in server_addresses if a.version == 6), None)
    if r['pool'] != str(v4.network) or r['pool6'] != (str(v6.network) if v6 else ''):
        raise VlessError('vpn_adoption_conflict')
    if not old and (r['port'] != int(values['ListenPort']) or r['enabled'] != current['resource']['active']):
        raise VlessError('vpn_adoption_conflict')
    # Keep the source service lifecycle and hooks intact. Disabling an adopted
    # interface revokes our peers while existing peers keep their access.
    header, blocks = peer_blocks(current['raw'])
    previous = {c['id']: c for c in (old or {}).get('clients', [])}
    own_keys = {c['publicKey'] for c in previous.values()}
    foreign = [(pub, values, block) for pub, values, block in blocks if pub not in own_keys]
    reserved = [ipaddress.ip_network(v.strip(), strict=False)
                for _, peer, _ in foreign for v in peer.get('allowedips', '').split(',') if v.strip()]
    used = {c['address'] for c in previous.values()} | {str(a.ip) for a in server_addresses}
    used6 = {c.get('address6') for c in previous.values()} | {str(a.ip) for a in server_addresses}
    clients = []
    for user in sorted(p['users'], key=lambda u: u['id']):
        previous_client = previous.get(user['id'])
        if previous_client:
            address = previous_client['address']
            address6 = previous_client.get('address6', '')
            if ipaddress.ip_address(address) not in v4.network:
                raise VlessError('vpn_adoption_conflict')
        else:
            address = next((str(v4.network.network_address + n)
                            for n in range(1, min(v4.network.num_addresses - 1, 65536))
                            if str(v4.network.network_address + n) not in used and
                            not any(net.version == 4 and v4.network.network_address + n in net for net in reserved)), None)
            if address is None:
                raise VlessError('awg_pool_full')
            address6 = ''
            if v6:
                address6 = next((str(v6.network.network_address + n) for n in range(1, min(v6.network.num_addresses, 65536))
                                 if str(v6.network.network_address + n) not in used6 and
                                 not any(net.version == 6 and v6.network.network_address + n in net for net in reserved)), None)
                if address6 is None:
                    raise VlessError('awg_pool_full')
        used.add(address)
        used6.add(address6)
        private = bytearray(derive(store, p, r, 'awg/' + user['id'], preview))
        private[0] &= 248
        private[31] = (private[31] & 127) | 64
        private = b64(private)
        pub = public_key(private)
        if any(key == pub for key, _, _ in foreign):
            raise VlessError('vpn_adoption_conflict')
        clients.append(dict(id=user['id'], enabled=user_enabled(r, user), address=address, address6=address6,
                            privateKey=private, publicKey=pub,
                            presharedKey=b64(derive(store, p, r, 'awg-psk/' + user['id'], preview))))
    clients += [{**c, 'enabled': False} for uid, c in previous.items() if uid not in {u['id'] for u in p['users']}]
    target = header + ''.join(block for _, _, block in foreign)
    for c in clients:
        if c['enabled']:
            target += ('\n[Peer]\nPublicKey = ' + c['publicKey'] + '\nPresharedKey = ' + c['presharedKey'] +
                       '\nAllowedIPs = ' + c['address'] + '/32' +
                       (', ' + c['address6'] + '/128' if c['address6'] else '') + '\n')
    proxy = dict(type='wireguard', udp=True, mtu=r['mtu'], **{
        'persistent-keepalive': r['keepalive'], 'public-key': public_key(values['PrivateKey']),
        'allowed-ips': ['0.0.0.0/0'] + (['::/0'] if v6 else []), 'amnezia-wg-option': options(values)})
    return intent(old, current, target, clients, proxy)


def matches(raw, runtime):
    return awg.runtime_matches(raw.encode(), runtime.encode())


def healthy(current):
    return current['runtime'] is None or matches(current['raw'], current['runtime'])


def apply(store, p, r, plan, marker=None):
    current = snapshot(store, p, r)
    before = plan['before']
    if (current['resource'] != before['resource'] or current['raw'] not in (before['raw'], plan['after']) or
            current['runtime'] is not None and not any(matches(raw, current['runtime']) for raw in (before['raw'], plan['after']))):
        raise VlessError('vpn_adoption_conflict')
    resource = current['resource']
    if current['raw'] != plan['after']:
        external.write_file(resource, plan['after'].encode())
    if resource['active'] and not matches(plan['after'], current['runtime']):
        external.exec_resource(resource, [resource['binary'], 'syncconf', resource['name'], '/dev/stdin'],
                               awg.core(plan['after'].encode()))


def restore(store, p, r, plan, marker=None):
    """Undo this job's write: the config file and live peers return to the
    inspected ``before``. A file that is neither ours nor the original is
    left alone (None). Raises when the restored state cannot be verified."""
    current = snapshot(store, p, r)
    before = plan['before']
    if current['resource'] != before['resource']:
        return None
    resource = current['resource']
    if current['raw'] == before['raw']:
        if current['runtime'] is None or matches(before['raw'], current['runtime']):
            return True
    elif current['raw'] == plan['after']:
        external.write_file(resource, before['raw'].encode())
    else:
        return None
    if resource['active']:
        external.exec_resource(resource, [resource['binary'], 'syncconf', resource['name'], '/dev/stdin'],
                               awg.core(before['raw'].encode()))
    again = snapshot(store, p, r)
    if again['raw'] != before['raw'] or not healthy(again):
        raise VlessError('vpn_adoption_failed')
    return True


def locator(current):
    """Where the adopted interface lives, to tell "gone" from "unreadable"."""
    resource = current['resource']
    return dict(path=resource['path'], container=resource.get('container'), name=resource['name'])


def absent(source):
    return external.absent(source)


def drop_foreign(store, record, save):
    """Remove the peers AntiRKN did not issue from an adopted interface."""
    spec = record['spec']
    current = snapshot(store, {}, spec)
    ours = {c['publicKey'] for c in record.get('clients', []) if c.get('publicKey')}
    header, blocks = peer_blocks(current['raw'])
    kept = [block for pub, _, block in blocks if pub in ours]
    if len(kept) == len(blocks):
        return 0
    if not header.endswith('\n'):
        header += '\n'
    raw = (header + ''.join(kept)).encode()
    resource = current['resource']
    external.write_file(resource, raw)
    record['observedHash'] = snapshot(store, {}, spec)['fingerprint']
    save(record)
    if resource['active']:
        external.exec_resource(resource, [resource['binary'], 'syncconf', resource['name'], '/dev/stdin'], awg.core(raw))
        # The fingerprint also binds the live peers.
        record['observedHash'] = snapshot(store, {}, spec)['fingerprint']
        save(record)
    return len(blocks) - len(kept)


def verify(current, plan):
    return current['raw'] == plan['after'] and healthy(current)
