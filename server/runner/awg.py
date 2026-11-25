"""AWG 3.1 interfaces and stable personal peers, through durable runner jobs."""
import base64
from client_revocations import check as check_revocations
import hashlib
import hmac
import ipaddress
import json
from pathlib import Path
import secrets
import subprocess

from awg_contract import SCHEMA
from awg_network import (configure as network_configure, create_key, key_valid, port_available,
    rules as network_rules)
from components import CONFIG, installed, unit_source, UNITS, ComponentError, safe_directory, usable
from panel import atomic_file, command, safe_file, PanelError
from vless import canonical, digest, VlessError
from vless_contract import validate_schema

ROOT = CONFIG / 'amneziawg'
AWG = '/usr/local/bin/awg'
KEY = ROOT / 'master.key'
OPTIONS = SCHEMA['properties']['resources']['items']['properties']['options']['properties']


class AwgError(VlessError):
    def __init__(self, code='awg_invalid'):
        self.code = code


def parse_payload(raw):
    def pairs(entries):
        value = {}
        for k, v in entries:
            if k in value:
                raise AwgError()
            value[k] = v
        return value
    try:
        p = json.loads(raw, object_pairs_hook=pairs)
        validate_schema(p, SCHEMA)
        if p['panelId'] != p['workspaceId']:
            raise AwgError()
        for key in ('users', 'resources'):
            if len({v['id'] for v in p[key]}) != len(p[key]):
                raise AwgError()
        for r in p['resources']:
            if 'adoption' in r:
                import managed_existing
                managed_existing.validate_spec(r, 'awg')
                continue
            pool = ipaddress.ip_network(r['pool'])
            if pool.version != 4 or not 16 <= pool.prefixlen <= 24 or not any(pool.subnet_of(ipaddress.ip_network(n)) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')):
                raise AwgError()
            if r['pool6']:
                v6 = ipaddress.ip_network(r['pool6'])
                if v6.version != 6 or v6.prefixlen != 64 or not v6.subnet_of(ipaddress.ip_network('fc00::/7')):
                    raise AwgError()
            if ':' in r['endpoint'] or r['endpoint'].replace('.', '').isdigit():
                ip = ipaddress.ip_address(r['endpoint'])
                if ip.is_unspecified or ip.is_multicast:
                    raise AwgError()
            if r['deleted'] and r['enabled']:
                raise AwgError()
            o = r['options']
            if o['jmin'] > o['jmax'] or o['random-trailers'] and len({o[f's{i}'] for i in range(1, 5)}) != 1:
                raise AwgError()
            for k, rule in OPTIONS.items():
                if rule.get('range') and not 1 <= int(o[k].split('-')[0]) <= int(o[k].split('-')[-1]) <= 65535:
                    raise AwgError()
            if int(o['rekey-after-time'].split('-')[-1]) >= int(o['reject-after-time'].split('-')[0]):
                raise AwgError()
    except (ValueError, TypeError, KeyError):
        raise AwgError()
    import managed_existing
    managed_existing.validate_payload(p, 'awg')
    return p


def name_for(rid):
    return 'ar' + rid[:12]


def paths(rid):
    name = name_for(rid)
    return ROOT / (name + '.conf'), ROOT / (name + '.network.json')


def owned(store):
    return {r['id']: json.loads(r['data']) for r in store.db.execute('SELECT * FROM awg_resources')}


def prerequisites():
    try:
        safe_directory(CONFIG)
        safe_directory(ROOT)
        record = installed('amneziawg')
        if not usable('amneziawg', record):
            raise AwgError('awg_prerequisites')
        unit = UNITS / 'antirkn-awg@.service'
        safe_file(unit)
        if unit.read_bytes() != unit_source('amneziawg'):
            raise AwgError('awg_conflict')
        for path in ('/usr/sbin/iptables', '/usr/sbin/ip6tables', '/usr/sbin/sysctl', '/dev/net/tun'):
            if not Path(path).exists():
                raise AwgError('awg_prerequisites')
        command(['/usr/sbin/iptables', '-w', '10', '-S'])
        command(['/usr/sbin/ip6tables', '-w', '10', '-S'])
        return record['release']
    except (ComponentError, PanelError, OSError):
        raise AwgError('awg_prerequisites')


def routes():
    result = []
    for family in ('-4', '-6'):
        rows = json.loads(command(['/usr/sbin/ip', '-j', family, 'route', 'show', 'table', 'all']))
        for row in rows:
            if row.get('dst', 'default') != 'default':
                result.append((ipaddress.ip_network(row['dst'], strict=False), row.get('dev')))
    return result


def free_port(port):
    """The wildcard UDP socket AWG binds (both families)."""
    return port_available('::', port, tcp=False, udp=True)


def defaults(store):
    prerequisites()
    existing = routes()
    reserved = owned(store)
    for r in reserved.values():
        existing.append((ipaddress.ip_network(r['spec']['pool']), None))
    for _ in range(256):
        pool = ipaddress.ip_network(f'10.{secrets.randbelow(256)}.{secrets.randbelow(16)*16}.0/20')
        if not any(n.version == 4 and n.overlaps(pool) for n, _ in existing):
            break
    else:
        raise AwgError('awg_pool_conflict')
    for _ in range(256):
        port = 49152 + secrets.randbelow(16384)
        if free_port(port) and not any(r['spec']['port'] == port for r in reserved.values()):
            break
    else:
        raise AwgError('awg_port_busy')
    options = {k: v['default'] for k, v in OPTIONS.items()}
    options['jc'] = 4 + secrets.randbelow(3)
    return dict(id=secrets.token_hex(16), name='AmneziaWG', enabled=True, deleted=False,
                endpoint='', port=port, externalPort=port, pool=str(pool), pool6='',
                mtu=1280, keepalive=0, options=options)


def derive(label, preview=False):
    if preview and not key_valid(KEY):
        # Read-only capacity/config validation before bootstrap. A short key
        # left by a crash is recreated (or refused) by the first job step.
        key = bytes(32)
    else:
        safe_file(KEY, 32)
        key = KEY.read_bytes()
    if len(key) != 32:
        raise AwgError('awg_conflict')
    return hmac.new(key, ('awg-v1/' + label).encode(), hashlib.sha256).digest()


def _x25519_pure(scalar_bytes):
    P = 2**255 - 19
    A24 = 121665
    s = bytearray(scalar_bytes)
    s[0] &= 248
    s[31] = (s[31] & 127) | 64
    k = int.from_bytes(s, 'little')
    x1, x2, z2, x3, z3 = 9, 1, 0, 9, 1
    swap = 0
    for t in reversed(range(255)):
        k_t = (k >> t) & 1
        swap ^= k_t
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = k_t
        A = (x2 + z2) % P
        AA = (A * A) % P
        B = (x2 - z2) % P
        BB = (B * B) % P
        E = (AA - BB) % P
        C = (x3 + z3) % P
        D = (x3 - z3) % P
        DA = (D * A) % P
        CB = (C * B) % P
        x3 = ((DA + CB) ** 2) % P
        z3 = (x1 * ((DA - CB) ** 2)) % P
        x2 = (AA * BB) % P
        z2 = (E * (AA + A24 * E)) % P
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, 'little')


