#!/usr/bin/env python3
"""Reproduce SSH hardening audit findings without changing any server.

Uses temporary files, mocked administrative commands, sshd -T (no listener),
and one transient *user* systemd unit to verify watchdog self-termination.
Output describes observed defects, not successful security acceptance.
"""
import contextlib
import importlib.util
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('audit_harden', ROOT / 'server/runner/ssh_harden.py')
HARDEN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARDEN)
REAL_RUN = subprocess.run


class Store:
    def __init__(self):
        self.db = sqlite3.connect(':memory:')
        self.db.execute('CREATE TABLE jobs (id TEXT, status TEXT, checkpoint INTEGER)')
        self.db.execute("INSERT INTO jobs VALUES ('fixture', 'failed', 6)")

    def event(self, *args):
        pass


@contextlib.contextmanager
def sandbox(directory):
    def mapped_path(value):
        p = Path(value)
        if p.is_absolute() and p.parts[1] in ('etc', 'var', 'home', 'root'):
            return directory / p.relative_to('/')
        return p

    with contextlib.ExitStack() as stack:
        stack.enter_context(patch.object(HARDEN, 'Path', mapped_path))
        stack.enter_context(patch.object(HARDEN, 'BACKUP_DIR', directory / 'backups'))
        stack.enter_context(patch.object(HARDEN, 'CONFIRMED_DIR', directory / 'confirmed'))
        (directory / 'etc/ssh/sshd_config.d').mkdir(parents=True)
        (directory / 'etc/sudoers.d').mkdir(parents=True)
        yield


def fixture_info(job_id='fixture', **changes):
    info = dict(username='auditfixture', port=2222, old_port=22,
                socket_activation=False, disable_root=True, deadline=300,
                user_created=False, ufw_rule_added=False)
    info.update(changes)
    bdir = HARDEN.backup_path(job_id)
    bdir.mkdir(parents=True, exist_ok=True)
    (bdir / 'info.json').write_text(json.dumps(info))
    return bdir


