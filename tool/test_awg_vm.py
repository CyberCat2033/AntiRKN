#!/usr/bin/env python3
"""AWG tests on a separate disposable VM. Never print peer credentials."""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sys
import time
from test_panel_vm import ROOT, remote, python, bundle_strings


def rpc(req):
    r = remote('/usr/bin/python3 -I /usr/local/lib/antirkn-runner/v10/runner.py rpc', json.dumps(req).encode(), check=False)
    return json.loads(r.stdout)


def wait(req):
    response = rpc(req)
    if response['code'] != 'ok': raise AssertionError(response['code'])
    for _ in range(900):
        result = rpc(dict(version=1,action='status',id=req['id'],cursor=0))
        if result['code']=='busy':
            time.sleep(.5); continue
        if not result['jobs']: raise AssertionError(result['code'])
        job = result['jobs'][0]
        if job['status'] not in ('planned','running'): return job
        time.sleep(.5)
    raise AssertionError('AWG job timeout')


def bootstrap():
    if '--deploy' in sys.argv:
        # Development deployment is limited to this disposable fixture. The
        # immutable production upgrader never replaces an unknown release.
        if Path(os.environ.get('ANTIRKN_VM_DIRECTORY', '')).name not in ('awg-test', 'awg-test2'):
            raise RuntimeError('Not the AWG disposable fixture')
        python("""import pathlib,sqlite3,subprocess,shutil
assert pathlib.Path('/etc/hostname').read_text().strip()=='antirkn-runner-fixture'
p=pathlib.Path('/var/lib/antirkn-runner/jobs.sqlite')
if p.exists():
 d=sqlite3.connect(p);assert not d.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone();d.close()
subprocess.run(['systemctl','stop','antirkn-runner'],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
shutil.rmtree('/usr/local/lib/antirkn-runner/v10',ignore_errors=True)
base=pathlib.Path('/usr/local/lib/antirkn-runner')
if base.exists() and not any(base.iterdir()):base.rmdir()
pathlib.Path('/etc/systemd/system/antirkn-runner.service').unlink(missing_ok=True)
subprocess.run(['systemctl','daemon-reload'],check=True)
""")
    sources = bundle_strings()
    plan = json.loads(python(sources['runnerInspector']+'\nprint(json.dumps(inspect_runner()))').stdout)
    if plan['release'] != json.loads(sources['runnerBundle'])['release']:
        installed = json.loads(python(sources['runnerInstaller'], json.dumps(dict(fingerprint=plan['fingerprint'],bundle=json.loads(sources['runnerBundle']))).encode()).stdout)
        assert installed['active']
    # The existing-installation test adds a real Docker AWG next to ours.
    # Component discovery then correctly refuses a new installation, while
    # the already owned installation remains usable by managed interfaces.
    present = python("import sys;sys.path.insert(0,'/usr/local/lib/antirkn-runner/v10');from awg import prerequisites;prerequisites()", check=False)
    if present.returncode == 0:
        return
    source=(ROOT/'packages/ssh_transport/lib/src/runner_bundle.g.dart').read_text()
    inspector=re.search(r"const runnerComponentInspector =\s*r'''(.*?)''';",source,re.S).group(1)
    plan=json.loads(python(inspector,json.dumps(dict(component='amneziawg')).encode()).stdout)['componentPlan']
    if plan['state'] == 'current': return
    req=dict(version=1,action='submit',id=secrets.token_hex(16),kind='component_install',component='amneziawg',count=6,interval=1,fingerprint=plan['fingerprint'])
    release=json.loads((ROOT/'schemas/component-releases.json').read_text())['amneziawg']
    directory='/var/lib/antirkn-runner/component-'+req['id']
    remote('mkdir -m 700 -p '+directory)
    for name,path in {'source':'/tmp/antirkn-awg-source.tar.gz','tools':'/tmp/antirkn-awg-tools.zip','go':'/tmp/antirkn-go.tar.gz'}.items():
        data=Path(path).read_bytes()
        assert hashlib.sha256(data).hexdigest()==release['archives'][name]['sha256']
        remote('cat > '+directory+'/'+name+'.archive',data)
    job=wait(req)
    if job['status']!='succeeded': raise AssertionError(job['events'][-1]['code'])
    print('PASS real AWG installation',flush=True)


if __name__=='__main__':
    bootstrap()
