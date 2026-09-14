#!/usr/bin/env python3
"""3x-ui 3.7 -> 3.8 on a dedicated, disposable Ubuntu VM; no owner data."""
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tarfile
import time
from test_panel_vm import remote, python, bundle_strings, ROOT
from runner_vm import ssh_command

PANEL_ID = '10000000000000000000000000000001'
RESULTS = {}


def check(value, name):
    if not value: raise AssertionError(name)
    RESULTS[name] = True
    print('PASS', name, flush=True)


def rpc(req, version='v9'):
    return json.loads(remote('/usr/bin/python3 -I /usr/local/lib/antirkn-runner/'+version+'/runner.py rpc', json.dumps(req).encode(),check=False).stdout)


def wait(req):
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        job = rpc(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
        if job['status'] not in ('running','planned'): return job
        time.sleep(.5)
    raise AssertionError('job_timeout')


def cache(req, update=False):
    directory = '/var/lib/antirkn-runner/panel' + ('-update' if update else '') + '-' + req['id']
    remote('mkdir -p -m 700 ' + directory)
    with open('/tmp/antirkn-panel-' + ('update' if update else 'release') + '.tar.gz', 'rb') as stream:
        subprocess.run(ssh_command()+['umask 077; cat > '+directory+'/release.tar.gz'],stdin=stream,check=True)


def panel(code):
    return python("import sys,json\nfrom pathlib import Path\nsys.path.insert(0,'/usr/local/lib/antirkn-runner/v9')\nfrom runner import Store\nfrom vless import panel_for\ns=Store(Path('/var/lib/antirkn-runner'))\na=panel_for(s,'"+PANEL_ID+"')\n"+code)


def run():
    global PANEL_ID
    if not os.environ.get('ANTIRKN_VM_DIRECTORY','').endswith('/panel-update-test'):
        raise SystemExit('Requires isolated panel-update-test VM')
    if '--reset' in sys.argv:
        # Explicit test reset: this entry point admits only the disposable fixture path.
        remote('systemctl stop x-ui antirkn-runner', check=False)
        python('''from pathlib import Path
import shutil
for name in ['/usr/local/x-ui','/etc/x-ui','/etc/antirkn-runner','/usr/local/lib/antirkn-runner','/var/lib/antirkn-runner']:
 p=Path(name)
 if p.exists(): shutil.rmtree(p)
for name in ['/etc/systemd/system/x-ui.service','/etc/systemd/system/antirkn-x-ui-bootstrap.service','/etc/systemd/system/antirkn-runner.service','/usr/bin/x-ui']:
 Path(name).unlink(missing_ok=True)
''')
        remote('systemctl daemon-reload')
    sources = bundle_strings()
    def inspect(src): return json.loads(python(src['runnerInspector']+'\nprint(json.dumps(inspect_runner()))').stdout)
    def install(src):
        p=inspect(src)
        return json.loads(python(src['runnerInstaller'],json.dumps(dict(fingerprint=p['fingerprint'],bundle=json.loads(src['runnerBundle']))).encode()).stdout)
    if inspect(sources)['state']=='missing':
        text=subprocess.check_output(['git','show','HEAD:packages/ssh_transport/lib/src/runner_bundle.g.dart'],cwd=ROOT,text=True)
        old={n:re.search(r'const '+n+r" =\s*r'''(.*?)''';",text,re.S)[1] for n in ('runnerBundle','runnerInspector','runnerInstaller')}
        check(install(old)['active'],'old_v7_started')
        check(inspect(sources)['upgradable'],'v7_predecessor_verified')
        check(install(sources)['active'],'v7_to_v9_upgrade')
    discovery=rpc(dict(version=1,action='panel_discover'))
    if not discovery.get('panelAccess'):
        p=json.loads(python(sources['runnerPanelInspector'],b'{"port":0}').stdout)['panelPlan']
        req=dict(version=1,action='submit',id=PANEL_ID,kind='panel_install',count=6,interval=1,port=p['port'],fingerprint=p['fingerprint'])
        cache(req)
        check(rpc(req)['code']=='ok','panel_install_accepted')
        check(wait(req)['status']=='succeeded','old_panel_installed')
    before=rpc(dict(version=1,action='panel_access',id=PANEL_ID))['panelAccess']
    if '--external' in sys.argv:
        with tarfile.open('/tmp/antirkn-panel-release.tar.gz') as archive:
            unit = archive.extractfile('x-ui/x-ui.service.debian').read()
        remote('systemctl stop x-ui')
        python("from pathlib import Path; import sys; Path('/etc/systemd/system/x-ui.service').write_bytes(sys.stdin.buffer.read())", unit)
        # Convert only this fixture to an ordinary installation and an owner login.
        python("from pathlib import Path; Path('/usr/local/x-ui/.antirkn-owner').unlink(); Path('/etc/x-ui/.antirkn-owner').unlink()")
        remote('systemctl daemon-reload && systemctl start x-ui')
        time.sleep(4)
        result=rpc(dict(version=1,action='panel_connect',payload=json.dumps({k:before[k] for k in ('port','username','password')})))
        check(result.get('panelVerified'),'standard_panel_connected')
        PANEL_ID=result['panelAccess']['id']
        before=result['panelAccess']

    panel('''from vless import wanted_inbound
p=dict(version=1,workspaceId='b'*32,panelId='''+repr(PANEL_ID)+''',users=[dict(id='c'*32,enabled=True)],resources=[dict(id='f'*32,transport='raw',security='reality',target='example.com:443',sni='example.com',enabled=True,listen='0.0.0.0',port=2470)])
w=wanted_inbound(p,p['resources'][0]);w['remark']='Existing client inbound'
if not a.call('/panel/api/inbounds/list'): a.call('/panel/api/inbounds/add',w)
''')
    time.sleep(3)
    getplan=lambda:rpc(dict(version=1,action='panel_update_plan',id=PANEL_ID))['panelUpdatePlan']
    preview=getplan()
    check(preview['state']=='update' and preview['supported'],'update_preview')
    check(preview['panelVersion']=='3.8.0' and preview['xrayVersion']=='26.7.28','pinned_pair')
    check(panel("print(a.call('/panel/api/server/status')['panelVersion'])").stdout.strip()==b'3.7.0','preview_does_not_update')
    def request(p): return dict(version=1,action='submit',kind='panel_update',id=secrets.token_hex(16),panelId=PANEL_ID,count=6,interval=1,fingerprint=p['fingerprint'])
    cancelled=request(preview)
    remote('systemctl stop antirkn-runner')
    rpc(cancelled);rpc(dict(version=1,action='cancel',id=cancelled['id']))
    remote('systemctl start antirkn-runner')
    check(wait(cancelled)['status']=='cancelled','cancel_before_update')
    stale=request(preview)
    panel("rows=a.call('/panel/api/inbounds/list'); r=rows[0];r['remark']='Changed after preview';a.call('/panel/api/inbounds/update/'+str(r['id']),r)")
    rpc(stale)
    job=wait(stale)
    check(job['status']=='failed' and job['events'][-1]['code']=='panel_conflict','stale_plan_rejected')
    req=request(getplan());cache(req,True)
    remote('systemctl stop antirkn-runner')
    check(rpc(req)['code']=='ok','update_accepted')
    # Worker checkpoint survives a process exit after replacing only the panel binary.
    result=python('''import sys,json
from pathlib import Path
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v9')
from runner import Store
import panel_update as u
s=Store(Path('/var/lib/antirkn-runner'))
for _ in range(4):s.tick()
real=u.atomic_file
def interrupted(path,data,mode=0o600):
 real(path,data,mode)
 if str(path)=='/usr/local/x-ui/x-ui': raise OSError('fixture interruption')
u.atomic_file=interrupted
s.tick()
print(s.db.execute('SELECT status FROM jobs WHERE id=?',('''+repr(req['id'])+''',)).fetchone()[0])
''')
    check(result.stdout.strip()==b'partially_applied','interrupted_update_is_partial')
    job=rpc(dict(version=1,action='status',id=req['id'],cursor=0))['jobs'][0]
    check(job['checkpoint']==4,'switch_checkpoint_retained')
    check(rpc(dict(version=1,action='resume',id=req['id']))['code']=='ok','resume_same_job')
    remote('systemctl start antirkn-runner')
    job=wait(req)
    if job['status']!='succeeded': print('job',job['status'],[e['code'] for e in job['events']],flush=True)
    check(job['status']=='succeeded','upgrade_resumed_and_verified')
    check(rpc(req)['jobs'][0]['sequence']==job['sequence'],'repeat_no_second_update')
    after=rpc(dict(version=1,action='panel_access',id=PANEL_ID))['panelAccess']
    check(all(before[k]==after[k] for k in ('id','username','password','port','basePath')),'credentials_and_address_preserved')
    check(after['panelVersion']=='3.8.0' and after['xrayVersion']=='26.7.28','actual_versions_refreshed')
    check(rpc(dict(version=1,action='panel_discover'))['panelAccess']==after,'discovery_after_upgrade')
    remote('systemctl reboot', check=False)
    time.sleep(5)
    for _ in range(60):
        try:
            if rpc(dict(version=1,action='panel_access',id=PANEL_ID)).get('panelAccess')==after: break
        except (ValueError, RuntimeError, OSError): pass
        time.sleep(1)
    else: raise AssertionError('reboot_recovery')
    check(True,'access_after_reboot')
    check(getplan()['state']=='current','no_repeat_or_downgrade')
    check(remote('test -s /var/lib/antirkn-runner/panel-update-'+req['id']+'/backup/x-ui.db').returncode==0,'database_backup_retained')
    check(before['password'] not in json.dumps(job),'no_password_in_events')
    (ROOT/'docs/evidence'/('panel-update-external-ubuntu.json' if '--external' in sys.argv else 'panel-update-ubuntu.json')).write_text(json.dumps(dict(results=RESULTS,panel='3.7.0 -> 3.8.0',xray='26.7.28 (compatible core retained)',runner='v7 -> v9'),indent=2)+'\n')

if __name__=='__main__':run()
