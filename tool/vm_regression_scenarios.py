#!/usr/bin/env python3
"""Scenarios of the VM regression suite. Each gets its own overlay of golden."""
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import socket
import time

import vm_regression_lib as lib
from vm_regression_lib import remote, python, upload

OPTIONS = {}
# Positive traffic checks wait up to ~(retries+1)*timeout for convergence after a
# state change (restart, rollback, new probe credentials); each wait is logged as SLOW.
POSITIVE_RETRIES = 1

WORKSPACE = 'b' * 32
PANEL_ID = '10000000000000000000000000000001'
USERS = [
    dict(id='c' * 32, login='alice', enabled=True),
    dict(id='d' * 32, login='bob', enabled=True),
]
VLESS_USERS = [dict(id=u['id'], enabled=u['enabled']) for u in USERS]
COMPILER_USERS = [dict(id=u['id'], enabled=u['enabled'], login=u['login'], name='Client ' + str(i))
                  for i, u in enumerate(USERS)]

VLESS_RAW_ID = '0' * 31 + '1'
VLESS_XHTTP_REALITY_ID = '0' * 31 + '2'
VLESS_XHTTP_TLS_ID = '0' * 31 + '3'
TT_CERT_ID = 'e' * 32
TT_RES_ID = 'f' * 32
AWG_RES_ID = 'a' * 32
XRAY_CORE_REV = 'ac017cdd246ce8bd547653d927e7bf77d7ee73d5'


def active(unit='antirkn-runner'):
    return remote('systemctl is-active ' + unit, check=False).stdout.decode().strip() == 'active'


def enabled(unit='antirkn-runner'):
    return remote('systemctl is-enabled ' + unit, check=False).stdout.decode().strip() == 'enabled'


def diagnostic(rpc, count=3):
    request = dict(version=1, action='submit', id=secrets.token_hex(16), kind='diagnostic', count=count, interval=1)
    job = rpc.run_job(request, timeout=120)
    return request, job


def _vless_specs():
    xhttp_opts = lib.xhttp_defaults()
    return [
        dict(id=VLESS_RAW_ID, name='VLESS RAW REALITY', enabled=True, deleted=False,
             listen='0.0.0.0', port=2443, endpoint='127.0.0.1', externalPort=42443,
             transport='raw', security='reality', sni='vless.test', target='10.0.2.2:29443',
             path='/antirkn/', host='', mode='auto', certificate='', certificateKey='', region=''),
        dict(id=VLESS_XHTTP_REALITY_ID, name='VLESS XHTTP REALITY', enabled=True, deleted=False,
             listen='0.0.0.0', port=2444, endpoint='127.0.0.1', externalPort=42444,
             transport='xhttp', security='reality', sni='vless.test', target='10.0.2.2:29443',
             path='/antirkn/', host='', mode='auto', certificate='', certificateKey='', region='',
             xhttp=xhttp_opts),
        dict(id=VLESS_XHTTP_TLS_ID, name='VLESS XHTTP TLS', enabled=True, deleted=False,
             listen='0.0.0.0', port=2445, endpoint='127.0.0.1', externalPort=42445,
             transport='xhttp', security='tls', sni='vless.test', target='10.0.2.2:29443',
             path='/antirkn/', host='', mode='packet-up',
             certificate='/etc/antirkn-test-tls/server.crt',
             certificateKey='/etc/antirkn-test-tls/server.key',
             region='', xhttp=xhttp_opts),
    ]


def _tt_spec():
    return dict(id=TT_RES_ID, name='TrustTunnel Fixture', enabled=True, deleted=False,
                listen='0.0.0.0', port=28443, endpoint='127.0.0.1', externalPort=42449,
                domain='tt.fixture.test', certificateId=TT_CERT_ID, quic=False, ipv6=False,
                allowPrivate=True, outbound='direct', socksAddress='127.0.0.1:1080', rotation=0)


def _compiler_workspace(vless_specs, vless_obs, tt_spec, tt_obs, awg_spec, awg_obs):
    return dict(
        version=3,
        id=WORKSPACE,
        users=COMPILER_USERS,
        inbounds=[dict(serverId='fixture', spec=s) for s in vless_specs],
        awgInterfaces=[dict(serverId='fixture', spec=awg_spec)],
        ttEndpoints=[dict(serverId='fixture', spec=tt_spec)],
        servers={
            'fixture': dict(observed=vless_obs),
            'tt/fixture': dict(observed=tt_obs),
            'awg/fixture': dict(observed=awg_obs),
        },
        profiles={},
    )


def _allow_echo_routing(version, panel_id):
    """Allow local echo ports 29880/29881 on 10.0.2.2 through the panel's freedom outbound."""
    python(f'''import sys, json, urllib.request, urllib.parse
from pathlib import Path
sys.path.insert(0, '/usr/local/lib/antirkn-runner/{version}')
from runner import Store
from vless import panel_for
store = Store(Path('/var/lib/antirkn-runner'))
api = panel_for(store, {panel_id!r})
value = api.call('/panel/api/xray/', {{}})
if isinstance(value, str): value = json.loads(value)
config = value['xraySetting']
if isinstance(config, str): config = json.loads(config)
outbound = next(o for o in config['outbounds'] if o['protocol'] == 'freedom')
tag = outbound['tag']
final = outbound.setdefault('settings', {{}}).setdefault('finalRules', [])
allow = dict(action='allow', ip=['10.0.2.2'], port='29880,29881')
changed = allow not in final
if changed: final.insert(0, allow)
rule = dict(type='field', ip=['10.0.2.2'], port='29880,29881', outboundTag=tag)
rules = config['routing']['rules']
if rule not in rules:
    rules.insert(0, rule)
    changed = True
if changed:
    req = urllib.request.Request(
        api.base + '/panel/api/xray/update',
        data=urllib.parse.urlencode(dict(xraySetting=json.dumps(config))).encode(),
        headers={{'Content-Type': 'application/x-www-form-urlencoded', 'Origin': api.origin, 'X-CSRF-Token': api.csrf}},
    )
    with api.client.open(req, timeout=20) as resp:
        result = json.load(resp)
    if result.get('success') is not True:
        raise RuntimeError('xray routing update failed')
store.close()
''')


def _check_traffic(ctx, workspace, resource_id, label, user_index=0, timeout=10.0, retries=POSITIVE_RETRIES):
    mihomo = lib.fixture('mihomo')
    ca_crt = lib.BASE / 'protocols-tls/ca.crt'
    work_dir = ctx.run_dir / ('mihomo-' + ctx.name) / (label + '-u' + str(user_index))
    return lib.check_proxy_traffic(workspace, USERS[user_index]['id'], resource_id, ca_crt, mihomo, work_dir,
                                   timeout=timeout, retries=retries)


