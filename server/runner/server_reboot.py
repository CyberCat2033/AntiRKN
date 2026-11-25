"""Explicit, durable one-shot server reboot; recovery only observes a new boot."""
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import time
sys.path.insert(0,str(Path(__file__).resolve().parent))
from awg_network import open_lock
from panel import atomic_file,command,safe_file
BOOT=Path('/proc/sys/kernel/random/boot_id')

class RebootError(Exception):
    code='server_reboot_failed'

def record_path(store,key):
    if not re.fullmatch('[a-f0-9]{32}',key):raise RebootError()
    return store.directory/('reboot-'+key+'.json')
def save(path,value):atomic_file(path,json.dumps(value,sort_keys=True).encode())
def load(path):
    safe_file(path,4096)
    return json.loads(path.read_text())

def poll(store,req):
    path=record_path(store,req['id'])
    if not path.exists():save(path,dict(boot=BOOT.read_text().strip(),created=time.time(),issued=False))
    value=load(path)
    if value['boot']!=BOOT.read_text().strip():return True
    if value.get('failed') or time.time()-value['created']>180:raise RebootError()
    with store.db:
        if store.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running') AND id != ?",(req['id'],)).fetchone():
            return False
    if not value['issued']:
        unit='antirkn-reboot-'+req['id']
        try:command(['/usr/bin/systemctl','is-active','--quiet',unit+'.timer'])
        except Exception:
            # The executor checks the durable issued flag, so repeating an arm
            # after a lost response cannot cause a second reboot.
            command(['/usr/bin/systemd-run','--quiet','--collect','--unit='+unit,'--on-active=3s',
                     '--property=UMask=0077','/usr/bin/python3','-I',str(Path(__file__).resolve()),'execute',req['id']])
        with store.db:
            current=store.db.execute('SELECT checkpoint FROM jobs WHERE id=?',(req['id'],)).fetchone()[0]
            if current==0:
                store.db.execute('UPDATE jobs SET checkpoint=1 WHERE id=?',(req['id'],))
                store.event(req['id'],'server_reboot_waiting',1,2)
    return False

def execute(store,key):
    path=record_path(store,key)
    lock=open_lock(path.with_suffix('.lock'))  # No link/FIFO/foreign file.
    try:
        fcntl.flock(lock,fcntl.LOCK_EX)
        value=load(path)
        if value['issued'] or value['boot']!=BOOT.read_text().strip():return
        if not 0<=time.time()-value['created']<=180:raise RebootError()
        value['issued']=True;save(path,value)
        try:command(['/usr/bin/systemctl','reboot'])
        except Exception:
            value['failed']=True;save(path,value);raise RebootError() from None
    finally:os.close(lock)

if __name__=='__main__':
    try:
        if len(sys.argv)!=3 or sys.argv[1]!='execute' or os.geteuid()!=0:raise RebootError()
        from runner import Store,STATE
        store=Store(STATE)
        try:execute(store,sys.argv[2])
        finally:store.close()
    except Exception:raise SystemExit(1) from None
