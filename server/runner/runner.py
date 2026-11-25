#!/usr/bin/env python3
"""Private SSH RPC and durable diagnostic worker. No user-supplied commands."""
import fcntl
import json
import shutil
import os
from pathlib import Path
import signal
import sqlite3
import sys
import time
import threading
import subprocess

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contract import SCHEMA, validate_request


class _Lazy:
    """A module attribute imported on first use.

    Every RPC is a fresh process; importing all protocol modules (ssl, urllib,
    tarfile, ...) cost more than a status poll itself. Tests can still patch
    ``runner.<name>``.
    """
    __slots__ = ('module', 'name')

    def __init__(self, module, name):
        self.module, self.name = module, name

    def resolve(self):
        import importlib
        return getattr(importlib.import_module(self.module), self.name)

    def __call__(self, *args, **kwargs):
        return self.resolve()(*args, **kwargs)

    def __getattr__(self, attr):
        return getattr(self.resolve(), attr)

    # Class attributes patched through the proxy land on the real class.
    def __setattr__(self, attr, value):
        if attr in _Lazy.__slots__:
            object.__setattr__(self, attr, value)
        else:
            setattr(self.resolve(), attr, value)

    def __delattr__(self, attr):
        delattr(self.resolve(), attr)


discover_panel = _Lazy('panel_discovery', 'discover')
connect_existing = _Lazy('panel_discovery', 'connect_existing')
external_access = _Lazy('panel_discovery', 'external_access')
ComponentInstaller = _Lazy('components', 'ComponentInstaller')
ProtocolRemoval = _Lazy('protocol_remove', 'ProtocolRemoval')
protocol_removal_plan = _Lazy('protocol_remove', 'plan')
SshHardenJob = _Lazy('ssh_harden', 'SshHardenJob')
ssh_harden_plan = _Lazy('ssh_harden', 'plan')
InboundRemove = _Lazy('inbound_remove', 'InboundRemove')
inbound_removal_plan = _Lazy('inbound_remove', 'plan')
ObservedInboundEdit = _Lazy('observed_inbounds', 'ObservedInboundEdit')
inbound_snapshot = _Lazy('observed_inbounds', 'snapshot')
inbound_plan = _Lazy('observed_inbounds', 'plan')
stage_payload = _Lazy('observed_inbounds', 'stage_payload')
AptJob = _Lazy('apt', 'AptJob')
apt_plan = _Lazy('apt', 'plan')
PanelInstaller = _Lazy('panel', 'PanelInstaller')
access_for = _Lazy('panel', 'access_for')
install_cli = _Lazy('panel', 'install_cli')
PanelUpdate = _Lazy('panel_update', 'PanelUpdate')
panel_update_plan = _Lazy('panel_update', 'plan')
ExternalAwgEdit = _Lazy('awg_external', 'ExternalAwgEdit')
awg_discovery = _Lazy('awg_external', 'discovery')
awg_snapshot = _Lazy('awg_external', 'public_snapshot')
awg_external_plan = _Lazy('awg_external', 'plan')
TtApply = _Lazy('tt', 'TtApply')
tt_plan = _Lazy('tt', 'plan')
tt_state = _Lazy('tt', 'state')
tt_defaults = _Lazy('tt', 'defaults')
ExternalTtEdit = _Lazy('tt_external', 'ExternalTtEdit')
tt_discovery = _Lazy('tt_external', 'discovery')
tt_snapshot = _Lazy('tt_external', 'public_snapshot')
tt_external_plan = _Lazy('tt_external', 'plan')
CertificateJob = _Lazy('tt_certificates', 'CertificateJob')
tt_certificates = _Lazy('tt_certificates', 'inventory')
tt_certificate_plan = _Lazy('tt_certificates', 'plan')
AwgApply = _Lazy('awg', 'AwgApply')
awg_plan = _Lazy('awg', 'plan')
awg_state = _Lazy('awg', 'state')
awg_defaults = _Lazy('awg', 'defaults')
VlessApply = _Lazy('vless', 'VlessApply')
parse_payload = _Lazy('vless', 'parse_payload')
vless_plan = _Lazy('vless', 'plan')
vless_state = _Lazy('vless', 'state')
panel_for = _Lazy('vless', 'panel_for')
ComponentUpgradeJob = _Lazy('component_upgrade', 'ComponentUpgradeJob')
component_upgrade_plan = _Lazy('component_upgrade', 'plan')


def _load_errors():
    """Bind the protocol exception classes for handlers that catch them."""
    global VlessError, PanelError, AptError, ComponentError, ComponentUpgradeError
    global RemovalError, SshHardenError, TtError, AwgError
    from vless import VlessError
    from panel import PanelError
    from apt import AptError
    from components import ComponentError
    from component_upgrade import ComponentUpgradeError
    from protocol_remove import RemovalError
    from ssh_harden import SshHardenError
    from tt_common import TtError
    from awg import AwgError

STATE = Path('/var/lib/antirkn-runner')
HEARTBEAT_INTERVAL = 3
ALIVE_WITHIN = 15  # The app's "runner alive" indicator.
STALE_AFTER = 30  # A worker silent this long has stopped, if it holds no lock.
BOOT_GRACE = 120  # After boot the unit may start after the first SSH call.
MAX_STEP_CRASHES = 3  # Then the job is parked, not retried until StartLimit.
RETAIN_SECONDS = 30 * 86400
# Rows that later code reads back by id as ownership or result records.
RETAINED_KINDS = ('panel_install', 'component_install', 'panel_update', 'ssh_harden',
                  'component_upgrade_apply', 'egress_access', 'egress_apply')
TABLES = (
    'CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, request TEXT NOT NULL, status TEXT NOT NULL, checkpoint INTEGER NOT NULL, sequence INTEGER NOT NULL, cancel INTEGER NOT NULL, created REAL NOT NULL)',
    'CREATE TABLE IF NOT EXISTS events (id TEXT NOT NULL, sequence INTEGER NOT NULL, event TEXT NOT NULL, PRIMARY KEY(id,sequence))',
    'CREATE TABLE IF NOT EXISTS health (id INTEGER PRIMARY KEY, heartbeat REAL NOT NULL)',
    'CREATE TABLE IF NOT EXISTS vless_resources (id TEXT PRIMARY KEY, data TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS tt_resources (id TEXT PRIMARY KEY, data TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS awg_resources (id TEXT PRIMARY KEY, data TEXT NOT NULL)',
    'CREATE TABLE IF NOT EXISTS revoked_clients (workspace TEXT NOT NULL, user TEXT NOT NULL, PRIMARY KEY(workspace,user))',
    'CREATE TABLE IF NOT EXISTS step_crashes (id TEXT PRIMARY KEY, checkpoint INTEGER NOT NULL, attempts INTEGER NOT NULL)',
)
TABLE_NAMES = frozenset(statement.split()[5] for statement in TABLES)
INPUT_PROMPT = '__ANTIRKN_RUNNER_INPUT__'