def _fetch_live_workspace(ctx, meta):
    vless_obs = ctx.rpc(dict(version=1, action='vless_state', id=meta['panel_id']))['vlessState']
    tt_obs = ctx.rpc(dict(version=1, action='tt_state', id=meta['workspace_id']))['tt']['resources']
    awg_obs = ctx.rpc(dict(version=1, action='awg_state', id=meta['workspace_id']))['awgState']
    ws = _compiler_workspace(meta['vless_specs'], vless_obs, meta['tt_spec'], tt_obs, meta['awg_spec'], awg_obs)
    return ws, vless_obs, tt_obs, awg_obs


def _component_plan(version, component):
    out = python(f"import sys, json; sys.path.insert(0, '/usr/local/lib/antirkn-runner/{version}'); "
                 f"from components import component_plan; print(json.dumps(component_plan({component!r})))").stdout
    return json.loads(out)


def _xray_version():
    out = remote('/usr/local/x-ui/bin/xray-linux-amd64 version').stdout.decode()
    m = re.search(r'Xray\s+v?([0-9]+\.[0-9]+\.[0-9]+)', out)
    return m.group(1) if m else ''


def _load_meta():
    return json.loads((lib.BASE / 'protocols.meta.json').read_text())


def _protocols_disk_current(release):
    """True only for a protocols snapshot built by this exact runner release."""
    disk, meta_path = lib.BASE / 'protocols.qcow2', lib.BASE / 'protocols.meta.json'
    if not (disk.exists() and meta_path.exists()):
        return False
    try:
        return _load_meta().get('runner_release') == release
    except (OSError, ValueError):
        return False


def _drop_protocols_disk():
    for name in ('protocols.qcow2', 'protocols.meta.json'):
        (lib.BASE / name).unlink(missing_ok=True)


def _ensure_protocols_disk(ctx, vm):
    disk = lib.BASE / 'protocols.qcow2'
    if _protocols_disk_current(ctx.bundle['release']):
        return disk
    # Build protocols.qcow2 on demand if downstream scenarios are run with --only.
    protocols(ctx, vm, mutation=None)
    vm.stop()
    return disk


# ---------------------------------------------------------------- runner_upgrade

# Fault injected into the installer text in memory only: after the normal
# installation it erases the job history (database stays valid), as an
# installer that recreated or migrated the journal incorrectly would.
DROP_JOBS = ("\nimport sqlite3 as _sqlite3\n"
             "_db = _sqlite3.connect('/var/lib/antirkn-runner/jobs.sqlite', timeout=30)\n"
             "_db.execute('DELETE FROM events'); _db.execute('DELETE FROM jobs'); _db.commit(); _db.close()\n")


def runner_upgrade(ctx, vm, mutation=None):
    current = ctx.bundle
    # (a) fresh install of the current runner.
    vm.start(lib.new_overlay('runner-fresh', lib.BASE / 'golden.qcow2'))
    plan = lib.inspect_runner(current)
    ctx.check(plan['supported'] and plan['state'] == 'missing', 'fresh_vm_supported_and_runner_missing')
    result = lib.install_runner(current)
    ctx.check(result['active'], 'fresh_install_reports_active')
    ctx.check(active() and enabled(), 'fresh_daemon_active_and_enabled')
    ctx.check(ctx.rpc(dict(version=1, action='list')).get('code') == 'ok', 'fresh_rpc_works')
    _, job = diagnostic(ctx.rpc)
    ctx.check(job['status'] == 'succeeded', 'fresh_diagnostic_job_succeeds')
    vm.stop()
    # (b) upgrade from the previous release, with a job in the old journal.
    vm.start(lib.new_overlay('runner-upgrade', lib.BASE / 'golden.qcow2'))
    old = lib.previous_bundle(current, OPTIONS.get('previous_commit'))
    ctx.check(old['version'] != current['version'] and old['release'] != current['release'], 'previous_release_is_distinct')
    ctx.check(lib.install_runner(old)['active'], 'previous_release_installed')
    old_rpc = lib.Rpc(old['version'])
    request, before = diagnostic(old_rpc)
    ctx.check(before['status'] == 'succeeded' and len(lib.codes(before)) >= 3, 'old_release_job_ran')
    plan = lib.inspect_runner(current)
    ctx.check(plan['upgradable'], 'previous_release_recognised_as_upgradable')
    installer = current['runnerInstaller'] + (DROP_JOBS if mutation == 'installer_drops_jobs_db' else '')
    result = lib.install_runner(current, installer=installer)
    ctx.check(result['active'] and active(), 'upgraded_daemon_active')
    ctx.check(ctx.rpc(dict(version=1, action='list')).get('code') == 'ok', 'upgraded_rpc_works')
    response = ctx.rpc.status(request['id'])
    jobs = response.get('jobs') or []
    ctx.check(jobs and jobs[0]['status'] == 'succeeded', 'upgrade_preserves_old_job')
    ctx.check(lib.codes(jobs[0]) == lib.codes(before), 'upgrade_preserves_old_job_events')
    pid = lib.main_pid()
    ctx.check(pid not in ('', '0'), 'upgraded_daemon_has_pid')
    state = lib.inspect_runner(current)
    ctx.check(state['state'] == 'installed' and not state['upgradable'], 'repeat_plan_reports_installed')
    lib.install_runner(current)
    ctx.check(lib.main_pid() == pid, 'repeat_install_is_noop_same_mainpid')
    _, job = diagnostic(ctx.rpc, 1)
    ctx.check(job['status'] == 'succeeded', 'upgraded_runner_runs_new_jobs')


# ---------------------------------------------------------------- protocols


def _traffic(ctx):
    response = ctx.rpc(dict(version=1, action='traffic_read', id=WORKSPACE))
    ctx.check(response.get('code') == 'ok', 'traffic_read_ok')
    return {(r['protocol'], r['id']): r for r in response.get('traffic', {}).get('resources', [])}


def _check_traffic_ledger(ctx, checked):
    """After real traffic every protocol counted both users this month, and a
    second read does not count it again. 3x-ui stores Xray counters every 10 s."""
    time.sleep(12)
    first = _traffic(ctx)
    for protocol, rid, label in checked:
        r = first.get((protocol, rid), {})
        users = {u['id']: u for u in r.get('users', [])}
        ok = r.get('state') == 'ok' and all(
            u['id'] in users and users[u['id']]['months']
            and users[u['id']]['months'][-1]['down'] > 0 and users[u['id']]['months'][-1]['up'] > 0
            for u in USERS[:2])
        ctx.check(ok, label + '_traffic_counted')
    # Nothing counted twice: the ledger of the idle AWG interface equals its
    # raw counters (all read since the interface came up), read after read.
    second = _traffic(ctx)
    if any(protocol == 'awg' for protocol, _, _ in checked):
        # Only on the VM that built the interface: a restored snapshot's
        # ledger also holds what was counted before its boot.
        awg = {c['id']: c for c in ctx.rpc(dict(version=1, action='awg_state', id=WORKSPACE))['awgState'][0]['clients']}
        ledger = {u['id']: u for u in second.get(('awg', AWG_RES_ID), {}).get('users', [])}
        ctx.check(all(uid in ledger and (ledger[uid]['down'], ledger[uid]['up']) == (c['tx'], c['rx'])
                      for uid, c in awg.items() if c.get('rx') is not None), 'traffic_awg_ledger_matches_counters')
    ctx.check(all(u['down'] >= v['down'] and u['up'] >= v['up']
                  for k in first for u, v in zip(second.get(k, {}).get('users', []), first[k]['users'])),
              'traffic_totals_monotonic')


