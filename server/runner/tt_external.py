"""Discover/edit native TrustTunnel services without taking over clients.

Discovery derives resource selectors from systemd and the process command line.
RPC selectors never authorize an arbitrary executable, unit or configuration.
"""
import copy
import json
import os
from pathlib import Path
import re
import shlex
import pwd
import time

from awg_network import replace_preserving
from panel import atomic_file
from tt_common import (ROOT, TtError, active, address, available, canonical, digest,
    domain, file_lock, identifier, ip, lock, read, run, safe_path, split_address, toml_bytes,
    toml_loads)
import tt_certificates as certificates
from tt import check_socks


def candidates():
    names = set()
    for cmd in ('list-units', 'list-unit-files'):
        result = run(['/usr/bin/systemctl', cmd, '--type=service', '--no-legend', '--plain'], check=False)
        for line in result.stdout.decode().splitlines():
            name = line.split()[0] if line.split() else ''
            if 'trusttunnel' in name.lower() and not name.startswith('antirkn-'):
                names.add(name)
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            argv = (proc / 'cmdline').read_bytes().split(b'\x00')
            if not argv or Path(os.fsdecode(argv[0])).name != 'trusttunnel_endpoint': continue
            for line in (proc / 'cgroup').read_text().splitlines():
                unit = line.rsplit('/',1)[-1]
                if unit.endswith('.service') and not unit.startswith('antirkn-'): names.add(unit)
        except (OSError, ValueError): pass
    return sorted(n for n in names if re.fullmatch(r'[A-Za-z0-9_.@:-]+\.service', n))[:64]


def supported_version(output):
    """The runner configures the pinned TrustTunnel generation: the same major
    version, the pinned release or newer (as the checked component update
    installs). Requiring exactly 1.1.0 lost every resource after an update."""
    from component_releases import RELEASES
    pinned = tuple(int(x) for x in RELEASES['trusttunnel']['version'].split('.'))
    match = re.search(r'(?<![0-9.])([0-9]{1,4})\.([0-9]{1,4})\.([0-9]{1,6})(?![0-9])', output)
    if match is None:
        return False
    have = tuple(int(x) for x in match.groups())
    return have[0] == pinned[0] and have >= pinned


def definition(unit, versions=None):
    raw = run(['/usr/bin/systemctl','show',unit,'--property=ExecStart,WorkingDirectory,FragmentPath,MainPID,ActiveState']).stdout.decode()
    props = dict(line.split('=',1) for line in raw.splitlines() if '=' in line)
    fragment = props.get('FragmentPath','')
    safe_path(fragment)
    start = props.get('ExecStart','')
    match = re.search(r'argv\[\]=(.*?) ;', start)
    if not match: raise TtError('tt_unsupported')
    argv = shlex.split(match[1])
    if not argv or Path(argv[0]).name != 'trusttunnel_endpoint': raise TtError('tt_unsupported')
    owner=Path(argv[0]).stat().st_uid
    safe_path(argv[0], max_bytes=None, owner_uid=owner)
    configs = [a for a in argv[1:] if a.endswith('.toml')]
    if len(configs) != 2: raise TtError('tt_unsupported')
    base = Path(props.get('WorkingDirectory') or '/')
    paths = [str(Path(p) if Path(p).is_absolute() else base/p) for p in configs]
    for p in paths:
        safe_path(p, owner_uid=owner)
        if not any(Path(root) in Path(p).resolve().parents for root in ('/etc','/opt','/usr/local')):
            raise TtError('tt_unsupported')
    if any(ROOT == Path(p) or ROOT in Path(p).parents for p in paths): raise TtError('tt_unsupported')
    meta=os.stat(argv[0])
    key=(argv[0],owner,meta.st_dev,meta.st_ino,meta.st_mtime_ns,meta.st_size)
    if versions is None or key not in versions:
        command=[argv[0],'--version']
        if owner and os.geteuid()==0:
            command=['/usr/bin/setpriv','--reuid='+str(owner),'--regid='+str(pwd.getpwuid(owner).pw_gid),
                '--clear-groups','--no-new-privs',*command]
        version=run(command).stdout.decode()
        if versions is not None: versions[key]=version
    else: version=versions[key]
    if not supported_version(version): raise TtError('tt_unsupported')
    return dict(unit=unit, settings=paths[0], hosts=paths[1], base=str(base),
        binary=argv[0], ownerUid=owner, fragment=fragment, unitHash=digest(read(fragment).decode()),
        execHash=digest(argv), active=props.get('ActiveState')=='active')