def strict_json(raw):
    def pairs(entries):
        result = {}
        for key, value in entries:
            if key in result:
                raise ValueError('invalid')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs)


class ClearIncomplete(Exception):
    """Some resources could not be cleaned; the others were."""


AWG_QUICK_FIELDS = {b'Address', b'MTU', b'DNS', b'Table', b'PreUp', b'PostUp', b'PreDown', b'PostDown', b'SaveConfig'}


def _awg_core(raw):
    return b''.join(line for line in raw.splitlines(keepends=True) if line.split(b'=', 1)[0].strip() not in AWG_QUICK_FIELDS)


def clear_managed_clients(store):
    """Drop clients and peers that AntiRKN does not own from managed resources.

    Each resource is handled on its own: a failure no longer hides behind
    ``ok`` nor stops the remaining resources, and a record's hash follows the
    file as soon as it is written, so a failed reload cannot leave the
    resource in a permanent adoption conflict."""
    import vless
    import hashlib
    cleared, failed = 0, False

    def records(table):
        nonlocal failed
        try:
            return {r['id']: json.loads(r['data']) for r in store.db.execute('SELECT * FROM ' + table)}
        except (sqlite3.Error, ValueError):
            failed = True
            return {}

    def save(table, res_id, record):
        with store.db:
            store.db.execute('UPDATE ' + table + ' SET data=? WHERE id=?', (vless.canonical(record), res_id))

    # 1. VLESS resources
    from egress_access import clients_for
    panels = {}
    for res_id, r in records('vless_resources').items():
        panels.setdefault(r.get('panelId'), []).append((res_id, r))
    for panel_id, items in panels.items():
        try:
            api = panel_for(store, panel_id)
            inbounds = api.call('/panel/api/inbounds/list')
        except Exception:
            failed = True
            continue
        restart = False
        for res_id, r in items:
            try:
                if r.get('adopted'):
                    source_id = int(r['spec']['adoption']['sourceId'])
                    row = next((x for x in inbounds if x['id'] == source_id), None)
                else:
                    row = vless.locate(inbounds, r['workspaceId'], res_id)
                if row is None:
                    continue
                settings = vless.object_field(row.get('settings') or '{}')
                clients_list = settings.get('clients') or []
                ours = {c['uuid'] for c in r.get('clients', []) if c.get('uuid')} | {c['id'] for c in r.get('clients', []) if c.get('id')}
                ours.update(c['id'] for c in clients_for(row))
                kept = [c for c in clients_list if (c.get('id') in ours or c.get('uuid') in ours)]
                if len(kept) == len(clients_list):
                    continue
                settings['clients'] = kept
                wanted = dict(row)
                wanted['settings'] = vless.canonical(settings)
                api.call('/panel/api/inbounds/update/%d' % row['id'], wanted)
                restart = True
                cleared += len(clients_list) - len(kept)
                # Hash the panel's own readback, as VlessApply does.
                detail = api.call('/panel/api/inbounds/get/%d' % row['id'])
                r['observedHash'] = vless.digest(vless.normal(detail if isinstance(detail, dict) and detail.get('id') == row['id'] else wanted))
                save('vless_resources', res_id, r)
            except Exception:
                failed = True
        if restart:
            try:
                api.call('/panel/api/server/restartXrayService', {})
                deadline = time.monotonic() + 20
                while True:
                    st = api.call('/panel/api/server/status')
                    if isinstance(st, dict) and isinstance(st.get('xray'), dict) and st['xray'].get('state') == 'running':
                        break
                    if time.monotonic() >= deadline:
                        raise ValueError('xray')
                    time.sleep(0.25)
            except Exception:
                failed = True

    # 2. AmneziaWG resources
    import awg
    import managed_awg
    import awg_external
    from panel import atomic_file
    for res_id, r in records('awg_resources').items():
        try:
            ours = {c['publicKey'] for c in r.get('clients', []) if c.get('publicKey')}
            if r.get('adopted'):
                source_id = r['spec']['adoption']['sourceId']
                resource, raw, _, _, _ = awg_external.read_resource(source_id)
                header, blocks = managed_awg.peer_blocks(raw.decode())
            else:
                conf_path, _ = awg.paths(res_id)
                if not conf_path.exists():
                    continue
                header, blocks = managed_awg.peer_blocks(conf_path.read_text())
            kept = [block for pub, _, block in blocks if pub in ours]
            if len(kept) == len(blocks):
                continue
            if not header.endswith('\n'):
                header += '\n'
            new_raw = (header + ''.join(kept)).encode()
            if r.get('adopted'):
                awg_external.write_file(resource, new_raw)
                r['observedHash'] = awg_external.read_resource(source_id)[4]
                save('awg_resources', res_id, r)
                cleared += len(blocks) - len(kept)
                if resource.get('active'):
                    awg_external.exec_resource(resource, [resource['binary'], 'syncconf', resource['name'], '/dev/stdin'], _awg_core(new_raw))
            else:
                atomic_file(conf_path, new_raw)
                r['configHash'] = hashlib.sha256(new_raw).hexdigest()
                save('awg_resources', res_id, r)
                cleared += len(blocks) - len(kept)
                if awg.active(res_id):
                    vless.command([awg.AWG, 'syncconf', awg.name_for(res_id), '/dev/stdin'], input_data=_awg_core(new_raw))
        except Exception:
            failed = True

    # 3. TrustTunnel resources
    import tt
    import tt_common
    import secrets
    import hmac
    for res_id, r in records('tt_resources').items():
        try:
            names = {c['username'] for c in r.get('clients', []) if c.get('username')} | {c['id'] for c in r.get('clients', []) if c.get('id')}
            # The certificate watcher also rewrites and restarts these services.
            with tt_common.lock():
                if r.get('adopted'):
                    import managed_tt
                    import tt_external
                    current = managed_tt.snapshot(store, {}, r)
                    resource = current['resource']
                    credentials = tt_common.toml_loads(current['credentials'])
                    clients = credentials.get('client', [])
                else:
                    rid = r.get('spec', {}).get('id') or res_id
                    cred_path = tt_common.ROOT / rid / 'credentials.toml'
                    if not cred_path.exists():
                        continue
                    clients = tt_common.toml_loads(cred_path.read_text()).get('client', [])
                foreign = [c for c in clients if c.get('username') not in names and c.get('username') != '_antirkn_no_clients']
                if not foreign:
                    continue
                kept = [c for c in clients if c.get('username') in names]
                if r.get('adopted'):
                    credentials['client'] = kept or [dict(username='_antirkn_no_clients', password=secrets.token_hex(32))]
                    tt_external.write_existing(Path(resource['credentials']), tt_common.toml_bytes(credentials), resource['ownerUid'])
                    r['observedHash'] = managed_tt.snapshot(store, {}, r)['fingerprint']
                    save('tt_resources', res_id, r)
                    cleared += len(foreign)
                    if resource.get('active'):
                        tt_common.run(['/usr/bin/systemctl', 'restart', resource['unit']], timeout=60)
                else:
                    if not kept:
                        key = Path(tt.KEY).read_bytes() if Path(tt.KEY).exists() else secrets.token_bytes(32)
                        sentinel = hmac.new(key, ('tt-deny-all/' + r['workspaceId'] + '/' + rid).encode(), hashlib.sha256).hexdigest()
                        kept = [dict(username='_antirkn_no_clients', password=sentinel)]
                    new_bytes = tt_common.toml_bytes(dict(client=kept))
                    with tt_common.file_lock(cred_path):
                        atomic_file(cred_path, new_bytes)
                    if 'hashes' in r and len(r['hashes']) >= 3:
                        r['hashes'][2] = hashlib.sha256(new_bytes).hexdigest()
                    save('tt_resources', res_id, r)
                    cleared += len(foreign)
                    unit = 'antirkn-tt@' + rid + '.service'
                    if tt_common.active(unit):
                        tt_common.run(['/usr/bin/systemctl', 'restart', unit], timeout=60)
        except Exception:
            failed = True

    if failed:
        raise ClearIncomplete(cleared)
    return dict(cleared=cleared)


