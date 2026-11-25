"""Only-Xray replacement with device probes and a durable independent rollback."""
import hashlib
import json
import os
import platform
import re
import stat
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sysutil import run as sysutil_run
import connectivity_probe as probes
import panel_update as panel
import vless
from panel import atomic_file, command, safe_file, PanelError

from xray_upgrade_release import TARGET
BINARY = Path('/usr/local/x-ui/bin/xray-linux-amd64')
CONFIG = Path('/usr/local/x-ui/bin/config.json')
UNITS = Path('/etc/systemd/system')
FINAL = {'committed', 'rolled_back', 'not_changed'}
# A rollback that could not finish: mutations stay blocked and nothing retries
# it automatically; only an explicit xray_check_abort tries again.
STUCK = 'recovery_required'
MAX_ROLLBACK_ATTEMPTS = 3
ROLLBACK_RETRY_SECONDS = 20
# Large files no finished transaction needs (the state record stays).
TRANSIENT = ('previous', 'candidate', 'candidate.zip', 'download.tmp')
# An explicitly chosen release: only XTLS's own amd64 asset, with the digest
# the device read from the release (as for component upgrades), size-bounded.
OFFICIAL = 'https://github.com/XTLS/Xray-core/releases/download/v{0}/Xray-linux-64.zip'
MAX_ARCHIVE = 64 * 1024 * 1024
DOWNLOAD_FIELDS = ('version', 'url', 'sha256', 'bytes', 'binarySha256')
BEGIN_FIELDS = {'panelId', 'fingerprint', 'leases', 'network', 'baseline', 'core'}
# How often the watchdog logs in to 3x-ui while the device compares.
PANEL_CHECK_SECONDS = 30

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
    """Whether a transaction blocks mutations. Read-only apart from settling a
    begin that crashed before arming: an expired transaction is rolled back by
    its watchdog, never inside an RPC."""
    for path in directory(store).iterdir():
        if path.is_dir():
            info = load(store, path.name)
            if info and info['phase'] not in FINAL and not settle_unarmed(store, info):
                return True
    return False

def settle_unarmed(store, info):
    """A crash before arming cannot have launched the replacement worker.
    Callers hold the operation lock, under which begin() arms."""
    if info['phase']=='preparing' and not (UNITS/unit(info['id'],'rollback')).exists():
        info.update(phase='not_changed',code='xray_check_watchdog');save(store,info)
        return True
    return False

def prune(store):
    """Finished transactions keep only their state record, and only the newest
    one per panel (latest() reports it); stuck or running ones stay whole."""
    newest={}
    finished=[]
    for path in directory(store).iterdir():
        if not path.is_dir() or path.is_symlink():continue
        try:info=load(store,path.name)
        except Exception:continue
        if not info or info.get('phase') not in FINAL:continue
        for name in TRANSIENT:(path/name).unlink(missing_ok=True)
        panel_id=(info.get('payload') or {}).get('panelId')
        finished.append((info.get('created',0),path,panel_id))
        if panel_id not in newest or info.get('created',0)>newest[panel_id][0]:newest[panel_id]=(info.get('created',0),path)
    for created,path,panel_id in finished:
        if newest[panel_id][1]!=path:shutil.rmtree(str(path),ignore_errors=True)

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

def parse_semver(v):
    if not isinstance(v, str):
        raise ValueError(f'Invalid version: {v}')
    import re
    match = re.search(r'(\d+)\.(\d+)(?:\.(\d+))?', v)
    if not match:
        raise ValueError(f'Invalid version: {v}')
    major = int(match.group(1))
    minor = int(match.group(2))
    patch = int(match.group(3)) if match.group(3) is not None else 0
    return (major, minor, patch)