def definitions(issues=None):
    result=[];versions={}
    for name in candidates():
        try:
            r=definition(name,versions)
            r['id']=digest({k:r[k] for k in ('unit','settings','hosts')})[:32]
            result.append(r)
        except (TtError,OSError,ValueError) as e:
            if issues is not None:
                issues.append(dict(name=name,code=e.code if isinstance(e,TtError) else 'tt_invalid'))
    return result


def snapshot(rid, found=None):
    """``found`` reuses the definitions one RPC or step already discovered."""
    r=next((dict(r) for r in (definitions() if found is None else found) if r['id']==identifier(rid)),None)
    if r is None: raise TtError('tt_conflict')
    vpnraw,hostsraw=read(r['settings'],r['ownerUid']),read(r['hosts'],r['ownerUid'])
    vpn,hosts=toml_loads(vpnraw.decode()),toml_loads(hostsraw.decode())
    credpath=vpn.get('credentials_file')
    credentials=b''
    if credpath:
        credpath=str(Path(credpath) if Path(credpath).is_absolute() else Path(r['base'])/credpath)
        credentials=read(credpath,r['ownerUid'])
    rules=b''
    if vpn.get('rules_file'):
        path=Path(vpn['rules_file']);rules=read(path if path.is_absolute() else Path(r['base'])/path,r['ownerUid'])
    r.update(credentials=credpath, credentialsHash=digest(credentials.decode()), rulesHash=digest(rules.decode()))
    fingerprint=digest(dict(resource=r,settings=vpnraw.decode(),hosts=hostsraw.decode()))
    return r,vpnraw,hostsraw,vpn,hosts,fingerprint


def absent(source):
    """Positively gone: both configs are missing and systemd no longer knows
    the unit. A stopped service, an unsupported binary or any read doubt
    answers False, so a read-only poll never forgets the resource."""
    if not source:
        return False
    try:
        for path in (source['settings'], source['hosts']):
            try:
                os.lstat(path)
                return False
            except FileNotFoundError:
                pass
        load=run(['/usr/bin/systemctl','show',source['unit'],'--property=LoadState','--value'],check=False)
        return load.returncode==0 and load.stdout.decode().strip()=='not-found'
    except (TtError,OSError,ValueError,KeyError,TypeError):
        return False


def public_snapshot(rid, found=None):
    r,_,_,vpn,hosts,fingerprint=snapshot(rid,found)
    if not hosts.get('main_hosts'): raise TtError('tt_unsupported')
    listen,port=split_address(vpn['listen_address'])
    forward=vpn.get('forward_protocol',{'direct':{}})
    outbound='socks5' if 'socks5' in forward else 'direct' if 'direct' in forward else 'unsupported'
    users=[]
    if r['credentials']:
        users=[c['username'] for c in toml_loads(read(r['credentials'],r['ownerUid']).decode()).get('client',[])]
    return dict(id=rid,name=r['unit'],source='systemd',active=r['active'],fingerprint=fingerprint,
        settings=r['settings'],hostsPath=r['hosts'],users=users,
        values=dict(listen=listen,port=port,quic='quic' in vpn.get('listen_protocols',{}),
            ipv6=vpn.get('ipv6_available',True),allowPrivate=vpn.get('allow_private_network_connections',False),
            outbound=outbound,socksAddress=forward.get('socks5',{}).get('address','127.0.0.1:1080')),
        hosts=[dict(index=i,domain=h['hostname'],certificate=h['cert_chain_path'],privateKey=h['private_key_path'])
            for i,h in enumerate(hosts.get('main_hosts',[]))])


def discovery():
    result=[];issues=[]
    found=definitions(issues)
    for r in found:
        try: result.append(public_snapshot(r['id'],found))
        except (TtError,OSError,ValueError,KeyError) as e:
            issues.append(dict(name=r['unit'],code=e.code if isinstance(e,TtError) else 'tt_invalid'))
    return dict(resources=result,issues=issues)


def write_existing(path, data, owner):
    """Replace only the selected file, retaining its owner, group and mode."""
    with file_lock(path):
        replace_preserving(safe_path(path,owner_uid=owner),data)


