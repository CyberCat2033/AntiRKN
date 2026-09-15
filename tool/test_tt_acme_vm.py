#!/usr/bin/env python3
"""Real Certbot HTTP-01 issuance/renewal against local Pebble, no public domain."""
import io
import json
import secrets
import sys
import tarfile
import time
import urllib.request
from test_tt_vm import ROOT,DIRECTORY,remote,python,download,check,results,rpc,apply,observed,certificate_fixture


def main():
    if '--stop-test-renewal' in sys.argv:
        print(python("""from pathlib import Path
import os,signal
assert Path('/etc/hostname').read_text().strip()=='antirkn-runner-fixture'
count=0
for p in Path('/proc').glob('[0-9]*'):
 try:
  a=p.joinpath('cmdline').read_bytes().decode().split('\\x00')
  if '/usr/bin/certbot' not in a or '--force-renewal' not in a or '--config-dir' not in a:continue
  config=Path(a[a.index('--config-dir')+1])
  if Path('/etc/antirkn-certificates') not in config.parents:continue
  if 'https://tt.fixture.test:14000/dir' not in (config/'renewal/endpoint.conf').read_text():continue
  os.kill(int(p.name),signal.SIGTERM);count+=1
 except (OSError,ValueError):pass
print('Stopped local test renewals:',count)
""").stdout.decode());return
    if '--delay' in sys.argv:
        print(python("""from pathlib import Path
import re,subprocess
values=[]
for p in Path('/etc/antirkn-certificates').glob('*/logs/letsencrypt.log'):
 matches=re.findall(r'Non-interactive renewal: random delay of ([0-9.]+) seconds',p.read_text())
 if matches:values.append((p.stat().st_mtime,matches[-1]))
print('Latest Certbot random delay:',max(values)[1] if values else 'none')
print('\\n'.join(line for line in subprocess.check_output(['ps','-eo','comm,etime'],text=True).splitlines() if 'certbot' in line))
""").stdout.decode());return
    check(python("from pathlib import Path;assert Path('/etc/hostname').read_text().strip()=='antirkn-runner-fixture'").returncode==0,'isolated_ubuntu')
    files=certificate_fixture()
    check(any(c['certificate']==files['certificate'] for c in rpc(dict(version=1,action='tt_certificates'))['tt']['candidates']),'root_certificate_discovery_and_job')
    imported={**files,'id':secrets.token_hex(16),'mode':'import','certificate':'','privateKey':'',
        'certificatePem':remote('cat /etc/tt-fixture/certificate.pem').stdout.decode(),'privateKeyPem':remote('cat /etc/tt-fixture/private.pem').stdout.decode()}
    apply('tt_certificate_plan','tt_certificate',imported,4)
    check('PRIVATE KEY' not in json.dumps(rpc(dict(version=1,action='tt_certificates'))),'pem_import_and_public_inventory_redaction')
    meta=json.load(urllib.request.urlopen('https://api.github.com/repos/letsencrypt/pebble/releases/tags/v2.10.1'))
    asset=next(a for a in meta['assets'] if a['name']=='pebble-linux-amd64.tar.gz')
    data=download(asset['browser_download_url'],asset['digest'].split(':')[1],DIRECTORY/'pebble.tar.gz')
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        binary=tar.extractfile(next(m for m in tar.getmembers() if m.name.split('/')[-1]=='pebble')).read()
    remote('systemctl stop tt-pebble-fixture.service',check=False)
    remote('cat > /etc/tt-fixture/pebble',binary);remote('chmod 700 /etc/tt-fixture/pebble')
    config={'pebble':dict(listenAddress='0.0.0.0:14000',managementListenAddress='0.0.0.0:15000',certificate='/etc/tt-fixture/certificate.pem',privateKey='/etc/tt-fixture/private.pem',httpPort=80,tlsPort=5001,profiles={'default':{'description':'fixture','validityPeriod':90*86400}})}
    remote('cat > /etc/tt-fixture/pebble.json',json.dumps(config).encode())
    remote('cat > /etc/systemd/system/tt-pebble-fixture.service',b'[Unit]\nDescription=TT ACME fixture\n[Service]\nEnvironment=PEBBLE_VA_NOSLEEP=1\nEnvironment=PEBBLE_WFE_NONCEREJECT=0\nExecStart=/etc/tt-fixture/pebble -config /etc/tt-fixture/pebble.json\n')
    python("from pathlib import Path;p=Path('/etc/hosts');s=p.read_text();p.write_text(s+'\\n10.0.2.15 tt.fixture.test\\n' if 'tt.fixture.test' not in s else s)")
    remote('systemctl daemon-reload');remote('systemctl restart tt-pebble-fixture');time.sleep(1)
    python("""import urllib.request,subprocess
from pathlib import Path
Path('/usr/local/share/ca-certificates/tt-pebble-fixture.crt').write_bytes(urllib.request.urlopen('https://tt.fixture.test:15000/roots/0').read())
subprocess.run(['update-ca-certificates'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
""")
    remote('apt-get update -qq',timeout=240)
    cid=secrets.token_hex(16)
    p=dict(id=cid,domain='tt.fixture.test',mode='acme',listen='10.0.2.15',expectedIps=['10.0.2.15'],email='admin@example.test',certificate='',privateKey='',certificatePem='',privateKeyPem='')
    rejected={**p,'expectedIps':['203.0.113.5']}
    check(rpc(dict(version=1,action='tt_certificate_plan',payload=json.dumps(rejected)))['code']=='tt_dns_mismatch','wrong_domain_address_blocks_issuance')
    preview=rpc(dict(version=1,action='tt_certificate_plan',payload=json.dumps(p)))
    check(preview['code']=='ok','acme_dns_and_package_plan')
    remote('systemctl stop antirkn-runner antirkn-tt-certificates.timer')
    req=dict(version=1,action='submit',kind='tt_certificate',id=secrets.token_hex(16),count=4,interval=1,payload=json.dumps(p),fingerprint=preview['tt']['fingerprint'])
    try:
        # Only the test invocation substitutes the ACME authority. Production
        # sources and certificate verification remain unchanged.
        code="""import sys,json,time
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v11')
from runner import Store
import tt_certificates as cert
from unittest.mock import patch
req=json.load(sys.stdin)
original=cert.run
def local_ca(argv,*args,**kwargs):
 if argv[0]=='/usr/bin/certbot' and 'certonly' in argv:argv=argv+['--server','https://tt.fixture.test:14000/dir']
 return original(argv,*args,**kwargs)
s=Store('/var/lib/antirkn-runner');assert s.request(req)['code']=='ok'
with patch.object(cert,'run',local_ca):
 for _ in range(12):
  s.tick();row=s.db.execute('SELECT * FROM jobs WHERE id=?',(req['id'],)).fetchone()
  if row['status'] not in ('planned','running'):break
job=s.job(row)
print(json.dumps(dict(status=job['status'],event=job['events'][-1]['code'])))
"""
        result=json.loads(python(code,json.dumps(req).encode(),timeout=800).stdout)
        check(result['status']=='succeeded','real_http01_issue_'+result['event'])
    finally:remote('systemctl start antirkn-runner')
    payload=json.loads((DIRECTORY/'payload.json').read_text());payload['resources'][0]['certificateId']=cid
    apply('tt_plan','tt_apply',payload,3)
    remote('systemctl stop antirkn-tt-certificates.timer antirkn-tt-certificates.service')
    old=observed()[0]['certificate']['fingerprint'];unit='antirkn-tt@'+'b'*32+'.service'
    before=remote('systemctl show '+unit+' --property=MainPID --value').stdout
    renew="""import sys,json
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v11')
import tt_certificates as cert
from unittest.mock import patch
cid=json.load(sys.stdin)['id'];r=cert.record(cid);original=cert.run
def force_due(argv,*args,**kwargs):
 if argv[0]=='/usr/bin/certbot' and 'renew' in argv:argv=argv+['--force-renewal','--no-random-sleep-on-renew']
 return original(argv,*args,**kwargs)
with cert.lock(),patch.object(cert,'run',force_due):
 cert.issue(r['spec'],renew=True);new=cert.activate(r['spec'],r)
print(json.dumps(dict(changed=r['fingerprint']!=new['fingerprint'],error=new['error'])))
"""
    result=json.loads(python(renew,json.dumps({'id':cid}).encode(),timeout=700).stdout)
    current=observed()[0]
    check(result['changed'] and current['confirmed'] and current['certificate']['fingerprint']!=old,'real_acme_renewal_and_tls_readback')
    check(remote('systemctl show '+unit+' --property=MainPID --value').stdout!=before,'acme_renewal_restarts_tt')
    remote('systemctl start antirkn-tt-certificates.timer')
    (ROOT/'docs/evidence/tt-acme.json').write_text(json.dumps(dict(authority='Local Pebble 2.10.1',archiveSha256=asset['digest'],challenge='real HTTP-01 on port 80',publicLetsEncrypt=False,certbot=remote('certbot --version').stdout.decode().strip(),results=results),indent=2)+'\n')


if __name__=='__main__':main()
