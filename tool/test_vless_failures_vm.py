#!/usr/bin/env python3
"""Effect/checkpoint failures on an already provisioned disposable VLESS VM."""
import copy
import json
import secrets
import time
from test_panel_vm import rpc, remote, python, ROOT
from test_vless_vm import PANEL_ID, WORKSPACE, USERS, payload, preview

results={}
def check(value,name):
    if not value:raise AssertionError(name)
    results[name]=True;print('PASS',name,flush=True)
def job(request):return rpc(dict(version=1,action='status',id=request['id'],cursor=0))['jobs'][0]
def wait(request):
    for _ in range(180):
        result=job(request)
        if result['status'] in ('succeeded','failed','partially_applied','cancelled'):return result
        time.sleep(.25)
    raise AssertionError('job_timeout')
def request(p):
    plan=preview(p)
    check(plan['code']=='ok','preflight_before_failure')
    return dict(version=1,action='submit',id=secrets.token_hex(16),kind='vless_apply',count=len(p['resources'])+2,interval=1,payload=json.dumps(p),fingerprint=plan['vlessPlan']['fingerprint'])

API_PREFIX='''import json,sys
from pathlib import Path
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v5')
from runner import Store
from vless import panel_for
store=Store(Path('/var/lib/antirkn-runner'))
api=panel_for(store,'10000000000000000000000000000001')
'''
def main():
    state=rpc(dict(version=1,action='vless_state',id=PANEL_ID))['vlessState']
    resources=[r['spec'] for r in sorted(state,key=lambda r:r['id'])]
    p=payload(resources)
    stale=request(p)
    python(API_PREFIX+'''import os
os.umask(0o077)
row=next(r for r in api.call('/panel/api/inbounds/list') if r['port']==2443)
Path('/var/lib/antirkn-runner/fixture-drift-row.json').write_text(json.dumps(row))
row['enable']=False
api.call('/panel/api/inbounds/update/'+str(row['id']),row)
''')
    try:
        check(preview(p)['code']=='vless_conflict','foreign_edit_blocks_plan')
        rpc(stale)
        result=wait(stale)
        check(result['status']=='failed' and result['checkpoint']==0,'stale_plan_has_zero_effects')
        observed=rpc(dict(version=1,action='vless_state',id=PANEL_ID))['vlessState']
        check(any(not r['confirmed'] for r in observed),'drift_never_reported_confirmed')
    finally:
        python(API_PREFIX+'''row=json.loads(Path('/var/lib/antirkn-runner/fixture-drift-row.json').read_text())
api.call('/panel/api/inbounds/update/'+str(row['id']),row)
''')
    # The real API update succeeds, then an injected runner SQLite failure
    # prevents recording it. Restart must reconcile the exact same operation.
    p=copy.deepcopy(p);p['users'][0]['enabled']=False
    req=request(p)
    remote('systemctl stop antirkn-runner')
    rpc(req)
    try:
        output=python(API_PREFIX+'''import sqlite3
store.tick()
store.db.execute("CREATE TRIGGER fixture_fail BEFORE INSERT ON vless_resources BEGIN SELECT RAISE(ABORT,'fixture'); END")
try:store.tick()
except sqlite3.Error:print('injected')
finally:store.db.execute('DROP TRIGGER fixture_fail')
''').stdout.decode()
        check('injected' in output,'crash_between_effect_and_checkpoint')
        check(job(req)['checkpoint']==1,'checkpoint_not_falsely_advanced')
        rpc(dict(version=1,action='cancel',id=req['id']))
        python(API_PREFIX+'store.tick()')
        check(job(req)['status']=='partially_applied','cancel_preserves_uncertain_effect_without_rollback')
        check(rpc(dict(version=1,action='resume',id=req['id']))['code']=='ok','explicit_resume_same_operation')
    finally:
        remote('systemctl start antirkn-runner')
    check(wait(req)['status']=='succeeded','restart_reconciles_uncertain_effect')
    observed=rpc(dict(version=1,action='vless_state',id=PANEL_ID))['vlessState']
    check(len(observed)==len(resources) and all(r['confirmed'] for r in observed),'no_duplicate_inbounds_after_recovery')
    check(all(not r['clients'][0]['enabled'] for r in observed),'revocation_completed_after_recovery')
    # OS reboot, not just worker restart, must preserve registry and UUIDs.
    before={(r['id'],u['id']):u['uuid'] for r in observed for u in r['clients']}
    remote('systemctl reboot',check=False)
    time.sleep(2)
    for _ in range(90):
        result=remote('systemctl is-active --quiet antirkn-runner x-ui',check=False,timeout=5)
        if result.returncode==0:break
        time.sleep(1)
    else:raise AssertionError('reboot_timeout')
    after=rpc(dict(version=1,action='vless_state',id=PANEL_ID))['vlessState']
    check(before=={(r['id'],u['id']):u['uuid'] for r in after for u in r['clients']} and all(r['confirmed'] for r in after),'reboot_preserves_registry_and_personal_credentials')
    (ROOT/'docs/evidence/vless-failures-ubuntu.json').write_text(json.dumps(dict(results=results),indent=2)+'\n')
if __name__=='__main__':main()
