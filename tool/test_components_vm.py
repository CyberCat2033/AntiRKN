#!/usr/bin/env python3
"""Pinned component install/update on the disposable loopback Ubuntu fixture."""
import json
from pathlib import Path
import re
import time
from test_panel_vm import ROOT, remote, python, rpc, bundle_strings


def main():
    results = {}
    def check(value, name):
        if not value:
            raise AssertionError(name)
        results[name] = True
        print('PASS', name, flush=True)
    text = (ROOT / 'packages/ssh_transport/lib/src/runner_bundle.g.dart').read_text()
    inspector = re.search(r"const runnerComponentInspector =\s*r'''(.*?)''';", text, re.S).group(1)
    def plan(component):
        return json.loads(python(inspector, json.dumps(dict(component=component)).encode()).stdout)['componentPlan']
    sources = bundle_strings()
    runner_plan = json.loads(python(sources['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))').stdout)
    if not runner_plan['active']:
        python(sources['runnerInstaller'], json.dumps(dict(fingerprint=runner_plan['fingerprint'],bundle=json.loads(sources['runnerBundle']))).encode())
    def wait(request):
        previous = None
        retries = 0
        for _ in range(1800):
            job = rpc(dict(version=1,action='status',id=request['id'],cursor=0))['jobs'][0]
            current = (job['status'],job['checkpoint'])
            if current != previous:
                print(request['component'], current, job['events'][-1]['code'], flush=True)
                previous = current
            if job['status']=='failed' and job['events'][-1]['code']=='component_download_failed' and retries < 2:
                retries += 1
                check(rpc(dict(version=1,action='resume',id=request['id']))['code']=='ok',request['component']+'_network_retry_same_id')
                continue
            if job['status'] not in ('planned','running'):
                check(job['status']=='succeeded',request['component']+'_succeeded')
                return job
            time.sleep(1)
        raise AssertionError('component_timeout')
    import sys
    for index, component in ([] if '--update-only' in sys.argv else enumerate(('trusttunnel','amneziawg'))):
        preview = plan(component)
        check(preview['state']=='missing' and preview['supported'],component+'_read_only_plan')
        check(remote('test ! -e /usr/local/lib/antirkn-components/' + component,check=False).returncode==0,component+'_preview_no_effect')
        request = dict(version=1,action='submit',kind='component_install',component=component,
            id=str(index+2)*32,count=6,interval=1,fingerprint=preview['fingerprint'])
        if '--cache' in sys.argv:
            cache = {'endpoint':'/tmp/antirkn-tt.tar.gz', 'tools':'/tmp/antirkn-awg-tools.zip',
                'source':'/tmp/antirkn-awg-source.tar.gz', 'go':'/tmp/antirkn-go.tar.gz'}
            import hashlib
            directory = '/var/lib/antirkn-runner/component-' + request['id']
            remote('mkdir -m 700 -p ' + directory)
            for name, artifact in preview['archives'].items():
                data = Path(cache[name]).read_bytes()
                check(hashlib.sha256(data).hexdigest()==artifact['sha256'],component+'_cached_'+name+'_checksum')
                remote('cat > ' + directory + '/' + name + '.archive',data)
        check(rpc(request)['code']=='ok',component+'_submit')
        job = wait(request)
        check(rpc(request)['jobs'][0]['sequence']==job['sequence'],component+'_repeat_no_effect')
        check(plan(component)['state']=='current',component+'_read_back_current')
    # A real older upstream binary in the owned installation format.
    old = json.loads(open('/tmp/antirkn-tt-old.json').read())
    asset = next(a for a in old['assets'] if a['name']=='trusttunnel-v1.0.33-linux-x86_64.tar.gz')
    import hashlib
    data = open('/tmp/antirkn-tt-old.tar.gz','rb').read()
    check('sha256:'+hashlib.sha256(data).hexdigest()==asset['digest'],'older_upstream_checksum')
    remote('cat > /var/lib/antirkn-runner/old-tt.tar.gz',data)
    python('''
import sys,json,os,hashlib
from pathlib import Path
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v4')
from components import extract,encode,installed
from panel import atomic_file
base=Path('/usr/local/lib/antirkn-components/trusttunnel')
old=base/'versions'/('f'*64)
old.mkdir()
extract(Path('/var/lib/antirkn-runner/old-tt.tar.gz'),old/'archive','tar')
import shutil
files={}
for f in (old/'archive/trusttunnel-v1.0.33-linux-x86_64').iterdir():
 shutil.copyfile(f,old/f.name)
 (old/f.name).chmod(0o755 if f.name in ('trusttunnel_endpoint','setup_wizard') else 0o644)
 files[f.name]=hashlib.sha256(f.read_bytes()).hexdigest()
atomic_file(old/'manifest.json',encode(dict(component='trusttunnel',version='1.0.33',toolsVersion=None,release='f'*64,files=files)),0o644)
(base/'current').unlink()
os.symlink('versions/'+('f'*64),base/'current')
assert installed('trusttunnel')['version']=='1.0.33'
''')
    check(b'1.0.33' in remote('/usr/local/bin/trusttunnel_endpoint --version').stdout,'real_older_version')
    # Sensitive fixture content is never printed or copied into evidence.
    remote('umask 077; mkdir -p /etc/antirkn-components/trusttunnel; head -c 32 /dev/urandom > /etc/antirkn-components/trusttunnel/credentials')
    # Exercise the real managed service, TLS health and config backup on update.
    config = Path('/tmp/antirkn-tt-config.md').read_text()
    main_config = re.search(r'```toml\n(# The address.*?)```',config,re.S).group(1)
    main_config = main_config.replace('0.0.0.0:443','127.0.0.1:18443')
    remote('cat > /etc/antirkn-components/trusttunnel/vpn.toml',main_config.encode())
    python('''
from pathlib import Path
import secrets,subprocess
root=Path('/etc/antirkn-components/trusttunnel')
(root/'credentials.toml').write_text('[[client]]\\nusername = "fixture"\\npassword = "'+secrets.token_hex(24)+'"\\n')
(root/'credentials.toml').chmod(0o600)
(root/'rules.toml').write_text('')
(root/'hosts.toml').write_text('[[main_hosts]]\\nhostname = "localhost"\\ncert_chain_path = "cert.pem"\\nprivate_key_path = "key.pem"\\n[[ping_hosts]]\\nhostname = "ping.localhost"\\ncert_chain_path = "cert.pem"\\nprivate_key_path = "key.pem"\\n')
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','2','-subj','/CN=ping.localhost','-addext','subjectAltName=DNS:ping.localhost,DNS:localhost','-keyout',str(root/'key.pem'),'-out',str(root/'cert.pem')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
''')
    remote('systemctl start antirkn-trusttunnel')
    time.sleep(2)
    check(remote('systemctl is-active --quiet antirkn-trusttunnel',check=False).returncode==0,'old_service_active')
    old_pid=remote('systemctl show antirkn-trusttunnel -p MainPID --value').stdout
    before = remote('sha256sum /etc/antirkn-components/trusttunnel/*').stdout
    preview = plan('trusttunnel')
    check(preview['state']=='update' and preview['installedVersion']=='1.0.33','update_plan_versions')
    request = dict(version=1,action='submit',kind='component_install',component='trusttunnel',
        id='4'*32,count=6,interval=1,fingerprint=preview['fingerprint'])
    if '--cache' in sys.argv:
        directory = '/var/lib/antirkn-runner/component-' + request['id']
        remote('mkdir -m 700 -p ' + directory)
        remote('cat > ' + directory + '/endpoint.archive',Path('/tmp/antirkn-tt.tar.gz').read_bytes())
    check(rpc(request)['code']=='ok','update_submit')
    wait(request)
    check(before==remote('sha256sum /etc/antirkn-components/trusttunnel/*').stdout,'update_preserves_configs_and_credentials')
    check(old_pid!=remote('systemctl show antirkn-trusttunnel -p MainPID --value').stdout,'active_service_restarted')
    check(remote('systemctl is-active --quiet antirkn-trusttunnel').returncode==0,'updated_service_active')
    check(remote('test -s /var/lib/antirkn-runner/component-'+'4'*32+'/config-backup/credentials.toml').returncode==0,'credential_backup_created')
    python('''
import ssl,socket
ctx=ssl.create_default_context(cafile='/etc/antirkn-components/trusttunnel/cert.pem')
with socket.create_connection(('127.0.0.1',18443),timeout=10) as sock:
 with ctx.wrap_socket(sock,server_hostname='ping.localhost') as tls:
  tls.sendall(b'GET / HTTP/1.1\\r\\nHost: ping.localhost\\r\\nConnection: close\\r\\n\\r\\n')
  assert b'200' in tls.recv(4096)
''')
    check(True,'updated_tls_ping_with_certificate_verification')
    check(b'1.1.0' in remote('/usr/local/bin/trusttunnel_endpoint --version').stdout,'real_updated_version')
    check(remote('test -x /usr/local/lib/antirkn-components/trusttunnel/versions/'+'f'*64+'/trusttunnel_endpoint').returncode==0,'old_version_backup_kept')
    (ROOT/'docs/evidence/components-ubuntu.json').write_text(json.dumps(dict(results=results),indent=2)+'\n')


if __name__=='__main__':
    main()
