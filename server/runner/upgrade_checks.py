"""Device connection checks around a 3x-ui, TrustTunnel or AmneziaWG upgrade.

As for the Xray core (xray_transaction): before submitting the upgrade the
device checks every enabled resource of the component through a diagnostic
lease (connectivity_probe) and sends the results with the job. The job keeps
the leases alive across the switch, and its confirmation window
(component_upgrade, "deadman") then waits for the same checks from the same
device network. Only a commit with results at least as good as before keeps
the new version; anything else, or no answer in time, rolls it back through
the job's own backup.

Without enabled resources there is nothing a device could check and the
upgrade keeps the plain confirmation window.
"""
from __future__ import annotations

import hashlib
import json
import re
import time

from component_upgrade import (DEADMAN_SECONDS, ComponentUpgradeError, _deadman_path, _read_window,
                               _start_deadman_timer, confirm_upgrade, upgrade_lock, window_open)
import connectivity_probe as probes

# Component of an upgrade -> protocol of the leases that cover it.
CHECKED = {'panel': 'vless', 'trusttunnel': 'tt', 'amneziawg': 'awg'}
FIELDS = {'leases', 'baseline', 'network', 'keyHash'}
MAX_LEASES = 32
# A lease must outlive the whole upgrade: at submission, before the switch
# (verification, the shortest window and a margin) and when the window opens.
MIN_LEASE = 600
SWITCH_RESERVE = 360
MIN_WINDOW = 90
MARGIN = 60
HEX = re.compile('[0-9a-f]{64}')


def device_check(payload):
    """The validated deviceCheck of a job payload, or None."""
    value = payload.get('deviceCheck') if isinstance(payload, dict) else None
    if value is None:
        return None
    component = payload.get('component')
    expected = FIELDS | ({'panelId'} if component == 'panel' else set())
    if component not in CHECKED or not isinstance(value, dict) or set(value) != expected:
        raise ComponentUpgradeError('upgrade_checks_coverage')
    leases, baseline = value['leases'], value['baseline']
    if (not isinstance(leases, list) or len(leases) > MAX_LEASES or len(set(leases)) != len(leases) or
            not all(isinstance(k, str) and re.fullmatch('[a-f0-9]{32}', k) for k in leases)):
        raise ComponentUpgradeError('upgrade_checks_coverage')
    if not all(isinstance(value[k], str) and HEX.fullmatch(value[k]) for k in ('network', 'keyHash')):
        raise ComponentUpgradeError('upgrade_checks_coverage')
    if component == 'panel' and not (isinstance(value['panelId'], str) and re.fullmatch('[a-f0-9]{32}', value['panelId'])):
        raise ComponentUpgradeError('upgrade_checks_coverage')
    results(baseline, leases)
    return value


def checked(payload):
    """Whether the window of this job waits for the device's checks."""
    value = device_check(payload)
    return bool(value and value['leases'])


def results(checks, leases):
    """{lease: (tcp, udp)} for exactly these leases; each worked somehow."""
    if not isinstance(checks, list) or len(checks) != len(leases):
        raise ComponentUpgradeError('upgrade_checks_coverage')
    found = {}
    for row in checks:
        if (not isinstance(row, dict) or set(row) != {'lease', 'tcp', 'udp'} or
                not isinstance(row['tcp'], bool) or not isinstance(row['udp'], bool) or not (row['tcp'] or row['udp'])):
            raise ComponentUpgradeError('upgrade_checks_coverage')
        found[row['lease']] = (row['tcp'], row['udp'])
    if set(found) != set(leases):
        raise ComponentUpgradeError('upgrade_checks_coverage')
    return found


def panel_rows(store, panel_id):
    import panel_update
    import vless
    try:
        return panel_update.client(vless.access_for_panel(store, panel_id)).call('/panel/api/inbounds/list')
    except Exception:
        raise ComponentUpgradeError('upgrade_checks_panel_api') from None


def panel_known(store):
    from panel_discovery import external_access
    return bool(external_access()) or store.db.execute(
        "SELECT 1 FROM jobs WHERE status='succeeded' AND request LIKE '%\"kind\":\"panel_install\"%'").fetchone() is not None


def wanted(store, component, value):
    """What the leases must cover: the enabled inbounds of the panel (all of
    them VLESS, as for Xray), or every enabled TrustTunnel/AmneziaWG resource
    the runner keeps. Not only the confirmed ones: a live lease changes the
    configuration that confirmation compares, and a broken resource fails the
    device's check before anything is replaced."""
    if component == 'panel':
        rows = panel_rows(store, value['panelId'])
        enabled = [r for r in rows if r.get('enable')]
        if any(r.get('protocol') != 'vless' for r in enabled):
            raise ComponentUpgradeError('upgrade_checks_coverage')
        return {r['id'] for r in enabled}
    if component == 'trusttunnel':
        from tt import owned
    else:
        from awg import owned
    return {rid for rid, saved in owned(store).items()
            if saved['spec'].get('enabled') and not saved['spec'].get('deleted')}


