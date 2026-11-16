"""Pinned 3x-ui/Xray upgrades; retain panel ownership of DB/configuration.

Only standard systemd/SQLite installations are admitted. Private snapshots and
backups stay in the root-only job directory. No downloaded scripts are executed.
"""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import time

from panel import (PANEL, DATABASE, CLI, UNIT, PanelInstaller, PanelError,
                   atomic_file, command, digest, prerequisites, safe_file, systemctl)
from panel_api import PanelApi
from panel_update_release import UPDATE_RELEASE
from vless import access_for_panel, canonical, digest as object_digest, normal


def client(access):
    api = PanelApi(access['port'], access.get('basePath', '/'), tls=access.get('tls', False),
        certificate=access.get('certificate'), host=access.get('host', '127.0.0.1'))
    api.login(access['username'], access['password'])
    return api


def configuration(api):
    return dict(settings=api.call('/panel/api/setting/all', {}),
        inbounds=sorted([normal(r) for r in api.call('/panel/api/inbounds/list')], key=lambda r: r['id']))


def versions(api):
    status = api.call('/panel/api/server/status')
    if status.get('xray', {}).get('state') != 'running':
        raise PanelError('panel_api_failed')
    return dict(panelVersion=status['panelVersion'], xrayVersion=status['xray']['version'])


def semver(value):
    if not isinstance(value, str):
        raise PanelError('panel_update_incompatible')
    s = value.strip()
    if s.startswith(('v', 'V')):
        s = s[1:]
    s = s.split('-')[0].split('+')[0]
    parts = s.split('.')
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        raise PanelError('panel_update_incompatible')
    if not nums:
        raise PanelError('panel_update_incompatible')
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums)


def version(value):
    return semver(value)


def layout():
    for path in (PANEL, PANEL / 'bin', DATABASE):
        meta = path.lstat()
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != 0 or meta.st_mode & 0o022:
            raise PanelError('panel_update_incompatible')
    safe_file(DATABASE / 'x-ui.db', 512 * 1024 * 1024)
    # No Docker, custom DB/bin folder, wrapper, PostgreSQL or alternate service.
    props = systemctl('show', 'x-ui.service', '--property=ExecStart,Environment,EnvironmentFiles,FragmentPath,DropInPaths,WorkingDirectory').decode()
    values = dict(line.split('=', 1) for line in props.splitlines() if '=' in line)
    if ('path=/usr/local/x-ui/x-ui ;' not in values.get('ExecStart', '')
            or 'argv[]=/usr/local/x-ui/x-ui ;' not in values.get('ExecStart', '')
            or values.get('DropInPaths')
            or values.get('FragmentPath') != str(UNIT)
            or values.get('WorkingDirectory', '').rstrip('/') != str(PANEL)):
        raise PanelError('panel_update_incompatible')
    import shlex
    allowed = {'XUI_DB_FOLDER': {str(DATABASE)}, 'XUI_BIN_FOLDER': {str(PANEL / 'bin')},
               'XUI_LOG_FOLDER': {str(DATABASE / 'logs'), '/var/log/x-ui'},
               'XUI_ENABLE_FAIL2BAN': {'true', 'false'}, 'XRAY_VMESS_AEAD_FORCED': {'false'},
               'XUI_DB_TYPE': {'sqlite'}}
    env_files = values.get('EnvironmentFiles', '')
    environment = shlex.split(values.get('Environment', ''))
    result = {str(UNIT): digest(UNIT)}
    if env_files:
        if env_files != '/etc/default/x-ui (ignore_errors=yes)':
            raise PanelError('panel_update_incompatible')
        env_path = Path('/etc/default/x-ui')
        result[str(env_path)] = None
        if env_path.exists() or env_path.is_symlink():
            safe_file(env_path)
            result[str(env_path)] = digest(env_path)
            for line in env_path.read_text().splitlines():
                if line.strip() and not line.lstrip().startswith('#'):
                    environment.extend(shlex.split(line))
    for entry in environment:
        key, _, value = entry.partition('=')
        if key not in allowed or value.rstrip('/') not in allowed[key]:
            raise PanelError('panel_update_incompatible')
    safe_file(UNIT)
    systemctl('is-active', '--quiet', 'x-ui.service')
    result[str(UNIT)] = digest(UNIT)
    for name in UPDATE_RELEASE['files']:
        path = PANEL / name
        if not path.exists() and name == 'x-ui.sh':
            result[str(path)] = None
        else:
            safe_file(path, 200 * 1024 * 1024)
            result[str(path)] = digest(path)
    if CLI.exists() or CLI.is_symlink():
        safe_file(CLI)
        result[str(CLI)] = digest(CLI)
    else:
        result[str(CLI)] = None
    return result


def snapshot(store, panel_id):
    access = access_for_panel(store, panel_id)
    api = client(access)
    current = versions(api)
    files = layout()
    # Confirm that the running API matches the executables being replaced.
    if command([str(PANEL / 'x-ui'), '-v']).decode().strip() != current['panelVersion']:
        raise PanelError('panel_conflict')
    if not command([str(PANEL / 'bin/xray-linux-amd64'), 'version']).decode().startswith('Xray ' + current['xrayVersion'] + ' '):
        raise PanelError('panel_conflict')
    return dict(panelId=panel_id, **current, files=files, configuration=configuration(api),
                release=object_digest(UPDATE_RELEASE))


