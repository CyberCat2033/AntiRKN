#!/usr/bin/env python3
"""Short existing native/Docker editing check, in the disposable AWG VM only."""
import json
import secrets
import sys
import time
from test_awg_vm import rpc, wait, remote, python, ROOT

results={}
def check(value,name):
    if not value:raise AssertionError(name)
    results[name]=True;print('PASS',name,flush=True)


def prepare():
    source=r'''import pathlib,subprocess,re,shutil
root=pathlib.Path('/var/lib/antirkn-awg-container-test');root.mkdir(mode=0o700,exist_ok=True)
for name in ['awg','awg-quick','amneziawg-go']:
 shutil.copyfile('/usr/local/bin/'+name,root/name);(root/name).chmod(0o755)
config=next(pathlib.Path('/etc/antirkn-components/amneziawg').glob('ar*.conf')).read_text()
config=''.join(line for line in config.splitlines(keepends=True) if not line.startswith(('PostUp','PostDown')))
config=re.sub(r'^ListenPort = .*$', 'ListenPort = 35428',config,flags=re.M)
(root/'awg0.conf').write_text(config);(root/'awg0.conf').chmod(0o600)
(root/'Dockerfile').write_text('FROM ubuntu:24.04\nRUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 iptables bash && rm -rf /var/lib/apt/lists/*\nCOPY awg awg-quick amneziawg-go /usr/local/bin/\nCOPY awg0.conf /opt/amnezia/awg/awg0.conf\nENV WG_QUICK_USERSPACE_IMPLEMENTATION=/usr/local/bin/amneziawg-go\nCMD ["bash", "-c", "awg-quick up /opt/amnezia/awg/awg0.conf && exec sleep infinity"]\n')
subprocess.run(['docker','build','-q','-t','antirkn-amnezia-awg-fixture',str(root)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['docker','run','-d','--name','antirkn-amnezia-awg-fixture','--cap-add=NET_ADMIN','--device=/dev/net/tun','-p','127.0.0.1:35428:35428/udp','antirkn-amnezia-awg-fixture'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
root=pathlib.Path('/etc/amneziawg');root.mkdir(mode=0o700,exist_ok=True)
(root/'prior.conf').write_text(config.replace('ListenPort = 35428','ListenPort = 35429')+'\n# retained external comment\n')
(root/'prior.conf').chmod(0o600)
'''
    python(source,timeout=600)


def main():
    if '--prepare' in sys.argv:prepare()
    response=rpc(dict(version=1,action='awg_discover'))
    check(response['code']=='ok','existing_discovery')
    rows=response['awgExternal']['resources'];check({r['source'] for r in rows}>={'native','docker'},'native_and_docker_detected')
    for row in rows:
        if row['source']=='docker' and 'antirkn-amnezia-awg-fixture' not in row['name']:continue
        if row['source']=='native' and not row['path'].endswith('/prior.conf'):continue
        public=json.dumps(row)
        check('PrivateKey' not in public and 'PresharedKey' not in public and 'HeaderProtectionKey' not in public,row['source']+'_snapshot_redacted')
        p=dict(resourceId=row['id'],observedHash=row['fingerprint'],changes={'Jc':str(4 if row['values']['Jc']!='4' else 5)})
        response=rpc(dict(version=1,action='awg_external_plan',payload=json.dumps(p)));check(response['code']=='ok',row['source']+'_plan')
        req=dict(version=1,action='submit',id=secrets.token_hex(16),kind='awg_external_edit',count=3,interval=1,payload=json.dumps(p),fingerprint=response['awgExternal']['fingerprint'])
        job=wait(req);check(job['status']=='succeeded',row['source']+'_edit')
        check(rpc(req)['jobs'][0]['sequence']==job['sequence'],row['source']+'_repeat')
        verified=python('''import sys,json
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v10')
from awg_external import read_resource,parse
from pathlib import Path
p=json.loads(sys.stdin.read());b=json.loads((Path('/var/lib/antirkn-runner')/('awg-external-'+p['id']+'.json')).read_text())
_,raw,_,_,_=read_resource(p['rid'])
before=parse(b['before'].encode())[0];after=parse(raw)[0]
keys=['PrivateKey','HeaderProtectionKey']
print(json.dumps({'keys':all(before.get(k)==after.get(k) for k in keys),'peers':b['before'].split('[Peer]',1)[1]==raw.decode().split('[Peer]',1)[1]}))
''',json.dumps(dict(id=req['id'],rid=row['id'])).encode())
        kept=json.loads(verified.stdout);check(kept['keys'] and kept['peers'],row['source']+'_keys_and_peers_preserved')
        conflict=rpc(dict(version=1,action='awg_external_plan',payload=json.dumps(p)));check(conflict['code']=='awg_conflict',row['source']+'_stale_plan_rejected')
    (ROOT/'docs/evidence/awg-existing.json').write_text(json.dumps(dict(fixture='Native config and real Docker container with official Amnezia paths and published UDP port; pinned AWG binaries, Ubuntu 24.04 base',results=results),indent=2)+'\n')


if __name__=='__main__':main()