def runner_probes(directory):
    with sandbox(directory), patch.object(HARDEN.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')):
        bdir = fixture_info()
        (bdir / 'rolled_back').touch()
        store = Store()
        with patch.object(HARDEN, 'reload_ssh_service'):
            result = HARDEN.SshHardenJob.confirm(store, {'id': 'fixture'})
        config = directory / 'etc/ssh/sshd_config.d/99-antirkn-harden.conf'
        findings = {
            'confirm_after_rollback': {
                'confirmed': result['confirmed'],
                'database_status': store.db.execute('SELECT status FROM jobs').fetchone()[0],
                'root_disabled_without_recreating_user': 'PermitRootLogin no' in config.read_text(),
            },
        }

        with patch.object(HARDEN, 'reload_ssh_service', side_effect=subprocess.CalledProcessError(1, 'fixture-restart')):
            try:
                HARDEN.SshHardenJob.confirm(store, {'id': 'fixture'})
            except subprocess.CalledProcessError:
                findings['restart_failure'] = {
                    'exception_escaped': True,
                    'confirmation_token_still_present': HARDEN.confirmed_token('fixture').exists(),
                    'final_config_still_present': 'PermitRootLogin no' in config.read_text(),
                }

        with patch.object(HARDEN, 'reload_ssh_service'):
            aborted = HARDEN.SshHardenJob.abort(store, {'id': 'fixture'})
        findings['abort_after_success'] = {
            'aborted': aborted['aborted'],
            'previously_committed_config_deleted': not config.exists(),
        }

        fixture_info(ufw_rule_added=True)
        (bdir / 'rolled_back').unlink(missing_ok=True)
        with patch.object(HARDEN, 'reload_ssh_service', side_effect=OSError('fixture-reload-failed')):
            findings['rollback_reload_failure'] = {
                'reports_success': HARDEN.rollback('fixture'),
                'rolled_back_marker_written': (bdir / 'rolled_back').exists(),
            }
        store.db.close()
        return findings


def sshd_probe(directory):
    directory.mkdir()
    key = directory / 'host_key'
    REAL_RUN(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    includes = directory / 'sshd_config.d'
    includes.mkdir()
    (includes / '50-existing.conf').write_text('PermitRootLogin yes\nPort 22\n')
    (includes / '99-antirkn-harden.conf').write_text('Port 2222\nPermitRootLogin no\n')
    config = directory / 'sshd_config'
    config.write_text(f'HostKey {key}\nInclude {includes}/*.conf\nUsePAM no\n')
    result = REAL_RUN([shutil.which('sshd'), '-T', '-f', str(config), '-C',
                       'user=root,host=fixture,addr=127.0.0.1'],
                      check=True, capture_output=True, text=True)
    effective = [line.lower() for line in result.stdout.splitlines()
                 if line.lower().startswith(('port ', 'permitrootlogin '))]
    if not effective:
        raise RuntimeError('sshd returned no effective port/root policy')
    return {'effective_configuration': effective,
            'root_still_allowed': 'permitrootlogin yes' in effective,
            'old_port_still_present': 'port 22' in effective}


def watchdog_child(directory, job_id):
    # Redirect only systemctl calls to the temporary USER service. All filesystem
    # paths are inside the supplied fixture; no system SSH/UFW/user commands run.
    def user_systemctl(command, **kwargs):
        if command[0] != '/usr/bin/systemctl':
            raise RuntimeError('Unexpected administrative command in fixture')
        return REAL_RUN([command[0], '--user', *command[1:]], **kwargs)

    with sandbox(directory):
        fixture_info(job_id)
        (directory / 'etc/ssh/sshd_config.d/99-antirkn-harden.conf').write_text('Port 2222\n')
        (directory / 'entered_watchdog').touch()
        with patch.object(HARDEN.subprocess, 'run', side_effect=user_systemctl):
            HARDEN.watchdog_loop(job_id, 0)


def watchdog_probe(directory):
    directory.mkdir()
    job_id = 'audit-' + uuid.uuid4().hex
    unit = f'antirkn-ssh-watchdog-{job_id}'
    try:
        result = REAL_RUN(['systemd-run', '--user', '--quiet', '--wait', '--pipe',
                           '--unit', unit, sys.executable, str(Path(__file__).resolve()),
                           '--watchdog-fixture', str(directory), job_id],
                          capture_output=True, text=True, timeout=20)
        entered = (directory / 'entered_watchdog').exists()
        if not entered:
            raise RuntimeError('The transient user watchdog fixture did not start')
        return {'entered_watchdog': entered,
                'unit_exit_code': result.returncode,
                'staged_config_still_present': (directory / 'etc/ssh/sshd_config.d/99-antirkn-harden.conf').exists(),
                'rollback_completed': (directory / 'backups' / f'ssh_{job_id}' / 'rolled_back').exists()}
    finally:
        REAL_RUN(['systemctl', '--user', 'stop', unit], capture_output=True, timeout=5)
        REAL_RUN(['systemctl', '--user', 'reset-failed', unit], capture_output=True, timeout=5)


def dart_probe():
    source = r'''
import 'dart:convert';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_ssh_transport/src/ssh_connector.dart';
Future<void> main() async {
  final profile = SshProfile(host: '127.0.0.1', port: 22,
    username: 'root', authMethod: SshAuthMethod.password,
    secrets: {ServerSecret.sshPassword: 'fixture-old'});
  final updated = profile.withHardenedAccess(user: 'auditfixture',
    port: 2222, sudoPassword: 'fixture-new');
  final jumpProfile = SshProfile(host: '127.0.0.1', port: 2222,
    username: 'auditfixture', authMethod: SshAuthMethod.password,
    jumpServerId: 'fixture-jump', secrets: updated.secrets);
  String? jumpIssue;
  try {
    final connection = await const DirectSshConnector().connect(jumpProfile,
      verifyHostKey: (_) async => false, cancellation: CancellationToken());
    connection.close();
  } on SshFailure catch (e) { jumpIssue = e.issue.name; }
  print(jsonEncode({
    'password_profile_keeps_old_ssh_password':
      updated.secrets[ServerSecret.sshPassword] == profile.secrets[ServerSecret.sshPassword],
    'ssh_and_new_account_password_differ':
      updated.secrets[ServerSecret.sshPassword] != updated.secrets[ServerSecret.sudoPassword],
    'wizard_style_connect_with_jump_profile': jumpIssue,
  }));
}
'''
    with tempfile.TemporaryDirectory(prefix='ssh-audit-', dir=ROOT / '.dart_tool') as temp:
        script = Path(temp) / 'probe.dart'
        script.write_text(source)
        result = REAL_RUN(['dart', 'run', str(script)], cwd=ROOT,
                          capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return json.loads(result.stdout)


def main():
    with tempfile.TemporaryDirectory(prefix='antirkn-ssh-audit-') as temp:
        directory = Path(temp)
        result = {
            'scope': 'isolated audit; no deployed server changed; findings are not acceptance',
            'source_commit': REAL_RUN(['git', 'rev-parse', 'HEAD'], cwd=ROOT, check=True,
                                      capture_output=True, text=True).stdout.strip(),
            'timestamp_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'runner': runner_probes(directory / 'runner'),
            'openssh': sshd_probe(directory / 'openssh'),
            'systemd_user_watchdog': watchdog_probe(directory / 'watchdog'),
            'dart': dart_probe(),
        }
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--watchdog-fixture':
        watchdog_child(Path(sys.argv[2]), sys.argv[3])
    else:
        main()
