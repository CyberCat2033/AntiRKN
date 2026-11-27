"""Per-client traffic accounting for managed VLESS, AmneziaWG and TrustTunnel.

Protocol counters are cumulative but not durable: an AWG interface restart,
a TrustTunnel endpoint restart or a re-created 3x-ui client starts them again
from zero. A small ledger folds every reading into a lifetime and a monthly
sum (the last ``MONTHS`` calendar months, UTC) per protocol/resource/user, so
no time series and no connection data is kept.

Sampling is cheap and bounded: one read-only query of the 3x-ui database, one
``awg show transfer`` per interface and one loopback HTTP request per
TrustTunnel endpoint, each with a timeout. The daemon samples every
``INTERVAL`` and before a job starts (a job may restart a service and reset
its counters); ``traffic_read`` samples once more before it answers.

A counter that disappeared (deleted client, stopped endpoint) is left as it
was: only a reading that is present updates the ledger. A smaller reading or a
new counter epoch (3x-ui row id, interface index, service invocation) is a
restart: the whole reading is new traffic. "down" is what the client
downloaded, "up" what it uploaded."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import sqlite3
import time
import urllib.request
from pathlib import Path

LEDGER = 'traffic.json'
LOCK = 'traffic.lock'
INTERVAL = 900
MONTHS = 12
FORGET_AFTER = 400 * 86400
METRICS_PORT = 1987
MAX_METRICS = 4 * 1024 * 1024
MAX_LEDGER = 16 * 1024 * 1024
TABLES = {'vless': 'vless_resources', 'awg': 'awg_resources', 'tt': 'tt_resources'}


class Unavailable(Exception):
    """The counters of one resource could not be read this time."""


class Off(Exception):
    """The resource does not count traffic per client (TrustTunnel metrics off)."""


def metrics_address(rid, endpoint_port=None):
    """A loopback address of its own for each managed TrustTunnel endpoint:
    deterministic, so no state, and distinct, so several endpoints coexist.
    The port differs from the endpoint's own, which may listen on 0.0.0.0."""
    h = hashlib.sha256(('antirkn-tt-metrics/' + rid).encode()).digest()
    port = METRICS_PORT if endpoint_port != METRICS_PORT else METRICS_PORT + 1
    return '127.%d.%d.%d' % (h[0], h[1], 1 + h[2] % 254), port


def month_of(ts):
    return time.strftime('%Y-%m', time.gmtime(ts))


def kept_months(ts):
    year, month = map(int, month_of(ts).split('-'))
    result = []
    for _ in range(MONTHS):
        result.append('%04d-%02d' % (year, month))
        year, month = (year - 1, 12) if month == 1 else (year, month - 1)
    return set(result)


def records(store):
    result = []
    for protocol, table in TABLES.items():
        for row in store.db.execute('SELECT id, data FROM ' + table):
            saved = json.loads(row['data'])
            spec = saved.get('spec') or {}
            if spec.get('deleted'):
                continue
            result.append((protocol, row['id'], saved))
    return result


# ---- counter readers: {user id: (epoch, down, up)} ----

def read_vless(found):
    """``found`` lists (rid, saved) of every VLESS resource. Their clients are
    the 3x-ui clients with email ar_<rid>_<user>."""
    wanted = {}
    for rid, saved in found:
        for c in saved.get('clients') or []:
            if isinstance(c, dict) and c.get('id'):
                wanted['ar_' + rid + '_' + c['id']] = (rid, c['id'])
    if not wanted:
        return {}
    from panel_discovery import databases
    from panel import safe_file
    result, readable = {}, False
    for path, _source in databases():
        try:
            safe_file(path, 512 * 1024 * 1024)
            db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=3)
        except (OSError, sqlite3.Error):
            continue
        try:
            db.execute('PRAGMA query_only=ON')
            rows = db.execute("SELECT id, email, up, down FROM client_traffics WHERE email LIKE 'ar\\_%' ESCAPE '\\'").fetchall()
        except sqlite3.Error:
            continue
        finally:
            db.close()
        readable = True
        for row_id, email, up, down in rows:
            if email in wanted and isinstance(up, int) and isinstance(down, int):
                rid, uid = wanted[email]
                # The service's own database is listed first; a stale copy in
                # a stopped container must not replace its readings.
                result.setdefault(rid, {}).setdefault(uid, (str(row_id), max(down, 0), max(up, 0)))
    if not readable:
        raise Unavailable()
    return result