def protocols(ctx, vm, mutation=None):
    current = ctx.bundle
    protocols_disk = lib.BASE / 'protocols.qcow2'
    meta_path = lib.BASE / 'protocols.meta.json'
    tls_dir = lib.ensure_tls_material(lib.BASE / 'protocols-tls')

    if mutation is None and OPTIONS.get('reuse_protocols') and _protocols_disk_current(current['release']):
        meta = _load_meta()
        vm.start(lib.new_overlay('protocols-verify', protocols_disk))
        ws, vless_obs, tt_obs, awg_obs = _fetch_live_workspace(ctx, meta)
        ctx.check(len(vless_obs) == 3 and all(r['confirmed'] for r in vless_obs), 'vless_state_confirmed')
        ctx.check(len(tt_obs) == 1 and tt_obs[0]['confirmed'], 'tt_state_confirmed')
        ctx.check(len(awg_obs) == 1 and awg_obs[0]['confirmed'], 'awg_state_confirmed')
        with lib.EchoFixtures(tls_dir):
            for label, rid in [('vless_raw_reality', VLESS_RAW_ID), ('vless_xhttp_reality', VLESS_XHTTP_REALITY_ID),
                               ('vless_xhttp_tls', VLESS_XHTTP_TLS_ID), ('tt', TT_RES_ID), ('awg', AWG_RES_ID)]:
                tcp, udp = _check_traffic(ctx, ws, rid, label)
                ctx.check(tcp and udp, label + '_tcp_udp')
        return

    if mutation is None:
        # A failed build must not leave an older snapshot for the dependent scenarios.
        _drop_protocols_disk()
    overlay_name = 'protocols-mut' if mutation is not None else 'protocols-build'
    building = lib.new_overlay(overlay_name, lib.BASE / 'golden.qcow2')
    vm.start(building)

    # 1. Runner + panel from cache
    ctx.check(lib.install_runner(current)['active'] and active(), 'runner_installed')
    panel_plan = json.loads(python(current['panel_inspector'], json.dumps(dict(port=2053)).encode()).stdout)['panelPlan']
    ctx.check(panel_plan['state'] == 'missing' and panel_plan['supported'] and panel_plan['portAvailable'], 'panel_plan_missing')
    panel_dir = '/var/lib/antirkn-runner/panel-' + PANEL_ID
    remote('mkdir -m 700 -p ' + panel_dir)
    upload(lib.fixture('panel'), panel_dir + '/release.tar.gz', mode='600')
    panel_job = ctx.rpc.run_job(dict(version=1, action='submit', id=PANEL_ID, kind='panel_install',
                                     count=6, interval=1, port=2053, fingerprint=panel_plan['fingerprint']))
    ctx.check(panel_job['status'] == 'succeeded', 'panel_installed')
    access_resp = ctx.rpc(dict(version=1, action='panel_access', id=PANEL_ID))
    access = access_resp.get('panelAccess') or {}
    ctx.check(access_resp.get('code') == 'ok' and access.get('panelVersion') == '3.7.0'
              and access.get('xrayVersion') == '26.7.28', 'panel_access_verified')

    # Allow test echo targets on 10.0.2.2:29880,29881 via panel API, and upload TLS certs.
    _allow_echo_routing(current['version'], PANEL_ID)
    remote('mkdir -m 700 -p /etc/antirkn-test-tls /root/cert/tt.fixture.test')
    upload(tls_dir / 'server.crt', '/etc/antirkn-test-tls/server.crt', mode='600')
    upload(tls_dir / 'server.key', '/etc/antirkn-test-tls/server.key', mode='600')
    upload(tls_dir / 'server.crt', '/root/cert/tt.fixture.test/fullchain.pem', mode='600')
    upload(tls_dir / 'server.key', '/root/cert/tt.fixture.test/privkey.pem', mode='600')
    upload(tls_dir / 'ca.crt', '/usr/local/share/ca-certificates/antirkn-fixture.crt', mode='644')
    remote('update-ca-certificates >/dev/null')

    # 2. VLESS inbounds (RAW/REALITY, XHTTP/REALITY, XHTTP/TLS) with 2 users
    vless_specs = _vless_specs()
    vless_payload = dict(version=1, workspaceId=WORKSPACE, panelId=PANEL_ID, resources=vless_specs, users=VLESS_USERS)
    vless_plan = ctx.rpc(dict(version=1, action='vless_plan', id=PANEL_ID, payload=json.dumps(vless_payload)))
    ctx.check(vless_plan.get('code') == 'ok', 'vless_plan_ok')
    vless_job = ctx.rpc.run_job(dict(
        version=1, action='submit', id=secrets.token_hex(16), kind='vless_apply',
        count=len(vless_specs) + 2, interval=1, payload=json.dumps(vless_payload),
        fingerprint=vless_plan['vlessPlan']['fingerprint']))
    ctx.check(vless_job['status'] == 'succeeded', 'vless_applied')
    vless_obs = ctx.rpc(dict(version=1, action='vless_state', id=PANEL_ID))['vlessState']
    ctx.check(len(vless_obs) == 3 and all(r['confirmed'] and len(r['clients']) == 2 for r in vless_obs)
              and len({c['uuid'] for r in vless_obs for c in r['clients']}) == 6, 'vless_state_confirmed')

    # 3. TrustTunnel component + certificate + endpoint with 2 users
    tt_comp_plan = _component_plan(current['version'], 'trusttunnel')
    ctx.check(tt_comp_plan['state'] == 'missing' and tt_comp_plan['supported'], 'tt_component_plan_missing')
    tt_comp_id = secrets.token_hex(16)
    tt_comp_dir = '/var/lib/antirkn-runner/component-' + tt_comp_id
    remote('mkdir -m 700 -p ' + tt_comp_dir)
    upload(lib.fixture('tt-endpoint'), tt_comp_dir + '/endpoint.archive', mode='600')
    tt_comp_job = ctx.rpc.run_job(dict(version=1, action='submit', id=tt_comp_id, kind='component_install',
                                       component='trusttunnel', payload='', count=6, interval=1,
                                       fingerprint=tt_comp_plan['fingerprint']))
    ctx.check(tt_comp_job['status'] == 'succeeded', 'tt_component_installed')

    cert_spec = dict(id=TT_CERT_ID, mode='files', domain='tt.fixture.test', listen='0.0.0.0',
                     expectedIps=['127.0.0.1'], email='',
                     certificate='/root/cert/tt.fixture.test/fullchain.pem',
                     privateKey='/root/cert/tt.fixture.test/privkey.pem',
                     certificatePem='', privateKeyPem='')
    cert_plan = ctx.rpc(dict(version=1, action='tt_certificate_plan', payload=json.dumps(cert_spec)))
    ctx.check(cert_plan.get('code') == 'ok', 'tt_cert_plan_ok')
    cert_job = ctx.rpc.run_job(dict(version=1, action='submit', id=secrets.token_hex(16), kind='tt_certificate',
                                    count=4, interval=1, payload=json.dumps(cert_spec),
                                    fingerprint=cert_plan['tt']['fingerprint']))
    ctx.check(cert_job['status'] == 'succeeded', 'tt_certificate_installed')

    tt_spec = _tt_spec()
    tt_payload = dict(version=1, protocol='tt', workspaceId=WORKSPACE, panelId=WORKSPACE,
                      resources=[tt_spec], users=[dict(id=u['id'], login=u['login'], enabled=u['enabled']) for u in USERS])
    tt_plan = ctx.rpc(dict(version=1, action='tt_plan', id=WORKSPACE, payload=json.dumps(tt_payload)))
    ctx.check(tt_plan.get('code') == 'ok', 'tt_plan_ok')
    tt_job = ctx.rpc.run_job(dict(version=1, action='submit', id=secrets.token_hex(16), kind='tt_apply',
                                  count=3, interval=1, payload=json.dumps(tt_payload),
                                  fingerprint=tt_plan['tt']['fingerprint']))
    ctx.check(tt_job['status'] == 'succeeded', 'tt_applied')
    tt_obs = ctx.rpc(dict(version=1, action='tt_state', id=WORKSPACE))['tt']['resources']
    ctx.check(len(tt_obs) == 1 and tt_obs[0]['confirmed'] and len(tt_obs[0]['clients']) == 2, 'tt_state_confirmed')

    # 4. AmneziaWG component (built offline with pre-cached Go modules) + interface with 2 users
    awg_comp_plan = _component_plan(current['version'], 'amneziawg')
    ctx.check(awg_comp_plan['state'] == 'missing' and awg_comp_plan['supported'], 'awg_component_plan_missing')
    awg_comp_id = secrets.token_hex(16)
    awg_comp_dir = '/var/lib/antirkn-runner/component-' + awg_comp_id
    remote('mkdir -m 700 -p ' + awg_comp_dir + '/go-path/pkg')
    upload(lib.fixture('awg-source'), awg_comp_dir + '/source.archive', mode='600')
    upload(lib.fixture('awg-tools'), awg_comp_dir + '/tools.archive', mode='600')
    upload(lib.fixture('awg-go'), awg_comp_dir + '/go.archive', mode='600')
    upload(lib.fixture('awg-gomod'), awg_comp_dir + '/awg-gomod.tar.gz', mode='600')
    remote('umask 077 && tar -xzf %s/awg-gomod.tar.gz -C %s/go-path/pkg && rm -f %s/awg-gomod.tar.gz'
           % (awg_comp_dir, awg_comp_dir, awg_comp_dir))
    awg_comp_job = ctx.rpc.run_job(dict(version=1, action='submit', id=awg_comp_id, kind='component_install',
                                        component='amneziawg', payload='', count=6, interval=1,
                                        fingerprint=awg_comp_plan['fingerprint']), timeout=600)
    ctx.check(awg_comp_job['status'] == 'succeeded', 'awg_component_installed')

    awg_def_resp = ctx.rpc(dict(version=1, action='awg_defaults'))
    ctx.check(awg_def_resp.get('code') == 'ok', 'awg_defaults_ok')
    awg_spec = dict(awg_def_resp['awgDefaults'])
    awg_spec.update(id=AWG_RES_ID, name='AmneziaWG Fixture', endpoint='127.0.0.1', port=51820, externalPort=42450)
    awg_payload = dict(version=1, protocol='awg', workspaceId=WORKSPACE, panelId=WORKSPACE,
                       resources=[awg_spec], users=VLESS_USERS)
    awg_plan = ctx.rpc(dict(version=1, action='awg_plan', id=WORKSPACE, payload=json.dumps(awg_payload)))
    ctx.check(awg_plan.get('code') == 'ok', 'awg_plan_ok')
    awg_job = ctx.rpc.run_job(dict(version=1, action='submit', id=secrets.token_hex(16), kind='awg_apply',
                                   count=3, interval=1, payload=json.dumps(awg_payload),
                                   fingerprint=awg_plan['awgPlan']['fingerprint']))
    ctx.check(awg_job['status'] == 'succeeded', 'awg_applied')
    awg_obs = ctx.rpc(dict(version=1, action='awg_state', id=WORKSPACE))['awgState']
    ctx.check(len(awg_obs) == 1 and awg_obs[0]['confirmed'] and len(awg_obs[0]['clients']) == 2
              and len({c['privateKey'] for c in awg_obs[0]['clients']}) == 2, 'awg_state_confirmed')

    # 5. Real TCP + UDP traffic through every inbound via pinned Mihomo + production compiler
    ws = _compiler_workspace(vless_specs, vless_obs, tt_spec, tt_obs, awg_spec, awg_obs)
    _traffic(ctx)  # The first read of each resource is the accounting baseline.
    with lib.EchoFixtures(tls_dir):
        for label, rid in [('vless_raw_reality', VLESS_RAW_ID), ('vless_xhttp_reality', VLESS_XHTTP_REALITY_ID)]:
            tcp, udp = _check_traffic(ctx, ws, rid, label)
            ctx.check(tcp and udp, label + '_tcp_udp')
        if mutation == 'drop_vless_tls_before_traffic_check':
            remote('iptables -I INPUT 1 -p tcp --dport 2445 -j DROP')
        tcp, udp = _check_traffic(ctx, ws, VLESS_XHTTP_TLS_ID, 'vless_xhttp_tls',
                                  timeout=6.0 if mutation else 10.0, retries=0 if mutation else POSITIVE_RETRIES)
        ctx.check(tcp and udp, 'vless_xhttp_tls_tcp_udp')
        for label, rid in [('tt', TT_RES_ID), ('awg', AWG_RES_ID)]:
            tcp, udp = _check_traffic(ctx, ws, rid, label)
            ctx.check(tcp and udp, label + '_tcp_udp')
        # Also verify the second user (bob) across protocols.
        for label, rid in [('vless_raw_reality_u1', VLESS_RAW_ID), ('tt_u1', TT_RES_ID), ('awg_u1', AWG_RES_ID)]:
            tcp, udp = _check_traffic(ctx, ws, rid, label, user_index=1)
            ctx.check(tcp and udp, label + '_tcp_udp')
    # This TrustTunnel allows private networks (the echo fixtures), so its
    # clients could reach a loopback metrics listener: it must not count.
    _check_traffic_ledger(ctx, [('vless', VLESS_RAW_ID, 'vless_raw_reality'), ('awg', AWG_RES_ID, 'awg')])
    ctx.check(_traffic(ctx).get(('tt', TT_RES_ID), {}).get('state') == 'off', 'tt_private_endpoint_has_no_client_metrics')

    if mutation is None:
        vm.stop()
        meta = dict(
            panel_id=PANEL_ID,
            workspace_id=WORKSPACE,
            runner_version=current['version'],
            runner_release=current['release'],
            vless_specs=vless_specs,
            tt_spec=tt_spec,
            awg_spec=awg_spec,
        )
        meta_path.write_text(json.dumps(meta, indent=2) + '\n')
        os.replace(building, protocols_disk)


