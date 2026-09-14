#!/usr/bin/env python3
"""Integration checks on the disposable local Ubuntu VM; no owner VPS access."""
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

from runner_vm import DIRECTORY, ssh_command

ROOT = Path(__file__).resolve().parent.parent


def remote(command, data=None, timeout=180, check=True):
    result = subprocess.run(ssh_command() + [command], input=data,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError('fixture command failed: ' + result.stderr.decode(errors='replace')[-1000:])
    return result


def python(source, data=None, **kwargs):
    return remote('/usr/bin/python3 -I -c ' + shlex.quote(source), data=data, **kwargs)


def bundle_strings():
    source = (ROOT / 'packages/ssh_transport/lib/src/runner_bundle.g.dart').read_text()
    return {name: re.search(r'const ' + name + r" =\s*r'''(.*?)''';", source, re.S).group(1)
        for name in ('runnerBundle', 'runnerInspector', 'runnerInstaller', 'runnerPanelInspector')}


def rpc(request):
    result = remote('/usr/bin/python3 -I /usr/local/lib/antirkn-runner/v2/runner.py rpc',
                    json.dumps(request).encode())
    return json.loads(result.stdout)


def main():
    results = {}
    def check(value, name):
        if not value:
            raise AssertionError(name)
        results[name] = True
        print('PASS', name, flush=True)
    sources = bundle_strings()
    if '--reset' in sys.argv:
        # Only this disposable fixture's generated trust file/loopback port are used.
        remote('systemctl stop x-ui antirkn-x-ui-bootstrap antirkn-runner', check=False)
        remote('systemctl stop antirkn-fixture-listener', check=False)
        remote('systemctl disable x-ui antirkn-runner', check=False)
        remote('rm -rf /usr/local/x-ui /etc/x-ui /etc/antirkn-runner /usr/local/lib/antirkn-runner /var/lib/antirkn-runner /etc/systemd/system/x-ui.service /etc/systemd/system/antirkn-x-ui-bootstrap.service /etc/systemd/system/antirkn-runner.service')
        remote('systemctl daemon-reload')
    inspect = lambda: json.loads(python(sources['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))').stdout)
    plan = inspect()
    check(plan['supported'], 'ubuntu_prerequisites')
    preview = json.loads(python(sources['runnerPanelInspector'], json.dumps(dict(port=2053)).encode()).stdout)['panelPlan']
    check(preview['state'] == 'missing' and preview['supported'] and preview['portAvailable'], 'panel_read_only_preview')
    check(remote('test ! -e /usr/local/x-ui && test ! -e /etc/x-ui').returncode == 0, 'preview_has_no_mutations')
    installed = json.loads(python(sources['runnerInstaller'], json.dumps(dict(fingerprint=plan['fingerprint'], bundle=json.loads(sources['runnerBundle']))).encode()).stdout)
    check(installed['active'], 'runner_install')
    job_id = '10000000000000000000000000000001'
    request = dict(version=1, action='submit', id=job_id, kind='panel_install', count=6, interval=1,
                   port=2053, fingerprint=preview['fingerprint'])
    check(rpc(request)['code'] == 'ok', 'panel_submit')
    last = None
    for _ in range(1200):
        job = rpc(dict(version=1, action='status', id=job_id, cursor=0))['jobs'][0]
        status = (job['status'], job['checkpoint'])
        if status != last:
            print('job', status, [e['code'] for e in job['events']][-3:], flush=True)
            last = status
        if job['status'] not in ('planned', 'running'):
            break
        time.sleep(1)
    check(job['status'] == 'succeeded', 'panel_installed')
    check(rpc(request)['jobs'][0]['sequence'] == job['sequence'], 'repeat_same_id_no_effect')
    # This response is deliberately never printed or written to evidence.
    access = rpc(dict(version=1, action='panel_access', id=job_id))['panelAccess']
    check(len(access['password']) == 43 and access['username'] == 'antirkn', 'stable_private_credentials')
    check(rpc(dict(version=1, action='panel_access', id=job_id))['panelAccess'] == access, 'credential_repeat_stable')
    ports = remote('ss -lntp').stdout.decode()
    check('127.0.0.1:2053' in ports and '0.0.0.0:2053' not in ports and ':2096' not in ports, 'only_loopback_panel_no_subscription')
    preview2 = json.loads(python(sources['runnerPanelInspector'], json.dumps(dict(port=2054)).encode()).stdout)['panelPlan']
    check(preview2['state'] == 'existing', 'existing_installation_preserved')
    record = dict(results=results, panelVersion=access['panelVersion'], xrayVersion=access['xrayVersion'],
                  os=remote('lsb_release -ds').stdout.decode().strip())
    (ROOT / 'docs/evidence/panel-ubuntu.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    main()