def plan(store,panel_id):
    try:current=snapshot(store,panel_id)
    except PanelError as error:
        if error.code=='panel_update_incompatible':raise UpdateError('xray_check_layout') from None
        raise
    stable = TARGET.get('prerelease') is False
    panel_supported = False
    try:
        panel_ver = parse_semver(current['panelVersion'])
        min_panel = min(parse_semver(p) for p in TARGET.get('supportedPanels', ['3.7.0']))
        panel_supported = (min_panel <= panel_ver <= (3, 11, 99)) or (current['panelVersion'] in TARGET.get('supportedPanels', []))
        core_ver = parse_semver(current['xrayVersion'])
        target_ver = parse_semver(TARGET['version'])
        core_supported = core_ver <= target_ver
        supported = panel_supported and core_supported
    except (ValueError, TypeError, KeyError):
        supported = False
    try:parse_semver(current['xrayVersion'])
    except (ValueError, TypeError, KeyError):panel_supported = False
    rows=current['configuration']['inbounds']
    try:
        candidate_available = stable and supported and (parse_semver(current['xrayVersion']) != parse_semver(TARGET['version']))
    except (ValueError, TypeError, KeyError):
        candidate_available = False
    return dict(supported=supported,current=current['xrayVersion'],candidate=TARGET['version'] if stable else None,fingerprint=vless.digest(current),
        inbounds=[dict(id=r['id'],enabled=r['enable'],protocol=r['protocol'],name=r.get('remark',''),port=r['port']) for r in rows],
        available=candidate_available,maxInbounds=TARGET['maxInbounds'],latest=latest(store,panel_id),
        # An explicitly chosen version (newer or older) needs only a supported
        # panel; the pinned target above is offered only forward.
        choosable=panel_supported)

def public(info):
    return {k:info[k] for k in ('id','phase','current','candidate','deadline','code','manifest','history') if k in info}

def latest(store,panel_id):
    records=[load(store,p.name) for p in directory(store).iterdir() if p.is_dir()]
    records=[r for r in records if r and r['payload']['panelId']==panel_id]
    return public(max(records,key=lambda r:r['created'])) if records else None

def holds_lease(store,key):
    for p in directory(store).iterdir():
        if p.is_dir():
            info=load(store,p.name)
            if info and info['phase'] not in FINAL and key in info['payload']['leases']:return True
    return False


def unit(key,role):return 'antirkn-xray-'+role+'-'+probes.identifier(key)+'.service'

def arm(info):
    source=str(Path(__file__).resolve())
    name=unit(info['id'],'rollback')
    atomic_file(UNITS/name,('[Unit]\nDescription=AntiRKN Xray rollback watchdog\nAfter=local-fs.target\nStartLimitIntervalSec=0\n'
        '[Service]\nType=simple\nUMask=0077\nRestart=on-failure\nRestartSec=10\n'
        f'ExecStart=/usr/bin/python3 -I {source} watchdog {info["id"]}\n[Install]\nWantedBy=multi-user.target\n').encode(),0o644)
    command(['/usr/bin/systemctl','daemon-reload'])
    command(['/usr/bin/systemctl','enable','--now',name])
    command(['/usr/bin/systemctl','is-active','--quiet',name])

def retire(info):
    """Idempotent: the unit may be disabled, unloaded or gone already. The
    watchdog calls this from inside the unit, so it is never stopped here."""
    probes.retire_unit(unit(info['id'],'rollback'))

def chosen_target(candidate):
    """(release, explicit): the pinned TARGET, or the version the device chose
    with the archive digest it read from the release. The pinned version keeps
    its pinned archive and binary hashes."""
    if candidate is None:
        if TARGET.get('prerelease') is not False:raise UpdateError('xray_check_invalid')
        return {k:TARGET[k] for k in DOWNLOAD_FIELDS},False
    if not isinstance(candidate,dict) or set(candidate)!={'version','url','sha256'} or not all(isinstance(v,str) for v in candidate.values()):
        raise UpdateError('xray_check_invalid')
    version=candidate['version']
    if not re.fullmatch(r'[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}',version) or candidate['url']!=OFFICIAL.format(version):
        raise UpdateError('xray_check_invalid')
    if not re.fullmatch(r'[0-9a-f]{64}',candidate['sha256']):raise UpdateError('xray_check_digest')
    if version==TARGET['version']:
        if candidate['url']!=TARGET['url'] or candidate['sha256']!=TARGET['sha256']:raise UpdateError('xray_check_digest')
        return {k:TARGET[k] for k in DOWNLOAD_FIELDS},True
    return dict(version=version,url=candidate['url'],sha256=candidate['sha256']),True