# ---------------------------------------------------------------- inbound_isolation

def inbound_isolation(ctx, vm, mutation=None):
    disk = _ensure_protocols_disk(ctx, vm)
    meta = _load_meta()
    vm.start(lib.new_overlay('inbound-isolation', disk))
    ws, _, _, _ = _fetch_live_workspace(ctx, meta)
    all_ids = [s['id'] for s in meta['vless_specs']] + [TT_RES_ID, AWG_RES_ID]
    tt_unit = 'antirkn-tt@%s.service' % TT_RES_ID

    with lib.EchoFixtures(lib.BASE / 'protocols-tls'):
        ctx.check(all(all(_check_traffic(ctx, ws, rid, 'base-' + rid[-4:])) for rid in all_ids), 'baseline_all_inbounds_pass')

        # (a) Break TrustTunnel only -> TT unconfirmed & fails traffic; VLESS + AWG stay healthy.
        remote('systemctl stop ' + tt_unit)
        tt_state = ctx.rpc(dict(version=1, action='tt_state', id=WORKSPACE))['tt']['resources']
        ctx.check(len(tt_state) == 1 and not tt_state[0]['confirmed'], 'tt_state_unconfirmed_when_stopped')
        tt_tcp, tt_udp = _check_traffic(ctx, ws, TT_RES_ID, 'tt-down', timeout=5.0, retries=0)
        ctx.check(not tt_tcp and not tt_udp, 'tt_traffic_fails_when_stopped')

        if mutation == 'kill_extra_inbound_during_tt_outage':
            remote('iptables -I INPUT 1 -p tcp --dport 2443 -j DROP')

        for label, rid in [('vless_raw', VLESS_RAW_ID), ('vless_xhttp_reality', VLESS_XHTTP_REALITY_ID),
                           ('vless_xhttp_tls', VLESS_XHTTP_TLS_ID), ('awg', AWG_RES_ID)]:
            tcp, udp = _check_traffic(ctx, ws, rid, 'during-tt-outage-' + label,
                                      timeout=6.0 if mutation else 10.0, retries=0 if mutation else POSITIVE_RETRIES)
            ctx.check(tcp and udp, label + '_passes_during_tt_outage')

        vless_state = ctx.rpc(dict(version=1, action='vless_state', id=PANEL_ID))['vlessState']
        awg_state = ctx.rpc(dict(version=1, action='awg_state', id=WORKSPACE))['awgState']
        ctx.check(all(r['confirmed'] for r in vless_state), 'vless_state_confirmed_during_tt_outage')
        ctx.check(all(r['confirmed'] for r in awg_state), 'awg_state_confirmed_during_tt_outage')

        # Repair TT -> confirmed & passes again.
        remote('systemctl start ' + tt_unit)
        for _ in range(15):
            tt_state = ctx.rpc(dict(version=1, action='tt_state', id=WORKSPACE))['tt']['resources']
            if tt_state and tt_state[0]['confirmed']:
                break
            time.sleep(1)
        ctx.check(bool(tt_state) and tt_state[0]['confirmed'], 'tt_state_confirmed_after_repair')
        tt_tcp, tt_udp = _check_traffic(ctx, ws, TT_RES_ID, 'tt-repaired')
        ctx.check(tt_tcp and tt_udp, 'tt_traffic_passes_after_repair')

        # (b) Make ONE Xray inbound (2444 XHTTP/REALITY) unreachable -> only that inbound fails.
        remote('iptables -I INPUT 1 -p tcp --dport 2444 -j DROP')
        try:
            x_tcp, x_udp = _check_traffic(ctx, ws, VLESS_XHTTP_REALITY_ID, 'xhttp-dropped', timeout=5.0, retries=0)
            ctx.check(not x_tcp and not x_udp, 'vless_xhttp_reality_fails_when_dropped')
            for label, rid in [('vless_raw', VLESS_RAW_ID), ('vless_xhttp_tls', VLESS_XHTTP_TLS_ID),
                               ('tt', TT_RES_ID), ('awg', AWG_RES_ID)]:
                tcp, udp = _check_traffic(ctx, ws, rid, 'during-xhttp-outage-' + label)
                ctx.check(tcp and udp, label + '_passes_during_xhttp_outage')
            ctx.check(ctx.rpc(dict(version=1, action='tt_state', id=WORKSPACE))['tt']['resources'][0]['confirmed'],
                      'tt_state_confirmed_during_xhttp_outage')
            ctx.check(ctx.rpc(dict(version=1, action='awg_state', id=WORKSPACE))['awgState'][0]['confirmed'],
                      'awg_state_confirmed_during_xhttp_outage')
        finally:
            remote('iptables -D INPUT -p tcp --dport 2444 -j DROP', check=False)

        ctx.check(all(all(_check_traffic(ctx, ws, rid, 'repaired-' + rid[-4:])) for rid in all_ids),
                  'all_inbounds_pass_after_xhttp_repair')