def _curve25519_pubkey(private_bytes):
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        k = X25519PrivateKey.from_private_bytes(bytes(private_bytes))
        pub = k.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return base64.b64encode(pub).decode()
    except Exception:
        pass
    try:
        return base64.b64encode(_x25519_pure(private_bytes)).decode()
    except Exception:
        private_b64 = base64.b64encode(private_bytes).decode()
        return command([AWG, 'pubkey'], input_data=(private_b64 + '\n').encode()).decode().strip()


def keys(label, preview=False):
    private = bytearray(derive(label, preview))
    private[0] &= 248
    private[31] = (private[31] & 127) | 64
    public = _curve25519_pubkey(private)
    private_b64 = base64.b64encode(private).decode()
    return private_b64, public


def desired(p, r, previous, preview=False):
    label = p['workspaceId'] + '/' + r['id']
    private, public = keys('server/' + label, preview)
    header = base64.b64encode(derive('header/' + label, preview)).decode()
    if previous and (previous['publicKey'] != public or previous['headerProtectionKey'] != header):
        raise AwgError('awg_conflict')
    old = {c['id']: c for c in (previous or {}).get('clients', [])}
    offsets = {c['offset'] for c in old.values()}
    pool = ipaddress.ip_network(r['pool'])
    if offsets and max(offsets) >= pool.num_addresses - 1:
        raise AwgError('awg_pool_full')
    clients = []
    for user in sorted(p['users'], key=lambda u: u['id']):
        if user['id'] in old:
            offset = old[user['id']]['offset']
        else:
            offset = next((i for i in range(2, pool.num_addresses - 1) if i not in offsets), None)
            if offset is None:
                raise AwgError('awg_pool_full')
            offsets.add(offset)
        cprivate, cpublic = keys('client/' + label + '/' + user['id'], preview)
        clients.append(dict(id=user['id'], enabled=user['enabled'], offset=offset,
            address=str(pool.network_address + offset),
            address6=str(ipaddress.ip_network(r['pool6']).network_address + offset) if r['pool6'] else '',
            privateKey=cprivate, publicKey=cpublic,
            presharedKey=base64.b64encode(derive('psk/' + label + '/' + user['id'], preview)).decode()))
    # Retain removed peer address reservations so a returning identity is stable.
    clients += [{**c, 'enabled': False} for uid, c in old.items() if uid not in {u['id'] for u in p['users']}]
    address = f'{pool.network_address + 1}/{pool.prefixlen}'
    if r['pool6']:
        v6 = ipaddress.ip_network(r['pool6'])
        address += f', {v6.network_address + 1}/64'
    name = name_for(r['id'])
    hook = '/usr/bin/python3 -I ' + str(Path(__file__).resolve().with_name('awg_network.py'))
    lines = ['[Interface]', 'PrivateKey = ' + private, 'Address = ' + address,
        'ListenPort = ' + str(r['port']), 'MTU = ' + str(r['mtu']), 'Table = off',
        'PostUp = ' + hook + ' up ' + name, 'PostDown = ' + hook + ' down ' + name,
        'HeaderProtectionKey = ' + header]
    for i in range(1, 5):
        lines.append(f'H{i} = {i}')
    for k, value in r['options'].items():
        if value != '':
            lines.append(OPTIONS[k]['config'] + ' = ' + ('on' if value is True else 'off' if value is False else str(value)))
    for c in clients:
        if not c['enabled']:
            continue
        allowed = c['address'] + '/32' + (', ' + c['address6'] + '/128' if c['address6'] else '')
        lines += ['', '[Peer]', 'PublicKey = ' + c['publicKey'], 'PresharedKey = ' + c['presharedKey'], 'AllowedIPs = ' + allowed]
    config = ('\n'.join(lines) + '\n').encode()
    network = dict(pool=r['pool'], pool6=r['pool6'], port=r['port'])
    return dict(workspaceId=p['workspaceId'], spec=r, clients=clients, publicKey=public,
        headerProtectionKey=header, revision=digest(p), configHash=hashlib.sha256(config).hexdigest(),
        networkHash=digest(network)), config, canonical(network).encode()