def begin(store,req):
    key=probes.identifier(req['id']);payload=json.loads(req['payload']);old=load(store,key)
    if old:
        if old['requestHash']!=vless.digest(payload):raise UpdateError('xray_check_changed')
        return {**public(old),'nonce':old['nonce']}
    if not isinstance(payload,dict) or set(payload)-{'candidate'}!=BEGIN_FIELDS or not isinstance(payload['network'],str) or not 1<=len(payload['network'])<=1024:
        raise UpdateError('xray_check_invalid')
    target,explicit=chosen_target(payload.get('candidate'))
    prune(store)
    if active(store) or store.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone():raise UpdateError('xray_check_busy')
    if payload['core']!='ac017cdd246ce8bd547653d927e7bf77d7ee73d5':raise UpdateError('xray_check_invalid')
    owned=leases(store,payload['leases']);current=snapshot(store,payload['panelId'])
    if vless.digest(current)!=payload['fingerprint']:raise UpdateError('xray_check_changed')
    offer=plan(store,payload['panelId'])
    if explicit:
        # An older version only when chosen; the panel check is the same.
        try:same=parse_semver(current['xrayVersion'])==parse_semver(target['version'])
        except ValueError:same=True
        if not offer['choosable'] or same:raise UpdateError('xray_check_changed')
    elif not offer['available']:raise UpdateError('xray_check_changed')
    wanted={r['id'] for r in current['configuration']['inbounds'] if r['enable']}
    covered={row['rowId'] for row in owned if row['protocol']=='vless' and row['saved']['panelId']==payload['panelId']}
    if not wanted or covered!=wanted or any(r['enable'] and r['protocol']!='vless' for r in current['configuration']['inbounds']):raise UpdateError('xray_check_coverage')
    if len(covered)!=len(owned):raise UpdateError('xray_check_coverage')
    verify_checks(payload['baseline'],payload['leases'])
    if min(r['expires'] for r in owned)-time.time()<120+65*len(owned):raise UpdateError('xray_check_timeout')
    info=dict(id=key,phase='preparing',current=current['xrayVersion'],candidate=target['version'],target=target,deadline=min(time.time()+600,min(r['expires'] for r in owned)-30),
        created=time.time(),boot=boot(),uptimeDeadline=uptime()+600,payload=payload,requestHash=vless.digest(payload),nonce=secrets.token_hex(32),before=current,oldHash=hashlib.sha256(BINARY.read_bytes()).hexdigest(),code='preparing')
    meta=BINARY.stat()
    info['oldMode']=stat.S_IMODE(meta.st_mode);info['oldUid']=meta.st_uid;info['oldGid']=meta.st_gid
    info['manifest']=vless.digest(dict(before=current,target=target,leases=payload['leases'],network=payload['network'],id=key))
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

class HttpsRedirects(urllib.request.HTTPRedirectHandler):
    """Every redirect hop of a release download stays on https."""
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        if not newurl.startswith('https://'):raise UpdateError('xray_check_digest')
        return super().redirect_request(req,fp,code,msg,headers,newurl)

def reports(output,version):
    return output.startswith('Xray '+version+' ') or output.startswith('Xray v'+version+' ')

