#!/usr/bin/env python3
"""Real effect/checkpoint interruption, cancellation and reboot recovery."""
import json
import time
from pathlib import Path
from test_panel_vm import ROOT, remote, python, rpc


def main():
    results = {}
    def check(value,name):
        if not value: raise AssertionError(name)
        results[name]=True
        print('PASS',name,flush=True)
    remote('systemctl stop antirkn-runner')
    remote('systemctl enable antirkn-trusttunnel')
    directory='/var/lib/antirkn-runner/component-'+('6'*32)
    remote('mkdir -m 700 -p '+directory)
    remote('cat > '+directory+'/endpoint.archive',Path('/tmp/antirkn-tt.tar.gz').read_bytes())
    outcome=python(r'''
import sys,json,os
from pathlib import Path
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v4')
from components import component_plan,ComponentInstaller,installed
from runner import Store
base=Path('/usr/local/lib/antirkn-components/trusttunnel')
(base/'current').unlink()
os.symlink('versions/'+('f'*64),base/'current')
import subprocess
subprocess.run(['systemctl','restart','antirkn-trusttunnel'],check=True)
plan=component_plan('trusttunnel')
store=Store('/var/lib/antirkn-runner')
req=dict(version=1,action='submit',kind='component_install',component='trusttunnel',id='6'*32,count=6,interval=1,fingerprint=plan['fingerprint'])
assert store.request(req)['code']=='ok'
for _ in range(4): store.tick()
row=store.db.execute('SELECT checkpoint FROM jobs WHERE id=?',(req['id'],)).fetchone()
assert row[0]==4
installer=ComponentInstaller(store,req)
def crash(*args): raise RuntimeError('fixture crash after pointer effect')
installer.checkpoint=crash
try: installer.step(4)
except RuntimeError: pass
assert installed('trusttunnel')['version']=='1.1.0'
assert store.db.execute('SELECT checkpoint FROM jobs WHERE id=?',(req['id'],)).fetchone()[0]==4
store.request(dict(version=1,action='cancel',id=req['id']))
store.tick()
job=store.request(dict(version=1,action='status',id=req['id'],cursor=0))['jobs'][0]
assert job['status']=='partially_applied'
print(json.dumps(dict(effect_without_checkpoint=True,cancel_after_effect_is_partial=True)))
store.close()
''')
    for name,value in json.loads(outcome.stdout).items(): check(value,name)
    before=remote('sha256sum /etc/antirkn-components/trusttunnel/*').stdout
    old_boot=remote('cat /proc/sys/kernel/random/boot_id').stdout
    remote('systemctl reboot',check=False)
    time.sleep(2)
    for _ in range(120):
        try:
            if remote('systemctl is-active --quiet antirkn-runner',check=False,timeout=5).returncode==0:
                if remote('cat /proc/sys/kernel/random/boot_id').stdout!=old_boot: break
        except Exception: pass
        time.sleep(1)
    check(remote('cat /proc/sys/kernel/random/boot_id').stdout!=old_boot,'real_reboot')
    job=rpc(dict(version=1,action='status',id='6'*32,cursor=0))['jobs'][0]
    check(job['status']=='partially_applied','partial_result_survives_reboot')
    check(rpc(dict(version=1,action='resume',id='6'*32))['code']=='ok','explicit_resume_same_id')
    for _ in range(60):
        job=rpc(dict(version=1,action='status',id='6'*32,cursor=0))['jobs'][0]
        if job['status'] not in ('planned','running'): break
        time.sleep(1)
    check(job['status']=='succeeded' and job['checkpoint']==6,'effect_reconciled_and_finished')
    check(before==remote('sha256sum /etc/antirkn-components/trusttunnel/*').stdout,'recovery_preserves_configs_and_keys')
    check(len({e['sequence'] for e in job['events']})==len(job['events']),'events_remain_monotonic')
    check(remote('systemctl is-active --quiet antirkn-trusttunnel').returncode==0,'service_active_after_recovery')
    check(json.loads(python(r'''
import sys,json
from pathlib import Path
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v4')
from components import component_plan
path=Path('/etc/systemd/system/antirkn-trusttunnel.service')
original=path.read_bytes()
try:
 path.write_bytes(original+b'\n# external edit\n')
 assert component_plan('trusttunnel')['state']=='conflict'
 print('true')
finally: path.write_bytes(original)
''').stdout),'unknown_unit_not_overwritten')
    (ROOT/'docs/evidence/components-recovery.json').write_text(json.dumps(dict(results=results),indent=2)+'\n')


if __name__=='__main__': main()
