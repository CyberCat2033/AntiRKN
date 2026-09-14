#!/usr/bin/env python3
"""Known v1/v2/v3 -> current runner upgrade and interrupted-bootstrap repair on a disposable VM."""
import json
import os
import re
import subprocess
import time
from test_panel_vm import ROOT, remote, python, rpc, bundle_strings


def main():
    results = {}
    def check(value, name):
        if not value: raise AssertionError(name)
        results[name] = True
        print('PASS', name, flush=True)
    version = os.environ.get('ANTIRKN_PREDECESSOR', 'v2')
    commit = {'v1':'9f7c846', 'v2':'5f057bc', 'v3':'bbf67ed'}[version]
    source = subprocess.check_output(['git', 'show', commit + ':packages/ssh_transport/lib/src/runner_bundle.g.dart'], cwd=ROOT, text=True)
    old = {name: re.search(r'const ' + name + r" =\s*r'''(.*?)''';", source, re.S).group(1)
           for name in ('runnerBundle', 'runnerInspector', 'runnerInstaller')}
    new = bundle_strings()
    material_before = remote('sha256sum /etc/antirkn-runner/panel.key', check=False).stdout
    remote('systemctl stop antirkn-runner', check=False)
    remote('systemctl disable antirkn-runner', check=False)
    remote('rm -rf /usr/local/lib/antirkn-runner /var/lib/antirkn-runner /etc/systemd/system/antirkn-runner.service')
    remote('systemctl daemon-reload')
    def inspect(sources):
        return json.loads(python(sources['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))').stdout)
    def install(sources, preview, override=None, check=True):
        return python(override or sources['runnerInstaller'],
            json.dumps(dict(fingerprint=preview['fingerprint'],bundle=json.loads(sources['runnerBundle']))).encode(),check=check)
    check(json.loads(install(old, inspect(old)).stdout)['active'], 'previous_release_installed')
    req = dict(version=1, action='submit', id='f' * 32, kind='diagnostic', count=1, interval=1)
    remote('/usr/bin/python3 -I /usr/local/lib/antirkn-runner/' + version + '/runner.py rpc', json.dumps(req).encode())
    time.sleep(2)
    preview = inspect(new)
    check(preview['upgradable'], 'known_predecessor_recognized')
    original = remote('cat /etc/systemd/system/antirkn-runner.service').stdout
    remote('cat > /etc/systemd/system/antirkn-runner.service', original + b'\n# fixture administrator edit\n')
    check(inspect(new)['state'] == 'conflict', 'unknown_unit_not_adopted')
    check(install(new, preview, check=False).returncode != 0, 'changed_unit_refuses_old_plan')
    remote('cat > /etc/systemd/system/antirkn-runner.service', original)
    preview = inspect(new)
    broken = new['runnerInstaller'].replace('os.replace(str(temp_unit), str(UNIT))', "raise OSError('fixture crash before unit commit')")
    check(install(new, preview, override=broken, check=False).returncode != 0, 'injected_bootstrap_interruption')
    partial = inspect(new)
    check(partial['state'] == 'partial', 'partial_bootstrap_identified')
    check(json.loads(install(new, partial).stdout)['active'], 'partial_bootstrap_repaired_by_plan')
    job = rpc(dict(version=1,action='status',id=req['id'],cursor=0))['jobs'][0]
    check(job['status'] == 'succeeded' and job['checkpoint'] == 1, 'previous_job_and_events_preserved')
    pid = remote('systemctl show antirkn-runner -p MainPID --value').stdout
    check(json.loads(install(new, inspect(new)).stdout)['active'], 'repeat_install_confirmed')
    check(pid == remote('systemctl show antirkn-runner -p MainPID --value').stdout, 'repeat_does_not_restart_worker')
    if material_before:
        check(material_before == remote('sha256sum /etc/antirkn-runner/panel.key').stdout, 'panel_root_material_preserved')
    (ROOT / ('docs/evidence/components-runner-upgrade-' + version + '.json')).write_text(json.dumps({'from':version,'to':'v5','release':json.loads(new['runnerBundle'])['release'],'results':results},indent=2)+'\n')


if __name__ == '__main__': main()
