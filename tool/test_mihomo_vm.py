#!/usr/bin/env python3
"""Real embedded-core acceptance on a private disposable VM, never owner hosts."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent.parent
DIRECTORY=Path('/tmp/antirkn-mihomo-vm')
os.environ['ANTIRKN_VM_DIRECTORY']=str(DIRECTORY)
from test_panel_vm import remote, python, bundle_strings
VERSION='v24'
WORKSPACE='b'*32
PANEL_ID='10000000000000000000000000000001'

def rpc(req):
    result=remote(f'/usr/bin/python3 -I /usr/local/lib/antirkn-runner/{VERSION}/runner.py rpc',json.dumps(req).encode(),check=False)
    return json.loads(result.stdout)

def wait(req):
    response=rpc(req)
    if response['code']!='ok':raise AssertionError(response['code'])
    for _ in range(1200):
        response=rpc(dict(version=1,action='status',id=req['id'],cursor=0))
        if response['code']=='busy':time.sleep(.5);continue
        job=response['jobs'][0]
        if job['status'] not in ('planned','running'):
            if job['status']!='succeeded':raise AssertionError((job['status'],[e['code'] for e in job['events']]))
            return job
        time.sleep(.5)
    raise AssertionError('fixture timeout')

def install():
    if not (DIRECTORY/'ready').exists():raise AssertionError('isolated VM not ready')
    sources=bundle_strings()
    state=json.loads(python(sources['runnerInspector']+'\nprint(json.dumps(inspect_runner()))').stdout)
    desired=json.loads(sources['runnerBundle'])['release']
    if state['release']!=desired and not state.get('upgradable') and remote('test -d /usr/local/lib/antirkn-runner/v24',check=False).returncode==0:
        # Only this named, disposable VM may replace an unpublished development bundle.
        python("""import pathlib,sqlite3,subprocess,shutil
assert pathlib.Path('/etc/hostname').read_text().strip()=='antirkn-runner-fixture'
import sys
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v24')
from runner import Store,STATE
import xray_transaction as x
s=Store(STATE);assert not x.active(s);s.close()
c=sqlite3.connect('/var/lib/antirkn-runner/jobs.sqlite');assert not c.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone();c.close()
subprocess.run(['systemctl','stop','antirkn-runner'],check=True)
shutil.rmtree('/usr/local/lib/antirkn-runner/v24')
base=pathlib.Path('/usr/local/lib/antirkn-runner')
if not any(base.iterdir()):base.rmdir()
unit=pathlib.Path('/etc/systemd/system/antirkn-runner.service')
previous=base/'v23/manifest.json'
if previous.exists():
 import hashlib,json
 data=unit.read_bytes().replace(b'/v24/',b'/v23/')
 assert hashlib.sha256(data).hexdigest()==json.loads(previous.read_text())['hashes']['antirkn-runner.service']
 unit.write_bytes(data)
