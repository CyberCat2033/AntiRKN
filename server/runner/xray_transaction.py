"""Only-Xray replacement with device probes and a durable independent rollback."""
import hashlib
import json
import os
import platform
import stat
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time
import urllib.request
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import connectivity_probe as probes
import panel_update as panel
import vless
from panel import atomic_file, command, safe_file, PanelError

from xray_upgrade_release import TARGET
BINARY = Path('/usr/local/x-ui/bin/xray-linux-amd64')
CONFIG = Path('/usr/local/x-ui/bin/config.json')
UNITS = Path('/etc/systemd/system')
FINAL = {'committed', 'rolled_back', 'not_changed'}

def boot(): return Path('/proc/sys/kernel/random/boot_id').read_text().strip()
def uptime(): return float(Path('/proc/uptime').read_text().split()[0])
def expired(info):
    return time.time() >= info['deadline'] or info.get('boot') != boot() or uptime() >= info.get('uptimeDeadline', 0)


class UpdateError(Exception):
    def __init__(self, code='xray_check_failed'): self.code=code

def directory(store):
    path=store.directory/'xray-upgrades';path.mkdir(mode=0o700,exist_ok=True)
    if path.is_symlink():raise UpdateError()
    return path

def location(store,key):return directory(store)/probes.identifier(key)

def load(store,key):
    file=location(store,key)/'state.json'
    if not file.exists():return None
    safe_file(file,4*1024*1024)
    return json.loads(file.read_text())

def save(store,info):
    path=location(store,info['id']);path.mkdir(mode=0o700,exist_ok=True)
    history=info.setdefault('history',[])
    if not history or history[-1]['phase']!=info['phase'] or history[-1]['code']!=info['code']:
        history.append(dict(phase=info['phase'],code=info['code'],at=time.time()))
        info['history']=history[-32:]
    atomic_file(path/'state.json',vless.canonical(info).encode())

def active(store):
    return any((info:=load(store,path.name)) and info['phase'] not in FINAL for path in directory(store).iterdir() if path.is_dir())

def leases(store,keys):
    if not isinstance(keys,list) or not 1<=len(keys)<=TARGET['maxInbounds'] or len(set(keys))!=len(keys):raise UpdateError('xray_check_coverage')
    result=[]
    for key in keys:
        info=probes.load(store,key)
        if not info or info['status']!='active' or info['expires']<=time.time()+60 or probes.fingerprint(store,info)!=info['afterHash']:
            raise UpdateError('xray_check_changed')
        result.append(info)
    return result

def snapshot(store,panel_id):
    if platform.machine() != 'x86_64':raise UpdateError('xray_check_layout')
    current=panel.snapshot(store,panel_id)
    # Ignore only the exact UUIDs issued by active, root-owned diagnostic leases.
    temporary={}
    for path in probes.directory(store).glob('*.json'):
        info=probes.load(store,path.stem)
        if info['status']!='closed' and info.get('protocol')=='vless' and info['saved']['panelId']==panel_id:
            temporary.setdefault(info['rowId'],set()).add(info['observation']['clients'][0]['uuid'])
    for row in current['configuration']['inbounds']:
        row['settings']['clients']=[c for c in row['settings'].get('clients',[]) if c.get('id') not in temporary.get(row['id'],set())]
    return current

def plan(store,panel_id):
    try:current=snapshot(store,panel_id)
    except PanelError as error:
        if error.code=='panel_update_incompatible':raise UpdateError('xray_check_layout') from None
        raise
    stable = TARGET.get('prerelease') is False
    supported=(current['panelVersion'] in TARGET['supportedPanels'] and panel.version(current['xrayVersion'])<=panel.version(TARGET['version']))
    rows=current['configuration']['inbounds']
    return dict(supported=supported,current=current['xrayVersion'],candidate=TARGET['version'] if stable else None,fingerprint=vless.digest(current),
        inbounds=[dict(id=r['id'],enabled=r['enable'],protocol=r['protocol'],name=r.get('remark',''),port=r['port']) for r in rows],
        available=stable and supported and current['xrayVersion']!=TARGET['version'],maxInbounds=TARGET['maxInbounds'],latest=latest(store,panel_id))

def public(info):
    return {k:info[k] for k in ('id','phase','current','candidate','deadline','code','manifest','history') if k in info}

def latest(store,panel_id):
    records=[load(store,p.name) for p in directory(store).iterdir() if p.is_dir()]
    records=[r for r in records if r and r['payload']['panelId']==panel_id]
    return public(max(records,key=lambda r:r['created'])) if records else None

def holds_lease(store,key):
    return any((info:=load(store,p.name)) and info['phase'] not in FINAL and key in info['payload']['leases']
               for p in directory(store).iterdir() if p.is_dir())


