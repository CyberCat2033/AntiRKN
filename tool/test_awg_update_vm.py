#!/usr/bin/env python3
"""Real AmneziaWG 3.1.20260814 -> 3.1.20260828 service update fixture."""
import hashlib
import json
import re
import time
from pathlib import Path
from test_panel_vm import ROOT, remote, python, rpc


def main():
    results = {}
    def check(value, name):
        if not value: raise AssertionError(name)
        results[name] = True
        print('PASS',name,flush=True)
    archive=Path('/tmp/antirkn-awg-old-source.tar.gz').read_bytes()
    expected=json.loads((ROOT/'schemas/component-test-releases.json').read_text())['amneziawgOld']['sha256']
    check(hashlib.sha256(archive).hexdigest()==expected,'previous_source_checksum')
    remote('cat > /var/lib/antirkn-runner/awg-old.tar.gz',archive)
    python(r'''
import sys,json,os,subprocess,hashlib,shutil
from pathlib import Path
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v4')
from components import extract,encode,installed
from panel import atomic_file
job=Path('/var/lib/antirkn-runner/component-'+('3'*32))
source=Path('/var/lib/antirkn-runner/awg-old-source')
extract(Path('/var/lib/antirkn-runner/awg-old.tar.gz'),source,'tar')
source=source/'amneziawg-go-1b86b2ae0e493e7ea93f8c1a0f0cb6735b1551f1'
(source/'version.go').write_text('package main\nconst Version = "v3.1.20260814"\n')
base=Path('/usr/local/lib/antirkn-components/amneziawg')
old=base/'versions'/('e'*64)
old.mkdir(exist_ok=True)
env=dict(PATH='/usr/bin:/bin',HOME=str(job),CGO_ENABLED='0',GOOS='linux',GOARCH='amd64',GOTOOLCHAIN='local',GOPROXY='https://proxy.golang.org',GOSUMDB='sum.golang.org',GOCACHE=str(job/'go-cache'),GOPATH=str(job/'go-path'),GOMAXPROCS='2')
subprocess.run([str(job/'go/go/bin/go'),'build','-mod=readonly','-trimpath','-buildvcs=false','-o',str(old/'amneziawg-go'),'.'],cwd=source,env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
for name in ('awg','awg-quick'):
 shutil.copyfile(base/'current'/name,old/name)
 (old/name).chmod(0o755)
files={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in old.iterdir() if f.name!='manifest.json'}
atomic_file(old/'manifest.json',encode(dict(component='amneziawg',version='3.1.20260814',toolsVersion='3.1.20260812',release='e'*64,files=files)),0o644)
(base/'current').unlink()
os.symlink('versions/'+('e'*64),base/'current')
assert installed('amneziawg')['version']=='3.1.20260814'
config=Path('/etc/antirkn-components/amneziawg/awgtest.conf')
key=subprocess.check_output(['/usr/local/bin/awg','genkey']).decode().strip()
atomic_file(config,('[Interface]\nPrivateKey = '+key+'\nAddress = 10.77.0.1/24\nListenPort = 31820\n').encode())
''',timeout=600)
    check(b'3.1.20260814' in remote('/usr/local/bin/amneziawg-go --version').stdout,'real_old_awg_version')
    remote('systemctl start antirkn-awg@awgtest')
    check(remote('systemctl is-active --quiet antirkn-awg@awgtest').returncode==0,'old_awg_service_active')
    before=remote('sha256sum /etc/antirkn-components/amneziawg/awgtest.conf').stdout
    source=(ROOT/'packages/ssh_transport/lib/src/runner_bundle.g.dart').read_text()
    inspector=re.search(r"const runnerComponentInspector =\s*r'''(.*?)''';",source,re.S).group(1)
    plan=json.loads(python(inspector,json.dumps(dict(component='amneziawg')).encode()).stdout)['componentPlan']
    check(plan['state']=='update' and plan['activeUnits']==['antirkn-awg@awgtest.service'],'active_awg_update_plan')
    req=dict(version=1,action='submit',kind='component_install',component='amneziawg',id='5'*32,
        count=6,interval=1,fingerprint=plan['fingerprint'])
    old='/var/lib/antirkn-runner/component-'+('3'*32)
    new='/var/lib/antirkn-runner/component-'+req['id']
    remote('mkdir -m 700 -p '+new)
    for name in ('source','tools','go'):
        remote('cp '+old+'/'+name+'.archive '+new+'/'+name+'.archive')
    check(rpc(req)['code']=='ok','awg_update_submitted')
    previous=None
    for _ in range(1200):
        job=rpc(dict(version=1,action='status',id=req['id'],cursor=0))['jobs'][0]
        state=(job['status'],job['checkpoint'])
        if state!=previous:
            print('AWG update',state,job['events'][-1]['code'],flush=True)
            previous=state
        if job['status'] not in ('planned','running'): break
        time.sleep(1)
    check(job['status']=='succeeded','awg_update_succeeded')
    check(before==remote('sha256sum /etc/antirkn-components/amneziawg/awgtest.conf').stdout,'awg_config_key_and_address_preserved')
    check(b'3.1.20260828' in remote('/usr/local/bin/amneziawg-go --version').stdout,'real_updated_awg_version')
    check(b'31820' in remote('/usr/local/bin/awg show awgtest listen-port').stdout,'updated_awg_interface_listens')
    check(remote('systemctl is-active --quiet antirkn-awg@awgtest').returncode==0,'updated_awg_service_active')
    check(remote('test -s '+new+'/config-backup/awgtest.conf').returncode==0,'awg_configuration_backup')
    check(rpc(req)['jobs'][0]['sequence']==job['sequence'],'awg_repeat_no_effect')
    (ROOT/'docs/evidence/components-awg-update.json').write_text(json.dumps(dict(
        oldSourceCommit='1b86b2ae0e493e7ea93f8c1a0f0cb6735b1551f1',
        oldSourceSha256=hashlib.sha256(archive).hexdigest(),results=results),indent=2)+'\n')


if __name__=='__main__': main()