def file_hash(path):
    if not path.exists():
        return None
    safe_file(path)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def current_hashes(rid):
    conf, net = paths(rid)
    return file_hash(conf), file_hash(net)


QUICK_FIELDS = frozenset({b'Address', b'MTU', b'DNS', b'Table', b'PreUp', b'PostUp', b'PreDown',
                          b'PostDown', b'SaveConfig'})


def core(raw):
    """A config for ``awg syncconf``: only awg-quick metadata is stripped;
    unknown core fields and every peer/PSK stay verbatim."""
    return b''.join(line for line in raw.splitlines(keepends=True)
                    if line.split(b'=', 1)[0].strip() not in QUICK_FIELDS)


def interface_section(raw):
    """Everything before the first [Peer]: keys, address, port, hooks, obfuscation."""
    lines = []
    for line in raw.splitlines():
        if line.strip() == b'[Peer]':
            break
        lines.append(line)
    while lines and not lines[-1].strip():
        lines.pop()
    return b'\n'.join(lines)


def runtime_matches(wanted, actual):
    """The interface and peers of ``wanted`` (a config) are what ``actual``
    (``awg showconf`` output) runs. Extra runtime peers do not match."""
    wanted_i, wanted_p = runtime_config(wanted)
    actual_i, actual_p = runtime_config(actual)
    return (all(actual_i.get(k) == v for k, v in wanted_i.items()) and wanted_p.keys() == actual_p.keys() and
            all(all(actual_p[pub].get(k) == v for k, v in peer.items()) for pub, peer in wanted_p.items()))