def download(path,target):
    """The verified core of `target` (see chosen_target): archive digest and
    size, the pinned binary digest when there is one, and its own version."""
    output=path/'candidate.zip';temporary=path/'download.tmp';limit=target.get('bytes') or MAX_ARCHIVE
    if not output.exists() or hashlib.sha256(output.read_bytes()).hexdigest()!=target['sha256']:
        client=urllib.request.build_opener(urllib.request.ProxyHandler({}),HttpsRedirects());total=0;started=time.monotonic()
        with client.open(target['url'],timeout=20) as response,temporary.open('wb') as stream:
            if not response.geturl().startswith('https://'):raise UpdateError()
            while True:
                chunk=response.read(262144)
                if not chunk:break
                total+=len(chunk)
                if total>min(limit,MAX_ARCHIVE) or time.monotonic()-started>120:raise UpdateError()
                stream.write(chunk)
            stream.flush();os.fsync(stream.fileno())
        if (target.get('bytes') and total!=target['bytes']) or hashlib.sha256(temporary.read_bytes()).hexdigest()!=target['sha256']:raise UpdateError('xray_check_digest')
        os.replace(temporary,output)
    with zipfile.ZipFile(output) as archive:
        item=archive.getinfo('xray')
        if item.file_size>100*1024*1024:raise UpdateError()
        data=archive.read(item)
        if target.get('binarySha256') and hashlib.sha256(data).hexdigest()!=target['binarySha256']:raise UpdateError('xray_check_digest')
        atomic_file(path/'candidate',data,0o700)
    if not reports(command([str(path/'candidate'),'version']).decode(),target['version'].lstrip('v')):raise UpdateError()
    return path/'candidate'

def config_test(binary):
    safe_file(CONFIG,16*1024*1024)
    result=sysutil_run([str(binary),'run','-test','-config',str(CONFIG)], cwd=CONFIG.parent, env={**os.environ,'XRAY_LOCATION_ASSET':str(CONFIG.parent)}, capture=False, stderr=False, timeout=20)
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
            if actual['xrayVersion'].lstrip('v')==version.lstrip('v') and actual['panelVersion'].lstrip('v')==info['before']['panelVersion'].lstrip('v'):
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


def panel_api(store,info):
    """The app still works with 3x-ui after the core change: a fresh login to
    its API and inbounds/list returns the same inbound ids as before."""
    expected=sorted(row['id'] for row in info['before']['configuration']['inbounds'])
    try:
        api=panel.client(vless.access_for_panel(store,info['payload']['panelId']))
        actual=sorted(row['id'] for row in api.call('/panel/api/inbounds/list'))
    except Exception:raise UpdateError('xray_check_panel_api') from None
    if actual!=expected:raise UpdateError('xray_check_panel_api')

def replace_binary(info,data):
    atomic_file(BINARY,data,info['oldMode'])
    os.chown(BINARY,info['oldUid'],info['oldGid'])

def apply(store,key):
    try:
        candidate=download(location(store,key),load(store,key).get('target',TARGET))
        with probes.operation_lock(store):
            info=load(store,key)
            if info['phase']!='preparing':return
            if expired(info) or time.time()>=info['deadline']-30:raise UpdateError('xray_check_timeout')
            leases(store,info['payload']['leases'])
            if snapshot(store,info['payload']['panelId'])!=info['before']:raise UpdateError('xray_check_changed')
            config_test(candidate)
            info.update(phase='replacing',newHash=hashlib.sha256(candidate.read_bytes()).hexdigest(),code='replacing');save(store,info)
            replace_binary(info,candidate.read_bytes())
            restart(store,info,info['candidate'])
            panel_api(store,info)
            if not unchanged(store,info,new=True):raise UpdateError('xray_check_changed')
            info.update(phase='awaiting_checks',code='awaiting_checks');save(store,info)
    except Exception as error:
        with probes.operation_lock(store):
            info=load(store,key)
            if info and info['phase'] not in FINAL and info['phase']!=STUCK:
                info['code']=error.code if isinstance(error,UpdateError) else 'xray_check_failed';save(store,info)
                attempt_rollback(store,info)