def required(store, component):
    """Whether this upgrade may not run without device checks."""
    if component not in CHECKED:
        return False
    if component == 'panel':
        return panel_known(store)
    return bool(wanted(store, component, None))


def leases(store, keys, exact=True):
    """The active leases; with exact also unchanged since the device's checks."""
    rows = []
    for key in keys:
        try:
            info = probes.load(store, key)
            if (not info or info['status'] != 'active' or info['expires'] <= time.time() or
                    exact and probes.fingerprint(store, info) != info['afterHash']):
                raise ComponentUpgradeError('upgrade_checks_changed')
        except ComponentUpgradeError:
            raise
        except Exception:
            # An unreadable lease or resource is a changed one; job steps
            # only settle ComponentUpgradeError cleanly.
            raise ComponentUpgradeError('upgrade_checks_changed') from None
        rows.append(info)
    return rows


def covered(component, value, rows):
    protocol = CHECKED[component]
    if any(r['protocol'] != protocol for r in rows):
        raise ComponentUpgradeError('upgrade_checks_coverage')
    if protocol == 'vless':
        if any(r['saved'].get('panelId') != value['panelId'] for r in rows):
            raise ComponentUpgradeError('upgrade_checks_coverage')
        found = [r['rowId'] for r in rows]
    else:
        found = [r['saved']['spec']['id'] for r in rows]
    if len(set(found)) != len(found):
        raise ComponentUpgradeError('upgrade_checks_coverage')
    return set(found)


def remaining(rows):
    return min(r['expires'] for r in rows) - time.time() if rows else None


def verify(store, payload, reserve):
    """The leases still cover every resource and live at least `reserve`."""
    component, value = payload['component'], device_check(payload)
    rows = leases(store, value['leases'])
    if covered(component, value, rows) != wanted(store, component, value):
        raise ComponentUpgradeError('upgrade_checks_coverage')
    if rows and remaining(rows) < reserve:
        raise ComponentUpgradeError('upgrade_checks_timeout')
    return rows


def admit(store, req):
    """At submission of a component_upgrade_apply (under the operation lock)."""
    payload = json.loads(req['payload']) if isinstance(req.get('payload'), str) else req.get('payload') or {}
    component = payload.get('component')
    if component not in CHECKED:
        if 'deviceCheck' in payload:
            raise ComponentUpgradeError('upgrade_checks_coverage')
        return
    value = device_check(payload)
    if value is None:
        if required(store, component):
            raise ComponentUpgradeError('upgrade_checks_required')
        return
    if any(held(store, key) for key in value['leases']):
        raise ComponentUpgradeError('upgrade_checks_changed')
    verify(store, payload, MIN_LEASE)


def claims(store, request):
    """A submission that brings exactly the live leases as its device checks
    may run while they are live; any other one waits (probe_busy)."""
    try:
        if request.get('action') != 'submit' or request.get('kind') != 'component_upgrade_apply':
            return False
        payload = json.loads(request['payload'])
        value = payload.get('deviceCheck') or {}
        live = set()
        for path in probes.directory(store).glob('*.json'):
            info = probes.load(store, path.stem) or {}
            # The same leases as probes.active(): open and not yet expired.
            if info.get('status') != 'closed' and info.get('expires', 0) >= time.time():
                live.add(path.stem)
        return bool(live) and set(value.get('leases') or []) == live
    except Exception:
        return False


def held(store, key):
    """Whether an unsettled checked upgrade still needs this lease."""
    for job_id, request, status in store.db.execute(
            "SELECT id, request, status FROM jobs WHERE status IN ('planned','running','succeeded') AND request LIKE '%component_upgrade_apply%'"):
        try:
            payload = json.loads(json.loads(request)['payload'])
            if key not in ((payload.get('deviceCheck') or {}).get('leases') or []):
                continue
        except (ValueError, KeyError, TypeError):
            continue
        if status != 'succeeded' or window_open(store.directory, job_id):
            return True
    return False


def panel_inbounds(directory, job_id):
    return directory / ('upgrade-' + job_id) / 'checks.json'


