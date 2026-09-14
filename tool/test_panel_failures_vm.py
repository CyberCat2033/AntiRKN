#!/usr/bin/env python3
"""Fault/recovery checks exclusively on the generated local QEMU fixture."""
import json
from pathlib import Path
import sys
import time
from test_panel_vm import ROOT, remote, python, rpc, bundle_strings


def main():
    results = {}
    sources = bundle_strings()
    sequence = max([20] + [int(j['id'], 16) for j in rpc(dict(version=1,action='list'))['jobs'] if int(j['id'],16) < 1000000])
    def check(value, name):
        if not value: raise AssertionError(name)
        results[name] = True
        (ROOT / 'docs/evidence/panel-failures-ubuntu.json').write_text(json.dumps({'complete':False,'results':results},indent=2)+'\n')
        print('PASS', name, flush=True)
    def plan(port=2053):
        return json.loads(python(sources['runnerPanelInspector'], json.dumps(dict(port=port)).encode()).stdout)['panelPlan']
    def submit(preview=None):
        nonlocal sequence
        sequence += 1
        p = preview or plan()
        request = dict(version=1, action='submit', id=f'{sequence:032x}', kind='panel_install',
            count=6, interval=1, port=p['port'], fingerprint=p['fingerprint'])
        check(rpc(request)['code'] == 'ok', f'admit_{sequence}')
        return request
    def job(req):
        return rpc(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
    def wait(req):
        for _ in range(600):
            value = job(req)
            if value['status'] not in ('running', 'planned'): return value
            time.sleep(1)
        raise AssertionError('job_timeout')
    def reset_panel():
        remote('systemctl stop x-ui antirkn-x-ui-bootstrap', check=False)
        remote('systemctl disable x-ui', check=False)
        remote('rm -rf /usr/local/x-ui /etc/x-ui /etc/systemd/system/x-ui.service /etc/systemd/system/antirkn-x-ui-bootstrap.service')
        remote('systemctl daemon-reload')
    def tick_source(req, extra=''):
        return f"""import sys,json,os
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v4')
from runner import Store
from panel import PanelInstaller
s=Store('/var/lib/antirkn-runner')
req=json.loads({json.dumps(json.dumps(req))})
{extra}
s.tick()
"""
    # Keep a verified public archive to avoid repeat network traffic in fault injection.
    remote('cp /var/lib/antirkn-runner/panel-10000000000000000000000000000001/release.tar.gz /var/cache/antirkn-fixture-release.tar.gz')
    if remote('test -f /usr/local/x-ui/x-ui', check=False).returncode == 0:
        before = remote('sha256sum /usr/local/x-ui/x-ui /etc/systemd/system/x-ui.service').stdout
        existing = submit(plan(2054))
        check(wait(existing)['events'][-1]['code'] == 'panel_existing', 'existing_refused')
        check(before == remote('sha256sum /usr/local/x-ui/x-ui /etc/systemd/system/x-ui.service').stdout, 'existing_files_unchanged')
        reset_panel()

    stale = submit({**plan(), 'fingerprint': '0' * 64})
    check(wait(stale)['status'] == 'failed', 'stale_plan_rejected')
    check(remote('test ! -e /usr/local/x-ui && test ! -e /etc/x-ui').returncode == 0, 'stale_no_panel_effect')

    listener = "import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',2053));s.listen();time.sleep(180)"
    import shlex
    listener_unit = 'antirkn-fixture-listener-' + str(int(time.time()))
    remote('systemd-run --unit=' + listener_unit + ' /usr/bin/python3 -c ' + shlex.quote(listener))
    occupied = plan()
    for _ in range(30):
        if not occupied['portAvailable']: break
        time.sleep(0.2)
        occupied = plan()
    check(not occupied['portAvailable'], 'occupied_port_preview')
    req = submit(occupied)
    check(wait(req)['events'][-1]['code'] == 'panel_port_busy', 'occupied_port_apply_refused')
    remote('systemctl stop ' + listener_unit)

    remote('systemctl stop antirkn-runner')
    req = submit()
    rpc(dict(version=1, action='cancel', id=req['id']))
    remote('systemctl start antirkn-runner')
    check(wait(req)['status'] == 'cancelled', 'cancel_before_effect')
    check(remote('test ! -e /usr/local/x-ui && test ! -e /etc/x-ui').returncode == 0, 'cancel_no_files')

    # Real network failure (connection refused for GitHub), then same-ID resume.
    remote('systemctl stop antirkn-runner')
    req = submit()
    python(tick_source(req))
    hosts = remote('cat /etc/hosts').stdout
    remote('cat > /etc/hosts', hosts + b'\n127.0.0.1 github.com\n')
    try:
        python(tick_source(req), timeout=90)
        check(job(req)['events'][-1]['code'] == 'panel_download_failed', 'download_network_failure')
    finally:
        remote('cat > /etc/hosts', hosts)
    check(rpc(dict(version=1, action='resume', id=req['id']))['code'] == 'ok', 'resume_same_failed_job')
    path = '/var/lib/antirkn-runner/panel-' + req['id']
    remote('cp /var/cache/antirkn-fixture-release.tar.gz ' + path + '/release.tar.gz')
    python(tick_source(req))  # verified cached download -> checkpoint 2
    check(job(req)['checkpoint'] == 2, 'verified_download_checkpoint')
    # Kill the process after real file effects but before their checkpoint commit.
    python(tick_source(req, "PanelInstaller.checkpoint = lambda *args: os._exit(0)"))
    check(job(req)['checkpoint'] == 2 and remote('test -f /usr/local/x-ui/x-ui').returncode == 0,
          'crash_between_effect_and_checkpoint')
    remote('systemctl reboot', check=False)
    time.sleep(2)
    for _ in range(180):
        try:
            if remote('systemctl is-active --quiet antirkn-runner', check=False, timeout=6).returncode == 0:
                break
        except Exception: pass
        time.sleep(1)
    check(wait(req)['status'] == 'succeeded', 'reboot_reconciles_applied_files')
    check(rpc(req)['jobs'][0]['id'] == req['id'], 'reboot_no_second_job')

    # Cancellation after extraction retains effects; explicit resume finishes them.
    reset_panel()
    remote('systemctl stop antirkn-runner')
    req = submit()
    python(tick_source(req))
    path = '/var/lib/antirkn-runner/panel-' + req['id']
    remote('cp /var/cache/antirkn-fixture-release.tar.gz ' + path + '/release.tar.gz')
    python(tick_source(req)); python(tick_source(req))
    rpc(dict(version=1, action='cancel', id=req['id']))
    python(tick_source(req))
    check(job(req)['status'] == 'partially_applied', 'cancel_after_files_reports_partial')
    check(plan()['state'] == 'existing', 'partial_files_not_reinstalled')
    check(rpc(dict(version=1, action='resume', id=req['id']))['code'] == 'ok', 'explicit_resume_partial')
    remote('systemctl start antirkn-runner')
    check(wait(req)['status'] == 'succeeded', 'partial_resume_completes')
    (ROOT / 'docs/evidence/panel-failures-ubuntu.json').write_text(json.dumps({'complete':True,'results': results}, indent=2) + '\n')


if __name__ == '__main__': main()