def unit(key,role):return 'antirkn-xray-'+role+'-'+probes.identifier(key)+'.service'

def arm(info):
    source=str(Path(__file__).resolve())
    name=unit(info['id'],'rollback')
    atomic_file(UNITS/name,('[Unit]\nDescription=AntiRKN Xray rollback watchdog\nAfter=local-fs.target\nStartLimitIntervalSec=0\n'
        '[Service]\nType=simple\nUMask=0077\nRestart=on-failure\nRestartSec=3\n'
        f'ExecStart=/usr/bin/python3 -I {source} watchdog {info["id"]}\n[Install]\nWantedBy=multi-user.target\n').encode(),0o644)
    command(['/usr/bin/systemctl','daemon-reload'])
    command(['/usr/bin/systemctl','enable','--now',name])
    command(['/usr/bin/systemctl','is-active','--quiet',name])

def retire(info):
    name=unit(info['id'],'rollback')
    if (UNITS/name).exists():
        command(['/usr/bin/systemctl','disable',name]);(UNITS/name).unlink(missing_ok=True)
        command(['/usr/bin/systemctl','daemon-reload'])

def begin(store,req):
    key=probes.identifier(req['id']);payload=json.loads(req['payload']);old=load(store,key)
    if old:
        if old['requestHash']!=vless.digest(payload):raise UpdateError('xray_check_changed')
        return {**public(old),'nonce':old['nonce']}
    if TARGET.get('prerelease') is not False:raise UpdateError('xray_check_invalid')
    if active(store) or store.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():raise UpdateError('xray_check_busy')
    if set(payload)!={'panelId','fingerprint','leases','network','baseline','core'} or not isinstance(payload['network'],str) or not 1<=len(payload['network'])<=1024:
        raise UpdateError('xray_check_invalid')
    if payload['core']!='ac017cdd246ce8bd547653d927e7bf77d7ee73d5':raise UpdateError('xray_check_invalid')
    owned=leases(store,payload['leases']);current=snapshot(store,payload['panelId'])
    if vless.digest(current)!=payload['fingerprint'] or not plan(store,payload['panelId'])['available']:raise UpdateError('xray_check_changed')
    wanted={r['id'] for r in current['configuration']['inbounds'] if r['enable']}
    covered={row['rowId'] for row in owned if row['protocol']=='vless' and row['saved']['panelId']==payload['panelId']}
    if not wanted or covered!=wanted or any(r['enable'] and r['protocol']!='vless' for r in current['configuration']['inbounds']):raise UpdateError('xray_check_coverage')
    if len(covered)!=len(owned):raise UpdateError('xray_check_coverage')
    verify_checks(payload['baseline'],payload['leases'])
    if min(r['expires'] for r in owned)-time.time()<120+65*len(owned):raise UpdateError('xray_check_timeout')
    info=dict(id=key,phase='preparing',current=current['xrayVersion'],candidate=TARGET['version'],deadline=min(time.time()+600,min(r['expires'] for r in owned)-30),
        created=time.time(),boot=boot(),uptimeDeadline=uptime()+600,payload=payload,requestHash=vless.digest(payload),nonce=secrets.token_hex(32),before=current,oldHash=hashlib.sha256(BINARY.read_bytes()).hexdigest(),code='preparing')
    meta=BINARY.stat()
    info['oldMode']=stat.S_IMODE(meta.st_mode);info['oldUid']=meta.st_uid;info['oldGid']=meta.st_gid
    info['manifest']=vless.digest(dict(before=current,target=TARGET,leases=payload['leases'],network=payload['network'],id=key))
    save(store,info)
    atomic_file(location(store,key)/'previous',BINARY.read_bytes(),0o700)
    if hashlib.sha256((location(store,key)/'previous').read_bytes()).hexdigest()!=info['oldHash']:raise UpdateError()
    try:
        arm(info)  # No replacement is possible until enable + is-active succeed.
    except Exception:
        info.update(phase='not_changed',code='xray_check_watchdog');save(store,info)
        raise UpdateError('xray_check_watchdog') from None
    command(['/usr/bin/systemd-run','--quiet','--collect','--unit='+unit(key,'worker'),'--property=UMask=0077','/usr/bin/python3','-I',str(Path(__file__).resolve()),'apply',key])
    return {**public(info),'nonce':info['nonce']}

def verify_checks(checks,keys):
    if not isinstance(checks,list) or len(checks)!=len(keys) or {r.get('lease') for r in checks if isinstance(r,dict)}!=set(keys):raise UpdateError('xray_check_coverage')
    if any(set(r)!={'lease','tcp','udp'} or r['tcp'] is not True or r['udp'] is not True for r in checks):raise UpdateError('xray_check_coverage')