def before_upgrade(store, request, payload):
    """Step 0 of a checked job: the leases and coverage are as submitted; the
    panel's inbound ids are recorded once for the API check afterwards."""
    verify(store, payload, SWITCH_RESERVE)
    if payload['component'] == 'panel':
        path = panel_inbounds(store.directory, request['id'])
        if not path.exists():
            from panel import atomic_file
            ids = sorted(r['id'] for r in panel_rows(store, payload['deviceCheck']['panelId']))
            atomic_file(path, json.dumps(ids).encode())


def before_switch(store, payload):
    """Nothing is changed yet: no switch the leases could not outlive."""
    rows = leases(store, payload['deviceCheck']['leases'])
    if remaining(rows) < SWITCH_RESERVE:
        raise ComponentUpgradeError('upgrade_checks_timeout')


def panel_api(store, request, payload):
    """A fresh login to 3x-ui lists the same inbound ids as before."""
    if payload['component'] != 'panel':
        return
    path = panel_inbounds(store.directory, request['id'])
    try:
        expected = json.loads(path.read_text())
    except (OSError, ValueError):
        raise ComponentUpgradeError('upgrade_checks_panel_api') from None
    if sorted(r['id'] for r in panel_rows(store, payload['deviceCheck']['panelId'])) != expected:
        raise ComponentUpgradeError('upgrade_checks_panel_api')


def window(store, request, payload):
    """Step 5 of a checked job: how long the window waits for the device. The
    shapes of the leases may differ after the upgrade (a newer 3x-ui lists
    more fields); the device's checks prove them."""
    panel_api(store, request, payload)
    rows = leases(store, payload['deviceCheck']['leases'], exact=False)
    seconds = min(DEADMAN_SECONDS, remaining(rows) - MARGIN)
    if seconds < MIN_WINDOW:
        raise ComponentUpgradeError('upgrade_checks_timeout')
    return seconds


def job(store, job_id):
    row = store.db.execute('SELECT request FROM jobs WHERE id=?', (job_id,)).fetchone()
    if row is None:
        raise ComponentUpgradeError('upgrade_conflict')
    request = json.loads(row[0])
    if request.get('kind') != 'component_upgrade_apply':
        raise ComponentUpgradeError('upgrade_conflict')
    payload = json.loads(request['payload'])
    if not checked(payload):
        raise ComponentUpgradeError('upgrade_conflict')
    return request, payload


def key_matches(value, body):
    key = body.get('key') if isinstance(body, dict) else None
    return isinstance(key, str) and 32 <= len(key) <= 128 and hashlib.sha256(key.encode()).hexdigest() == value['keyHash']


def commit(store, req):
    """The device's checks after the upgrade: keep it, or roll back now."""
    request, payload = job(store, req['id'])
    value = payload['deviceCheck']
    body = json.loads(req['payload'])
    if not key_matches(value, body):
        raise ComponentUpgradeError('upgrade_conflict')

    def compare(info):
        if time.time() >= info.get('deadline', 0):
            raise ComponentUpgradeError('upgrade_checks_timeout')
        try:
            if body.get('network') != value['network']:
                raise ComponentUpgradeError('upgrade_checks_changed')
            before, after = results(value['baseline'], value['leases']), results(body.get('checks'), value['leases'])
            if any(after[k][0] < before[k][0] or after[k][1] < before[k][1] for k in before):
                raise ComponentUpgradeError('upgrade_checks_failed')
            leases(store, value['leases'], exact=False)
            panel_api(store, request, payload)
        except ComponentUpgradeError:
            expire(store, info, req['id'])
            raise

    return confirm_upgrade(store, req['id'], verify=compare)


def expire(store, info, job_id):
    """Roll the window back now: its own timer, as at the end of the window;
    after a reboot recover_deadmen finds the window due. Under upgrade_lock."""
    from panel import atomic_file
    info['deadline'] = min(info.get('deadline', 0), time.time())
    atomic_file(_deadman_path(store.directory, job_id), json.dumps(info).encode())
    _start_deadman_timer(job_id, 1)


def abort(store, req):
    """The device gave up (a check failed or was cancelled): roll back now."""
    request, payload = job(store, req['id'])
    if not key_matches(payload['deviceCheck'], json.loads(req['payload'])):
        raise ComponentUpgradeError('upgrade_conflict')
    path = _deadman_path(store.directory, req['id'])
    with upgrade_lock(store.directory):
        # Before its window the job is cancelled like any other job.
        if not path.exists():
            raise ComponentUpgradeError('upgrade_conflict')
        info = _read_window(path)
        if info.get('confirmed'):
            raise ComponentUpgradeError('upgrade_conflict')
        if not (info.get('rolledBack') or info.get('rollingBack') or info.get('rollbackFailed')):
            expire(store, info, req['id'])