# ---------------------------------------------------------------- upgrade_rollback

def _probe_workspace(spec, observation, probe_user):
    return dict(
        version=3,
        id=WORKSPACE,
        users=[dict(probe_user, login='probe', name='Diagnostic')],
        inbounds=[dict(serverId='fixture', spec=spec)],
        awgInterfaces=[],
        ttEndpoints=[],
        servers={'fixture': dict(observed=[observation])},
        profiles={},
    )


def upgrade_rollback(ctx, vm, mutation=None):
    disk = _ensure_protocols_disk(ctx, vm)
    meta = _load_meta()
    vm.start(lib.new_overlay('upgrade-rollback', disk))
    ws, _, _, _ = _fetch_live_workspace(ctx, meta)
    all_ids = [s['id'] for s in meta['vless_specs']] + [TT_RES_ID, AWG_RES_ID]
    ca_crt = lib.BASE / 'protocols-tls/ca.crt'
    mihomo = lib.fixture('mihomo')
    candidate_zip = lib.fixture('xray-candidate')

    def all_pass(tag):
        for rid in all_ids:
            tcp, udp = _check_traffic(ctx, ws, rid, tag + '-' + rid[-4:])
            if not (tcp and udp):
                return False
        return True

    def check_probe_ws(probe_ws, label, timeout=10.0, retries=POSITIVE_RETRIES):
        rid = probe_ws['inbounds'][0]['spec']['id']
        uid = probe_ws['users'][0]['id']
        work_dir = ctx.run_dir / ('mihomo-' + ctx.name) / label
        tcp, udp = lib.check_proxy_traffic(probe_ws, uid, rid, ca_crt, mihomo, work_dir,
                                           timeout=timeout, retries=retries)
        return tcp and udp

    def begin_tx(tag):
        plan_resp = ctx.rpc(dict(version=1, action='xray_check_plan', id=PANEL_ID))
        if plan_resp.get('code') != 'ok' or not plan_resp['xrayCheck']['available']:
            raise AssertionError('xray_check_plan unavailable: ' + str(plan_resp.get('code')))
        plan = plan_resp['xrayCheck']
        leases, probes = [], []
        for idx, spec in enumerate(meta['vless_specs']):
            lease = secrets.token_hex(16)
            resp = ctx.rpc(dict(version=1, action='probe_begin', id=lease,
                                payload=json.dumps(dict(protocol='vless', resource=spec['id'],
                                                        workspace=WORKSPACE, spec=spec))))
            if resp.get('code') != 'ok':
                raise AssertionError('probe_begin failed: ' + str(resp.get('code')))
            access = resp['connectionProbe']
            pws = _probe_workspace(spec, access['observation'], access['user'])
            if not check_probe_ws(pws, f'{tag}-base-{idx}'):
                raise AssertionError('probe baseline failed for ' + spec['id'])
            leases.append(lease)
            probes.append(pws)
        tx_key = secrets.token_hex(16)
        tx_dir = '/var/lib/antirkn-runner/xray-upgrades/' + tx_key
        remote('mkdir -m 700 -p ' + tx_dir)
        upload(candidate_zip, tx_dir + '/candidate.zip', mode='600')
        begin_payload = dict(
            panelId=PANEL_ID,
            fingerprint=plan['fingerprint'],
            leases=leases,
            network='vm-regression',
            core=XRAY_CORE_REV,
            baseline=[dict(lease=k, tcp=True, udp=True) for k in leases],
        )
        res = ctx.rpc(dict(version=1, action='xray_check_begin', id=tx_key, payload=json.dumps(begin_payload)))
        if res.get('code') != 'ok':
            raise AssertionError('xray_check_begin failed: ' + str(res.get('code')))
        commit_info = dict(nonce=res['xrayCheck']['nonce'], manifest=res['xrayCheck']['manifest'])
        status = None
        for _ in range(90):
            st = ctx.rpc(dict(version=1, action='xray_check_status', id=tx_key))
            status = st.get('xrayCheck') or {}
            if status.get('phase') in ('awaiting_checks', 'rolled_back', 'not_changed', 'recovery_required'):
                break
            time.sleep(1)
        if not status or status.get('phase') != 'awaiting_checks':
            raise AssertionError('unexpected begin phase: ' + str(status))
        return tx_key, commit_info, leases, probes

    def close_leases(leases):
        for k in leases:
            ended = ctx.rpc(dict(version=1, action='probe_end', id=k))
            if ended.get('connectionProbe') != dict(closed=True, stable=True):
                raise AssertionError('probe_end failed: ' + str(ended))

    with lib.EchoFixtures(lib.BASE / 'protocols-tls'):
        plan_resp = ctx.rpc(dict(version=1, action='xray_check_plan', id=PANEL_ID))
        ctx.check(plan_resp.get('code') == 'ok' and plan_resp['xrayCheck']['supported']
                  and plan_resp['xrayCheck']['available'] and plan_resp['xrayCheck']['current'] == '26.7.28'
                  and plan_resp['xrayCheck']['candidate'] == '26.11.9', 'xray_upgrade_plan_ready')

        # (a) Injected canary regression during check window -> rollback
        tx_a, commit_a, leases_a, probes_a = begin_tx('a')
        ctx.check(_xray_version() == '26.11.9', 'canary_candidate_active_in_window')
        remote('iptables -I INPUT 1 -p tcp --dport 2444 -j DROP')
        try:
            ctx.check(not check_probe_ws(probes_a[1], 'a-dropped', timeout=5.0, retries=0)
                      and check_probe_ws(probes_a[0], 'a-raw-ok')
                      and check_probe_ws(probes_a[2], 'a-tls-ok'), 'canary_regression_detected')
            if mutation == 'corrupt_rollback_previous':
                remote('printf corrupted > /var/lib/antirkn-runner/xray-upgrades/%s/previous' % tx_a)
            abort_resp = ctx.rpc(dict(version=1, action='xray_check_abort', id=tx_a, payload=json.dumps(commit_a)))
            ctx.check(abort_resp.get('code') == 'ok' and (abort_resp.get('xrayCheck') or {}).get('phase') == 'rolled_back',
                      'canary_abort_rolls_back')
        finally:
            remote('iptables -D INPUT -p tcp --dport 2444 -j DROP', check=False)
        close_leases(leases_a)
        ctx.check(_xray_version() == '26.7.28', 'canary_restored_original_xray_version')
        ctx.check(all_pass('after-canary'), 'all_inbounds_pass_after_canary_rollback')

        # (b) Deadline/watchdog path: runner stopped, deadline expires, independent watchdog rolls back
        tx_b, commit_b, leases_b, _ = begin_tx('b')
        ctx.check(_xray_version() == '26.11.9', 'watchdog_candidate_active_in_window')
        remote('systemctl stop antirkn-runner')
        watchdog_unit = 'antirkn-xray-rollback-' + tx_b + '.service'
        ctx.check(active(watchdog_unit), 'watchdog_unit_active')
        if mutation == 'disable_watchdog_unit':
            remote('systemctl stop ' + watchdog_unit)
        python(f'''import sys, time
sys.path.insert(0, '/usr/local/lib/antirkn-runner/{meta["runner_version"]}')
from runner import Store, STATE
import xray_transaction as x
import connectivity_probe as p
s = Store(STATE)
with p.operation_lock(s):
    info = x.load(s, {tx_b!r})
    info['deadline'] = time.time() - 1
    x.save(s, info)
s.close()
''')
        phase = None
        wait_limit = 15 if mutation == 'disable_watchdog_unit' else 60
        for _ in range(wait_limit):
            st = ctx.rpc(dict(version=1, action='xray_check_status', id=tx_b))
            phase = (st.get('xrayCheck') or {}).get('phase')
            if phase == 'rolled_back':
                break
            time.sleep(1)
        try:
            ctx.check(phase == 'rolled_back', 'watchdog_rolls_back_when_runner_stopped')
            late = ctx.rpc(dict(version=1, action='xray_check_commit', id=tx_b, payload=json.dumps(commit_b)))
            ctx.check(late.get('code') == 'xray_check_late', 'late_commit_rejected')
        finally:
            remote('systemctl start antirkn-runner')
        close_leases(leases_b)
        ctx.check(_xray_version() == '26.7.28', 'watchdog_restored_original_xray_version')
        ctx.check(all_pass('after-watchdog'), 'all_inbounds_pass_after_watchdog_rollback')

        # (c) Successful upgrade commit
        tx_c, commit_c, leases_c, probes_c = begin_tx('c')
        ctx.check(all(check_probe_ws(pws, f'c-ok-{i}') for i, pws in enumerate(probes_c)), 'commit_window_checks_pass')
        commit_c.update(network='vm-regression', checks=[dict(lease=k, tcp=True, udp=True) for k in leases_c])
        commit_resp = ctx.rpc(dict(version=1, action='xray_check_commit', id=tx_c, payload=json.dumps(commit_c)))
        ctx.check(commit_resp.get('code') == 'ok' and (commit_resp.get('xrayCheck') or {}).get('phase') == 'committed',
                  'xray_upgrade_committed')
        close_leases(leases_c)
        ctx.check(_xray_version() == '26.11.9', 'xray_committed_version_active')
        ctx.check(all_pass('after-commit'), 'all_inbounds_pass_after_commit')