def parse_transfer(text):
    result = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1].isdigit() and parts[2].isdigit():
            result[parts[0]] = (int(parts[1]), int(parts[2]))
    return result


def ifindex(name):
    try:
        return Path('/sys/class/net', name, 'ifindex').read_text().strip()
    except OSError:
        raise Unavailable()


def read_awg(store, rid, saved):
    import awg
    from sysutil import run
    if saved.get('adopted'):
        import managed_existing
        source = managed_existing.source_of(store, saved, 'awg')
        if not source:
            raise Unavailable()
        name, container = source['name'], source.get('container')
    else:
        name, container = awg.name_for(rid), None
    if not re.fullmatch(r'[A-Za-z0-9_.=+-]{1,15}', name or ''):
        raise Unavailable()
    if container:
        docker = shutil.which('docker')
        if not docker:
            raise Unavailable()
        argv, epoch = [docker, 'exec', container, 'awg', 'show', name, 'transfer'], None
    else:
        argv = [awg.AWG if not saved.get('adopted') else (shutil.which('awg') or awg.AWG), 'show', name, 'transfer']
        epoch = ifindex(name)
    try:
        out = run(argv, timeout=10, check=True, max_output=1024 * 1024)
    except Exception:
        raise Unavailable()
    if not container and ifindex(name) != epoch:
        raise Unavailable()  # Re-created during the read: which counters is unknown.
    peers = parse_transfer(out.stdout.decode('utf-8', 'replace'))
    result = {}
    for c in saved.get('clients') or []:
        if c.get('id') and c.get('publicKey') in peers:
            rx, tx = peers[c['publicKey']]
            result[c['id']] = (epoch, tx, rx)  # rx: from the client, its upload.
    return result


LABEL = re.compile(r'^(inbound|outbound)_traffic_bytes_per_user\{(.*)\}\s+([0-9.eE+]+)(?:\s+\d+)?$')
USERNAME = re.compile(r'(?:^|,)\s*username="((?:[^"\\]|\\.)*)"')


def parse_metrics(text):
    """Prometheus text of TrustTunnel: {username: [down, up]}."""
    result, seen = {}, {}
    for line in text.splitlines():
        m = LABEL.match(line.strip())
        if not m:
            continue
        u = USERNAME.search(m.group(2))
        if not u:
            continue
        name = re.sub(r'\\(.)', lambda e: '\n' if e.group(1) == 'n' else e.group(1), u.group(1))
        try:
            value = int(float(m.group(3)))
        except ValueError:
            continue
        entry = result.setdefault(name, [0, 0])
        # outbound: destination -> endpoint -> client, the client's download.
        direction = 0 if m.group(1) == 'outbound' else 1
        entry[direction] += max(value, 0)
        seen.setdefault(name, set()).add(direction)
    # A user with one direction unreadable is left out: a zero in its place
    # would look like a counter restart.
    return {name: v for name, v in result.items() if seen[name] == {0, 1}}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # Only the loopback listener itself is ever read.


def fetch_metrics(host, port, deadline=5.0):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    url = 'http://%s:%d/metrics' % (('[' + host + ']') if ':' in host else host, port)
    end = time.monotonic() + deadline
    chunks, size = [], 0
    try:
        with opener.open(url, timeout=3) as response:
            if response.status != 200:
                raise Unavailable()
            while size <= MAX_METRICS:
                if time.monotonic() > end:
                    raise Unavailable()  # A slow listener must not hold the ledger lock.
                chunk = response.read(65536)
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
    except Exception as error:
        if hasattr(error, 'close'):
            error.close()  # An HTTPError holds the response open.
        raise Unavailable()
    data = b''.join(chunks)
    if len(data) > MAX_METRICS:
        raise Unavailable()
    return parse_metrics(data.decode('utf-8', 'replace'))


def loopback(host):
    return host == '::1' or host == 'localhost' or re.fullmatch(r'127\.\d{1,3}\.\d{1,3}\.\d{1,3}', host or '') is not None