def decode(req):
    p=json.loads(req['payload'])
    if type(p) is not dict or set(p)!={'resourceId','observedHash','changes'}: raise TtError()
    identifier(p['resourceId'])
    if not re.fullmatch('[a-f0-9]{64}',p['observedHash']): raise TtError()
    c=p['changes']
    if type(c) is not dict or set(c)!={'listen','port','quic','ipv6','allowPrivate','outbound','socksAddress','hostIndex','domain','certificateId'}: raise TtError()
    ip(c['listen'],wildcard=True);domain(c['domain'])
    for k in ('quic','ipv6','allowPrivate'):
        if type(c[k]) is not bool: raise TtError()
    if type(c['port']) is not int or not 1<=c['port']<=65535: raise TtError()
    if type(c['hostIndex']) is not int or c['hostIndex']<0: raise TtError()
    if c['outbound'] not in ('direct','socks5'): raise TtError()
    if c['outbound']=='socks5': split_address(c['socksAddress'])
    if c['certificateId']: identifier(c['certificateId'])
    return p


def patched(p,r,vpn,hosts):
    c=p['changes'];v=copy.deepcopy(vpn);h=copy.deepcopy(hosts)
    if c['hostIndex']>=len(h.get('main_hosts',[])): raise TtError()
    v['listen_address']=address(c['listen'],c['port'])
    v['ipv6_available']=c['ipv6'];v['allow_private_network_connections']=c['allowPrivate']
    protocols=v.setdefault('listen_protocols',{})
    if c['quic']: protocols.setdefault('quic',{})
    else: protocols.pop('quic',None)
    if not protocols: raise TtError('tt_unsupported')
    forward=v.get('forward_protocol',{'direct':{}})
    if c['outbound']=='socks5':
        v['forward_protocol']={'socks5':{**forward.get('socks5',{}),'address':c['socksAddress']}}
    else: v['forward_protocol']={'direct':forward.get('direct',{})}
    host=h['main_hosts'][c['hostIndex']]
    host['hostname']=c['domain']
    if c['certificateId']:
        cert,key,cr=certificates.certificate_paths(c['certificateId'])
        if cr['domain']!=c['domain']: raise TtError('tt_certificate_invalid')
        host.update(cert_chain_path=cert,private_key_path=key)
    else:
        cert,key=[str(Path(host[k]) if Path(host[k]).is_absolute() else Path(r['base'])/host[k]) for k in ('cert_chain_path','private_key_path')]
    info=certificates.inspect_pair(cert,key,c['domain'])
    if not c['certificateId']:
        cid=digest([r['id'],c['hostIndex'],c['domain']])[:32]
        managed=certificates.path_for(cid)/'current'
        host.update(cert_chain_path=str(managed/'fullchain.pem'),private_key_path=str(managed/'privkey.pem'))
    if len({x['hostname'].lower() for x in h['main_hosts']})!=len(h['main_hosts']): raise TtError()
    same = r['active'] and v['listen_address']==vpn['listen_address']
    if not same and not available(c['listen'],c['port'],c['quic']): raise TtError('tt_port_busy')
    if same and c['quic'] and 'quic' not in vpn.get('listen_protocols',{}) and not available(c['listen'],c['port'],udp_only=True): raise TtError('tt_port_busy')
    if c['outbound']=='socks5': check_socks(c['socksAddress'])
    from client_egress import effective_forward
    effective_forward(v)
    return toml_bytes(v),toml_bytes(h),info


def prepare(req):
    p=decode(req)
    r,a,b,v,h,fingerprint=snapshot(p['resourceId'])
    if fingerprint!=p['observedHash']: raise TtError('tt_conflict')
    x,y,info=patched(p,r,v,h)
    preview=dict(fingerprint=digest(dict(payload=p,settings=x.decode(),hosts=y.decode(),certificate=info)),
        active=r['active'],restart=r['active'],preserveUsers=True,certificate=info)
    return r,a,b,h,x,y,info,preview


def plan(req):
    return prepare(req)[-1]


def link_for(r,c):
    return digest([r['id'],c['hostIndex']])[:32]


