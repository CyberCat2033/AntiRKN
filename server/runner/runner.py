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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contract import SCHEMA, validate_request

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
        return dict(id=row['id'], kind='diagnostic', count=req['count'], interval=req['interval'], status=row['status'], checkpoint=row['checkpoint'], sequence=row['sequence'], cancelRequested=bool(row['cancel']), events=events)

    def response(self, code, jobs=None):
        row = self.db.execute('SELECT heartbeat FROM health WHERE id=1').fetchone()
        alive = row is not None and 0 <= time.time() - row[0] < 15
        return dict(version=SCHEMA['version'], code=code, alive=alive, jobs=jobs or [])

    def request(self, request):
        req = validate_request(request)
        action = req['action']
        if action == 'list':
            rows = self.db.execute('SELECT * FROM jobs ORDER BY created DESC LIMIT ?', (SCHEMA['pageSize'],)).fetchall()
            return self.response('ok', [self.job(row, row['sequence']) for row in rows])
        self.db.execute('BEGIN IMMEDIATE')
        try:
            row = self.db.execute('SELECT * FROM jobs WHERE id=?', (req['id'],)).fetchone()
            if action == 'submit':
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
        # Only this read-only, checkpointed task is resumable. Future effectful
        # task kinds must define recovery before being admitted by the schema.
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
            if row['cancel']:
                self.db.execute("UPDATE jobs SET status='cancelled' WHERE id=?", (job_id,))
                self.event(job_id, 'cancelled', row['checkpoint'], req['count'])
                return 0.1
            if row['status'] == 'planned':
                self.db.execute("UPDATE jobs SET status='running' WHERE id=?", (job_id,))
                self.event(job_id, 'running', row['checkpoint'], req['count'])
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
    store = Store(STATE)
    try:
        print(json.dumps(store.request(req)), flush=True)
    finally:
        store.close()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, sqlite3.Error) as error:
        code = str(error) if str(error) in SCHEMA['codes'] else 'failed'
        print(json.dumps(dict(version=SCHEMA['version'], code=code, alive=False, jobs=[])), flush=True)
        sys.exit(1)