def tt_endpoint(store, rid, saved):
    """(host, port, systemd unit) of the endpoint's per-client metrics."""
    import tt_common
    if saved.get('adopted'):
        import managed_existing
        source = managed_existing.source_of(store, saved, 'tt')
        if not source:
            raise Unavailable()
        settings, unit = Path(source['settings']), source.get('unit')
    else:
        import tt
        settings, unit = tt.paths(rid)[0], tt.unit_for(rid)
    try:
        metrics = tt_common.toml_read(settings).get('metrics')
    except Exception:
        raise Unavailable()
    if not isinstance(metrics, dict) or metrics.get('per_client_metrics') is not True:
        raise Off()
    try:
        host, port = tt_common.split_address(str(metrics.get('address', '127.0.0.1:1987')))
        port = int(port)
    except Exception:
        raise Off()
    if not loopback(host):
        raise Off()  # Never read a listener reachable from outside.
    return host, port, unit


def read_tt(store, rid, saved):
    from sysutil import run
    host, port, unit = tt_endpoint(store, rid, saved)

    def invocation():
        if not unit or not re.fullmatch(r'[A-Za-z0-9@_.:-]{1,256}', unit):
            return None
        try:
            return run(['/usr/bin/systemctl', 'show', unit, '--property=InvocationID', '--value'],
                       timeout=10).stdout.decode().strip() or None
        except Exception:
            raise Unavailable()
    epoch = invocation()
    counters = fetch_metrics(host, port)
    if invocation() != epoch:
        raise Unavailable()  # Restarted during the read.
    result = {}
    for c in saved.get('clients') or []:
        if c.get('id') and c.get('username') in counters:
            down, up = counters[c['username']]
            result[c['id']] = (epoch, down, up)
    return result


def read_all(store):
    """{(protocol, rid): (state, workspace, {user: (epoch, down, up)})}"""
    found = records(store)
    result = {}
    vless = [(rid, saved) for protocol, rid, saved in found if protocol == 'vless'
             and saved.get('clients')]  # Internal relay inbounds have no client of their own.
    try:
        counters, vless_state = read_vless(vless), 'ok'
    except Exception:
        counters, vless_state = {}, 'unavailable'
    for protocol, rid, saved in found:
        workspace, spec = saved.get('workspaceId'), saved.get('spec') or {}
        if protocol == 'vless' and not saved.get('clients'):
            continue
        if spec.get('enabled') is False:
            result[(protocol, rid)] = ('disabled', workspace, {})
        elif protocol == 'vless':
            result[(protocol, rid)] = (vless_state, workspace, counters.get(rid, {}))
        else:
            try:
                values = (read_awg if protocol == 'awg' else read_tt)(store, rid, saved)
                result[(protocol, rid)] = ('ok', workspace, values)
            except Off:
                result[(protocol, rid)] = ('off', workspace, {})
            except Exception:
                result[(protocol, rid)] = ('unavailable', workspace, {})
    return result


# ---- ledger ----

def fold(entry, reading, now, known=False):
    """Add one reading to a ledger entry; True when the entry changed.

    ``known``: the resource was read before, so a counter new to the ledger
    appeared since then (a client's first connection) and is this month's.
    At the first reading of a resource what its counters already hold is
    real traffic of no known month: it goes to the total only."""
    epoch, down, up = reading
    last = entry.get('l')
    if last is None:
        entry.setdefault('t', [0, 0])
        entry.setdefault('m', {})
        if not known:
            entry.update(e=epoch, l=[down, up], t=[entry['t'][0] + down, entry['t'][1] + up], s=now)
            return True
        last = [0, 0]
    restarted = epoch != entry.get('e') or down < last[0] or up < last[1]
    dd, du = (down, up) if restarted else (down - last[0], up - last[1])
    changed = restarted or dd or du or now - entry.get('s', 0) > 86400
    if not changed:
        return False
    entry['e'], entry['l'], entry['s'] = epoch, [down, up], now
    if dd or du:
        entry['t'] = [entry['t'][0] + dd, entry['t'][1] + du]
        bucket = entry['m'].setdefault(month_of(now), [0, 0])
        bucket[0] += dd
        bucket[1] += du
    return True


def prune(ledger, now, resources=None, live=()):
    """Drop months past the window; forget the sums of a resource only when
    it no longer exists and has not been read for FORGET_AFTER."""
    keep = kept_months(now)
    changed = False
    for key in list(resources or {}):
        if key not in live and now - resources[key] > FORGET_AFTER:
            del resources[key]
            changed = True
    for key in list(ledger):
        entry = ledger[key]
        if key.rsplit('/', 1)[0] not in live and now - entry.get('s', now) > FORGET_AFTER:
            del ledger[key]
            changed = True
            continue
        for m in list(entry.get('m', {})):
            if m not in keep:
                del entry['m'][m]
                changed = True
    return changed


