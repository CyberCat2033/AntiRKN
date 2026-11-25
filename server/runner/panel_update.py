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

from panel import (PANEL, DATABASE, CLI, UNIT, PanelInstaller, PanelError, atomic_copy,
                   atomic_file, command, digest, prerequisites, relogin_needed, run, safe_file,
                   sync_directory, systemctl)
from panel_api import PanelApi
from panel_update_release import UPDATE_RELEASE
from vless import VlessError, access_for_panel, canonical, digest as object_digest, normal, observed_fingerprint

VERSION_KEYS = ('panelVersion', 'xrayVersion')


def client(access):
    return PanelApi.from_access(access)


def configuration(api):
    return dict(settings=api.call('/panel/api/setting/all', {}),
        inbounds=sorted([normal(r) for r in api.call('/panel/api/inbounds/list')], key=lambda r: r['id']))


def versions(api):
    from panel_api import xray_status
    status = api.call('/panel/api/server/status')
    xray = xray_status(status)
    if xray.get('state') != 'running' or not isinstance(status.get('panelVersion'), str):
        raise PanelError('panel_api_failed')
    return dict(panelVersion=status['panelVersion'], xrayVersion=xray.get('version'))


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


def same_inbounds(before, after):
    """The inbounds survived, allowing only columns a newer panel adds with
    their default value (3.11: excludeFromSub=false)."""
    old = {row.get('id'): row for row in before}
    new = {row.get('id'): row for row in after}
    if len(old) != len(before) or len(new) != len(after) or set(old) != set(new):
        return False
    return all(observed_fingerprint(new[key], object_digest(row)) == object_digest(row)
               for key, row in old.items())


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


def snapshot(store, panel_id, api=None):
    if api is None:
        api = client(access_for_panel(store, panel_id))
    current = versions(api)
    files = layout()
    # Confirm that the running API matches the executables being replaced.
    xui_ver = command([str(PANEL / 'x-ui'), '-v']).decode().strip()
    pv = current['panelVersion'].strip()
    if xui_ver != pv and xui_ver.lstrip('v') != pv.lstrip('v'):
        raise PanelError('panel_conflict')
    xray_bin = PANEL / 'bin/xray-linux-amd64'
    if not xray_bin.exists() and (PANEL / 'bin/xray-linux-arm64').exists():
        xray_bin = PANEL / 'bin/xray-linux-arm64'
    xray_out = command([str(xray_bin), 'version']).decode()
    xv = current['xrayVersion'].strip().lstrip('v')
    if not (xray_out.startswith('Xray ' + current['xrayVersion'] + ' ') or ('Xray ' + xv) in xray_out):
        raise PanelError('panel_conflict')
    return dict(panelId=panel_id, **current, files=files, configuration=configuration(api),
                release=object_digest(UPDATE_RELEASE))



def plan(store, panel_id, api=None):
    missing = prerequisites()
    if shutil.disk_usage('/var/lib').free < 1024 * 1024 * 1024:
        missing.append('disk_space')
    state, current = 'incompatible', {}
    try:
        current = snapshot(store, panel_id, api)
        old, core = current['panelVersion'], current['xrayVersion']
        old_ver, core_ver = semver(old), semver(core)
        target_panel_ver = semver(UPDATE_RELEASE['panelVersion'])
        target_xray_ver = semver(UPDATE_RELEASE['xrayVersion'])
        panel_supported = (3, 7, 0) <= old_ver <= (3, 11, 99) or old in UPDATE_RELEASE.get('supportedPanels', [])
        # Never a downgrade: a panel or core newer than the target stays as it is.
        if panel_supported and old_ver <= target_panel_ver and core_ver <= target_xray_ver:
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


def ownership(path):
    try:
        meta = path.lstat()
    except FileNotFoundError:
        return None
    return [stat.S_IMODE(meta.st_mode), meta.st_uid, meta.st_gid]


