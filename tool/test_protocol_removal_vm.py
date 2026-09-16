#!/usr/bin/env python3
"""Exercise actual systemd deletion inside a dedicated disposable Ubuntu VM.

Start tool/runner_vm.py with ANTIRKN_VM_DIRECTORY=/tmp/antirkn-removal-vm.
Uses synthetic services/configs, never an owner's VPN or credentials.
"""
import json
import os
from pathlib import Path
import secrets
import time
from test_panel_vm import python, remote, bundle_strings, ROOT

assert Path(os.environ.get('ANTIRKN_VM_DIRECTORY', '')).resolve() == Path('/tmp/antirkn-removal-vm')
bundle = bundle_strings()
release = json.loads(bundle['runnerBundle'])['release']
info = json.loads(python(bundle['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))').stdout)
if info['release'] != release:
    if info['release']:
        python("""from pathlib import Path
import sqlite3,subprocess,shutil
assert Path('/etc/hostname').read_text().strip() == 'antirkn-runner-fixture'
db=sqlite3.connect('/var/lib/antirkn-runner/jobs.sqlite')
assert not db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone()
subprocess.run(['systemctl','stop','antirkn-runner'],check=True)
shutil.rmtree('/usr/local/lib/antirkn-runner/v19')
base=Path('/usr/local/lib/antirkn-runner')
if not any(base.iterdir()): base.rmdir()
Path('/etc/systemd/system/antirkn-runner.service').unlink()
subprocess.run(['systemctl','daemon-reload'],check=True)
""")
        info = json.loads(python(bundle['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))').stdout)
    installed = json.loads(python(bundle['runnerInstaller'], json.dumps({'fingerprint':info['fingerprint'],'bundle':json.loads(bundle['runnerBundle'])}).encode()).stdout)
    assert installed['active']

def rpc(request):
    return json.loads(remote('/usr/bin/python3 -I /usr/local/lib/antirkn-runner/v19/runner.py rpc', json.dumps(request).encode()).stdout)

results = {}
for active in (False, True):
    python("""from pathlib import Path
import subprocess
assert Path('/etc/hostname').read_text().strip() == 'antirkn-runner-fixture'
p=Path('/etc/systemd/system/antirkn-awg@.service')
p.write_text('[Unit]\\nDescription=Disposable AWG lifecycle fixture\\n[Service]\\nExecStart=/usr/bin/sleep infinity\\n[Install]\\nWantedBy=multi-user.target\\n')
p.chmod(0o644)
p=Path('/etc/amneziawg');p.mkdir(exist_ok=True);p.chmod(0o700)
(p/'fixture.conf').write_text('# public lifecycle fixture, no keys\\n')
Path('/etc/antirkn-unrelated-fixture').write_text('keep')
subprocess.run(['systemctl','daemon-reload'],check=True)
""" + ("subprocess.run(['systemctl','enable','--now','antirkn-awg@fixture.service'],check=True)" if active else ''))
    plan = rpc(dict(version=1,action='protocol_remove_plan',protocol='amneziawg'))['removalPlan']
    assert 'antirkn-awg@.service' in plan['services']
    job_id = secrets.token_hex(16)
    request = dict(version=1,action='submit',id=job_id,kind='protocol_remove',count=4,interval=1,protocol='amneziawg',fingerprint=plan['fingerprint'])
    assert rpc(request)['code'] == 'ok'
    for _ in range(120):
        response = rpc(dict(version=1,action='status',id=job_id,cursor=0))
        if response['code'] == 'busy': time.sleep(.2); continue
        job = response['jobs'][0]
        if job['status'] not in ('planned','running'): break
        time.sleep(.25)
    assert job['status'] == 'succeeded', [event['code'] for event in job['events']]
    assert rpc(request)['jobs'][0]['id'] == job_id
    python("""from pathlib import Path
import subprocess
assert not Path('/etc/amneziawg').exists()
assert not Path('/etc/systemd/system/antirkn-awg@.service').exists()
assert Path('/etc/antirkn-unrelated-fixture').read_text() == 'keep'
assert subprocess.run(['systemctl','is-active','--quiet','antirkn-awg@fixture.service']).returncode != 0
""")
    results['active_instance' if active else 'unconfigured_template'] = {'status':job['status'],'checkpoints':job['checkpoint'],'idempotent':True,'unrelated_preserved':True}
    print('PASS', 'active AWG service' if active else 'AWG template without interfaces', flush=True)
(ROOT/'docs/evidence/protocol-removal-vm.json').write_text(json.dumps({'fixture':'isolated Ubuntu 24.04 with real systemd sandbox, synthetic AWG services/configs','runnerRelease':release,'results':results},indent=2)+'\n')