def download(path):
    output=path/'candidate.zip';temporary=path/'download.tmp'
    if not output.exists() or hashlib.sha256(output.read_bytes()).hexdigest()!=TARGET['sha256']:
        client=urllib.request.build_opener(urllib.request.ProxyHandler({}));total=0;started=time.monotonic()
        with client.open(TARGET['url'],timeout=20) as response,temporary.open('wb') as stream:
            if not response.geturl().startswith('https://'):raise UpdateError()
            while True:
                chunk=response.read(262144)
                if not chunk:break
                total+=len(chunk)
                if total>TARGET['bytes'] or time.monotonic()-started>120:raise UpdateError()
                stream.write(chunk)
            stream.flush();os.fsync(stream.fileno())
        if total!=TARGET['bytes'] or hashlib.sha256(temporary.read_bytes()).hexdigest()!=TARGET['sha256']:raise UpdateError('xray_check_digest')
        os.replace(temporary,output)
    with zipfile.ZipFile(output) as archive:
        item=archive.getinfo('xray')
        if item.file_size>100*1024*1024:raise UpdateError()
        data=archive.read(item)
        if hashlib.sha256(data).hexdigest()!=TARGET['binarySha256']:raise UpdateError('xray_check_digest')
        atomic_file(path/'candidate',data,0o700)
    if not command([str(path/'candidate'),'version']).decode().startswith('Xray '+TARGET['version']+' '):raise UpdateError()
    return path/'candidate'