else:unit.unlink()
""")
        state=json.loads(python(sources['runnerInspector']+'\nprint(json.dumps(inspect_runner()))').stdout)
    result=json.loads(python(sources['runnerInstaller'],json.dumps(dict(fingerprint=state['fingerprint'],bundle=json.loads(sources['runnerBundle']))).encode()).stdout)
    assert result['active']; print('PASS runner installation',flush=True)
    if remote('test -e /usr/local/x-ui/x-ui',check=False).returncode:
        archive=Path('/tmp/antirkn-mihomo-panel.tar.gz')
        assert hashlib.sha256(archive.read_bytes()).hexdigest()=='236b837627520f0c4ae4134dc6a34ea5e294b69e158879795fe8cd51c5f3582c'
        remote('cat > /tmp/mihomo-panel.tar.gz',archive.read_bytes())
        remote('tar --no-same-owner -xzf /tmp/mihomo-panel.tar.gz -C /usr/local')
        remote('cp /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service')
        old=Path('/tmp/antirkn-mihomo-xray-old.zip')
        meta=json.loads(Path('/tmp/antirkn-mihomo-xray-old-release.json').read_text())
        asset=next(a for a in meta['assets'] if a['name']=='Xray-linux-64.zip')
        assert 'sha256:'+hashlib.sha256(old.read_bytes()).hexdigest()==asset['digest']
        remote('cat > /tmp/mihomo-xray-old.zip',old.read_bytes())
        python("import zipfile\nfrom pathlib import Path\np=Path('/usr/local/x-ui/bin/xray-linux-amd64');p.write_bytes(zipfile.ZipFile('/tmp/mihomo-xray-old.zip').read('xray'));p.chmod(0o755)")
        credentials=dict(port=2053,username='fixture',password=secrets.token_hex(24))
        (DIRECTORY/'panel-login.json').write_text(json.dumps(credentials));(DIRECTORY/'panel-login.json').chmod(0o600)
        python("import json,sys,subprocess\nr=json.load(sys.stdin);subprocess.run(['/usr/local/x-ui/x-ui','setting','-username',r['username'],'-password',r['password'],'-port',str(r['port'])],check=True,stdout=subprocess.DEVNULL)",json.dumps(credentials).encode())
        remote('systemctl daemon-reload && systemctl enable --now x-ui')
    time.sleep(2)
    credentials=json.loads((DIRECTORY/'panel-login.json').read_text())
    connected=rpc(dict(version=1,action='panel_connect',payload=json.dumps(credentials)))
    assert connected['code']=='ok',connected.get('code')
    (DIRECTORY/'panel-access.json').write_text(json.dumps(connected['panelAccess']));(DIRECTORY/'panel-access.json').chmod(0o600)
    print('PASS panel 3.8.0 / Xray 26.7.28 baseline',flush=True)

def component(name):
    preview=json.loads(python("import sys,json;sys.path.insert(0,'/usr/local/lib/antirkn-runner/"+VERSION+"');from components import component_plan; print(json.dumps(component_plan("+repr(name)+")))").stdout)
    if preview['state']=='current':return
    req=dict(version=1,action='submit',kind='component_install',component=name,id=secrets.token_hex(16),count=6,interval=1,fingerprint=preview['fingerprint'])
    wait(req);print('PASS '+name+' installation',flush=True)

if __name__=='__main__':
    if sys.argv[1:]==['install']:install()
    elif len(sys.argv)==3 and sys.argv[1]=='component':component(sys.argv[2])

def native_check(fields, ca=None):
    import tempfile
    env={**os.environ}
    if ca:env['SSL_CERT_FILE']=str(ca)
    with tempfile.TemporaryDirectory(prefix='mihomo-native-',dir=DIRECTORY) as work:
        result=subprocess.run([str(ROOT/'build/mihomo/linux/antirkn-mihomo'),work],input=json.dumps(dict(mode='probe',yaml=json.dumps(fields),udp=True)).encode(),capture_output=True,env=env,timeout=20)
        if result.returncode:raise AssertionError('native worker crashed')
        return json.loads(result.stdout)

def compile_proxy(protocol,spec,observation,user):
    target={'vless':'fixture','awg':'awg/fixture','tt':'tt/fixture'}[protocol]
    workspace=dict(version=3,id=WORKSPACE,users=[dict(user,name='Diagnostic')],inbounds=[],awgInterfaces=[],ttEndpoints=[],servers={target:dict(observed=[observation])},profiles={})
    workspace[{'vless':'inbounds','awg':'awgInterfaces','tt':'ttEndpoints'}[protocol]]=[dict(serverId='fixture',spec=spec)]
    source=DIRECTORY/'compiler-input.json';output=DIRECTORY/'proxy.json'
    source.write_text(json.dumps(dict(workspace=workspace,userId=user['id'],resourceId=spec['id'])));source.chmod(0o600)
    subprocess.run(['/opt/flutter/bin/cache/dart-sdk/bin/dart','run','tool/compile_vless_fixture.dart',str(source),str(output),'--probe'],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
    output.chmod(0o600);return json.loads(output.read_text())

def lease_check(protocol,spec,expected=True,ca=None):
    req=dict(version=1,action='probe_begin',id=secrets.token_hex(16),payload=json.dumps(dict(protocol=protocol,resource=spec['id'],workspace=WORKSPACE,spec=spec)))
    result=rpc(req)
    try:
        assert result['code']=='ok',result['code']
        access=result['connectionProbe']
        fields=compile_proxy(protocol,spec,access['observation'],access['user'])

        result=native_check(fields,ca)
        if expected and result['status']!='success':
            # The device policy retries once after independent controls.
            time.sleep(1)
            result=native_check(fields,ca)
        print('PROBE',protocol,spec.get('transport',''),spec.get('security',''),{k:result[k] for k in ('status','code','tcp','udp')},flush=True)
        if result['status']!='success' and expected:
            subprocess.run(['go','test','-tags','with_gvisor','./probe','-run','TestLiveFixture','-v'],cwd=ROOT/'native/mihomo',env={**os.environ,'GOCACHE':'/tmp/antirkn-go-build-cache','ANTIRKN_PROBE_FIXTURE':str(DIRECTORY/'proxy.json'),'SSL_CERT_FILE':str(ca) if ca else ''},timeout=45)
        assert (result['status']=='success')==expected,result
        wrong=dict(fields)
        if protocol=='vless':wrong['uuid']='99999999-9999-4999-8999-999999999999'
        elif protocol=='tt':wrong['password']='fixture-invalid-password'
        else:wrong['private-key']='AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE='
        failure=native_check(wrong,ca)
        assert failure['status']!='success' and not failure['tcp'] and not failure['udp']
        print('PASS invalid credentials rejected '+protocol,flush=True)
    finally:
        ended=rpc(dict(version=1,action='probe_end',id=req['id']))
        assert ended.get('connectionProbe')==dict(closed=True,stable=True),ended.get('code')
        print('PASS temporary access cleanup '+protocol,flush=True)

def vless_tests():
    import test_vless_vm as v
    panel=json.loads((DIRECTORY/'panel-access.json').read_text())['id']
    v.PANEL_ID=panel;v.WORKSPACE=WORKSPACE;v.HOST_BASE=37443;v.FIXTURE=DIRECTORY/'tls';v.rpc=rpc
    v.python=lambda source,*args,**kw:python(source.replace('/v5','/'+VERSION).replace('10000000000000000000000000000001',panel).replace("'Origin':api.base","'Origin':api.origin"),*args,**kw)
    close=v.fixtures()
    try:
        resources=[v.public_spec(1),v.public_spec(2,'xhttp'),v.public_spec(3,'xhttp','tls','packet-up'),v.public_spec(4,'xhttp','tls','stream-up'),v.public_spec(5,'xhttp','tls','stream-one')]
        options=json.loads(subprocess.check_output(['/opt/flutter/bin/cache/dart-sdk/bin/dart','run','tool/compile_vless_fixture.dart','--xhttp-defaults'],cwd=ROOT))
        for spec in resources[1:]:spec['xhttp']=options
        observed,_=v.apply(v.payload(resources,users=[]),'native_baseline')
        for spec in resources:lease_check('vless',spec,ca=v.FIXTURE/'ca.crt')
        print('PASS all VLESS presets with embedded native runtime',flush=True)
    finally:close()

if __name__=='__main__' and sys.argv[1:]==['vless']:vless_tests()

def apply_resource(protocol,spec):
    p=dict(version=1,protocol=protocol,workspaceId=WORKSPACE,panelId=WORKSPACE,users=[],resources=[spec])
    preview=rpc(dict(version=1,action=protocol+'_plan',id=WORKSPACE,payload=json.dumps(p)))
    assert preview['code']=='ok',preview['code']
    plan=preview['tt' if protocol=='tt' else protocol+'Plan']
    wait(dict(version=1,action='submit',kind=protocol+'_apply',id=secrets.token_hex(16),count=3,interval=1,payload=json.dumps(p),fingerprint=plan['fingerprint']))
    print('PASS '+protocol+' resource created without clients',flush=True)

def awg_tests():
    state=rpc(dict(version=1,action='awg_state',id=WORKSPACE))['awgState']
    if state:spec=state[0]['spec']
    else:
        response=rpc(dict(version=1,action='awg_defaults'));assert response['code']=='ok',response['code']
        spec=response['awgDefaults'];spec.update(id='f'*32,endpoint='127.0.0.1',port=51820,externalPort=37450)
        apply_resource('awg',spec)
    lease_check('awg',spec)
    print('PASS native AmneziaWG TCP/UDP with diagnostic peer',flush=True)

def tt_tests():
    ca=DIRECTORY/'tls/ca.crt'
    remote('cat > /usr/local/share/ca-certificates/mihomo-fixture.crt',ca.read_bytes())
    remote('update-ca-certificates')
    python("""from pathlib import Path
