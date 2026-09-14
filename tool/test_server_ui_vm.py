#!/usr/bin/env python3
"""Server UI integration on a dedicated disposable VM. Never use the manual VM."""
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import time
from test_panel_vm import remote, python, bundle_strings, ROOT
from runner_vm import ssh_command

RESULTS = {}
PANEL_ID = '10000000000000000000000000000001'


def check(value, name):
    if not value: raise AssertionError(name)
    RESULTS[name] = True
    print('PASS', name, flush=True)


def rpc(request):
    result = remote('/usr/bin/python3 -I /usr/local/lib/antirkn-runner/v7/runner.py rpc', json.dumps(request).encode(), check=False)
    return json.loads(result.stdout)


def finish(req, timeout=300):
    response = rpc(req)
    check(response['code'] == 'ok', req['kind'] + '_accepted')
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = rpc(dict(version=1, action='status', id=req['id'], cursor=0))
        if status['code'] != 'ok' or not status['jobs']:
            time.sleep(.5)
            continue
        job = status['jobs'][0]
        if job['status'] not in ('planned', 'running'): return job
        time.sleep(.5)
    raise AssertionError('job_timeout')


def panel_code(code, data=None):
    return python("import sys,json\nfrom pathlib import Path\nsys.path.insert(0,'/usr/local/lib/antirkn-runner/v7')\nfrom runner import Store\nfrom vless import panel_for\ns=Store(Path('/var/lib/antirkn-runner'))\na=panel_for(s,'" + PANEL_ID + "')\n" + code, data)