class ExternalTtEdit:
    def __init__(self,store,req):
        self.store,self.req,self.p=store,req,decode(req)
        self.backup=store.directory/('tt-external-'+req['id']+'.json')

    def step(self,checkpoint):
        with lock():
            p,req,db=self.p,self.req,self.store.db
            if checkpoint==0:
                r,a,b,h,x,y,info,preview=prepare(req)
                if preview['fingerprint']!=req['fingerprint']: raise TtError('tt_conflict')
                source=None
                c=p['changes']
                if not c['certificateId']:
                    host=h['main_hosts'][c['hostIndex']]
                    cert,key=[str(Path(host[k]) if Path(host[k]).is_absolute() else Path(r['base'])/host[k]) for k in ('cert_chain_path','private_key_path')]
                    cid=digest([r['id'],c['hostIndex'],c['domain']])[:32]
                    if certificates.record_path(cid).exists():
                        # Retain the original issuer paths on subsequent edits.
                        source=certificates.record(cid)['spec']
                    else:
                        source=dict(id=cid,domain=c['domain'],mode='files',listen=c['listen'],expectedIps=[],email='',certificate=cert,privateKey=key)
                if not self.backup.exists():
                    # Link records too: a failed edit restores the old bindings.
                    links=certificates.links_of(r['unit'],link_for(r,c))
                    atomic_file(self.backup,canonical(dict(resource=r,before=[a.decode(),b.decode()],after=[x.decode(),y.decode()],certificate=info,source=source,links=links)).encode())
                code='tt_preparing'
            else:
                backup=json.loads(read(self.backup))
                r,a,b,_,_,_=snapshot(p['resourceId'])
                if {k:v for k,v in r.items() if k!='active'}!={k:v for k,v in backup['resource'].items() if k!='active'} or any(raw.decode() not in (backup['before'][i],backup['after'][i]) for i,raw in enumerate((a,b))):
                    raise TtError('tt_conflict')
                r['active']=backup['resource']['active']
                if checkpoint==1:
                    source=backup.get('source')
                    if source:
                        old=certificates.record(source['id']) if certificates.record_path(source['id']).exists() else None
                        certificates.activate(source,old)
                        certificates.install_timer()
                    for file,raw in zip((r['settings'],r['hosts']),backup['after']): write_existing(Path(file),raw.encode(),r['ownerUid'])
                    from client_egress import remember_tt_forward
                    remember_tt_forward(r['settings'], toml_loads(backup['before'][0]).get('forward_protocol'))
                    c=p['changes']
                    cid=c['certificateId'] or source['id']
                    link=link_for(r,c)
                    certificates.unbind(link)
                    certificates.bind(cid,link,r['unit'],c['listen'],c['port'])
                    certificates.move_listener(r['unit'],c['listen'],c['port'])
                    if r['active']: run(['/usr/bin/systemctl','restart',r['unit']],timeout=60)
                    code='tt_restarting'
                else:
                    if [read(r['settings'],r['ownerUid']).decode(),read(r['hosts'],r['ownerUid']).decode()]!=backup['after']: raise TtError('tt_conflict')
                    if r['active']:
                        c=p['changes'];certificates.verify_service(r['unit'],c['listen'],c['port'],c['domain'],backup['certificate']['fingerprint'])
                    code='tt_checking'
            with db:
                db.execute('UPDATE jobs SET checkpoint=? WHERE id=?',(checkpoint+1,req['id']))
                self.store.event(req['id'],code,checkpoint+1,req['count'])

    def recover(self,checkpoint):
        """Put the inspected configuration, certificate links and service state
        back after a failed write, restart or verification. A file that is
        neither ours nor the original is left alone (None)."""
        if checkpoint<1 or not self.backup.exists(): return None
        with lock():
            backup=json.loads(read(self.backup))
            r,a,b,_,_,_=snapshot(self.p['resourceId'])
            if {k:v for k,v in r.items() if k!='active'}!={k:v for k,v in backup['resource'].items() if k!='active'}:
                return None
            current=[a.decode(),b.decode()]
            if any(raw not in (backup['before'][i],backup['after'][i]) for i,raw in enumerate(current)):
                return None
            for file,now,old in zip((r['settings'],r['hosts']),current,backup['before']):
                if now!=old: write_existing(Path(file),old.encode(),r['ownerUid'])
            if 'links' in backup:
                certificates.restore_links(r['unit'],link_for(r,self.p['changes']),backup['links'])
            if backup['resource']['active']:
                run(['/usr/bin/systemctl','restart',r['unit']],timeout=60)
                deadline=time.monotonic()+5
                while not active(r['unit']):
                    if time.monotonic()>=deadline: raise TtError('tt_restart_failed')
                    time.sleep(.2)
            if [read(r['settings'],r['ownerUid']).decode(),read(r['hosts'],r['ownerUid']).decode()]!=backup['before']:
                raise TtError('tt_failed')
            return 'failed'