def load(path):
    from panel import safe_file
    try:
        safe_file(path, MAX_LEDGER)
        data = json.loads(path.read_bytes())
    except (OSError, ValueError):
        return {}, {}  # Missing or damaged: the accounting restarts, not the runner.
    if not isinstance(data, dict) or data.get('version') != 1:
        return {}, {}
    entries, resources = data.get('entries'), data.get('resources')
    entries = {k: v for k, v in (entries.items() if isinstance(entries, dict) else ()) if valid_entry(k, v)}
    resources = {k: v for k, v in (resources.items() if isinstance(resources, dict) else ())
                 if isinstance(k, str) and isinstance(v, int)}
    return entries, resources


def _pair(v):
    return isinstance(v, list) and len(v) == 2 and all(isinstance(x, int) and x >= 0 for x in v)


def valid_entry(key, e):
    """A damaged entry is dropped alone instead of failing every sample."""
    return (isinstance(key, str) and key.count('/') >= 2 and isinstance(e, dict)
            and _pair(e.get('t')) and isinstance(e.get('s'), int)
            and isinstance(e.get('m'), dict) and all(isinstance(m, str) and _pair(v) for m, v in e['m'].items())
            and (e.get('l') is None or _pair(e['l'])))


class _Locked:
    def __init__(self, directory):
        self.directory = Path(directory)

    def __enter__(self):
        from sysutil import open_lock
        self.fd = open_lock(self.directory / LOCK)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        os.close(self.fd)


def sample(store, now=None):
    """Read every counter and fold it into the ledger. Returns the ledger
    entries and the state of each resource."""
    path = Path(store.directory) / LEDGER
    # Read under the lock: a reading folded after a newer one would look
    # like a counter restart and be counted twice. The time is taken after
    # waiting for the lock, so the bytes go to the month they were read in.
    with _Locked(store.directory):
        now = int(time.time() if now is None else now)
        readings = read_all(store)
        ledger, seen = load(path)
        changed = prune(ledger, now, seen, {p + '/' + r for p, r in readings})
        for (protocol, rid), (state, workspace, values) in readings.items():
            if state != 'ok':
                continue
            known = protocol + '/' + rid in seen
            for uid, reading in values.items():
                key = protocol + '/' + rid + '/' + uid
                entry = ledger.setdefault(key, {'w': workspace})
                entry['w'] = workspace
                changed = fold(entry, reading, now, known) or changed
            if not known or now - seen[protocol + '/' + rid] > 86400:
                seen[protocol + '/' + rid] = now
                changed = True
        if changed:
            from panel import atomic_file
            atomic_file(path, json.dumps(dict(version=1, entries=ledger, resources=seen), sort_keys=True,
                                         separators=(',', ':')).encode())
    return ledger, {key: value[0] for key, value in readings.items()}


def read(store, workspace, now=None):
    """The ``traffic_read`` answer: every resource of the workspace with
    counted traffic or a current state, and each user's totals."""
    now = int(time.time() if now is None else now)
    ledger, states = sample(store, now)
    resources = {}
    for (protocol, rid), state in states.items():
        resources[(protocol, rid)] = dict(protocol=protocol, id=rid, state=state, users=[])
    # Workspace of a live resource from the records; a forgotten one from the ledger.
    owners = {}
    for protocol, rid, saved in records(store):
        owners[(protocol, rid)] = saved.get('workspaceId')
    for key, entry in sorted(ledger.items()):
        protocol, rid, uid = key.split('/', 2)
        if owners.get((protocol, rid), entry.get('w')) != workspace:
            continue
        r = resources.setdefault((protocol, rid), dict(protocol=protocol, id=rid, state='gone', users=[]))
        r['users'].append(dict(id=uid, down=entry['t'][0], up=entry['t'][1],
            months=[dict(month=m, down=v[0], up=v[1]) for m, v in sorted(entry.get('m', {}).items())]))
    result = [r for (protocol, rid), r in sorted(resources.items())
              if owners.get((protocol, rid), workspace) == workspace]
    return dict(readAt=now, resources=result)