def config_test(binary):
    safe_file(CONFIG,16*1024*1024)
    result=subprocess.run([str(binary),'run','-test','-config',str(CONFIG)],cwd=CONFIG.parent,env={**os.environ,'XRAY_LOCATION_ASSET':str(CONFIG.parent)},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
    if result.returncode:raise UpdateError('xray_check_config')

def restart(store,info,version):
    access=vless.access_for_panel(store,info['payload']['panelId'])
    try:
        api=panel.client(access)
        api.call('/panel/api/server/restartXrayService',{})
    except (PanelError,OSError,ValueError):
        # A stopped/crashed panel must not prevent restoring its owned core.
        command(['/usr/bin/systemctl','restart','x-ui.service'])
        api=None
    for _ in range(30):
        try:
            if api is None:api=panel.client(access)
            actual=panel.versions(api)
            if actual['xrayVersion']==version and actual['panelVersion']==info['before']['panelVersion']:
                cache_versions(store,info,actual)
                return
        except (PanelError,OSError,ValueError,KeyError):pass
        time.sleep(.5)
    raise UpdateError('xray_check_restart')

def cache_versions(store,info,actual):
    # The authenticated panel and both binaries have been read back. Update
    # only AntiRKN's version observations, never credentials or panel settings.
    from panel_discovery import EXTERNAL_ACCESS,external_access
    external=external_access()
    if external and external['id']==info['payload']['panelId']:
        external.update(actual);atomic_file(EXTERNAL_ACCESS,vless.canonical(external).encode())
    marker=panel.DATABASE/'.antirkn-owner'
    if marker.exists():
        safe_file(marker,32)
        if marker.read_text()==info['payload']['panelId']:
            atomic_file(panel.DATABASE/'.antirkn-versions',vless.canonical(dict(id=marker.read_text(),**actual)).encode())


def replace_binary(info,data):
    atomic_file(BINARY,data,info['oldMode'])
    os.chown(BINARY,info['oldUid'],info['oldGid'])

def apply(store,key):
    try:
        candidate=download(location(store,key))
        with probes.operation_lock(store):
            info=load(store,key)
            if info['phase']!='preparing':return
            if expired(info) or time.time()>=info['deadline']-30:raise UpdateError('xray_check_timeout')
            leases(store,info['payload']['leases'])
            if snapshot(store,info['payload']['panelId'])!=info['before']:raise UpdateError('xray_check_changed')
            config_test(candidate)
            info.update(phase='replacing',newHash=hashlib.sha256(candidate.read_bytes()).hexdigest(),code='replacing');save(store,info)
            replace_binary(info,candidate.read_bytes())
            restart(store,info,TARGET['version'])
            if not unchanged(store,info,new=True):raise UpdateError('xray_check_changed')
            info.update(phase='awaiting_checks',code='awaiting_checks');save(store,info)
    except Exception as error:
        with probes.operation_lock(store):
            info=load(store,key)
            if info and info['phase'] not in FINAL:
                info['code']=error.code if isinstance(error,UpdateError) else 'xray_check_failed';save(store,info)
                rollback(store,info)

def rollback(store,info):
    if info['phase'] in FINAL:return public(info)
    safe_file(BINARY,100*1024*1024)
    actual=hashlib.sha256(BINARY.read_bytes()).hexdigest()
    if actual not in (info['oldHash'],info.get('newHash')):
        info.update(phase='recovery_required',code='xray_check_changed');save(store,info);raise UpdateError('xray_check_rollback')
    if info['phase']=='preparing' and actual==info['oldHash']:
        info.update(phase='not_changed');save(store,info);retire(info);return public(info)
    info['phase']='rolling_back';save(store,info)
    previous=location(store,info['id'])/'previous';safe_file(previous,100*1024*1024)
    if hashlib.sha256(previous.read_bytes()).hexdigest()!=info['oldHash']:raise UpdateError('xray_check_rollback')
    # Restore the known binary even when an external config edit is invalid.
    # No database/config copy is written by this transaction.
    replace_binary(info,previous.read_bytes())
    restart(store,info,info['current'])
    if hashlib.sha256(BINARY.read_bytes()).hexdigest()!=info['oldHash']:raise UpdateError('xray_check_rollback')
    # External configuration edits are preserved, so report them separately.
    if not unchanged(store,info,new=False):info['code']='xray_check_changed'
    info['phase']='rolled_back';save(store,info);retire(info);return public(info)

def unchanged(store,info,new):
    after=snapshot(store,info['payload']['panelId']);before=info['before']
    expected=info['candidate'] if new else info['current']
    expected_hash=info['newHash'] if new else info['oldHash']
    if after['xrayVersion']!=expected or hashlib.sha256(BINARY.read_bytes()).hexdigest()!=expected_hash:return False
    meta=BINARY.stat()
    if (stat.S_IMODE(meta.st_mode),meta.st_uid,meta.st_gid)!=(info['oldMode'],info['oldUid'],info['oldGid']):return False
    after['files'][str(BINARY)]=before['files'][str(BINARY)];after['xrayVersion']=before['xrayVersion']
    return after==before


def finish(store,req):
    info=load(store,req['id'])
    if not info:raise UpdateError('xray_check_missing')
    payload=json.loads(req['payload'])
    if payload.get('nonce')!=info['nonce']:raise UpdateError('xray_check_invalid')
    if info['phase'] in FINAL:
        if req['action']=='xray_check_commit' and info['phase']!='committed':raise UpdateError('xray_check_late')
        retire(info);return public(info)
    if payload.get('manifest')!=info['manifest']:raise UpdateError('xray_check_invalid')
    if req['action']=='xray_check_abort':return rollback(store,info)
    if info['phase']!='awaiting_checks' or expired(info):return rollback(store,info)
    if payload.get('network')!=info['payload']['network']:return rollback(store,info)
    verify_checks(payload.get('checks'),info['payload']['leases']);leases(store,info['payload']['leases'])
    if not unchanged(store,info,new=True):return rollback(store,info)
    info.update(phase='committed',code='committed');save(store,info);retire(info);return public(info)

def status(store,req):
    info=load(store,req['id'])
    if not info:raise UpdateError('xray_check_missing')
    if info['phase']=='preparing' and not (UNITS/unit(info['id'],'rollback')).exists():
        # A crash before arming cannot have launched the replacement worker.
        info.update(phase='not_changed',code='xray_check_watchdog');save(store,info)
    return public(info)

def check_connectivity(info):
    inbounds = info.get('before', {}).get('configuration', {}).get('inbounds', [])
    enabled = [r for r in inbounds if r.get('enable')]
    if not enabled:
        return False
    for r in enabled:
        port = r.get('port')
        if not port or not isinstance(port, int):
            return False
        listen = r.get('listen')
        targets = [listen] if listen and listen not in ('0.0.0.0', '::', '') else ['127.0.0.1', '::1']
        bound = False
        for host in targets:
            try:
                with socket.create_connection((host, port), timeout=2):
                    bound = True
                    break
            except (OSError, socket.error):
                pass
        if not bound:
            return False
    return True

def watchdog(key):
    from runner import Store,STATE
    started=time.monotonic()
    while True:
        store=Store(STATE)
        try:
            with probes.operation_lock(store):
                info=load(store,key)
                if not info or info['phase'] in FINAL:
                    if info:retire(info)
                    return
                if info['phase'] in ('rolling_back','recovery_required') or expired(info) or time.monotonic()-started>=600:
                    healthy=False
                    if info['phase']=='awaiting_checks':
                        try:healthy=unchanged(store,info,new=True) and check_connectivity(info)
                        except Exception:healthy=False
                    if healthy:
                        info.update(phase='committed',code='committed');save(store,info);retire(info);return
                    rollback(store,info);return
        finally:store.close()
        time.sleep(1)

if __name__=='__main__':
    try:
        if len(sys.argv)!=3:raise ValueError()
        key=probes.identifier(sys.argv[2])
        if sys.argv[1]=='watchdog':watchdog(key)
        elif sys.argv[1]=='apply':
            from runner import Store,STATE
            s=Store(STATE)
            try:apply(s,key)
            finally:s.close()
        else:raise ValueError()
    except Exception:raise SystemExit(1) from None