def plan(store, panel_id):
    missing = prerequisites()
    if shutil.disk_usage('/var/lib').free < 1024 * 1024 * 1024:
        missing.append('disk_space')
    state, current = 'incompatible', {}
    try:
        current = snapshot(store, panel_id)
        old, core = current['panelVersion'], current['xrayVersion']
        old_ver, core_ver = semver(old), semver(core)
        target_panel_ver = semver(UPDATE_RELEASE['panelVersion'])
        target_xray_ver = semver(UPDATE_RELEASE['xrayVersion'])
        panel_supported = (3, 7, 0) <= old_ver <= (3, 11, 99) or old in UPDATE_RELEASE.get('supportedPanels', [])
        if panel_supported and core_ver <= target_xray_ver:
            state = 'update' if (old_ver != target_panel_ver or core_ver != target_xray_ver) else 'current'
    except PanelError as error:
        if error.code != 'panel_update_incompatible': raise
    return dict(state=state, supported=not missing, prerequisites=missing,
        panelId=panel_id, installedPanelVersion=current.get('panelVersion'),
        installedXrayVersion=current.get('xrayVersion'),
        panelVersion=UPDATE_RELEASE['panelVersion'], xrayVersion=UPDATE_RELEASE['xrayVersion'],
        url=UPDATE_RELEASE['url'], sha256=UPDATE_RELEASE['sha256'], bytes=UPDATE_RELEASE['bytes'] + UPDATE_RELEASE['coreArchive']['bytes'],
        fingerprint=object_digest(dict(snapshot=current, prerequisites=missing)),
        coreUrl=UPDATE_RELEASE['coreArchive']['url'], coreSha256=UPDATE_RELEASE['coreArchive']['sha256'],
        paths=[str(PANEL / n) for n in UPDATE_RELEASE['files']] + [str(CLI)],
        backupRoot=str(store.directory))