# ---------------------------------------------------------------- reboot

def reboot(ctx, vm, mutation=None):
    disk = _ensure_protocols_disk(ctx, vm)
    meta = _load_meta()
    vm.start(lib.new_overlay('reboot', disk))

    diag_req, diag_before = diagnostic(ctx.rpc, 1)
    ctx.check(diag_before['status'] == 'succeeded', 'pre_reboot_diagnostic_succeeded')
    previous_boot = lib.boot_id()

    if mutation == 'disable_tt_unit_before_reboot':
        remote('systemctl disable antirkn-tt@%s.service' % TT_RES_ID)

    reboot_req = dict(version=1, action='submit', id=secrets.token_hex(16), kind='server_reboot', count=2, interval=1)
    ctx.check(ctx.rpc(reboot_req).get('code') == 'ok', 'server_reboot_submitted')
    vm.wait_boot(previous_boot, timeout=240)
    ctx.check(lib.boot_id() != previous_boot, 'post_reboot_new_boot_id')

    for _ in range(30):
        if active('antirkn-runner'):
            break
        time.sleep(1)
    ctx.check(active('antirkn-runner'), 'post_reboot_runner_active')

    reboot_job = ctx.rpc.wait_job(reboot_req['id'], timeout=60)
    ctx.check(reboot_job['status'] == 'succeeded', 'post_reboot_job_succeeded')

    # Earlier jobs from protocols setup and pre-reboot remain readable in jobs.sqlite.
    panel_jobs = (ctx.rpc.status(PANEL_ID).get('jobs') or [])
    diag_jobs = (ctx.rpc.status(diag_req['id']).get('jobs') or [])
    ctx.check(bool(panel_jobs) and panel_jobs[0]['status'] == 'succeeded'
              and bool(diag_jobs) and diag_jobs[0]['status'] == 'succeeded', 'post_reboot_jobs_db_intact')

    ws, vless_obs, tt_obs, awg_obs = _fetch_live_workspace(ctx, meta)
    with lib.EchoFixtures(lib.BASE / 'protocols-tls'):
        ctx.check(len(vless_obs) == 3 and all(r['confirmed'] for r in vless_obs), 'post_reboot_vless_confirmed')
        for label, rid in [('vless_raw', VLESS_RAW_ID), ('vless_xhttp_reality', VLESS_XHTTP_REALITY_ID),
                           ('vless_xhttp_tls', VLESS_XHTTP_TLS_ID)]:
            tcp, udp = _check_traffic(ctx, ws, rid, 'reboot-' + label)
            ctx.check(tcp and udp, 'post_reboot_' + label + '_passes')

        ctx.check(len(awg_obs) == 1 and awg_obs[0]['confirmed'], 'post_reboot_awg_confirmed')
        awg_tcp, awg_udp = _check_traffic(ctx, ws, AWG_RES_ID, 'reboot-awg')
        ctx.check(awg_tcp and awg_udp, 'post_reboot_awg_passes')

        ctx.check(len(tt_obs) == 1 and tt_obs[0]['confirmed'], 'post_reboot_tt_confirmed')
        tt_tcp, tt_udp = _check_traffic(ctx, ws, TT_RES_ID, 'reboot-tt')
        ctx.check(tt_tcp and tt_udp, 'post_reboot_tt_passes')


