"""Edit existing native/official Docker AWG configurations without adopting peers.

Resource selectors are discovered on the server. RPC never accepts paths,
container names, executable names or secret-bearing complete configurations.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from awg import AwgError, core, free_port, runtime_config, runtime_matches
from awg_network import replace_preserving
from panel import atomic_file, safe_file
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
    """Replace the selected config only, keeping its owner, group and mode."""
    if not r.get('container'):
        path = Path(r['path'])
        safe_file(path)
        for parent in path.parents:
            # A directory another account can write would let it swap the file.
            meta = os.lstat(str(parent))
            if meta.st_uid != 0 or meta.st_mode & 0o022:
                raise AwgError('awg_conflict')
        replace_preserving(path, data)
        return
    script = ('set -eu; test -f "$1"; test ! -L "$1"; umask 077; m=$(stat -c %a "$1"); '
              't=$(mktemp "$1.antirkn.XXXXXX"); trap \'rm -f "$t"\' EXIT; cat > "$t"; chmod "$m" "$t"; mv -f "$t" "$1"')
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
        ids = [cid for cid in ps.stdout.decode().splitlines()[:64] if re.fullmatch('[a-f0-9]{64}', cid)]
        # One inspect for all containers. One that exits meanwhile is
        # reported as missing while the others are still listed.
        metas = []
        if ids:
            inspected = run([docker, 'inspect', *ids], check=False)
            try:
                metas = json.loads(inspected.stdout or b'[]')
            except ValueError:
                raise AwgError('awg_prerequisites')
            if not metas and inspected.returncode:
                raise AwgError('awg_prerequisites')
        for meta in metas:
            cid = meta['Id']
            if cid not in ids or not any(x in (meta['Name'] + ' ' + meta['Config']['Image']).lower() for x in ('amnezia', 'awg')):
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


def read_resource(rid, resources=None):
    """One discovered resource. ``resources`` reuses a discovery made by the
    same RPC or step instead of scanning every container again."""
    r = next((r for r in (discover_resources() if resources is None else resources) if r['id'] == rid), None)
    if not r:
        raise AwgError('awg_conflict')
    raw = read_file(r)
    values, peers = parse(raw)
    current = None
    if r['active']:
        current = runtime_config(exec_resource(r, [r['binary'], 'showconf', r['name']]).stdout)
    fingerprint = digest(dict(resource=r, file=raw.decode(), runtime=current))
    return r, raw, values, peers, fingerprint


def absent(source):
    """The resource is positively gone: a native config and its interface are
    both missing, or its container no longer exists (stopped ones still
    exist). Any doubt answers False, so a read-only poll never forgets an
    adopted resource whose peers may still be served."""
    if not source:
        return False
    try:
        if not source.get('container'):
            try:
                os.lstat(source['path'])
                return False
            except FileNotFoundError:
                pass
            return not os.path.lexists(os.path.join('/sys/class/net', source['name']))
        docker = shutil.which('docker')
        if not docker:
            return False
        listed = run([docker, 'ps', '-a', '--no-trunc', '--format', '{{.ID}}'], check=False)
        return listed.returncode == 0 and source['container'] not in listed.stdout.decode().split()
    except (AwgError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return False


def public_snapshot(rid, resources=None):
    r, raw, values, peers, fingerprint = read_resource(rid, resources)
    import ipaddress
    addresses = [ipaddress.ip_interface(v.strip()) for v in values.get('Address', '').split(',') if v.strip()]
    pool = next((str(a.network) for a in addresses if a.version == 4), '')
    pool6 = next((str(a.network) for a in addresses if a.version == 6), '')
    bindings = r.get('portBindings', {}).get(values['ListenPort'] + '/udp') or []
    mapped = {int(b['HostPort']) for b in bindings}
    # Keys, PSKs, hooks and peer endpoints never leave this RPC response.
    return dict(id=rid, name=r.get('containerName', r['name']) + '/' + r['name'],
        source=r['source'], path=r['path'], active=r['active'], peers=peers,
        version='3.1' if 'HeaderProtectionKey' in values else '2' if 'S3' in values or 'S4' in values else '1',
        fingerprint=fingerprint, portLocked=bool(r.get('portBindings')),
        values={k: v for k, v in values.items() if k in ALLOWED},
        hasHeaderProtection='HeaderProtectionKey' in values, pool=pool, pool6=pool6,
        externalPort=next(iter(mapped)) if len(mapped) == 1 else int(values['ListenPort']))


def discovery():
    resources = discover_resources()
    return dict(resources=[public_snapshot(r['id'], resources) for r in resources])


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


def prepare(req):
    p = decode(req)
    r, raw, _, peers, fingerprint = read_resource(p['resourceId'])
    if fingerprint != p['observedHash']:
        raise AwgError('awg_conflict')
    target = patched(raw, p['changes'], r)
    preview = dict(fingerprint=digest(dict(payload=p, desired=target.decode())), peers=peers,
                   source=r['source'], active=r['active'])
    return r, raw, target, preview


def plan(req):
    return prepare(req)[3]


class ExternalAwgEdit:
    def __init__(self, store, req):
        self.store, self.req, self.payload = store, req, decode(req)
        self.backup = store.directory / ('awg-external-' + req['id'] + '.json')

    def step(self, checkpoint):
        req, p, db = self.req, self.payload, self.store.db
        if checkpoint == 0:
            r, raw, target, preview = prepare(req)
            if preview['fingerprint'] != req['fingerprint']:
                raise AwgError('awg_conflict')
            if not self.backup.exists():
                backup = dict(resource=r, before=raw.decode(), after=target.decode())
                if 'MTU' in p['changes'] and r['active']:
                    # The live MTU, restored if this edit fails.
                    mtu = '/sys/class/net/' + r['name'] + '/mtu'
                    backup['mtu'] = (exec_resource(r, ['cat', mtu]).stdout.decode() if r.get('container')
                                     else Path(mtu).read_text()).strip()
                atomic_file(self.backup, canonical(backup).encode())
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
                    exec_resource(r, [r['binary'], 'syncconf', r['name'], '/dev/stdin'], core(wanted))
                    if 'MTU' in p['changes']:
                        exec_resource(r, ['ip', 'link', 'set', 'dev', r['name'], 'mtu', p['changes']['MTU']])
                code = 'awg_applying'
            else:
                if read_file(r) != wanted:
                    raise AwgError('awg_conflict')
                if r['active'] and not runtime_matches(wanted, exec_resource(r, [r['binary'], 'showconf', r['name']]).stdout):
                    raise AwgError('awg_failed')
                code = 'awg_checking'
        with db:
            db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (checkpoint + 1, req['id']))
            self.store.event(req['id'], code, checkpoint + 1, req['count'])

    def recover(self, checkpoint):
        """Put the inspected config and live interface back after a failed
        write or verification. None leaves a foreign edit untouched."""
        if checkpoint < 1 or not self.backup.exists():
            return None
        safe_file(self.backup)
        backup = json.loads(self.backup.read_text())
        r, raw, _, _, _ = read_resource(self.payload['resourceId'])
        if r != backup['resource']:
            return None
        before = backup['before'].encode()
        if raw == backup['after'].encode() and raw != before:
            write_file(r, before)
        elif raw != before:
            return None
        if r['active']:
            if not runtime_matches(before, exec_resource(r, [r['binary'], 'showconf', r['name']]).stdout):
                exec_resource(r, [r['binary'], 'syncconf', r['name'], '/dev/stdin'], core(before))
            if backup.get('mtu', '').isdigit():
                exec_resource(r, ['ip', 'link', 'set', 'dev', r['name'], 'mtu', backup['mtu']])
            if not runtime_matches(before, exec_resource(r, [r['binary'], 'showconf', r['name']]).stdout):
                raise AwgError('awg_failed')
        if read_file(r) != before:
            raise AwgError('awg_failed')
        return 'failed'