class PanelUpdate(PanelInstaller):
    release = UPDATE_RELEASE

    def __init__(self, store, request):
        self.store, self.request = store, request
        self.directory = store.directory / ('panel-update-' + request['id'])
        self.record = self.directory / 'snapshot.json'
        self.started = self.directory / 'switch-started'

    @property
    def target_files(self):
        return {**self.release['files'], **self.release['coreArchive']['files']}

    def core_installer(self):
        core = PanelInstaller(self.store, self.request)
        core.directory = self.directory / 'core'
        core.directory.mkdir(mode=0o700, exist_ok=True)
        core.release = self.release['coreArchive']
        return core

    def download(self):
        super().download()
        core = self.core_installer()
        archive = core.directory / 'release.tar.gz'
        # Reuse only a checksum-verified original installation archive.
        if not archive.exists():
            for candidate in self.store.directory.glob('panel-*/release.tar.gz'):
                if candidate.stat().st_size != core.release['bytes']: continue
                safe_file(candidate, core.release['bytes'])
                if digest(candidate) == core.release['sha256']:
                    atomic_file(archive, candidate.read_bytes())
                    break
        core.download()

    def unpack_pair(self):
        self.unpack(self.directory / 'release.tar.gz')
        core = self.core_installer()
        extracted = core.unpack(core.directory / 'release.tar.gz')
        for name in core.release['files']:
            atomic_file(self.directory / 'extracted' / name, (extracted / name).read_bytes(), 0o755)

    def read(self):
        safe_file(self.record, 8 * 1024 * 1024)
        return json.loads(self.record.read_text())

    def same_snapshot(self):
        old = self.read()
        if snapshot(self.store, self.request['panelId']) != old:
            raise PanelError('panel_conflict')
        return old

    def validate_core(self):
        binary = self.directory / 'extracted/bin/xray-linux-amd64'
        safe_file(binary, 200 * 1024 * 1024)
        if digest(binary) != self.target_files['bin/xray-linux-amd64']:
            raise PanelError('panel_checksum_failed')
        # Native validation uses the existing geo data and the panel's generated config.
        config = PANEL / 'bin/config.json'
        safe_file(config, 16 * 1024 * 1024)
        result = subprocess.run([str(binary), 'run', '-test', '-config', str(config)],
            cwd=str(PANEL), env={'PATH': '/usr/bin:/bin', 'XRAY_LOCATION_ASSET': str(PANEL / 'bin')},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if result.returncode: raise PanelError('panel_api_failed')

    def backup(self):
        old = self.same_snapshot()
        backup = self.directory / 'backup'
        backup.mkdir(mode=0o700, exist_ok=True)
        for index, (name, expected) in enumerate(old['files'].items()):
            if expected is None: continue
            data = Path(name).read_bytes()
            if object_digest_bytes(data) != expected: raise PanelError('panel_conflict')
            atomic_file(backup / str(index), data)
        atomic_file(backup / 'files.json', canonical(old['files']).encode())
        self.validate_core()
        self.same_snapshot()

    def switch(self):
        old = self.read()
        destinations = {str(PANEL / n): n for n in self.release['files']}
        # Preserve an administrator's custom menu. Upgrade the official copy only.
        if old['files'][str(CLI)] is None or old['files'][str(CLI)] == old['files'].get(str(PANEL / 'x-ui.sh')):
            destinations[str(CLI)] = 'x-ui.sh'
        if not self.started.exists():
            self.same_snapshot()
            atomic_file(self.started, b'1')
        # A crash between replacements is recoverable: each destination must be
        # exactly the recorded old file or the pinned new file before continuing.
        for name, expected in old['files'].items():
            path = Path(name)
            if path.exists() or path.is_symlink():
                safe_file(path, 200 * 1024 * 1024)
                actual = digest(path)
            else: actual = None
            acceptable = {expected}
            if name in destinations: acceptable.add(self.target_files[destinations[name]])
            if actual not in acceptable: raise PanelError('panel_conflict')
        for name, relative in destinations.items():
            source = self.directory / 'extracted' / relative
            safe_file(source, 200 * 1024 * 1024)
            if digest(source) != self.target_files[relative]: raise PanelError('panel_checksum_failed')
        systemctl('stop', 'x-ui.service')
        try:
            # Service is stopped: preserve a consistent, unmigrated DB exactly once.
            db_backup = self.directory / 'backup/x-ui.db'
            if not db_backup.exists():
                source = sqlite3.connect((DATABASE / 'x-ui.db').as_uri() + '?mode=ro', uri=True)
                temp = db_backup.with_suffix('.tmp')
                target = sqlite3.connect(str(temp))
                try: source.backup(target)
                finally: target.close(); source.close()
                atomic_file(db_backup, temp.read_bytes())
                temp.unlink()
                config = PANEL / 'bin/config.json'
                atomic_file(self.directory / 'backup/config.json', config.read_bytes())
            for name, relative in destinations.items():
                atomic_file(Path(name), (self.directory / 'extracted' / relative).read_bytes(), 0o755)
        finally:
            # Cancellation is observed only outside this stop/replace/start section.
            systemctl('start', 'x-ui.service')

    def verify(self):
        old = self.read()
        access = access_for_panel(self.store, self.request['panelId'])
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            self.pulse()
            try:
                api = client(access)
                actual = versions(api)
                if actual != {k: self.release[k] for k in ('panelVersion', 'xrayVersion')}:
                    raise ValueError('pending')
                config = configuration(api)
                if config['inbounds'] != old['configuration']['inbounds']:
                    raise PanelError('panel_conflict')
                # New releases may add settings; every existing value must survive.
                if any(config['settings'].get(k) != v for k, v in old['configuration']['settings'].items()):
                    raise PanelError('panel_conflict')
                for name, expected in self.target_files.items():
                    if digest(PANEL / name) != expected: raise PanelError('panel_conflict')
                systemctl('is-active', '--quiet', 'x-ui.service')
                from panel_discovery import EXTERNAL_ACCESS, external_access
                external = external_access()
                if external and external['port'] == access['port']:
                    external.update(actual)
                    atomic_file(EXTERNAL_ACCESS, canonical(external).encode())
                # Original install identity/credentials remain stable after the upgrade.
                marker = DATABASE / '.antirkn-owner'
                if marker.exists():
                    safe_file(marker, 32)
                    atomic_file(DATABASE / '.antirkn-versions', canonical(dict(id=marker.read_text(), **actual)).encode())
                return
            except (OSError, ValueError, subprocess.SubprocessError):
                time.sleep(1)
        raise PanelError('panel_api_failed')

    def step(self, checkpoint):
        codes = ['panel_update_preparing', 'panel_downloading', 'panel_extracting',
                 'panel_update_backup', 'panel_update_switching', 'panel_checking']
        with self.store.db:
            self.store.event(self.request['id'], codes[checkpoint], checkpoint, 6)
        if checkpoint == 0:
            current = plan(self.store, self.request['panelId'])
            if current['state'] != 'update': raise PanelError('panel_update_incompatible')
            if not current['supported']: raise PanelError('panel_prerequisites')
            if current['fingerprint'] != self.request['fingerprint']: raise PanelError('panel_conflict')
            observed = snapshot(self.store, self.request['panelId'])
            if object_digest(dict(snapshot=observed, prerequisites=current['prerequisites'])) != current['fingerprint']:
                raise PanelError('panel_conflict')
            self.directory.mkdir(mode=0o700, exist_ok=True)
            atomic_file(self.record, canonical(observed).encode())
        elif checkpoint == 1: self.download()
        elif checkpoint == 2: self.unpack_pair()
        elif checkpoint == 3: self.backup()
        elif checkpoint == 4: self.switch()
        elif checkpoint == 5: self.verify()
        self.checkpoint(checkpoint + 1, codes[checkpoint])

    def abort(self):
        return 'partially_applied' if self.started.exists() else 'cancelled'


def object_digest_bytes(data):
    import hashlib
    return hashlib.sha256(data).hexdigest()