p=Path('/root/cert/vless.test');p.mkdir(mode=0o700,parents=True,exist_ok=True)
for name,source in [('fullchain.pem','server.crt'),('privkey.pem','server.key')]:
 (p/name).write_bytes((Path('/etc/antirkn-test-tls')/source).read_bytes());(p/name).chmod(0o600)
""")
    certificate=dict(id='e'*32,mode='files',domain='vless.test',listen='0.0.0.0',expectedIps=['127.0.0.1'],email='',certificate='/root/cert/vless.test/fullchain.pem',privateKey='/root/cert/vless.test/privkey.pem',certificatePem='',privateKeyPem='')
    plan=rpc(dict(version=1,action='tt_certificate_plan',payload=json.dumps(certificate)))
    assert plan['code']=='ok',plan['code']
    wait(dict(version=1,action='submit',kind='tt_certificate',id=secrets.token_hex(16),count=4,interval=1,payload=json.dumps(certificate),fingerprint=plan['tt']['fingerprint']))
    spec=dict(id='d'*32,name='Diagnostic TT',enabled=True,deleted=False,listen='0.0.0.0',port=8443,endpoint='127.0.0.1',externalPort=37449,domain='vless.test',certificateId='e'*32,quic=False,ipv6=False,allowPrivate=False,outbound='direct',socksAddress='127.0.0.1:1080',rotation=0)
    apply_resource('tt',spec)
    lease_check('tt',spec,ca=ca)
    print('PASS native TrustTunnel TCP/UDP with diagnostic credential',flush=True)

if __name__=='__main__' and sys.argv[1:]==['awg']:awg_tests()
if __name__=='__main__' and sys.argv[1:]==['tt']:tt_tests()


def unattended_cleanup():
    # Stop the parent daemon and let the independent systemd unit do the work.
    for protocol in ('vless', 'awg', 'tt'):
        state=rpc(dict(version=1,action=protocol+'_state',id=json.loads((DIRECTORY/'panel-access.json').read_text())['id'] if protocol=='vless' else WORKSPACE))
        rows=state['tt']['resources'] if protocol=='tt' else state[protocol+'State']
        spec=rows[0]['spec'];key=secrets.token_hex(16)
        req=dict(version=1,action='probe_begin',id=key,payload=json.dumps(dict(protocol=protocol,resource=spec['id'],workspace=WORKSPACE,spec=spec)))
        result=rpc(req);assert result['code']=='ok',result['code']
        try:
            remote('systemctl stop antirkn-runner')
            python("import sys,time;sys.path.insert(0,'/usr/local/lib/antirkn-runner/"+VERSION+"');from runner import Store,STATE;import connectivity_probe as p\ns=Store(STATE)\nwith p.operation_lock(s):\n i=p.load(s,"+repr(key)+");i['expires']=time.time()-1;p.save(s,i)")
            for _ in range(45):
                closed=python("import sys;sys.path.insert(0,'/usr/local/lib/antirkn-runner/"+VERSION+"');from runner import Store,STATE;import connectivity_probe as p;s=Store(STATE);print(p.load(s,"+repr(key)+").get('status'))").stdout.strip()
                if closed==b'closed':break
                time.sleep(1)
            assert closed==b'closed','cleanup watchdog did not complete'
            print('PASS independent cleanup with runner stopped '+protocol,flush=True)
        finally:
            remote('systemctl start antirkn-runner')
            rpc(dict(version=1,action='probe_end',id=key))

if __name__=='__main__' and sys.argv[1:]==['cleanup']:unattended_cleanup()