class PanelUpdate(PanelInstaller):
    """Six checkpoints: plan, download, unpack, backup, switch, verify.

    A failure or cancellation after the switch started restores the recorded
    files, database and Xray config (with their owner and mode), starts the
    old panel and checks it. The job then ends 'failed' (or 'cancelled'), or
    'needs_attention' when the restore itself could not be confirmed."""
    release = UPDATE_RELEASE

    def __init__(self, store, request):
        self.store, self.request = store, request
        self.directory = store.directory / ('panel-update-' + request['id'])
        self.record = self.directory / 'snapshot.json'
        self.started = self.directory / 'switch-started'
        self.rolling_back = self.directory / 'rollback-started'
        self.rolled_back = None  # True/False once abort() attempted a restore.
        self._api = None

    @property
    def target_files(self):
        return {**self.release['files'], **self.release['coreArchive']['files']}

    def session(self):
        """One login per step; waiting loops log in again only after a rejection."""
        if self._api is None:
            try:
                access = access_for_panel(self.store, self.request['panelId'])
            except VlessError:
                raise PanelError('panel_conflict') from None
            self._api = client(access)
        return self._api

    SETTLE_SECONDS = 90

    def settle(self, check):
        """Retry check(api) until it passes; raise the last PanelError code."""
        deadline = time.monotonic() + self.SETTLE_SECONDS
        code = 'panel_api_failed'
        while True:
            pause = 1
            try:
                return check(self.session())
            except (OSError, ValueError, PanelError, subprocess.SubprocessError) as error:
                if isinstance(error, PanelError):
                    code = error.code
                if relogin_needed(error):
                    self._api = None
                    pause = 5  # Never hammer 3x-ui's login limiter.
            if time.monotonic() >= deadline:
                raise PanelError(code)
            time.sleep(pause)

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
                    atomic_copy(candidate, archive)
                    break
        core.download()

    def unpack_pair(self):
        self.unpack(self.directory / 'release.tar.gz')
        core = self.core_installer()
        extracted = core.unpack(core.directory / 'release.tar.gz')
        for name in core.release['files']:
            atomic_copy(extracted / name, self.directory / 'extracted' / name, 0o755)

    def read(self):
        safe_file(self.record, 8 * 1024 * 1024)
        return json.loads(self.record.read_text())

    def same_snapshot(self):
        old = self.read()
        if snapshot(self.store, self.request['panelId'], self.session()) != old:
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
        result = run([str(binary), 'run', '-test', '-config', str(config)], timeout=60, capture=False,
            cwd=str(PANEL), env={'PATH': '/usr/bin:/bin', 'XRAY_LOCATION_ASSET': str(PANEL / 'bin')})
        if result.returncode: raise PanelError('panel_api_failed')

    def backup(self):
        old = self.same_snapshot()
        backup = self.directory / 'backup'
        backup.mkdir(mode=0o700, exist_ok=True)
        for index, (name, expected) in enumerate(old['files'].items()):
            if expected is None: continue
            target = backup / str(index)
            if target.is_file() and digest(target) == expected: continue
            atomic_copy(Path(name), target)
            if digest(target) != expected: raise PanelError('panel_conflict')
        atomic_file(backup / 'files.json', canonical(old['files']).encode())
        self.validate_core()
        self.same_snapshot()

    def destinations(self, old):
        destinations = {str(PANEL / n): n for n in self.release['files']}
        # Preserve an administrator's custom menu. Upgrade the official copy only.
        if old['files'][str(CLI)] is None or old['files'][str(CLI)] == old['files'].get(str(PANEL / 'x-ui.sh')):
            destinations[str(CLI)] = 'x-ui.sh'
        return destinations

    @staticmethod
    def current_digest(name):
        path = Path(name)
        if not (path.exists() or path.is_symlink()):
            return None
        safe_file(path, 200 * 1024 * 1024)
        return digest(path)

    def switch(self):
        old = self.read()
        destinations = self.destinations(old)
        if not self.started.exists():
            self.same_snapshot()
            atomic_file(self.started, b'1')
        # A crash between replacements is recoverable: each destination must be
        # exactly the recorded old file or the pinned new file before continuing.
        for name, expected in old['files'].items():
            acceptable = {expected}
            if name in destinations: acceptable.add(self.target_files[destinations[name]])
            if self.current_digest(name) not in acceptable: raise PanelError('panel_conflict')
        for name, relative in destinations.items():
            source = self.directory / 'extracted' / relative
            safe_file(source, 200 * 1024 * 1024)
            if digest(source) != self.target_files[relative]: raise PanelError('panel_checksum_failed')
        systemctl('stop', 'x-ui.service')
        try:
            # Service is stopped: preserve a consistent, unmigrated DB exactly
            # once. The DB copy comes last: its presence means the set is complete.
            backup = self.directory / 'backup'
            db_backup = backup / 'x-ui.db'
            if not db_backup.exists():
                database, config = DATABASE / 'x-ui.db', PANEL / 'bin/config.json'
                atomic_file(backup / 'meta.json', canonical({str(path): ownership(path) for path in
                    [Path(n) for n in destinations] + [database, config]}).encode())
                atomic_copy(config, backup / 'config.json')
                temp = backup / 'x-ui.db.antirkn-tmp'
                temp.unlink(missing_ok=True)
                source = sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=10)
                target = sqlite3.connect(str(temp))
                try: source.backup(target)
                finally: target.close(); source.close()
                os.chmod(str(temp), 0o600)
                with temp.open('rb') as stream:
                    os.fsync(stream.fileno())
                os.replace(str(temp), str(db_backup))
                sync_directory(backup)
            for name, relative in destinations.items():
                atomic_copy(self.directory / 'extracted' / relative, Path(name), 0o755)
        finally:
            # Cancellation is observed only outside this stop/replace/start section.
            systemctl('start', 'x-ui.service')

    def survived(self, api, old, expected):
        """The panel answers with the expected versions and the recorded
        inbounds and settings (a newer release may add, never drop or change)."""
        if versions(api) != expected:
            raise ValueError('pending')
        config = configuration(api)
        if not same_inbounds(old['configuration']['inbounds'], config['inbounds']):
            raise PanelError('panel_conflict')
        if any(config['settings'].get(k) != v for k, v in old['configuration']['settings'].items()):
            raise PanelError('panel_conflict')

    def verify(self):
        old = self.read()
        target = {k: self.release[k] for k in VERSION_KEYS}

        def check(api):
            self.survived(api, old, target)
            for name, expected in self.target_files.items():
                if digest(PANEL / name) != expected: raise PanelError('panel_conflict')
            systemctl('is-active', '--quiet', 'x-ui.service')

        self.settle(check)
        access = access_for_panel(self.store, self.request['panelId'])
        from panel_discovery import EXTERNAL_ACCESS, external_access
        external = external_access()
        if external and external['port'] == access['port']:
            external.update(target)
            atomic_file(EXTERNAL_ACCESS, canonical(external).encode())
        # Original install identity/credentials remain stable after the upgrade.
        marker = DATABASE / '.antirkn-owner'
        if marker.exists():
            safe_file(marker, 32)
            atomic_file(DATABASE / '.antirkn-versions', canonical(dict(id=marker.read_text(), **target)).encode())

    def restore(self):
        """Put the recorded panel back. Idempotent: a crash midway resumes it."""
        old = self.read()
        backup = self.directory / 'backup'
        destinations = self.destinations(old)
        index = {name: number for number, name in enumerate(old['files'])}
        meta = {}
        if (backup / 'meta.json').exists():
            safe_file(backup / 'meta.json')
            meta = json.loads((backup / 'meta.json').read_text())
        # Never overwrite what is neither ours nor the original (an
        # administrator's change): that needs a person.
        for name, relative in destinations.items():
            if self.current_digest(name) not in (old['files'][name], self.target_files[relative]):
                raise PanelError('panel_conflict')
            if old['files'][name] is not None and digest(backup / str(index[name])) != old['files'][name]:
                raise PanelError('panel_conflict')
        atomic_file(self.rolling_back, b'1')
        systemctl('stop', 'x-ui.service')
        try:
            for name in destinations:
                path = Path(name)
                if old['files'][name] is None:
                    path.unlink(missing_ok=True)
                elif self.current_digest(name) != old['files'][name]:
                    self.put_back(backup / str(index[name]), path, meta, 0o755)
            if (backup / 'x-ui.db').exists():
                # A journal of the migrated DB must never be replayed onto the old one.
                for suffix in ('-wal', '-shm', '-journal'):
                    (DATABASE / ('x-ui.db' + suffix)).unlink(missing_ok=True)
                self.put_back(backup / 'x-ui.db', DATABASE / 'x-ui.db', meta, 0o600)
            if (backup / 'config.json').exists():
                self.put_back(backup / 'config.json', PANEL / 'bin/config.json', meta, 0o600)
        finally:
            systemctl('start', 'x-ui.service')
        expected = {k: old[k] for k in VERSION_KEYS}

        def check(api):
            self.survived(api, old, expected)
            for name in destinations:
                if self.current_digest(name) != old['files'][name]: raise PanelError('panel_conflict')
            systemctl('is-active', '--quiet', 'x-ui.service')

        self.settle(check)
        # The recorded panel runs again. A retry takes fresh backups: this DB
        # copy must never be restored over changes made after today.
        for name in ('x-ui.db', 'config.json', 'meta.json'):
            (backup / name).unlink(missing_ok=True)
        self.started.unlink(missing_ok=True)
        self.rolling_back.unlink(missing_ok=True)

    @staticmethod
    def put_back(source, path, meta, default_mode):
        recorded = meta.get(str(path))
        if recorded:
            mode, owner = recorded[0], (recorded[1], recorded[2])
        else:
            # A job started by an older runner has no record: keep what the
            # path has now (the replacement took the original's place).
            current = ownership(path)
            mode, owner = (current[0], (current[1], current[2])) if current else (default_mode, None)
        atomic_copy(source, path, mode, owner)

    def step(self, checkpoint):
        codes = ['panel_update_preparing', 'panel_downloading', 'panel_extracting',
                 'panel_update_backup', 'panel_update_switching', 'panel_checking']
        if self.rolling_back.exists():
            # A restore was interrupted: finish it (abort()), never the update.
            raise PanelError('panel_partial')
        with self.store.db:
            self.store.event(self.request['id'], codes[checkpoint], checkpoint, 6)
        if checkpoint == 0:
            api = self.session()
            current = plan(self.store, self.request['panelId'], api)
            if current['state'] != 'update': raise PanelError('panel_update_incompatible')
            if not current['supported']: raise PanelError('panel_prerequisites')
            if current['fingerprint'] != self.request['fingerprint']: raise PanelError('panel_conflict')
            observed = snapshot(self.store, self.request['panelId'], api)
            if object_digest(dict(snapshot=observed, prerequisites=current['prerequisites'])) != current['fingerprint']:
                raise PanelError('panel_conflict')
            self.directory.mkdir(mode=0o700, exist_ok=True)
            atomic_file(self.record, canonical(observed).encode())
        elif checkpoint == 1: self.download()
        elif checkpoint == 2: self.unpack_pair()
        elif checkpoint == 3: self.backup()
        elif checkpoint == 4: self.switch()
        elif checkpoint == 5:
            if not self.started.exists():
                # A retry after an automatic rollback switches again from fresh backups.
                self.backup()
                self.switch()
            self.verify()
        self.checkpoint(checkpoint + 1, codes[checkpoint])

    def abort(self):
        if not self.started.exists() and not self.rolling_back.exists():
            return 'cancelled'
        try:
            self.restore()
        except (PanelError, OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError):
            self.rolled_back = False
            return 'needs_attention'
        self.rolled_back = True
        # Nothing of the update remains; the worker reports a failure as 'failed'.
        return 'cancelled'

    def finished(self):
        """After success the backups (a full DB copy, the Xray config with its
        keys, the panel settings in the snapshot) are of no further use."""
        shutil.rmtree(str(self.directory), ignore_errors=True)
