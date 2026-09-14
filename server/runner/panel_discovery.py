"""Read existing panel configuration without changing its DB, users or service.

Only public connection settings and inbound summaries leave this module. Admin
credentials are recovered solely for a verified installation owned by our runner.
"""
import json
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess

from panel import CLI, DATABASE, PanelInstaller, PanelError, access_for, safe_file


def databases():
    candidates = [(DATABASE / 'x-ui.db', 'systemd')]
    # Respect the standard service override instead of assuming the default DB.
    try:
        env = subprocess.check_output(['/usr/bin/systemctl', 'show', 'x-ui.service',
            '--property=Environment', '--value'], timeout=10, stderr=subprocess.DEVNULL).decode()
        match = re.search(r'(?:^|\s)XUI_DB_FOLDER=(/[^\s"\x00]+)', env)
        if match:
            candidates.insert(0, (Path(match[1]) / 'x-ui.db', 'systemd'))
    except (OSError, subprocess.SubprocessError):
        pass
    docker = shutil.which('docker')
    if docker:
        try:
            ids = subprocess.check_output([docker, 'ps', '-aq', '--no-trunc'], timeout=15,
                stderr=subprocess.DEVNULL).decode().split()
            for cid in ids[:64]:
                if not re.fullmatch('[a-f0-9]{64}', cid): continue
                raw = subprocess.check_output([docker, 'inspect', cid], timeout=10,
                    stderr=subprocess.DEVNULL)
                if len(raw) > 1024 * 1024: continue
                obj = json.loads(raw)[0]
                if not any(s in (obj.get('Config', {}).get('Image', '') + obj.get('Name', '')).lower()
                           for s in ('3x-ui', '3xui', 'x-ui')): continue
                for mount in obj.get('Mounts', []):
                    if mount.get('Destination') == '/etc/x-ui':
                        candidates.append((Path(mount['Source']) / 'x-ui.db', 'docker'))
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return list(dict.fromkeys(candidates))


def read_database(path, source):
    safe_file(path, 512 * 1024 * 1024)
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=3)
    db.row_factory = sqlite3.Row
    try:
        db.execute('PRAGMA query_only=ON')
        db.execute('BEGIN')
        settings = dict(db.execute("SELECT key, value FROM settings WHERE key IN "
            "('webPort','webListen','webBasePath','webCertFile','webKeyFile')"))
        port = int(settings.get('webPort', '2053'))
        if not 1 <= port <= 65535: raise ValueError('panel_port')
        inbounds = []
        rows = db.execute('SELECT id, remark, enable, listen, port, protocol, '
            'stream_settings FROM inbounds ORDER BY id LIMIT 1001').fetchall()
        if len(rows) > 1000: raise ValueError('panel_size')
        for row in rows:
            stream = json.loads(row['stream_settings'] or '{}')
            inbounds.append(dict(id=row['id'], name=str(row['remark'])[:256],
                enabled=bool(row['enable']), listen=row['listen'] or '0.0.0.0',
                port=row['port'], protocol=row['protocol'],
                transport=str(stream.get('network', 'tcp'))[:32],
                security=str(stream.get('security', 'none'))[:32]))
        return dict(source=source, port=port, listen=settings.get('webListen') or '0.0.0.0',
            basePath=settings.get('webBasePath') or '/',
            tls=bool(settings.get('webCertFile') and settings.get('webKeyFile')), inbounds=inbounds)
    finally:
        db.close()


def discover(store):
    panels, failed = [], False
    for path, source in databases():
        if not path.exists(): continue
        try:
            panels.append(read_database(path, source))
        except (OSError, ValueError, sqlite3.Error, PanelError):
            failed = True
    access = None
    # History selection is a UI concern, never the identity of the installed panel.
    for row in store.db.execute("SELECT request FROM jobs WHERE status='succeeded' ORDER BY created DESC"):
        request = json.loads(row[0])
        if request.get('kind') != 'panel_install': continue
        try:
            PanelInstaller(store, request).assert_owned()
            candidate = access_for(request['id'], request['port'])
            if any(p['source'] == 'systemd' and p['port'] == candidate['port']
                   and p['basePath'] == '/' and not p['tls'] for p in panels):
                access = candidate
                break
        except (OSError, ValueError, PanelError):
            continue
    return dict(panels=panels, failed=failed, cliAvailable=CLI.is_file() and bool(CLI.stat().st_mode & 0o111)), access