TT_MIGRATION = 'tt-metrics.json'


def _wanted_metrics(rid, spec):
    from tt_common import address
    host, port = metrics_address(rid, spec['port'])
    return dict(address=address(host, port), request_timeout_secs=3, per_client_metrics=True)


def _endpoint_up(unit, rid, spec, sleep=time.sleep):
    """The restarted endpoint runs and answers on its metrics listener."""
    from tt_common import active
    for _ in range(10):
        sleep(1)
        if active(unit):
            try:
                fetch_metrics(*metrics_address(rid, spec['port']))
                return True
            except Unavailable:
                pass
    return False


def enable_tt_metrics(store, sleep=time.sleep):
    """Per-client metrics for managed TrustTunnel endpoints written by a
    runner before v77, which a new apply would enable anyway.

    Runs in the worker between jobs only: a job's intent compares the very
    file hashes this changes. Only an untouched file (its hash is the one
    recorded) is edited, so a drifted endpoint stays the owner's to resolve.
    A file intent makes a crash between the write, the record and the
    restart resumable; an endpoint that does not come up with metrics gets
    its old file back and is not tried again for that file."""
    if store.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():
        return
    import tt
    import tt_common
    from panel import atomic_file, safe_file
    from vless import canonical
    path = Path(store.directory) / TT_MIGRATION
    try:
        safe_file(path)
        state = json.loads(path.read_bytes())
        if not isinstance(state, dict):
            state = {}
    except (OSError, ValueError):
        state = {}

    def save_state():
        atomic_file(path, json.dumps(state, sort_keys=True).encode())

    def record(rid, saved, value):
        saved['hashes'][0] = value
        with store.db:
            store.db.execute('UPDATE tt_resources SET data=? WHERE id=?', (canonical(saved), rid))

    for rid, saved in tt.owned(store).items():
        spec = saved.get('spec') or {}
        if saved.get('adopted') or spec.get('deleted') or spec.get('allowPrivate') is not False:
            continue
        vpn, unit = tt.paths(rid)[0], tt.unit_for(rid)
        try:
            raw = tt_common.read(vpn)
            config = tt_common.toml_loads(raw.decode())
        except Exception:
            continue
        current = hashlib.sha256(raw).hexdigest()
        entry = state.get(rid) if isinstance(state.get(rid), dict) else None
        if entry and entry.get('phase') == 'writing' and current == entry.get('after'):
            before = entry['before']  # Written before a crash: finish it.
            if saved['hashes'][0] != current:
                record(rid, saved, current)
        else:
            if (config.get('metrics') or {}).get('per_client_metrics') is True:
                if rid in state:
                    state.pop(rid)
                    save_state()
                continue
            if entry and entry.get('phase') == 'failed' and entry.get('before') == current:
                continue
            if saved['hashes'][0] != current:
                continue
            before = current
            config['metrics'] = _wanted_metrics(rid, spec)
            data = tt_common.toml_bytes(config)
            state[rid] = dict(before=before, after=hashlib.sha256(data).hexdigest(), phase='writing',
                              old=raw.decode())
            save_state()
            atomic_file(vpn, data, 0o600)
            record(rid, saved, state[rid]['after'])
        old = state[rid].get('old')
        if spec.get('enabled') and not spec.get('deleted'):
            try:
                tt_common.run(['/usr/bin/systemctl', 'restart', unit], timeout=60)
                up = _endpoint_up(unit, rid, spec, sleep)
            except Exception:
                up = False
            if not up and old is not None:
                atomic_file(vpn, old.encode(), 0o600)
                record(rid, saved, before)
                try:
                    tt_common.run(['/usr/bin/systemctl', 'restart', unit], timeout=60)
                except Exception:
                    pass
                state[rid] = dict(before=before, phase='failed')
                save_state()
                continue
        state.pop(rid, None)
        save_state()


def safe_migrate(store):
    try:
        enable_tt_metrics(store)
    except Exception as error:
        import sys
        sys.stderr.write(f'[runner] traffic metrics migration skipped: {type(error).__name__}\n')


def safe_sample(store):
    """For the daemon: accounting never stops a job or the worker."""
    try:
        sample(store)
    except Exception as error:
        import sys
        sys.stderr.write(f'[runner] traffic sample skipped: {type(error).__name__}\n')