def run():
    if not os.environ.get('ANTIRKN_VM_DIRECTORY', '').endswith('/server-ui-test'):
        raise SystemExit('Requires the isolated server-ui-test VM')
    sources = bundle_strings()
    def inspect(s): return json.loads(python(s['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))').stdout)
    def install(s):
        p = inspect(s)
        return json.loads(python(s['runnerInstaller'], json.dumps(dict(fingerprint=p['fingerprint'], bundle=json.loads(s['runnerBundle']))).encode()).stdout)
    if inspect(sources)['state'] == 'missing':
        source = subprocess.check_output(['git', 'show', '6fa6ae2cd553a007afa50ab5dc84b02a74434d5b:packages/ssh_transport/lib/src/runner_bundle.g.dart'], cwd=ROOT, text=True)
        old = {n: re.search(r'const ' + n + r" =\s*r'''(.*?)''';", source, re.S)[1] for n in ('runnerBundle','runnerInspector','runnerInstaller')}
        check(install(old)['active'], 'old_v5_started')
        check(inspect(sources)['upgradable'], 'v5_predecessor_verified')
        check(install(sources)['active'], 'v5_to_v7_upgrade')
    elif inspect(sources)['upgradable']:
        check(install(sources)['active'], 'verified_predecessor_to_v7_upgrade')
    elif inspect(sources)['release'] != json.loads(sources['runnerBundle'])['release']:
        raise AssertionError('Fixture runner differs: start a fresh VM or explicitly update this test fixture')
    else: check(inspect(sources)['active'], 'v7_running')
    discovery = rpc(dict(version=1, action='panel_discover'))
    if not discovery.get('panelAccess'):
        preview = json.loads(python(sources['runnerPanelInspector'], b'{"port":0}').stdout)['panelPlan']
        check(10000 <= preview['port'] <= 65535 and preview['portAvailable'], 'random_free_port')
        check(remote('test ! -e /etc/x-ui && test ! -e /usr/local/x-ui').returncode == 0, 'preview_no_installation')
        directory = '/var/lib/antirkn-runner/panel-' + PANEL_ID
        remote('mkdir -m 700 -p ' + directory)
        with open('/tmp/antirkn-panel-release.tar.gz','rb') as stream:
            subprocess.run(ssh_command() + ['umask 077; cat > ' + directory + '/release.tar.gz'], stdin=stream, check=True)
        req = dict(version=1, action='submit', id=PANEL_ID, kind='panel_install', count=6, interval=1, port=preview['port'], fingerprint=preview['fingerprint'])
        job = finish(req)
        check(job['status'] == 'succeeded', 'panel_random_path_install')
    access = rpc(dict(version=1, action='panel_access', id=PANEL_ID))['panelAccess']
    check(bool(re.fullmatch(r'/[A-Za-z0-9_-]{24}/', access['basePath'])), 'random_persisted_webpath')
    check(rpc(dict(version=1, action='panel_discover'))['panelAccess'] == access, 'discovery_recovers_random_path')
    check(panel_code("print(a.call('/panel/api/server/status')['panelVersion'])").stdout.strip() == b'3.7.0', 'api_uses_random_path')
    # User-created row in the same panel. No application ownership marker.
    created = panel_code('''from vless import wanted_inbound
p=json.loads(sys.stdin.buffer.read())
w=wanted_inbound(p,p['resources'][0]);w['remark']='Manual inbound';w['port']=2470
rows=a.call('/panel/api/inbounds/list')
old=next((r for r in rows if r['remark'] in ('Manual inbound','Edited manual inbound')),None)
if old is None:a.call('/panel/api/inbounds/add',w)
row=next(r for r in a.call('/panel/api/inbounds/list') if r['remark'] in ('Manual inbound','Edited manual inbound'))
print(row['id'])
''', json.dumps(dict(version=1, workspaceId='b'*32, panelId=PANEL_ID,
        users=[dict(id='c'*32,enabled=True)], resources=[dict(id='f'*32,transport='xhttp',security='reality',target='example.com:443',sni='example.com',path='/manual',host='',mode='auto',enabled=True,listen='0.0.0.0',port=2470)])).encode())
    inbound_id = int(created.stdout)
    snap = rpc(dict(version=1, action='inbound_read', id=PANEL_ID, payload=json.dumps(dict(inboundId=inbound_id))))['inboundSnapshot']
    original = copy.deepcopy(snap['row'])
    p = dict(inboundId=inbound_id, observedHash=snap['fingerprint'], patch=dict(remark='Edited manual inbound', streamSettings=dict(xhttpSettings=dict(path='/edited-' + secrets.token_hex(4)))))
    plan = rpc(dict(version=1, action='inbound_plan', id=PANEL_ID, payload=json.dumps(p)))
    check(plan['code']=='ok', 'external_inbound_plan_native_validation')
    req = dict(version=1, action='submit', id=secrets.token_hex(16),kind='inbound_update',count=3,interval=1,fingerprint=plan['inboundPlan']['fingerprint'],payload=json.dumps(dict(p,panelId=PANEL_ID)))
    job = finish(req)
    check(job['status']=='succeeded','external_inbound_edit')
    after = rpc(dict(version=1,action='inbound_read',id=PANEL_ID,payload=json.dumps(dict(inboundId=inbound_id))))['inboundSnapshot']['row']
    check(after['id']==original['id'] and after['settings']==original['settings'],'external_clients_and_identity_preserved')
    check(json.loads(after['streamSettings'])['realitySettings']==json.loads(original['streamSettings'])['realitySettings'],'external_reality_keys_preserved')
    stale = rpc(dict(version=1,action='inbound_plan',id=PANEL_ID,payload=json.dumps(p)))
    check(stale['code']=='vless_conflict','external_stale_plan_refused')
    # Credentials for an existing panel are only in a private RPC/file, never job events.
    connected = rpc(dict(version=1,action='panel_connect',payload=json.dumps({k:access[k] for k in ('port','username','password')})))
    check(connected.get('panelVerified') and connected['panelAccess']['managed'] is False,'existing_panel_api_login')
    check(rpc(dict(version=1,action='inbound_read',id=connected['panelAccess']['id'],payload=json.dumps(dict(inboundId=inbound_id))))['code']=='ok','external_panel_api_access')
    # Isolated file repository with one real Debian package: deterministic, no internet needed.
    python('''import hashlib,json,subprocess
from pathlib import Path
repo=Path('/var/lib/antirkn-apt-fixture');repo.mkdir(exist_ok=True);repo.chmod(0o755)
for source in Path('/etc/apt/sources.list.d').glob('*.sources'):source.rename(source.with_suffix('.disabled'))
for source in Path('/etc/apt/sources.list.d').glob('*.list'):source.rename(source.with_suffix('.disabled'))
for version in ['1.0','2.0']:
 root=repo/('pkg'+version);(root/'DEBIAN').mkdir(parents=True,exist_ok=True);(root/'etc').mkdir(exist_ok=True)
 (root/'DEBIAN/control').write_text('Package: antirkn-test-upgrade\\nVersion: '+version+'\\nArchitecture: all\\nMaintainer: Fixture <fixture@example.invalid>\\nDescription: Isolated upgrade fixture\\n')
 (root/'DEBIAN/conffiles').write_text('/etc/antirkn-apt-fixture.conf\\n')
 (root/'etc/antirkn-apt-fixture.conf').write_text('default-'+version+'\\n')
 subprocess.run(['dpkg-deb','--build',str(root),str(repo/(version+'.deb'))],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['dpkg','--force-confnew','-i',str(repo/'1.0.deb')],check=True,stdout=subprocess.DEVNULL)
Path('/etc/antirkn-apt-fixture.conf').write_text('owner-local-setting\\n')
raw=(repo/'2.0.deb').read_bytes()
(repo/'Packages').write_text((repo/'pkg2.0/DEBIAN/control').read_text()+'Filename: 2.0.deb\\nSize: '+str(len(raw))+'\\nSHA256: '+hashlib.sha256(raw).hexdigest()+'\\n\\n')
Path('/etc/apt/sources.list.d/antirkn-fixture.list').write_text('deb [trusted=yes] file:'+str(repo)+' ./\\n')
''')
    req = dict(version=1, action='submit', id=secrets.token_hex(16), kind='apt_update', count=2, interval=1)
    check(finish(req)['status']=='succeeded','real_apt_indexes')
    plan = rpc(dict(version=1,action='apt_plan'))['aptPlan']
    check(any(p['name']=='antirkn-test-upgrade' and p['version']=='2.0' for p in plan['packages']),'real_apt_preview')
    req=dict(version=1,action='submit',id=secrets.token_hex(16),kind='apt_upgrade',count=2,interval=1,fingerprint=plan['fingerprint'])
    check(finish(req)['status']=='succeeded','real_apt_upgrade')
    check(remote("dpkg-query -W -f='${Version}' antirkn-test-upgrade").stdout==b'2.0','apt_version_verified')
    check(remote('cat /etc/antirkn-apt-fixture.conf').stdout==b'owner-local-setting\n','apt_local_config_preserved')
    check(rpc(dict(version=1,action='apt_plan'))['aptPlan']['packages']==[],'apt_no_remaining_updates')
    (ROOT/'docs/evidence/server-ui-ubuntu.json').write_text(json.dumps(dict(results=RESULTS,panel='3.7.0',xray='26.7.28',runner='v7',apt='Ubuntu file repository; real dpkg 1.0 -> 2.0'),indent=2)+'\n')

if __name__=='__main__':run()