def cleanup_job_transients(directory, job_id):
    if not job_id or not isinstance(job_id, str):
        return
    directory = Path(directory)
    for pattern in (f'vless-backup-{job_id}.json', f'awg-backup-{job_id}.json',
                    f'tt-backup-{job_id}.json', f'inbound-backup-{job_id}.json',
                    # Staged payloads may hold transport secrets.
                    f'inbound-request-{job_id}.json', f'inbound-removal-{job_id}.json',
                    f'apt-{job_id}.started', f'reboot-{job_id}.json',
                    f'reboot-{job_id}.lock', f'awg-intent-{job_id}-*.json',
                    f'tt-intent-{job_id}-*.json', f'upgrade-{job_id}*'):
        for p in directory.glob(pattern):
            try:
                if p.is_dir():
                    shutil.rmtree(str(p), ignore_errors=True)
                else:
                    p.unlink(missing_ok=True)
            except Exception:
                pass
    try:
        (directory / f'apt-{job_id}.started').unlink(missing_ok=True)
    except Exception:
        pass


def slim_finished_job(directory, job_id):
    """A finished install keeps its small records (ownership, plan) and drops
    archives, extracted trees, the Go toolchain and build cache (hundreds of
    MB per AmneziaWG build, kept forever before)."""
    if not job_id or not isinstance(job_id, str):
        return
    for prefix in ('component-', 'panel-'):
        work = Path(directory) / (prefix + job_id)
        if not work.is_dir() or work.is_symlink():
            continue
        for child in work.iterdir():
            if child.is_file() and child.suffix == '.json':
                continue
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(str(child), ignore_errors=True)
            else:
                child.unlink(missing_ok=True)


def slim_finished_jobs(store):
    for work in list(Path(store.directory).glob('component-*')) + list(Path(store.directory).glob('panel-*')):
        job_id = work.name.split('-', 1)[1]
        row = store.db.execute('SELECT status FROM jobs WHERE id=?', (job_id,)).fetchone()
        if row is not None and row[0] == 'succeeded':
            slim_finished_job(store.directory, job_id)


def worker_running(directory):
    """Whether some process holds the worker flock, read from /proc/locks.

    Probing with flock() itself could make a daemon that starts at that very
    moment fail its non-blocking lock and exit."""
    try:
        inode = os.stat(str(Path(directory) / 'worker.lock')).st_ino
    except FileNotFoundError:
        return False
    try:
        with open('/proc/locks') as stream:
            for line in stream:
                fields = line.split()
                if 'FLOCK' not in fields or '->' in fields:
                    continue
                for field in fields:
                    parts = field.split(':')
                    if len(parts) == 3 and parts[2].isdigit() and int(parts[2]) == inode:
                        return True
    except OSError:
        return True  # Unknown: never settle jobs a live worker may own.
    return False