def runtime_config(raw):
    interface, peers, entry = {}, {}, None
    for line in raw.decode().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line == '[Interface]':
            entry = interface
        elif line == '[Peer]':
            entry = {}
            peers[id(entry)] = entry
        elif '=' in line and entry is not None:
            k, v = line.split('=', 1)
            k = k.strip().lower().replace('_', '')
            if k in ('address', 'mtu', 'table', 'postup', 'postdown', 'preup', 'predown', 'dns', 'saveconfig', 'endpoint'):
                continue
            v = v.strip()
            if k in ('randomtrailers', 'disablecookies'):
                v = 'on' if v in ('on', 'true', '1') else 'off'
            if k == 'allowedips':
                v = ','.join(sorted(x.strip() for x in v.split(',')))
            entry[k] = v
    return interface, {v['publickey']: v for v in peers.values()}


def active(rid):
    return subprocess.run(['/usr/bin/systemctl', 'is-active', '--quiet', 'antirkn-awg@' + name_for(rid)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15).returncode == 0


def rule_groups(rule):
    """Option groups of one rule: ['-s', pool], ['!', '-o', name], ..."""
    groups = []
    for token in rule:
        if token.startswith('-') and not (groups and groups[-1] == ['!']):
            groups.append([token])
        elif token == '!':
            groups.append(['!'])
        else:
            groups[-1].append(token)
    return groups


def rule_present(binary, table, chain, rule, cache):
    """One listing per table and poll answers every resource's rules; a rule
    the listing does not show is checked with -C, which stays authoritative."""
    key = ('rules', binary, table)
    if key not in cache:
        result = subprocess.run([binary, '-w', '10', '-t', table, '-S'], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=15)
        cache[key] = [line.split() for line in result.stdout.decode(errors='replace').splitlines()] if result.returncode == 0 else []
    for line in cache[key]:
        if line[:2] != ['-A', chain]:
            continue
        if all(any(line[i:i + len(group)] == group for i in range(2, len(line) - len(group) + 1))
               for group in rule_groups(rule)):
            return True
    return subprocess.run([binary, '-w', '10', '-t', table, '-C', chain, *rule], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, timeout=15).returncode == 0


def addresses(name, cache):
    if 'addresses' not in cache:
        cache['addresses'] = {row.get('ifname'): row for row in json.loads(command(['/usr/sbin/ip', '-j', 'address', 'show']))}
    return cache['addresses'].get(name)


def confirmed(saved, cache=None):
    """Files, unit, runtime peers, addresses and firewall match the record.
    ``cache`` shares the address and firewall listings between the resources
    of one read-only poll; a job step after a change never passes one."""
    cache = {} if cache is None else cache
    r = saved['spec']
    expected = (None, None) if r['deleted'] else (saved['configHash'], saved['networkHash'])
    if current_hashes(r['id']) != expected:
        return False
    enabled = r['enabled'] and not r['deleted']
    if active(r['id']) != enabled:
        return False
    if not enabled:
        return not Path('/sys/class/net', name_for(r['id'])).exists()
    try:
        if not runtime_matches(paths(r['id'])[0].read_bytes(), command([AWG, 'showconf', name_for(r['id'])])):
            return False
        link = addresses(name_for(r['id']), cache)
        if link is None:
            return False
        pool = ipaddress.ip_network(r['pool'])
        expected_addresses = {(str(pool.network_address + 1), pool.prefixlen)}
        if r['pool6']:
            expected_addresses.add((str(ipaddress.ip_network(r['pool6']).network_address + 1), 64))
        actual_addresses = {(a['local'], a['prefixlen']) for a in link['addr_info'] if a['scope'] == 'global'}
        if expected_addresses != actual_addresses or link['mtu'] != r['mtu']:
            return False
        for binary, table, chain, rule in network_rules(dict(pool=r['pool'], pool6=r['pool6'], port=r['port']), name_for(r['id'])):
            if not rule_present(binary, table, chain, rule, cache):
                return False
        return Path('/proc/sys/net/ipv4/ip_forward').read_text().strip() == '1' and (not r['pool6'] or Path('/proc/sys/net/ipv6/conf/all/forwarding').read_text().strip() == '1')
    except (PanelError, OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
        return False


def preflight(store, p):
    check_revocations(store, p)
    release = prerequisites() if any('adoption' not in r for r in p['resources']) else None
    saved = owned(store)
    adopted = {}
    ids = {r['id'] for r in p['resources']}
    if any(v['workspaceId'] == p['workspaceId'] and rid not in ids for rid, v in saved.items()):
        raise AwgError('awg_conflict')
    selected_routes = routes()
    active_resources = [r for r in p['resources'] if r['enabled'] and not r['deleted'] and 'adoption' not in r]
    if len({r['port'] for r in active_resources}) != len(active_resources):
        raise AwgError('awg_port_busy')
    all_names = {name_for(rid): rid for rid in saved}
    pools = [ipaddress.ip_network(pool)
             for rid, record in saved.items() if rid not in ids and not record['spec']['deleted']
             for pool in (record['spec']['pool'], record['spec']['pool6']) if pool]
    cache = {}
    for r in p['resources']:
        if 'adoption' in r:
            import managed_existing
            adopted[r['id']] = managed_existing.preflight(store, p, r, saved.get(r['id']), 'awg')
            continue
        rid, name = r['id'], name_for(r['id'])
        previous = saved.get(rid)
        if name in all_names and all_names[name] != rid:
            raise AwgError('awg_conflict')
        all_names[name] = rid
        if previous:
            if previous['workspaceId'] != p['workspaceId'] or not confirmed(previous, cache):
                raise AwgError('awg_conflict')
        elif current_hashes(rid) != (None, None) or Path('/sys/class/net', name).exists():
            raise AwgError('awg_conflict')
        desired(p, r, previous, preview=True)  # Capacity/key/config validation before effects.
        if r['deleted']:
            continue
        for pool in (r['pool'], r['pool6']):
            if not pool:
                continue
            net = ipaddress.ip_network(pool)
            if any(n.version == net.version and n.overlaps(net) for n in pools):
                raise AwgError('awg_pool_conflict')
            if any(n.version == net.version and n.overlaps(net) and dev != name for n, dev in selected_routes):
                raise AwgError('awg_pool_conflict')
            pools.append(net)
        if r['enabled'] and not (previous and active(rid) and previous['spec']['port'] == r['port']) and not free_port(r['port']):
            raise AwgError('awg_port_busy')
    return dict(fingerprint=digest(dict(desired=p, saved=saved, release=release, adopted=adopted)),
        resources=len(p['resources']), users=len(p['users']),
        creates=sum(r['id'] not in saved and not r['deleted'] for r in p['resources']),
        updates=sum(r['id'] in saved and not r['deleted'] for r in p['resources']),
        deletes=sum(r['deleted'] and r['id'] in saved for r in p['resources']),
        forwarding=True, nat=True, wildcardUdp=True)


def plan(store, req):
    p = parse_payload(req['payload'])
    if p['workspaceId'] != req['id']:
        raise AwgError()
    return preflight(store, p)


def state(store, workspace, pending_job=None):
    result = []
    cache = {}
    found = None
    for rid, saved in owned(store).items():
        if saved['workspaceId'] != workspace:
            continue
        if saved.get('adopted'):
            import awg_external
            import managed_existing
            if found is None:
                found = awg_external.discover_resources()  # Once per poll.
            result.append(managed_existing.state(store, saved, 'awg', pending_job, found=found))
            continue
        valid = confirmed(saved, cache)
        clients = [dict(c) for c in saved['clients']]
        if valid and saved['spec']['enabled'] and not saved['spec']['deleted']:
            handshakes = dict(line.split() for line in command([AWG, 'show', name_for(rid), 'latest-handshakes']).decode().splitlines())
            transfers = {line.split()[0]: line.split()[1:] for line in command([AWG, 'show', name_for(rid), 'transfer']).decode().splitlines()}
            for c in clients:
                c['handshake'] = int(handshakes.get(c['publicKey'], '0'))
                c['rx'], c['tx'] = map(int, transfers.get(c['publicKey'], ['0', '0']))
        result.append(dict(id=rid, workspaceId=workspace, confirmed=valid, spec=saved['spec'],
            publicKey=saved['publicKey'], headerProtectionKey=saved['headerProtectionKey'],
            clients=clients, revision=saved['revision']))
    return result


class AwgApply:
    def __init__(self, store, req):
        self.store, self.req = store, req
        self.payload = parse_payload(req['payload'])
        if req['count'] != len(self.payload['resources']) + 2 or req['interval'] != 1:
            raise AwgError()

    def step(self, checkpoint):
        p, req, db = self.payload, self.req, self.store.db
        check_revocations(self.store, p)
        native = [r for r in p['resources'] if 'adoption' not in r]
        if native: prerequisites()
        if checkpoint == 0:
            if preflight(self.store, p)['fingerprint'] != req['fingerprint']:
                raise AwgError('awg_conflict')
            check_revocations(self.store, p, persist=True)
            backup = self.store.directory / ('awg-backup-' + req['id'] + '.json')
            if not backup.exists():
                content = {r['id']: [base64.b64encode(path.read_bytes()).decode() if path.exists() else None for path in paths(r['id'])] for r in native}
                atomic_file(backup, canonical(dict(resources=owned(self.store), files=content)).encode())
            if native:
                try:
                    create_key(KEY, in_use=any(not r.get('adopted') for r in owned(self.store).values()))
                except (OSError, ValueError):
                    raise AwgError('awg_conflict')
            code = 'awg_preparing'
        elif checkpoint <= len(p['resources']):
            r = p['resources'][checkpoint - 1]
            previous = owned(self.store).get(r['id'])
            if 'adoption' in r:
                import managed_existing
                managed_existing.apply(self.store, req, p, r, previous, 'awg', checkpoint)
                return
            wanted, config, network = desired(p, r, previous)
            conf_path, net_path = paths(r['id'])
            intent_path = self.store.directory / ('awg-intent-' + req['id'] + '-' + r['id'] + '.json')
            before = current_hashes(r['id'])
            after = (None, None) if r['deleted'] else (wanted['configHash'], wanted['networkHash'])
            if not intent_path.exists():
                if previous and not confirmed(previous) or not previous and before != (None, None):
                    raise AwgError('awg_conflict')
                atomic_file(intent_path, canonical(dict(before=before, after=after)).encode())
            safe_file(intent_path)
            intent = json.loads(intent_path.read_text())
            if tuple(intent['after']) != after or any(v not in (intent['before'][i], after[i]) for i, v in enumerate(before)):
                raise AwgError('awg_conflict')
            # A saved intent identifies every allowed partial write. Never
            # overwrite an unrelated edit merely because a job is resumed.
            if not (before == after and confirmed(wanted)):
                unit = 'antirkn-awg@' + name_for(r['id']) + '.service'
                running = active(r['id'])
                enabled = r['enabled'] and not r['deleted']
                # Preconditions first: a busy port must not take the working
                # interface (and every client on it) down.
                if enabled and not (previous and running and previous['spec']['port'] == r['port']) and not free_port(r['port']):
                    raise AwgError('awg_port_busy')
                if enabled and running and self.peers_only(previous, conf_path, config, before, after):
                    # Only [Peer] sections differ: update the live interface;
                    # existing clients keep their sessions.
                    atomic_file(conf_path, config)
                    command([AWG, 'syncconf', name_for(r['id']), '/dev/stdin'], input_data=core(config))
                    if not confirmed(wanted):
                        raise AwgError('awg_failed')
                    running = None
                if running:
                    command(['/usr/bin/systemctl', 'stop', unit])
                if running is not None:
                    if net_path.exists():
                        network_configure('down', name_for(r['id']))
                    if Path('/sys/class/net', name_for(r['id'])).exists():
                        command(['/usr/sbin/ip', 'link', 'delete', name_for(r['id'])])
                    if r['deleted']:
                        command(['/usr/bin/systemctl', 'disable', unit])
                        for path in (conf_path, net_path):
                            path.unlink(missing_ok=True)
                    else:
                        atomic_file(net_path, network)
                        atomic_file(conf_path, config)
                        if r['enabled']:
                            # Another process may have taken the port while it
                            # was released; recover() restores the old interface.
                            if not free_port(r['port']):
                                raise AwgError('awg_port_busy')
                            command(['/usr/bin/systemctl', 'enable', '--now', unit], timeout=60)
                        else:
                            command(['/usr/bin/systemctl', 'disable', unit])
                    if not confirmed(wanted):
                        raise AwgError('awg_failed')
            with db:
                db.execute('INSERT INTO awg_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data', (r['id'], canonical(wanted)))
                db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
                self.store.event(req['id'], 'awg_applying', checkpoint + 1, req['count'])
            return
        else:
            if any(not r['confirmed'] or r['revision'] != digest(p) for r in state(self.store, p['workspaceId'], pending_job=req['id'])):
                raise AwgError('awg_conflict')
            code = 'awg_checking'
        with db:
            db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
            self.store.event(req['id'], code, checkpoint + 1, req['count'])

    @staticmethod
    def peers_only(previous, conf_path, config, before, after):
        """The change touches [Peer] sections only: same interface section,
        firewall/network record and a file that is ours (old or new)."""
        if not previous or previous['spec']['deleted'] or not previous['spec']['enabled']:
            return False
        if before[1] != after[1] or before[0] not in (previous['configHash'], after[0]):
            return False
        try:
            safe_file(conf_path)
            return interface_section(conf_path.read_bytes()) == interface_section(config)
        except (PanelError, OSError):
            return False

    def recover(self, checkpoint):
        """After a failed resource step, put that resource back as recorded
        before the step. Returns the job status, None when the files are not
        ours to touch (a foreign edit), and raises when restoring failed."""
        p = self.payload
        if not 1 <= checkpoint <= len(p['resources']):
            return None
        status = 'failed' if checkpoint == 1 else 'partially_applied'
        r = p['resources'][checkpoint - 1]
        previous = owned(self.store).get(r['id'])
        if 'adoption' in r:
            import managed_existing
            return status if managed_existing.restore(self.store, self.req, p, r, previous, 'awg') else None
        rid, name = r['id'], name_for(r['id'])
        unit = 'antirkn-awg@' + name + '.service'
        conf_path, net_path = paths(rid)
        intent_path = self.store.directory / ('awg-intent-' + self.req['id'] + '-' + rid + '.json')
        if not intent_path.exists():
            return status  # The intent precedes every effect: nothing changed.
        safe_file(intent_path)
        intent = json.loads(intent_path.read_text())
        current = current_hashes(rid)
        if any(v not in (intent['before'][i], intent['after'][i]) for i, v in enumerate(current)):
            return None
        link = Path('/sys/class/net', name)
        if previous and confirmed(previous) or not previous and current == (None, None) and not link.exists() and not active(rid):
            intent_path.unlink()
            return status
        backup_file = self.store.directory / ('awg-backup-' + self.req['id'] + '.json')
        safe_file(backup_file, 16777216)
        files = json.loads(backup_file.read_text())['files'].get(rid) or [None, None]
        if active(rid):
            command(['/usr/bin/systemctl', 'stop', unit])
        if net_path.exists():
            network_configure('down', name)
        if link.exists():
            command(['/usr/sbin/ip', 'link', 'delete', name])
        # The network record first: the restored config's PostUp reads it.
        for path, data in ((net_path, files[1]), (conf_path, files[0])):
            if data is None:
                path.unlink(missing_ok=True)
            else:
                atomic_file(path, base64.b64decode(data))
        if previous and previous['spec']['enabled'] and not previous['spec']['deleted']:
            command(['/usr/bin/systemctl', 'enable', '--now', unit], timeout=60)
        else:
            command(['/usr/bin/systemctl', 'disable', unit])
        if not (confirmed(previous) if previous else current_hashes(rid) == (None, None) and not link.exists()):
            raise AwgError('awg_failed')
        intent_path.unlink()
        return status

    def rollback(self):
        req_id = self.req['id']
        backup_file = self.store.directory / ('awg-backup-' + req_id + '.json')
        if not backup_file.exists():
            return
        try:
            if backup_file.stat().st_size > 16777216:
                return
            data = json.loads(backup_file.read_text())
            with self.store.db:
                self.store.db.execute("DELETE FROM awg_resources WHERE data LIKE ?", (f'%"workspaceId":"{self.payload["workspaceId"]}"%',))
                for r_id, r_data in data.get('resources', {}).items():
                    self.store.db.execute("INSERT OR REPLACE INTO awg_resources VALUES (?,?)", (r_id, canonical(r_data)))
            files_backup = data.get('files', {})
            native = [r for r in self.payload['resources'] if 'adoption' not in r]
            for r in native:
                res_id = r['id']
                name = name_for(res_id)
                unit = 'antirkn-awg@' + name + '.service'
                conf_path, net_path = paths(res_id)
                if res_id not in files_backup or files_backup[res_id] == [None, None]:
                    try: command(['/usr/bin/systemctl', 'stop', unit])
                    except Exception: pass
                    try: command(['/usr/bin/systemctl', 'disable', unit])
                    except Exception: pass
                    if net_path.exists():
                        try: network_configure('down', name)
                        except Exception: pass
                    if Path('/sys/class/net', name).exists():
                        try: command(['/usr/sbin/ip', 'link', 'delete', name])
                        except Exception: pass
                    conf_path.unlink(missing_ok=True)
                    net_path.unlink(missing_ok=True)
                else:
                    conf_b64, net_b64 = files_backup[res_id]
                    if net_b64 is not None:
                        atomic_file(net_path, base64.b64decode(net_b64))
                    else:
                        net_path.unlink(missing_ok=True)
                    if conf_b64 is not None:
                        atomic_file(conf_path, base64.b64decode(conf_b64))
                        try: command(['/usr/bin/systemctl', 'restart', unit])
                        except Exception: pass
                    else:
                        conf_path.unlink(missing_ok=True)
                (self.store.directory / ('awg-intent-' + req_id + '-' + res_id + '.json')).unlink(missing_ok=True)
        finally:
            backup_file.unlink(missing_ok=True)


def drop_foreign(store, rid, record, save):
    """Remove peers AntiRKN did not issue from one managed interface.

    The record's hash follows the file right after the write, then the live
    interface is updated in place. Returns the number of removed peers."""
    import managed_awg
    if record.get('adopted'):
        return managed_awg.drop_foreign(store, record, save)
    ours = {c['publicKey'] for c in record.get('clients', []) if c.get('publicKey')}
    conf_path, _ = paths(rid)
    if not conf_path.exists():
        return 0
    safe_file(conf_path)
    header, blocks = managed_awg.peer_blocks(conf_path.read_text())
    kept = [block for pub, _, block in blocks if pub in ours]
    if len(kept) == len(blocks):
        return 0
    if not header.endswith('\n'):
        header += '\n'
    raw = (header + ''.join(kept)).encode()
    atomic_file(conf_path, raw)
    record['configHash'] = hashlib.sha256(raw).hexdigest()
    save(record)
    if active(rid):
        command([AWG, 'syncconf', name_for(rid), '/dev/stdin'], input_data=core(raw))
    return len(blocks) - len(kept)
