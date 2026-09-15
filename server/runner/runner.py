#!/usr/bin/env python3
"""Private SSH RPC and durable diagnostic worker. No user-supplied commands."""
import fcntl
import json
import os
from pathlib import Path
import signal
import sqlite3
import sys
import time
import threading
import subprocess

sys.path.insert(0, str(Path(__file__).resolve().parent))
from panel_discovery import discover as discover_panel, connect_existing, external_access
from components import ComponentInstaller, ComponentError
from protocol_remove import ProtocolRemoval, RemovalError, plan as removal_plan
from ssh_harden import SshHardenJob, SshHardenError, rollback as ssh_harden_rollback, backup_path as ssh_harden_backup_path, plan as ssh_harden_plan
from observed_inbounds import ObservedInboundEdit, snapshot as inbound_snapshot, plan as inbound_plan, stage_payload
from apt import AptJob, AptError, plan as apt_plan
from contract import SCHEMA, validate_request
from panel import PanelInstaller, PanelError, access_for, install_cli
from panel_update import PanelUpdate, plan as panel_update_plan
from awg_external import ExternalAwgEdit, discovery as awg_discovery, public_snapshot as awg_snapshot, plan as awg_external_plan
from tt import TtApply, plan as tt_plan, state as tt_state, defaults as tt_defaults
from tt_external import ExternalTtEdit, discovery as tt_discovery, public_snapshot as tt_snapshot, plan as tt_external_plan
from tt_certificates import CertificateJob, inventory as tt_certificates, plan as tt_certificate_plan
from tt_common import TtError
from awg import AwgApply, AwgError, plan as awg_plan, state as awg_state, defaults as awg_defaults
from vless import VlessApply, VlessError, parse_payload, plan as vless_plan, state as vless_state, panel_for

STATE = Path('/var/lib/antirkn-runner')
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