def attempt_rollback(store,info):
    """Automatic rollback with a bounded number of attempts across restarts.

    The attempt is counted before it starts, so a crash inside it (or a panel
    that never confirms the version) cannot restart x-ui forever. Returns True
    when the transaction is settled (rolled back or stuck), False to retry."""
    if info['phase'] in FINAL or info['phase']==STUCK:
        retire(info);return True
    attempts=info.get('rollbackAttempts',0)+1
    if attempts>MAX_ROLLBACK_ATTEMPTS:
        info.update(phase=STUCK,code=info.get('code') if info.get('code','').startswith('xray_check_') else 'xray_check_rollback')
        save(store,info);retire(info);return True
    info['rollbackAttempts']=attempts;save(store,info)
    try:
        rollback(store,info)
        return True
    except Exception as error:
        current=load(store,info['id']) or info
        if current['phase'] in FINAL or current['phase']==STUCK:
            retire(current);return True
        current['code']=error.code if isinstance(error,UpdateError) else 'xray_check_rollback'
        if attempts>=MAX_ROLLBACK_ATTEMPTS:
            current['phase']=STUCK;save(store,current);retire(current);return True
        save(store,current);return False

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
    info['phase']='rolled_back';save(store,info);retire(info);prune(store);return public(info)

def unchanged(store,info,new):
    after=snapshot(store,info['payload']['panelId']);before=info['before']
    expected=info['candidate'] if new else info['current']
    expected_hash=info['newHash'] if new else info['oldHash']
    if after['xrayVersion'].lstrip('v')!=expected.lstrip('v') or hashlib.sha256(BINARY.read_bytes()).hexdigest()!=expected_hash:return False
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
    try:panel_api(store,info)
    except UpdateError as error:
        info['code']=error.code;save(store,info);return rollback(store,info)
    if not unchanged(store,info,new=True):return rollback(store,info)
    info.update(phase='committed',code='committed');save(store,info);retire(info);prune(store);return public(info)

def status(store,req):
    info=load(store,req['id'])
    if not info:raise UpdateError('xray_check_missing')
    settle_unarmed(store,info)
    return public(info)

def panel_failure(store,key):
    """The code of a failed 3x-ui check while the device compares, else None.
    Runs without the operation lock: RPCs (a commit) are not held up by it."""
    info=load(store,key)
    if not info or info['phase']!='awaiting_checks' or expired(info):return None
    try:panel_api(store,info)
    except UpdateError as error:return error.code
    return None

def watchdog(key):
    """Rolls back once the window ends without a commit (checks arrive only
    through finish()) or as soon as the app can no longer work with 3x-ui; a
    rollback that keeps failing becomes recovery_required and the unit retires
    itself instead of restarting x-ui forever."""
    from runner import Store,STATE
    started=time.monotonic();next_check=started+PANEL_CHECK_SECONDS;failure=None
    while True:
        delay=1
        store=Store(STATE)
        try:
            if failure is None and time.monotonic()>=next_check:
                next_check=time.monotonic()+PANEL_CHECK_SECONDS
                failure=panel_failure(store,key)
            with probes.operation_lock(store):
                info=load(store,key)
                if not info or info['phase'] in FINAL or info['phase']==STUCK:
                    if info:retire(info)
                    return
                if failure and info['phase']=='awaiting_checks':
                    info['code']=failure;save(store,info)
                    if attempt_rollback(store,info):return
                    delay=ROLLBACK_RETRY_SECONDS
                elif info['phase']=='rolling_back' or expired(info) or time.monotonic()-started>=600:
                    if attempt_rollback(store,info):return
                    delay=ROLLBACK_RETRY_SECONDS
        except probes.ProbeError:
            pass  # The lock is busy (apply or an RPC): look again shortly.
        finally:store.close()
        time.sleep(delay)

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