class Store:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.db = sqlite3.connect(str(self.directory / 'jobs.sqlite'), timeout=5)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('PRAGMA journal_size_limit=1048576')
        self.db.execute('PRAGMA wal_autocheckpoint=100')
        version = self.db.execute('PRAGMA user_version').fetchone()[0]
        if version not in (0, SCHEMA['version']):
            self.db.close()
            raise ValueError('incompatible')
        # Tables were added over releases under the same user_version, so check
        # them; a read keeps every RPC (status polls included) off the write lock.
        present = {r[0] for r in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if version == 0 or not TABLE_NAMES <= present:
            with self.db:
                for statement in TABLES:
                    self.db.execute(statement)
                self.db.execute('PRAGMA user_version=1')

    def close(self):
        self.db.close()

    def event(self, job_id, code, progress, total):
        if code not in SCHEMA['events']:
            code = 'failed'
        sequence = self.db.execute('SELECT sequence FROM jobs WHERE id=?', (job_id,)).fetchone()[0] + 1
        event = dict(sequence=sequence, timestamp=time.time(), code=code, progress=progress, total=total)
        self.db.execute('UPDATE jobs SET sequence=? WHERE id=?', (sequence, job_id))
        self.db.execute('INSERT INTO events VALUES (?,?,?)', (job_id, sequence, json.dumps(event)))
        self.db.execute('DELETE FROM events WHERE id=? AND sequence<=?', (job_id, sequence - SCHEMA['maxEvents']))

    def job(self, row, cursor=0):
        req = json.loads(row['request'])
        events = [json.loads(r[0]) for r in self.db.execute('SELECT event FROM events WHERE id=? AND sequence>? ORDER BY sequence', (row['id'], cursor))]
        return dict(id=row['id'], kind=req['kind'], count=req['count'], interval=req['interval'], status=row['status'], checkpoint=row['checkpoint'], sequence=row['sequence'], cancelRequested=bool(row['cancel']), events=events)

    def response(self, code, jobs=None):
        row = self.db.execute('SELECT heartbeat FROM health WHERE id=1').fetchone()
        alive = row is not None and 0 <= time.time() - row[0] < ALIVE_WITHIN
        return dict(version=SCHEMA['version'], code=code, alive=alive, jobs=jobs or [])

    def request(self, request):
        # Job observation and cancellation only touch jobs.sqlite. They must
        # remain available while a probe or Xray watchdog owns the filesystem
        # lease during a slow panel call or service restart.
        if request.get('action') in ('status', 'list', 'cancel'):
            return self._request(request)
        import connectivity_probe as probes
        import xray_transaction as upgrade
        try:
            with probes.operation_lock(self):
                action=request.get('action')
                if action in ('submit','resume','panel_cli','panel_connect','probe_begin') and upgrade.active(self):
                    return self.response('xray_check_busy')
                if action=='probe_end' and upgrade.holds_lease(self,request.get('id')):
                    return self.response('xray_check_busy')
                if request.get('action') == 'submit' and probes.active(self):
                    return self.response('probe_busy')
                return self._request(request)
        except probes.ProbeError as error:
            return self.response(error.code)

    def _request(self, request):
        req = validate_request(request)
        action = req['action']
        if action not in ('status', 'list', 'cancel'):
            _load_errors()
        if action in ('egress_state', 'egress_plan', 'egress_check', 'egress_access_plan', 'egress_access_read'):
            import client_egress as egress
            if action == 'egress_check' and self.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
                return self.response('busy')
            try:
                import egress_access
                if action == 'egress_access_plan': result = egress_access.plan(self, req)
                elif action == 'egress_access_read': result = egress_access.result(self, req['id'])
                elif action == 'egress_state': result = egress.public()
                elif action == 'egress_plan': result = egress.plan(self, req)
                else: result = egress.check(self, req['id'])
                return {**self.response('ok'), 'egress': result}
            except egress.EgressError as error:
                return self.response(error.code)
            except Exception:
                return self.response('egress_failed')
        if action == 'component_upgrade_confirm':
            from component_upgrade import confirm_upgrade
            try:
                confirm_upgrade(self, req['id'])
                return self.response('ok')
            except ComponentUpgradeError as error:
                return self.response(error.code if error.code in SCHEMA['codes'] else 'upgrade_failed')
            except Exception:
                return self.response('upgrade_failed')
        if action == 'component_upgrade_check':
            try:
                res = component_upgrade_plan(self, req.get('component'), req.get('payload'))
                return {**self.response('ok'), 'componentUpgrade': res}
            except ComponentUpgradeError as error:
                return self.response(error.code)
            except Exception:
                return self.response('upgrade_failed')
        if action.startswith('xray_check_'):
            import xray_transaction as upgrade
            try:
                if action=='xray_check_plan': value=upgrade.plan(self,req['id'])
                elif action=='xray_check_latest': value=upgrade.latest(self,req['id'])
                elif action=='xray_check_status': value=upgrade.status(self,req)
                elif action=='xray_check_begin': value=upgrade.begin(self,req)
                else: value=upgrade.finish(self,req)
                return {**self.response('ok'),'xrayCheck':value}
            except upgrade.UpdateError as error:return self.response(error.code)
            except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError,VlessError,PanelError):
                return self.response('xray_check_failed')
        if action in ('probe_begin', 'probe_end'):
            import connectivity_probe as probes
            try:
                value = probes.begin(self, req) if action == 'probe_begin' else probes.end(self, req['id'])
                return {**self.response('ok'), 'connectionProbe': value}
            except probes.ProbeError as error:
                return self.response(error.code)
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, VlessError):
                return self.response('probe_failed')
        if action == 'protocol_remove_plan':
            try:
                return {**self.response('ok'), 'removalPlan': protocol_removal_plan(req['protocol'])}
            except RemovalError as error:
                return self.response(error.code)
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, VlessError):
                return self.response('protocol_remove_failed')
        if action in ('ssh_harden_plan', 'ssh_harden_status', 'ssh_harden_confirm', 'ssh_harden_commit', 'ssh_harden_abort'):
            try:
                if action == 'ssh_harden_plan':
                    return {**self.response('ok'), 'sshHardenPlan': ssh_harden_plan(self, req)}
                method = {'ssh_harden_status': SshHardenJob.status,
                          'ssh_harden_confirm': SshHardenJob.confirm,
                          'ssh_harden_commit': SshHardenJob.commit,
                          'ssh_harden_abort': SshHardenJob.abort}[action]
                return {**self.response('ok'), 'sshHardenResult': method(self, req)}
            except SshHardenError as error:
                return self.response(error.code)
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                return self.response('ssh_harden_failed')
        if action == 'panel_update_plan':
            try:
                return {**self.response('ok'), 'panelUpdatePlan': panel_update_plan(self, req['id'])}
            except PanelError as error:
                return self.response(error.code)
            except Exception:
                return self.response('failed')
        if action == 'panel_connect':
            return {**self.response('ok'), 'panelAccess': connect_existing(req['payload']), 'panelVerified': True}
        if action == 'inbound_read':
            return {**self.response('ok'), 'inboundSnapshot': inbound_snapshot(self, req)}
        if action == 'inbound_plan':
            return {**self.response('ok'), 'inboundPlan': (inbound_removal_plan(self, req) if 'removals' in json.loads(req['payload']) else inbound_plan(self, req))}
        if action == 'apt_plan':
            return {**self.response('ok'), 'aptPlan': apt_plan()}
        if action == 'reality_scan':
            result = panel_for(self, req['id']).call('/panel/api/server/scanRealityTarget',
                dict(target=req['target'], sni=req['sni'], xver='0', allowPrivate='false'), form=True)
            return {**self.response('ok'), 'realityScan': result}
        if action == 'panel_cli':
            install_cli()
            discovery, access = discover_panel(self)
            return {**self.response('ok'), 'panelDiscovery': discovery, 'panelAccess': access}
        if action == 'panel_discover':
            discovery, access = discover_panel(self)
            return {**self.response('ok'), 'panelDiscovery': discovery, 'panelAccess': access}
        if action == 'tt_defaults':
            return {**self.response('ok'), 'tt': tt_defaults(self)}
        if action == 'tt_plan':
            return {**self.response('ok'), 'tt': tt_plan(self, req)}
        if action == 'tt_state':
            return {**self.response('ok'), 'tt': {'resources': tt_state(self, req['id'])}}
        if action == 'tt_discover':
            return {**self.response('ok'), 'tt': tt_discovery()}
        if action == 'tt_external_read':
            return {**self.response('ok'), 'tt': tt_snapshot(req['id'])}
        if action == 'tt_external_plan':
            return {**self.response('ok'), 'tt': tt_external_plan(req)}
        if action == 'tt_certificates':
            return {**self.response('ok'), 'tt': tt_certificates()}
        if action == 'tt_certificate_plan':
            return {**self.response('ok'), 'tt': tt_certificate_plan(req)}
        if action == 'submit' and req['kind'] == 'tt_apply':
            TtApply(self, req)
        if action == 'awg_discover':
            return {**self.response('ok'), 'awgExternal': awg_discovery()}
        if action == 'awg_external_read':
            return {**self.response('ok'), 'awgExternal': awg_snapshot(req['id'])}
        if action == 'awg_external_plan':
            return {**self.response('ok'), 'awgExternal': awg_external_plan(req)}
        if action == 'awg_defaults':
            return {**self.response('ok'), 'awgDefaults': awg_defaults(self)}
        if action == 'awg_plan':
            return {**self.response('ok'), 'awgPlan': awg_plan(self, req)}
        if action == 'awg_state':
            return {**self.response('ok'), 'awgState': awg_state(self, req['id'])}
        if action == 'submit' and req['kind'] == 'awg_apply':
            AwgApply(self, req)
        if action == 'vless_plan':
            return {**self.response('ok'), 'vlessPlan': vless_plan(self, req)}
        if action == 'vless_state':
            return {**self.response('ok'), 'vlessState': vless_state(self, req['id'])}
        if action == 'submit' and req['kind'] == 'vless_apply':
            payload = parse_payload(req['payload'])
            if req['count'] != len(payload['resources']) + 2 or req['interval'] != 1:
                raise VlessError()
        if action == 'panel_access':
            external = external_access()
            if external and external['id'] == req['id']:
                panel_for(self, req['id'])
                external = external_access() or external
                return {**self.response('ok'), 'panelAccess': external, 'panelVerified': True}
            row = self.db.execute("SELECT * FROM jobs WHERE id=? AND status='succeeded'", (req['id'],)).fetchone()
            if row is None:
                return self.response('missing')
            original = json.loads(row['request'])
            if original['kind'] != 'panel_install' or not PanelInstaller(self, original).owns():
                return self.response('conflict')
            try:
                PanelInstaller(self, original).assert_owned()
            except (PanelError, OSError):
                return self.response('conflict')
            access = access_for(req['id'], original['port'])
            # Upgrades replace the panel and/or its bundled Xray. Without this
            # the recorded versions stay at the install pins, the app's panel
            # verification fails forever and every VLESS change is deferred.
            from component_upgrade import installed_panel_versions, sync_installed_versions
            actual = installed_panel_versions()
            if actual and any(access.get(k) != v for k, v in actual.items()):
                sync_installed_versions()
                access = access_for(req['id'], original['port'])
            return {**self.response('ok'), 'panelAccess': access}
        if action in ('panel_plan', 'panel_verify', 'component_plan'):
            raise ValueError('invalid')  # Device-side operations, never arbitrary worker commands.
        if action == 'clear_managed_clients':
            # It rewrites the files and services that jobs own; never beside one.
            if self.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
                return self.response('busy')
            try:
                result = clear_managed_clients(self)
                return {**self.response('ok'), 'clearedClients': result}
            except Exception:
                return self.response('clear_managed_clients_failed')
        if action == 'list':
            if self.daemon_stopped():
                with self.db:
                    self.reap_stale_jobs()
            rows = self.db.execute('SELECT * FROM jobs ORDER BY created DESC LIMIT ?', (SCHEMA['pageSize'],)).fetchall()
            return self.response('ok', [self.job(row, row['sequence']) for row in rows])
        self.db.execute('BEGIN IMMEDIATE')
        try:
            stopped = self.daemon_stopped()
            if action != 'cancel' and stopped:
                self.reap_stale_jobs()
            row = self.db.execute('SELECT * FROM jobs WHERE id=?', (req['id'],)).fetchone()
            if action == 'submit':
                if req['kind'] == 'inbound_update' and (row is not None or not self.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone()):
                    req = stage_payload(self, req)
                encoded = json.dumps(req, sort_keys=True, separators=(',', ':'))
                if row is not None:
                    code = 'ok' if row['request'] == encoded else 'conflict'
                elif self.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
                    code = 'busy'
                elif self.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0] >= SCHEMA['maxJobs'] and not self.prune_jobs():
                    code = 'capacity'
                else:
                    self.db.execute('INSERT INTO jobs VALUES (?,?,?,0,0,0,?)', (req['id'], encoded, 'planned', time.time()))
                    self.event(req['id'], 'planned', 0, req['count'])
                    row = self.db.execute('SELECT * FROM jobs WHERE id=?', (req['id'],)).fetchone()
                    code = 'ok'
            elif row is None:
                code = 'missing'
            elif action == 'resume':
                original = json.loads(row['request'])
                if original['kind'] not in ('panel_install', 'panel_update', 'vless_apply', 'awg_apply', 'awg_external_edit', 'tt_apply', 'tt_external_edit', 'tt_certificate', 'component_install', 'protocol_remove', 'inbound_update', 'inbound_remove', 'egress_access') or row['status'] not in ('failed', 'partially_applied'):
                    code = 'conflict'
                elif self.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
                    code = 'busy'
                else:
                    self.db.execute("UPDATE jobs SET status='running', cancel=0 WHERE id=?", (req['id'],))
                    self.event(req['id'], 'recovered', row['checkpoint'], original['count'])
                    row = self.db.execute('SELECT * FROM jobs WHERE id=?', (req['id'],)).fetchone()
                    code = 'ok'
            elif action == 'cancel' and row['status'] not in SCHEMA['terminal']:
                if stopped:
                    # No worker will reach a step boundary: settle it here, and
                    # say so when earlier steps already changed the server.
                    status = 'cancelled' if row['checkpoint'] == 0 or json.loads(row['request'])['kind'] == 'diagnostic' else 'partially_applied'
                    self.db.execute('UPDATE jobs SET status=?, cancel=1 WHERE id=?', (status, req['id']))
                    self.event(req['id'], 'cancelled', row['checkpoint'], json.loads(row['request'])['count'])
                elif not row['cancel']:
                    self.db.execute('UPDATE jobs SET cancel=1 WHERE id=?', (req['id'],))
                    self.event(req['id'], 'cancel_requested', row['checkpoint'], json.loads(row['request'])['count'])
                row = self.db.execute('SELECT * FROM jobs WHERE id=?', (req['id'],)).fetchone()
                code = 'ok'
            else:
                code = 'ok'
            jobs = [self.job(row, req.get('cursor', 0))] if row is not None else []
            self.db.commit()
            return self.response(code, jobs)
        except BaseException:
            self.db.rollback()
            raise

    def daemon_stopped(self):
        """True only when no worker runs: a stale heartbeat alone misreads a
        unit that is still starting after a reboot or restarting after a crash."""
        row = self.db.execute('SELECT heartbeat FROM health WHERE id=1').fetchone()
        if row is None or time.time() - row[0] <= STALE_AFTER:
            return False
        try:
            if float(Path('/proc/uptime').read_text().split()[0]) < BOOT_GRACE:
                return False
        except (OSError, ValueError, IndexError):
            pass
        return not worker_running(self.directory)

    def reap_stale_jobs(self):
        """Settle jobs of a stopped worker. Callers own the transaction."""
        cutoff = time.time() - STALE_AFTER
        rows = self.db.execute(
            "SELECT * FROM jobs WHERE status IN ('planned','running') AND (created < ? OR cancel=1)",
            (cutoff,)).fetchall()
        for r in rows:
            request = json.loads(r['request'])
            if r['checkpoint'] > 0 and request['kind'] != 'diagnostic':
                status = 'partially_applied'  # Earlier steps changed the server.
            else:
                status = 'cancelled' if r['cancel'] else 'failed'
            self.db.execute('UPDATE jobs SET status=? WHERE id=?', (status, r['id']))
            self.event(r['id'], 'cancelled' if r['cancel'] else 'failed', r['checkpoint'], request['count'])

    def prune_jobs(self):
        """Free room for new jobs by forgetting old finished history.

        Only terminal jobs older than RETAIN_SECONDS go, never a kind whose row
        is an ownership/result record, nor the last job of a resource (its
        readback is confirmed through that row). Runs inside the caller's
        transaction. Returns whether a slot is free."""
        referenced = set()
        for table in ('vless_resources', 'awg_resources', 'tt_resources'):
            for (data,) in self.db.execute('SELECT data FROM ' + table):
                try:
                    referenced.add(json.loads(data).get('jobId'))
                except (ValueError, AttributeError):
                    continue
        keep = SCHEMA['maxJobs'] - SCHEMA['pageSize']
        total = self.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0]
        marks = ','.join('?' * len(SCHEMA['terminal']))
        removed = []
        for row in self.db.execute('SELECT id, request FROM jobs WHERE status IN (' + marks + ') AND created < ? ORDER BY created',
                                   (*SCHEMA['terminal'], time.time() - RETAIN_SECONDS)).fetchall():
            if total - len(removed) <= keep:
                break
            if row['id'] in referenced or json.loads(row['request']).get('kind') in RETAINED_KINDS:
                continue
            removed.append(row['id'])
        for job_id in removed:
            self.db.execute('DELETE FROM jobs WHERE id=?', (job_id,))
            self.db.execute('DELETE FROM events WHERE id=?', (job_id,))
            self.db.execute('DELETE FROM step_crashes WHERE id=?', (job_id,))
        for job_id in removed:
            cleanup_job_transients(self.directory, job_id)
        return total - len(removed) < SCHEMA['maxJobs']

    def record_crash(self, job_id, checkpoint):
        """Count unexpected step crashes; return the attempts at this checkpoint."""
        with self.db:
            row = self.db.execute('SELECT checkpoint, attempts FROM step_crashes WHERE id=?', (job_id,)).fetchone()
            attempts = row['attempts'] + 1 if row is not None and row['checkpoint'] == checkpoint else 1
            self.db.execute('INSERT OR REPLACE INTO step_crashes VALUES (?,?,?)', (job_id, checkpoint, attempts))
        return attempts

    def park(self, job_id):
        """A step that keeps crashing needs a person, not a restart loop that
        ends with systemd giving up on the whole runner."""
        with self.db:
            row = self.db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone()
            if row is None or row['status'] in SCHEMA['terminal']:
                return
            self.db.execute("UPDATE jobs SET status='needs_attention' WHERE id=?", (job_id,))
            self.event(job_id, 'failed', row['checkpoint'], json.loads(row['request'])['count'])
            self.db.execute('DELETE FROM step_crashes WHERE id=?', (job_id,))

    def heartbeat(self):
        with self.db:
            self.db.execute('INSERT OR REPLACE INTO health VALUES (1,?)', (time.time(),))

    def finish(self, job_id, status, code, total):
        """Terminal status and its event, at the checkpoint the steps reached."""
        with self.db:
            progress = self.db.execute('SELECT checkpoint FROM jobs WHERE id=?', (job_id,)).fetchone()[0]
            self.db.execute('UPDATE jobs SET status=? WHERE id=?', (status, job_id))
            self.event(job_id, code, progress, total)
            self.db.execute('DELETE FROM step_crashes WHERE id=?', (job_id,))

    def recover(self):
        # Every admitted task defines recovery. Effectful steps verify owned
        # state before repeating a possibly completed API operation.
        with self.db:
            for row in self.db.execute("SELECT * FROM jobs WHERE status='running'").fetchall():
                self.event(row['id'], 'recovered', row['checkpoint'], json.loads(row['request'])['count'])

    def tick(self):
        # The heartbeat thread beats every HEARTBEAT_INTERVAL; an idle tick is
        # a read only (it used to commit a heartbeat four times a second).
        self.current = None
        row = self.db.execute("SELECT * FROM jobs WHERE status IN ('planned','running') ORDER BY created LIMIT 1").fetchone()
        if row is None:
            return 0.25
        _load_errors()
        req = validate_request(json.loads(row['request']))
        job_id = row['id']
        self.current = (job_id, row['checkpoint'])
        with self.db:
            if row['cancel'] and req['kind'] == 'diagnostic':
                self.db.execute("UPDATE jobs SET status='cancelled' WHERE id=?", (job_id,))
                self.event(job_id, 'cancelled', row['checkpoint'], req['count'])
                return 0.1
            if row['status'] == 'planned':
                self.db.execute("UPDATE jobs SET status='running' WHERE id=?", (job_id,))
                self.event(job_id, 'running', row['checkpoint'], req['count'])
        if req['kind'] in ('egress_apply', 'egress_access'):
            import client_egress as egress
            import egress_access
            task = egress.EgressApply(self, req) if req['kind'] == 'egress_apply' else egress_access.AccessApply(self, req)
            try:
                if row['cancel']:
                    if task.path.exists(): task.rollback()
                    status, code = 'cancelled', 'cancelled'
                else:
                    task.step(row['checkpoint'])
                    if row['checkpoint'] + 1 < req['count']: return .1
                    status, code = 'succeeded', 'succeeded'
            except Exception as error:
                code = error.code if isinstance(error, egress.EgressError) else 'egress_failed'
                status = 'failed'
                if task.path.exists():
                    try: task.rollback()
                    except Exception:
                        status, code = 'needs_attention', 'egress_rollback_failed'
            self.finish(job_id, status, code, req['count'])
            return .1
        if req['kind']=='server_reboot':
            import server_reboot as reboot
            try:
                if row['cancel'] and row['checkpoint']==0 and not reboot.record_path(self,job_id).exists():
                    status,code='cancelled','cancelled'
                elif not reboot.poll(self,req):return 1
                else:status,code='succeeded','server_reboot_done'
            except Exception:status,code='needs_attention','server_reboot_failed'
            with self.db:
                self.db.execute('UPDATE jobs SET status=?,checkpoint=? WHERE id=?',(status,2 if status=='succeeded' else row['checkpoint'],job_id))
                self.event(job_id,code,2 if status=='succeeded' else row['checkpoint'],2)
            return .1
        if req['kind'] in ('apt_update', 'apt_upgrade'):
            task = AptJob(self, req)
            try:
                if row['cancel']:
                    status = task.abort() if hasattr(task, 'abort') and row['checkpoint'] == 0 else ('cancelled' if row['checkpoint'] == 0 and not task.marker.exists() else 'partially_applied')
                    code = 'cancelled' if status == 'cancelled' else 'apt_interrupted'
                else:
                    task.step(row['checkpoint'])
                    if row['checkpoint'] + 1 < req['count']:
                        return 0.1
                    status, code = 'succeeded', 'succeeded'
            except (AptError, OSError, ValueError, subprocess.SubprocessError) as error:
                code = error.code if isinstance(error, AptError) else 'apt_failed'
                status = task.failure_status()
            self.finish(job_id, status, code, req['count'])
            if status == 'succeeded' or (status == 'cancelled' and row['checkpoint'] == 0):
                cleanup_job_transients(self.directory, job_id)
            return 0.1
        if req['kind'] in ('vless_apply', 'awg_apply', 'awg_external_edit', 'inbound_update', 'inbound_remove', 'tt_apply', 'tt_external_edit', 'tt_certificate'):
            task = (InboundRemove(self, req) if req['kind'] == 'inbound_remove' else TtApply(self, req) if req['kind'] == 'tt_apply' else ExternalTtEdit(self, req) if req['kind'] == 'tt_external_edit' else CertificateJob(self, req) if req['kind'] == 'tt_certificate' else ObservedInboundEdit(self, req) if req['kind'] == 'inbound_update' else ExternalAwgEdit(self, req) if req['kind'] == 'awg_external_edit' else AwgApply(self, req) if req['kind'] == 'awg_apply' else VlessApply(self, req))
            try:
                if row['cancel']:
                    status = 'partially_applied' if row['checkpoint'] > 0 else 'cancelled'
                    code = 'vless_partial' if status == 'partially_applied' else 'cancelled'
                    if status == 'cancelled' and hasattr(task, 'rollback'):
                        try: task.rollback()
                        except Exception: pass
                else:
                    task.step(row['checkpoint'])
                    if row['checkpoint'] + 1 < req['count']:
                        return 0.1
                    status, code = 'succeeded', 'succeeded'
            except (VlessError, PanelError, OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError):
                # Upstream errors can contain credentials; never persist text.
                error = sys.exc_info()[1]
                if isinstance(error, TtError) and error.code == 'tt_busy':
                    return 0.5  # The independent certificate watcher owns the lock.
                code = error.code if isinstance(error, VlessError) else 'tt_failed' if req['kind'].startswith('tt_') else 'awg_failed' if req['kind'] in ('awg_apply', 'awg_external_edit') else 'vless_api_failed'
                status = 'partially_applied' if row['checkpoint'] > 0 else 'failed'
            self.finish(job_id, status, code, req['count'])
            if status == 'succeeded' or (status == 'cancelled' and row['checkpoint'] == 0):
                cleanup_job_transients(self.directory, job_id)
            return 0.1
        if req['kind'] == 'protocol_remove':
            try:
                if row['cancel']:
                    status = 'partially_applied' if row['checkpoint'] > 0 else 'cancelled'
                    code = 'cancelled'
                else:
                    ProtocolRemoval(self, req).step(row['checkpoint'])
                    if row['checkpoint'] + 1 < req['count']:
                        return 0.1
                    status, code = 'succeeded', 'succeeded'
            except (RemovalError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                code = error.code if isinstance(error, RemovalError) else 'protocol_remove_failed'
                status = 'partially_applied' if row['checkpoint'] > 0 else 'failed'
            self.finish(job_id, status, code, req['count'])
            return 0.1
        if req['kind'] == 'ssh_harden':
            SshHardenJob(self, req).tick()
            return 0.5
        if req['kind'] == 'component_upgrade_apply':
            task = ComponentUpgradeJob(self, req)
            try:
                if row['cancel']:
                    task.rollback()
                    status, code = 'cancelled', 'cancelled'
                else:
                    task.step(row['checkpoint'])
                    if row['checkpoint'] + 1 < req['count']:
                        return 0.1
                    status, code = 'succeeded', 'succeeded'
            except (ComponentUpgradeError, OSError, ValueError, subprocess.SubprocessError) as error:
                code = error.code if isinstance(error, ComponentUpgradeError) else 'upgrade_failed'
                # Code and type only: error text may quote upstream output.
                sys.stderr.write(f"[runner] component_upgrade failed ({code}): {type(error).__name__}\n")
                status = 'failed'
                try:
                    task.rollback()
                    if code == 'upgrade_healthcheck_failed':
                        code = 'upgrade_rolled_back'
                except Exception:
                    status, code = 'needs_attention', 'upgrade_rollback_failed'
            self.finish(job_id, status, code, req['count'])
            if status == 'succeeded':
                # The backup stays until the app confirms or the window expires.
                from component_upgrade import window_open
                if not window_open(self.directory, job_id):
                    cleanup_job_transients(self.directory, job_id)
                else:
                    for leftover in ('staging', 'release_archive'):
                        target = self.directory / ('upgrade-' + job_id) / leftover
                        if target.is_dir():
                            shutil.rmtree(str(target), ignore_errors=True)
                        elif target.exists():
                            target.unlink()
            elif status in ('cancelled', 'failed'):
                # Rolled back (or never switched): archive, staging and backup
                # are of no further use. needs_attention keeps them.
                cleanup_job_transients(self.directory, job_id)
            return 0.1
        if req['kind'] == 'component_install':
            installer = ComponentInstaller(self, req)
            try:
                if row['cancel']:
                    status = installer.abort()
                    code = 'component_partial' if status == 'partially_applied' else 'cancelled'
                else:
                    if installer.step(row['checkpoint']) is False:
                        return 0.5
                    if row['checkpoint'] + 1 < req['count']:
                        return 0.1
                    status, code = 'succeeded', 'succeeded'
            except (ComponentError, PanelError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                code = error.code if isinstance(error, ComponentError) else 'component_partial'
                status = installer.abort()
                if status == 'cancelled' and code != 'cancelled':
                    status = 'failed'
            self.finish(job_id, status, code, req['count'])
            if status == 'succeeded':
                slim_finished_job(self.directory, job_id)
            return 0.1
        if req['kind'] in ('panel_install', 'panel_update'):
            installer = (PanelUpdate if req['kind'] == 'panel_update' else PanelInstaller)(self, req)
            try:
                if row['cancel']:
                    status = installer.abort()
                    code = 'panel_cancelled_partial' if status == 'partially_applied' else 'cancelled'
                else:
                    installer.step(row['checkpoint'])
                    if row['checkpoint'] + 1 < req['count']:
                        return 0.1
                    status, code = 'succeeded', 'succeeded'
            except (PanelError, OSError, ValueError, subprocess.SubprocessError) as error:
                code = error.code if isinstance(error, PanelError) else 'panel_partial'
                status = installer.abort()
                if code != 'cancelled' and status == 'cancelled':
                    status = 'failed'
                if code == 'cancelled' and status == 'partially_applied':
                    code = 'panel_cancelled_partial'
            self.finish(job_id, status, code, req['count'])
            if status == 'succeeded':
                slim_finished_job(self.directory, job_id)
            return 0.1
        # Real, bounded probes. No configs, environment, logins or keys are read.
        try:
            uptime = float(Path('/proc/uptime').read_text().split()[0])
            disk = os.statvfs('/')
            if uptime < 0 or disk.f_bsize <= 0:
                raise ValueError('failed')
        except (OSError, ValueError):
            with self.db:
                self.db.execute("UPDATE jobs SET status='failed' WHERE id=?", (job_id,))
                self.event(job_id, 'failed', row['checkpoint'], req['count'])
            return 0.1
        progress = row['checkpoint'] + 1
        # Checkpoint + event + terminal state commit atomically. Re-reading the
        # probes after a crash before this commit is harmless.
        with self.db:
            self.db.execute('UPDATE jobs SET checkpoint=? WHERE id=?', (progress, job_id))
            self.event(job_id, 'sample', progress, req['count'])
            if progress == req['count']:
                self.db.execute("UPDATE jobs SET status='succeeded' WHERE id=?", (job_id,))
                self.event(job_id, 'succeeded', progress, req['count'])
        return req['interval']


def daemon(directory=STATE):
    # FD lifetime, not a timestamp/PID file, owns the exclusive worker lock.
    with (directory / 'worker.lock').open('a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        store = Store(directory)
        heartbeat_stop = threading.Event()
        store.heartbeat()  # Before recovery, which may take a while.
        def heartbeat_loop():
            health_store = Store(directory)
            try:
                while not heartbeat_stop.wait(HEARTBEAT_INTERVAL):
                    health_store.heartbeat()
            finally:
                health_store.close()
        heartbeat_thread = threading.Thread(target=heartbeat_loop, daemon=True)
        heartbeat_thread.start()
        stopping = False
        def stop(_signal, _frame):
            nonlocal stopping
            stopping = True
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            store.recover()
            try:
                from component_upgrade import recover_deadmen
                recover_deadmen(store)
            except Exception as error:
                sys.stderr.write(f'[runner] deadman recovery skipped: {type(error).__name__}\n')
            try:
                slim_finished_jobs(store)
            except Exception as error:
                sys.stderr.write(f'[runner] job directory sweep skipped: {type(error).__name__}\n')
            while not stopping:
                try:
                    delay = store.tick()
                except BaseException as error:
                    # Say where it broke without the message, which may carry
                    # panel responses or credentials.
                    import traceback
                    frames = traceback.extract_tb(error.__traceback__)[-3:]
                    where = ' <- '.join(f'{Path(f.filename).name}:{f.lineno}' for f in reversed(frames))
                    sys.stderr.write(f'[runner] job step failed: {type(error).__name__} at {where}\n')
                    sys.stderr.flush()
                    current = getattr(store, 'current', None)
                    if current is None or not isinstance(error, Exception):
                        raise
                    try:
                        store.db.rollback()
                        if store.record_crash(*current) < MAX_STEP_CRASHES:
                            raise error  # A fresh process resumes from the checkpoint.
                        store.park(current[0])
                        sys.stderr.write('[runner] job parked as needs_attention after repeated crashes\n')
                    except sqlite3.Error:
                        raise error
                    delay = 1
                deadline = time.monotonic() + delay
                while not stopping and time.monotonic() < deadline:
                    time.sleep(min(0.1, max(0, deadline - time.monotonic())))
        finally:
            heartbeat_stop.set()
            heartbeat_thread.join(timeout=6)
            store.close()


def write_rpc_response(payload):
    encoded = (json.dumps(payload) + '\n').encode('utf-8')
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()


def main():
    os.umask(0o077)
    if os.geteuid() != 0 or len(sys.argv) != 2:
        raise ValueError('invalid')
    if sys.argv[1] == 'daemon':
        daemon()
        return
    if sys.argv[1] != 'rpc' or not (STATE / 'jobs.sqlite').is_file():
        raise ValueError('missing')
    import warnings
    warnings.simplefilter('ignore')
    print(INPUT_PROMPT, file=sys.stderr, flush=True)
    raw = sys.stdin.buffer.read(SCHEMA['maxRequestBytes'] + 1)
    if len(raw) > SCHEMA['maxRequestBytes']:
        raise ValueError('invalid')
    req = validate_request(strict_json(raw))
    lock = os.open('/usr/local/lib', os.O_RDONLY | os.O_DIRECTORY)
    fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
    store = Store(STATE)
    try:
        write_rpc_response(store.request(req))
    finally:
        store.close()
        os.close(lock)


if __name__ == '__main__':
    try:
        main()
    except BlockingIOError:
        write_rpc_response(dict(version=SCHEMA['version'], code='busy', alive=False, jobs=[]))
        sys.exit(1)
    except sqlite3.OperationalError as error:
        code = 'busy' if 'lock' in str(error).lower() or 'busy' in str(error).lower() else 'failed'
        write_rpc_response(dict(version=SCHEMA['version'], code=code, alive=False, jobs=[]))
        sys.exit(1)
    except Exception as error:  # Upstream text may carry credentials; answer with a code only.
        code = getattr(error, 'code', str(error))
        if code not in SCHEMA['codes']:
            code = 'failed'
        write_rpc_response(dict(version=SCHEMA['version'], code=code, alive=False, jobs=[]))
        sys.exit(1)