class Store:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.db = sqlite3.connect(str(self.directory / 'jobs.sqlite'), timeout=5)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        version = self.db.execute('PRAGMA user_version').fetchone()[0]
        if version not in (0, SCHEMA['version']):
            self.db.close()
            raise ValueError('incompatible')
        with self.db:
            self.db.execute('CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, request TEXT NOT NULL, status TEXT NOT NULL, checkpoint INTEGER NOT NULL, sequence INTEGER NOT NULL, cancel INTEGER NOT NULL, created REAL NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS events (id TEXT NOT NULL, sequence INTEGER NOT NULL, event TEXT NOT NULL, PRIMARY KEY(id,sequence))')
            self.db.execute('CREATE TABLE IF NOT EXISTS health (id INTEGER PRIMARY KEY, heartbeat REAL NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS vless_resources (id TEXT PRIMARY KEY, data TEXT NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS tt_resources (id TEXT PRIMARY KEY, data TEXT NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS awg_resources (id TEXT PRIMARY KEY, data TEXT NOT NULL)')
            self.db.execute('CREATE TABLE IF NOT EXISTS revoked_clients (workspace TEXT NOT NULL, user TEXT NOT NULL, PRIMARY KEY(workspace,user))')
            self.db.execute('PRAGMA user_version=1')

    def close(self):
        self.db.close()

    def event(self, job_id, code, progress, total):
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
        alive = row is not None and 0 <= time.time() - row[0] < 15
        return dict(version=SCHEMA['version'], code=code, alive=alive, jobs=jobs or [])

    def request(self, request):
        req = validate_request(request)
        action = req['action']
        if action == 'protocol_remove_plan':
            return {**self.response('ok'), 'removalPlan': removal_plan(req['protocol'])}
        if action == 'ssh_harden_plan':
            return {**self.response('ok'), 'sshHardenPlan': ssh_harden_plan(self, req)}
        if action == 'ssh_harden_confirm':
            try:
                res = SshHardenJob.confirm(self, req)
                return {**self.response('ok'), 'sshHardenResult': res}
            except SshHardenError as error:
                return self.response(error.code)
        if action == 'ssh_harden_abort':
            try:
                res = SshHardenJob.abort(self, req)
                return {**self.response('ok'), 'sshHardenResult': res}
            except SshHardenError as error:
                return self.response(error.code)
        if action == 'panel_update_plan':
            return {**self.response('ok'), 'panelUpdatePlan': panel_update_plan(self, req['id'])}
        if action == 'panel_connect':
            return {**self.response('ok'), 'panelAccess': connect_existing(req['payload']), 'panelVerified': True}
        if action == 'inbound_read':
            return {**self.response('ok'), 'inboundSnapshot': inbound_snapshot(self, req)}
        if action == 'inbound_plan':
            return {**self.response('ok'), 'inboundPlan': inbound_plan(self, req)}
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
            return {**self.response('ok'), 'panelAccess': access_for(req['id'], original['port'])}
        if action in ('panel_plan', 'panel_verify', 'component_plan'):
            raise ValueError('invalid')  # Device-side operations, never arbitrary worker commands.
        if action == 'list':
            rows = self.db.execute('SELECT * FROM jobs ORDER BY created DESC LIMIT ?', (SCHEMA['pageSize'],)).fetchall()
            return self.response('ok', [self.job(row, row['sequence']) for row in rows])
        self.db.execute('BEGIN IMMEDIATE')
        try:
            row = self.db.execute('SELECT * FROM jobs WHERE id=?', (req['id'],)).fetchone()
            if action == 'submit':
                if req['kind'] == 'inbound_update' and (row is not None or not self.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone()):
                    req = stage_payload(self, req)
                encoded = json.dumps(req, sort_keys=True, separators=(',', ':'))
                if row is not None:
                    code = 'ok' if row['request'] == encoded else 'conflict'
                elif self.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
                    code = 'busy'
                elif self.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0] >= SCHEMA['maxJobs']:
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
                if original['kind'] not in ('panel_install', 'panel_update', 'vless_apply', 'awg_apply', 'awg_external_edit', 'tt_apply', 'tt_external_edit', 'tt_certificate', 'component_install', 'protocol_remove', 'inbound_update') or row['status'] not in ('failed', 'partially_applied'):
                    code = 'conflict'
                elif self.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
                    code = 'busy'
                else:
                    self.db.execute("UPDATE jobs SET status='running', cancel=0 WHERE id=?", (req['id'],))
                    self.event(req['id'], 'recovered', row['checkpoint'], original['count'])
                    row = self.db.execute('SELECT * FROM jobs WHERE id=?', (req['id'],)).fetchone()
                    code = 'ok'
            elif action == 'cancel' and row['status'] not in SCHEMA['terminal']:
                if not row['cancel']:
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

    def heartbeat(self):
        with self.db:
            self.db.execute('INSERT OR REPLACE INTO health VALUES (1,?)', (time.time(),))

    def recover(self):
        # Every admitted task defines recovery. Effectful steps verify owned
        # state before repeating a possibly completed API operation.
        with self.db:
            for row in self.db.execute("SELECT * FROM jobs WHERE status='running'").fetchall():
                self.event(row['id'], 'recovered', row['checkpoint'], json.loads(row['request'])['count'])

    def tick(self):
        self.heartbeat()
        row = self.db.execute("SELECT * FROM jobs WHERE status IN ('planned','running') ORDER BY created LIMIT 1").fetchone()
        if row is None:
            return 0.25
        req = validate_request(json.loads(row['request']))
        job_id = row['id']
        with self.db:
            if row['cancel'] and req['kind'] == 'diagnostic':
                self.db.execute("UPDATE jobs SET status='cancelled' WHERE id=?", (job_id,))
                self.event(job_id, 'cancelled', row['checkpoint'], req['count'])
                return 0.1
            if row['status'] == 'planned':
                self.db.execute("UPDATE jobs SET status='running' WHERE id=?", (job_id,))
                self.event(job_id, 'running', row['checkpoint'], req['count'])
        if req['kind'] in ('apt_update', 'apt_upgrade'):
            task = AptJob(self, req)
            try:
                if row['cancel']:
                    status = 'cancelled' if row['checkpoint'] == 0 and not task.marker.exists() else 'partially_applied'
                    code = 'cancelled' if status == 'cancelled' else 'apt_interrupted'
                else:
                    task.step(row['checkpoint'])
                    if row['checkpoint'] + 1 < req['count']:
                        return 0.1
                    status, code = 'succeeded', 'succeeded'
            except (AptError, OSError, ValueError, subprocess.SubprocessError) as error:
                code = error.code if isinstance(error, AptError) else 'apt_failed'
                status = task.failure_status()
            with self.db:
                progress = self.db.execute('SELECT checkpoint FROM jobs WHERE id=?', (job_id,)).fetchone()[0]
                self.db.execute('UPDATE jobs SET status=? WHERE id=?', (status, job_id))
                self.event(job_id, code, progress, req['count'])
            return 0.1
        if req['kind'] in ('vless_apply', 'awg_apply', 'awg_external_edit', 'inbound_update', 'tt_apply', 'tt_external_edit', 'tt_certificate'):
            try:
                if row['cancel']:
                    # After preflight, an API effect may already have happened
                    # without its checkpoint (lost reply or database failure).
                    status = 'partially_applied' if row['checkpoint'] > 0 else 'cancelled'
                    code = 'vless_partial' if status == 'partially_applied' else 'cancelled'
                else:
                    (TtApply(self, req) if req['kind'] == 'tt_apply' else ExternalTtEdit(self, req) if req['kind'] == 'tt_external_edit' else CertificateJob(self, req) if req['kind'] == 'tt_certificate' else ObservedInboundEdit(self, req) if req['kind'] == 'inbound_update' else ExternalAwgEdit(self, req) if req['kind'] == 'awg_external_edit' else AwgApply(self, req) if req['kind'] == 'awg_apply' else VlessApply(self, req)).step(row['checkpoint'])
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
            with self.db:
                progress = self.db.execute('SELECT checkpoint FROM jobs WHERE id=?', (job_id,)).fetchone()[0]
                self.db.execute('UPDATE jobs SET status=? WHERE id=?', (status, job_id))
                self.event(job_id, code, progress, req['count'])
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
            with self.db:
                progress = self.db.execute('SELECT checkpoint FROM jobs WHERE id=?', (job_id,)).fetchone()[0]
                self.db.execute('UPDATE jobs SET status=? WHERE id=?', (status, job_id))
                self.event(job_id, code, progress, req['count'])
            return 0.1
        if req['kind'] == 'ssh_harden':
            try:
                if row['cancel']:
                    SshHardenJob.abort(self, req)
                    return 0.1
                harden_job = SshHardenJob(self, req)
                if row['checkpoint'] < 6:
                    harden_job.step(row['checkpoint'])
                    return 0.1
                bdir = ssh_harden_backup_path(job_id)
                if (bdir / 'rolled_back').exists():
                    with self.db:
                        self.db.execute("UPDATE jobs SET status='failed' WHERE id=?", (job_id,))
                        self.event(job_id, 'ssh_harden_aborted', 6, req['count'])
                    return 0.5
                return 1.0
            except (SshHardenError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                ssh_harden_rollback(job_id)
                code = error.code if isinstance(error, SshHardenError) else 'ssh_harden_failed'
                with self.db:
                    progress = self.db.execute('SELECT checkpoint FROM jobs WHERE id=?', (job_id,)).fetchone()[0]
                    self.db.execute("UPDATE jobs SET status='failed' WHERE id=?", (job_id,))
                    self.event(job_id, code, progress, req['count'])
                return 0.1
        if req['kind'] == 'component_install':
            installer = ComponentInstaller(self, req)
            try:
                if row['cancel']:
                    status = installer.abort()
                    code = 'component_partial' if status == 'partially_applied' else 'cancelled'
                else:
                    installer.step(row['checkpoint'])
                    if row['checkpoint'] + 1 < req['count']:
                        return 0.1
                    status, code = 'succeeded', 'succeeded'
            except (ComponentError, PanelError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                code = error.code if isinstance(error, ComponentError) else 'component_partial'
                status = installer.abort()
                if status == 'cancelled' and code != 'cancelled':
                    status = 'failed'
            with self.db:
                progress = self.db.execute('SELECT checkpoint FROM jobs WHERE id=?', (job_id,)).fetchone()[0]
                self.db.execute('UPDATE jobs SET status=? WHERE id=?', (status, job_id))
                self.event(job_id, code, progress, req['count'])
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
            with self.db:
                progress = self.db.execute('SELECT checkpoint FROM jobs WHERE id=?', (job_id,)).fetchone()[0]
                self.db.execute('UPDATE jobs SET status=? WHERE id=?', (status, job_id))
                self.event(job_id, code, progress, req['count'])
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
        def heartbeat_loop():
            health_store = Store(directory)
            try:
                while not heartbeat_stop.wait(3):
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
            while not stopping:
                delay = store.tick()
                deadline = time.monotonic() + delay
                while not stopping and time.monotonic() < deadline:
                    time.sleep(min(0.1, max(0, deadline - time.monotonic())))
        finally:
            heartbeat_stop.set()
            heartbeat_thread.join(timeout=6)
            store.close()


def main():
    os.umask(0o077)
    if os.geteuid() != 0 or len(sys.argv) != 2:
        raise ValueError('invalid')
    if sys.argv[1] == 'daemon':
        daemon()
        return
    if sys.argv[1] != 'rpc' or not (STATE / 'jobs.sqlite').is_file():
        raise ValueError('missing')
    print(INPUT_PROMPT, file=sys.stderr, flush=True)
    raw = sys.stdin.buffer.read(SCHEMA['maxRequestBytes'] + 1)
    if len(raw) > SCHEMA['maxRequestBytes']:
        raise ValueError('invalid')
    req = validate_request(strict_json(raw))
    lock = os.open('/usr/local/lib', os.O_RDONLY | os.O_DIRECTORY)
    fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
    store = Store(STATE)
    try:
        print(json.dumps(store.request(req)), flush=True)
    finally:
        store.close()
        os.close(lock)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, TypeError, KeyError, AttributeError, OSError, sqlite3.Error, VlessError, PanelError, AptError, subprocess.SubprocessError) as error:
        code = error.code if isinstance(error, VlessError) else str(error) if str(error) in SCHEMA['codes'] else 'failed'
        print(json.dumps(dict(version=SCHEMA['version'], code=code, alive=False, jobs=[])), flush=True)
        sys.exit(1)