# ---------------------------------------------------------------- tt_metrics_upgrade

def tt_metrics_upgrade(ctx, vm, mutation=None):
    """A TrustTunnel endpoint written before runner v77 (no metrics section,
    private networks off) gets per-client metrics once the worker restarts,
    stays confirmed and counts its clients."""
    disk = _ensure_protocols_disk(ctx, vm)
    meta = _load_meta()
    vm.start(lib.new_overlay('tt-metrics', disk))
    ws, _, _, _ = _fetch_live_workspace(ctx, meta)
    vpn = '/etc/antirkn-components/trusttunnel/%s/vpn.toml' % TT_RES_ID
    unit = 'antirkn-tt@%s.service' % TT_RES_ID
    ctx.check('per_client_metrics' not in remote('cat ' + vpn).stdout.decode(), 'old_endpoint_has_no_metrics')
    # The stage endpoint allows private networks (the echo fixtures); its
    # record now says it does not, like an endpoint of an older runner.
    python("import json,sqlite3\n"
           "db=sqlite3.connect('/var/lib/antirkn-runner/jobs.sqlite')\n"
           "d=json.loads(db.execute('SELECT data FROM tt_resources WHERE id=?',(%r,)).fetchone()[0])\n"
           "d['spec']['allowPrivate']=False\n"
           "db.execute('UPDATE tt_resources SET data=? WHERE id=?',(json.dumps(d,sort_keys=True),%r))\n"
           "db.commit()\n" % (TT_RES_ID, TT_RES_ID))
    pid = lib.main_pid()
    remote('systemctl restart antirkn-runner')
    deadline = time.monotonic() + 90
    migrated = False
    while time.monotonic() < deadline and not migrated:
        time.sleep(3)
        migrated = re.search(r'per_client_metrics"?\s*=\s*true', remote('cat ' + vpn).stdout.decode()) is not None
    if not migrated:
        print(remote('journalctl -u antirkn-runner -n 40 --no-pager | grep -v heartbeat; '
                     'cat /var/lib/antirkn-runner/tt-metrics.json; echo; sha256sum ' + vpn + '; '
                     "sqlite3 /var/lib/antirkn-runner/jobs.sqlite \"SELECT status FROM jobs WHERE status IN ('planned','running')\"",
                     check=False).stdout.decode(errors='replace')[-4000:])
    ctx.check(migrated and lib.main_pid() != pid, 'worker_enables_metrics_after_restart')
    ctx.check(remote('systemctl is-active ' + unit, check=False).returncode == 0, 'tt_active_with_metrics')
    tt_state = ctx.rpc(dict(version=1, action='tt_state', id=WORKSPACE))['tt']['resources']
    ctx.check(len(tt_state) == 1 and tt_state[0]['confirmed'], 'tt_confirmed_after_migration')
    _traffic(ctx)
    with lib.EchoFixtures(lib.BASE / 'protocols-tls'):
        for index in (0, 1):
            tcp, udp = _check_traffic(ctx, ws, TT_RES_ID, 'tt-metrics-u%d' % index, user_index=index)
            ctx.check(tcp and udp, 'tt_traffic_after_migration_u%d' % index)
    _check_traffic_ledger(ctx, [('tt', TT_RES_ID, 'tt_migrated')])


