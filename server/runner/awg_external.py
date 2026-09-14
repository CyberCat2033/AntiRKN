"""Edit existing native/official Docker AWG configurations without adopting peers.

Resource selectors are discovered on the server. RPC never accepts paths,
container names, executable names or secret-bearing complete configurations.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess

from awg import AwgError, runtime_config, free_port
from panel import atomic_file, command, safe_file
from vless import canonical, digest

DOCKER_PATHS = ('/opt/amnezia/awg/awg0.conf', '/opt/amnezia/awg/wg0.conf')
NATIVE_ROOTS = ('/etc/amnezia/amneziawg', '/etc/amneziawg', '/etc/wireguard', '/opt/amnezia/awg')
NUMBERS = {'ListenPort': (1, 65535), 'MTU': (1280, 1500), 'Jc': (0, 32),
           'Jmin': (0, 1280), 'Jmax': (0, 1280), **{f'S{i}': (0, 1280) for i in range(1, 5)}}
RANGES = {f'H{i}': (0, 4294967295) for i in range(1, 5)}
RANGES.update({k: (1, 65535) for k in ('RekeyAfterTime', 'RekeyTimeout', 'RejectAfterTime', 'KeepaliveTimeout', 'MaxHandshakeAttempts')})
RANGES['ContentPaddingAddition'] = (0, 65535)
BOOLEANS = {'RandomTrailers', 'DisableCookies'}
CPS = {f'I{i}' for i in range(1, 6)}
ALLOWED = set(NUMBERS) | set(RANGES) | BOOLEANS | CPS


def run(argv, data=None, check=True):
    result = subprocess.run(argv, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if check and result.returncode:
        raise AwgError('awg_failed')
    if len(result.stdout) > 1048576:
        raise AwgError('awg_invalid')
    return result


def exec_resource(r, args, data=None, check=True):
    prefix = [r['docker'], 'exec', '-i', r['container']] if r.get('container') else []
    return run(prefix + args, data, check)


def read_file(r):
    if not r.get('container'):
        path = Path(r['path'])
        safe_file(path)
        return path.read_bytes()
    # Fixed script; the discovered path is a separate positional argument.
    script = 'test -f "$1" && test ! -L "$1" && test "$(stat -c %u "$1")" = 0 && test "$(wc -c < "$1")" -le 1048576 && cat "$1"'
    return exec_resource(r, ['/bin/sh', '-c', script, 'antirkn', r['path']]).stdout


def write_file(r, data):
    if not r.get('container'):
        atomic_file(Path(r['path']), data)
        return
    script = 'set -eu; test -f "$1"; test ! -L "$1"; umask 077; t=$(mktemp "$1.antirkn.XXXXXX"); trap \'rm -f "$t"\' EXIT; cat > "$t"; chmod 600 "$t"; mv -f "$t" "$1"'
    exec_resource(r, ['/bin/sh', '-c', script, 'antirkn', r['path']], data)


def parse(raw):
    text = raw.decode('utf-8')
    if '\x00' in text:
        raise AwgError()
    values, in_interface, peers = {}, False, 0
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('['):
            in_interface = line == '[Interface]'
            peers += line == '[Peer]'
        elif in_interface and '=' in line and not line.startswith('#'):
            k, v = (p.strip() for p in line.split('=', 1))
            if k in values:
                raise AwgError('awg_invalid')
            values[k] = v
    if 'PrivateKey' not in values or 'ListenPort' not in values:
        raise AwgError('awg_invalid')
    return values, peers


def discover_resources():
    result = []
    binary = shutil.which('awg')
    if binary:
        for root in NATIVE_ROOTS:
            parent = Path(root)
            if parent.is_symlink():
                continue
            for path in sorted(parent.glob('*.conf'))[:32]:
                if not re.fullmatch(r'[A-Za-z0-9_=+.-]{1,15}', path.stem):
                    continue
                record = dict(path=str(path), name=path.stem, binary=binary, source='native')
                try:
                    values, _ = parse(read_file(record))
                    if not any(k in values for k in ('Jc', 'S1', 'H1', 'HeaderProtectionKey')):
                        continue
                    record['active'] = Path('/sys/class/net', path.stem).exists()
                    result.append(record)
                except (AwgError, OSError, ValueError):
                    continue
    docker = shutil.which('docker')
    if docker:
        ps = run([docker, 'ps', '--no-trunc', '--format', '{{.ID}}'], check=False)
        if ps.returncode:
            raise AwgError('awg_prerequisites')
        for cid in ps.stdout.decode().splitlines()[:64]:
            if not re.fullmatch('[a-f0-9]{64}', cid):
                continue
            meta = json.loads(run([docker, 'inspect', cid]).stdout)[0]
            if not any(x in (meta['Name'] + ' ' + meta['Config']['Image']).lower() for x in ('amnezia', 'awg')):
                continue
            for path in DOCKER_PATHS:
                record = dict(path=path, name=Path(path).stem, binary='awg', source='docker',
                    docker=docker, container=cid, containerName=meta['Name'].lstrip('/'),
                    networkMode=meta['HostConfig']['NetworkMode'], portBindings=meta['HostConfig'].get('PortBindings') or {})
                try:
                    parse(read_file(record))
                    record['active'] = exec_resource(record, ['awg', 'show', record['name'], 'public-key'], check=False).returncode == 0
                    result.append(record)
                except (AwgError, OSError, ValueError):
                    continue
    for record in result:
        record['id'] = digest({k: record.get(k) for k in ('path', 'container')})[:32]
    return result


def read_resource(rid):
    r = next((r for r in discover_resources() if r['id'] == rid), None)
    if not r:
        raise AwgError('awg_conflict')
    raw = read_file(r)
    values, peers = parse(raw)
    current = None
    if r['active']:
        current = runtime_config(exec_resource(r, [r['binary'], 'showconf', r['name']]).stdout)
    fingerprint = digest(dict(resource=r, file=raw.decode(), runtime=current))
    return r, raw, values, peers, fingerprint


def public_snapshot(rid):
    r, raw, values, peers, fingerprint = read_resource(rid)
    # Keys, PSKs, hooks and peer endpoints never leave this RPC response.
    return dict(id=rid, name=r.get('containerName', r['name']) + '/' + r['name'],
        source=r['source'], path=r['path'], active=r['active'], peers=peers,
        version='3.1' if 'HeaderProtectionKey' in values else '2' if 'S3' in values or 'S4' in values else '1',
        fingerprint=fingerprint, portLocked=bool(r.get('portBindings')),
        values={k: v for k, v in values.items() if k in ALLOWED},
        hasHeaderProtection='HeaderProtectionKey' in values)


def discovery():
    return dict(resources=[public_snapshot(r['id']) for r in discover_resources()])


def patched(raw, changes, r):
    values, _ = parse(raw)
    if type(changes) is not dict or not set(changes) <= ALLOWED:
        raise AwgError()
    for key, value in changes.items():
        if type(value) is not str or len(value) > 2048 or any(c in value for c in '\n\r\x00'):
            raise AwgError()
        if key not in values and key != 'MTU':
            raise AwgError()  # No implicit protocol migration/new generation.
        if key in NUMBERS:
            if not re.fullmatch(r'[0-9]{1,5}', value) or not NUMBERS[key][0] <= int(value) <= NUMBERS[key][1]:
                raise AwgError()
        elif key in RANGES:
            if not re.fullmatch(r'[0-9]{1,10}(-[0-9]{1,10})?', value):
                raise AwgError()
            bounds = list(map(int, value.split('-')))
            if not RANGES[key][0] <= bounds[0] <= bounds[-1] <= RANGES[key][1]:
                raise AwgError()
        elif key in BOOLEANS and value not in ('on', 'off'):
            raise AwgError()
        elif key in CPS and not re.fullmatch(r'(<(?:r [0-9]{1,4}|b 0x[0-9a-fA-F]+)>)*', value):
            raise AwgError()
    new = {**values, **changes}
    if int(new.get('Jmin', 0)) > int(new.get('Jmax', 1280)):
        raise AwgError()
    if 'HeaderProtectionKey' in values and any(int(new.get(f'S{i}', 0)) < 12 for i in range(1, 5)):
        raise AwgError()
    if new.get('RandomTrailers') == 'on' and len({new.get(f'S{i}') for i in range(1, 5)}) != 1:
        raise AwgError()
    if 'HeaderProtectionKey' not in values:
        spans = []
        for i in range(1, 5):
            span = list(map(int, new.get(f'H{i}', str(i)).split('-')))
            if any(span[0] <= b and a <= span[-1] for a, b in spans):
                raise AwgError()
            spans.append((span[0], span[-1]))
    if 'RekeyAfterTime' in new and 'RejectAfterTime' in new and int(new['RekeyAfterTime'].split('-')[-1]) >= int(new['RejectAfterTime'].split('-')[0]):
        raise AwgError()
    if new['ListenPort'] != values['ListenPort']:
        # Docker published ports belong to container creation. Keep them fixed
        # when editing its inner configuration; display this boundary in UI.
        if r.get('portBindings'):
            raise AwgError('awg_port_mapping')
        if r['source'] == 'native' or r.get('networkMode') == 'host':
            if not free_port(int(new['ListenPort'])):
                raise AwgError('awg_port_busy')
    lines, in_interface, inserted = [], False, set()
    for line in raw.decode().splitlines(keepends=True):
        if line.strip().startswith('['):
            if in_interface:
                lines += [k + ' = ' + v + '\n' for k, v in changes.items() if k not in inserted]
            in_interface = line.strip() == '[Interface]'
        if in_interface and '=' in line and not line.lstrip().startswith('#'):
            k = line.split('=', 1)[0].strip()
            if k in changes:
                line = k + ' = ' + changes[k] + '\n'
                inserted.add(k)
        lines.append(line)
    if in_interface:
        lines += [k + ' = ' + v + '\n' for k, v in changes.items() if k not in inserted]
    return ''.join(lines).encode()


def decode(req):
    p = json.loads(req['payload'])
    if type(p) is not dict or set(p) != {'resourceId', 'observedHash', 'changes'} or not re.fullmatch('[a-f0-9]{32}', p['resourceId']) or not re.fullmatch('[a-f0-9]{64}', p['observedHash']):
        raise AwgError()
    return p


def plan(req):
    p = decode(req)
    r, raw, _, peers, fingerprint = read_resource(p['resourceId'])
    if fingerprint != p['observedHash']:
        raise AwgError('awg_conflict')
    target = patched(raw, p['changes'], r)
    return dict(fingerprint=digest(dict(payload=p, desired=target.decode())), peers=peers,
                source=r['source'], active=r['active'])


class ExternalAwgEdit:
    def __init__(self, store, req):
        self.store, self.req, self.payload = store, req, decode(req)
        self.backup = store.directory / ('awg-external-' + req['id'] + '.json')

    def step(self, checkpoint):
        req, p, db = self.req, self.payload, self.store.db
        if checkpoint == 0:
            if plan(req)['fingerprint'] != req['fingerprint']:
                raise AwgError('awg_conflict')
            r, raw, _, _, _ = read_resource(p['resourceId'])
            if not self.backup.exists():
                atomic_file(self.backup, canonical(dict(resource=r, before=raw.decode(), after=patched(raw, p['changes'], r).decode())).encode())
            code = 'awg_preparing'
        else:
            safe_file(self.backup)
            backup = json.loads(self.backup.read_text())
            r, raw, _, _, _ = read_resource(p['resourceId'])
            if raw.decode() not in (backup['before'], backup['after']) or r != backup['resource']:
                raise AwgError('awg_conflict')
            wanted = backup['after'].encode()
            if checkpoint == 1:
                if raw != wanted:
                    write_file(r, wanted)
                if r['active']:
                    # Strip only awg-quick metadata; unknown core fields and
                    # every peer/PSK remain verbatim for the native validator.
                    core = b''.join(line for line in wanted.splitlines(keepends=True) if line.split(b'=', 1)[0].strip() not in
                        (b'Address', b'MTU', b'DNS', b'Table', b'PreUp', b'PostUp', b'PreDown', b'PostDown', b'SaveConfig'))
                    exec_resource(r, [r['binary'], 'syncconf', r['name'], '/dev/stdin'], core)
                    if 'MTU' in p['changes']:
                        exec_resource(r, ['ip', 'link', 'set', 'dev', r['name'], 'mtu', p['changes']['MTU']])
                code = 'awg_applying'
            else:
                if read_file(r) != wanted:
                    raise AwgError('awg_conflict')
                if r['active']:
                    ei, ep = runtime_config(wanted)
                    ai, ap = runtime_config(exec_resource(r, [r['binary'], 'showconf', r['name']]).stdout)
                    if any(ai.get(k) != v for k, v in ei.items()) or ep.keys() != ap.keys() or any(any(ap[pub].get(k) != v for k, v in peer.items()) for pub, peer in ep.items()):
                        raise AwgError('awg_failed')
                code = 'awg_checking'
        with db:
            db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
            self.store.event(req['id'], code, checkpoint + 1, req['count'])