# ---------------------------------------------------------------- reality_target

def _xray_pid():
    return remote("pgrep -o -f '/bin/xray-linux'").stdout.decode().strip()


def _panel_rows(version, remark_prefix):
    out = python(f'''import sys, json
from pathlib import Path
sys.path.insert(0, '/usr/local/lib/antirkn-runner/{version}')
from runner import Store
from vless import panel_for
store = Store(Path('/var/lib/antirkn-runner'))
rows = panel_for(store, {PANEL_ID!r}).call('/panel/api/inbounds/list')
print(json.dumps([dict(id=r['id'], remark=r['remark'], port=r['port']) for r in rows if r['remark'].startswith({remark_prefix!r})]))
store.close()
''').stdout
    return json.loads(out)


def reality_target(ctx, vm, mutation=None):
    """FR-SNI S5: a temporary REALITY inbound for one target and SNI.

    Real 3x-ui and Xray: the inbound is hot-added (Xray keeps its PID), real
    Mihomo traffic with a 100 KB transfer passes through it, managed inbounds
    keep working, discovery hides it, and the lease end removes it.
    """
    disk = _ensure_protocols_disk(ctx, vm)
    meta = _load_meta()
    vm.start(lib.new_overlay('reality-target', disk))
    version = ctx.bundle['version']
    ws, _, _, _ = _fetch_live_workspace(ctx, meta)
    # Target is the SNI with a port; the disposable VM resolves the host TLS fixture.
    remote("grep -q ' vless.test$' /etc/hosts || echo '10.0.2.2 vless.test' >> /etc/hosts")
    raw = next(s for s in meta['vless_specs'] if s['id'] == VLESS_RAW_ID)
    lease = secrets.token_hex(16)
    tunnel = None
    with lib.EchoFixtures(lib.BASE / 'protocols-tls'):
        ctx.check(all(_check_traffic(ctx, ws, VLESS_RAW_ID, 'managed-before')), 'managed_raw_before')
        pid = _xray_pid()
        try:
            response = ctx.rpc(dict(version=1, action='probe_begin', id=lease, payload=json.dumps(dict(
                protocol='reality_target', panel=PANEL_ID, target='vless.test:29443', sni='vless.test'))))
            ctx.check(response.get('code') == 'ok', 'begin_ok')
            access = response['connectionProbe']
            observed = access['observation']
            port = observed['spec']['port']
            ctx.check(20000 <= port < 61000, 'port_in_probe_range')
            ctx.check(_xray_pid() == pid, 'xray_not_restarted_by_begin')
            ctx.check([r['port'] for r in _panel_rows(version, 'AntiRKN:probe:')] == [port], 'one_temporary_inbound')
            listed = ctx.rpc(dict(version=1, action='panel_discover'))
            names = [i['name'] for p in listed.get('panelDiscovery', {}).get('panels', []) for i in p.get('inbounds', [])]
            ctx.check(listed.get('code') == 'ok' and bool(names) and not any(n.startswith('AntiRKN:probe:') for n in names),
                      'discovery_hides_temporary_inbound')
            local = lib._free_port()
            tunnel = subprocess.Popen(lib.ssh_command()[:-1] + ['-N', '-o', 'ExitOnForwardFailure=yes',
                                      '-L', '127.0.0.1:%d:127.0.0.1:%d' % (local, port), lib.ssh_command()[-1]],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(50):
                try:
                    with socket.create_connection(('127.0.0.1', local), timeout=.2):
                        break
                except OSError:
                    time.sleep(.1)
            spec = dict(raw, id=observed['id'], name='REALITY target check', port=port, endpoint='127.0.0.1',
                        externalPort=local, target='vless.test:29443', sni='vless.test')
            observation = dict(observed, workspaceId=WORKSPACE, spec=spec)
            probe_ws = _probe_workspace(spec, observation, access['user'])
            work_dir = ctx.run_dir / ('mihomo-' + ctx.name) / 'temporary'
            tcp, udp = lib.check_proxy_traffic(probe_ws, access['user']['id'], spec['id'], lib.BASE / 'protocols-tls/ca.crt',
                                               lib.fixture('mihomo'), work_dir, retries=POSITIVE_RETRIES, download=100 * 1024)
            ctx.check(tcp, 'temporary_inbound_tcp_and_100kb')
            ctx.check(udp, 'temporary_inbound_udp')
            ctx.check(all(_check_traffic(ctx, ws, VLESS_RAW_ID, 'managed-during')), 'managed_raw_during')
        finally:
            if tunnel is not None:
                tunnel.terminate()
                tunnel.wait(timeout=10)
            end = ctx.rpc(dict(version=1, action='probe_end', id=lease))
        ctx.check(end.get('code') == 'ok' and end['connectionProbe'] == dict(closed=True, stable=True), 'end_closed_stable')
        ctx.check(_panel_rows(version, 'AntiRKN:probe:') == [], 'temporary_inbound_removed')
        ctx.check(remote('ss -ltn | grep -q ":%d "' % port, check=False).returncode != 0, 'port_closed')
        ctx.check(_xray_pid() == pid, 'xray_not_restarted_by_end')
        ctx.check(all(_check_traffic(ctx, ws, VLESS_RAW_ID, 'managed-after')), 'managed_raw_after')
        ctx.check(ctx.rpc(dict(version=1, action='probe_end', id=lease))['connectionProbe'] == dict(closed=True, stable=True),
                  'end_is_idempotent')


SCENARIOS = {
    'runner_upgrade': dict(run=runner_upgrade, timeout=900,
                           mutations={'installer_drops_jobs_db': 'upgrade_preserves_old_job'}),
    'protocols': dict(run=protocols, timeout=1500,
                      mutations={'drop_vless_tls_before_traffic_check': 'vless_xhttp_tls_tcp_udp'}),
    'inbound_isolation': dict(run=inbound_isolation, timeout=600,
                              mutations={'kill_extra_inbound_during_tt_outage': 'vless_raw_passes_during_tt_outage'}),
    'upgrade_rollback': dict(run=upgrade_rollback, timeout=900,
                             mutations={
                                 'corrupt_rollback_previous': 'canary_abort_rolls_back',
                                 'disable_watchdog_unit': 'watchdog_rolls_back_when_runner_stopped',
                             }),
    'reboot': dict(run=reboot, timeout=600,
                   mutations={'disable_tt_unit_before_reboot': 'post_reboot_tt_confirmed'}),
    'tt_metrics_upgrade': dict(run=tt_metrics_upgrade, timeout=600, mutations={}),
    'reality_target': dict(run=reality_target, timeout=600, mutations={}),
}
ORDER = ['runner_upgrade', 'protocols', 'inbound_isolation', 'tt_metrics_upgrade', 'reality_target', 'upgrade_rollback', 'reboot']
