#!/usr/bin/env python3
"""Destructive acceptance tests restricted to our newly-created disposable VM.

Set ANTIRKN_VM_DIRECTORY to a /tmp/antirkn-ssh-fix-vm-* fixture from runner_vm.py
with a host forward to guest port 2222 and the host port in new_port.
Credentials are read/generated privately and passed through stdin/askpass.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
VM = Path(os.environ['ANTIRKN_VM_DIRECTORY']).resolve()
if VM.parent != Path('/tmp') or not VM.name.startswith('antirkn-ssh-fix-vm-') or not (VM / 'ready').exists():
    raise SystemExit('This suite requires its own disposable SSH-fix VM')
OLD_PORT = int((VM / 'port').read_text())
NEW_PORT = int((VM / 'new_port').read_text())
PASSWORD = secrets.token_urlsafe(30)
RPC = '/usr/bin/python3 -I /usr/local/lib/antirkn-runner/v21/runner.py rpc'
SOURCE = (ROOT / 'packages/ssh_transport/lib/src/runner_bundle.g.dart').read_text()
BUNDLE = {key: re.search(r'const ' + key + r"\s*=\s*r'''(.*?)''';", SOURCE, re.S).group(1)
          for key in ('runnerBundle', 'runnerInspector', 'runnerInstaller')}
RESULTS = {}


def check(value, label):
    if not value:
        raise AssertionError(label)
    RESULTS[label] = True
    print('PASS: ' + label, flush=True)


def remote(command, data=b'', user='root', port=OLD_PORT, password_auth=False, check=True):
    public = (VM / 'host.pub').read_text().split()
    known = VM / 'hardening_known_hosts'
    known.write_text(''.join(f'[127.0.0.1]:{p} {public[0]} {public[1]}\n' for p in (OLD_PORT, NEW_PORT)))
    argv = ['ssh', '-T', '-i', str(VM / 'client'), '-o', 'IdentitiesOnly=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known}',
            '-o', 'ConnectTimeout=3', '-o', 'NumberOfPasswordPrompts=1',
            '-p', str(port)]
    env = dict(os.environ)
    if password_auth:
        secret = VM / 'hardening_password'
        secret.write_text(PASSWORD + '\n')
        secret.chmod(0o600)
        askpass = VM / 'hardening_askpass'
        askpass.write_text('#!/usr/bin/python3\nimport os\nfrom pathlib import Path\nprint(Path(os.environ["ANTIRKN_FIXTURE_PASSWORD_FILE"]).read_text(),end="")\n')
        askpass.chmod(0o700)
        env.update(SSH_ASKPASS=str(askpass), SSH_ASKPASS_REQUIRE='force', DISPLAY=':fixture',
                   ANTIRKN_FIXTURE_PASSWORD_FILE=str(secret))
        argv += ['-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=password']
    else:
        argv += ['-o', 'BatchMode=yes']
    result = subprocess.run(argv + [f'{user}@127.0.0.1', command], input=data,
                            capture_output=True, timeout=50, env=env)
    if check and result.returncode:
        # Do not include remote output/credentials in exceptions or evidence.
        raise RuntimeError('Disposable VM command failed: ' + command[:90])
    return result


def python_remote(source, data=b'', **kwargs):
    return remote('/usr/bin/python3 -I -c ' + shlex.quote(source), data, **kwargs)


def rpc(action, *, user='root', **fields):
    port = OLD_PORT if user == 'root' else NEW_PORT
    payload = json.dumps(dict(version=1, action=action, **fields)).encode()
    command = RPC
    if user != 'root':
        command = 'sudo -k -S -p "" -- ' + RPC
        payload = (PASSWORD + '\n').encode() + payload
    result = remote(command, payload, user=user, port=port)
    return json.loads(result.stdout)


def wait_for(checker, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if checker():
                return True
        except (OSError, RuntimeError, subprocess.SubprocessError, ValueError):
            pass
        time.sleep(1)
    return False


def start_job(user, deadline=120):
    plan = rpc('ssh_harden_plan', payload=json.dumps(dict(username=user, port=2222)))
    check(plan['code'] == 'ok', user + '_plan')
    job = uuid.uuid4().hex
    result = rpc('submit', id=job, kind='ssh_harden', count=7, interval=1,
                 fingerprint=plan['sshHardenPlan']['fingerprint'],
                 payload=json.dumps(dict(username=user, port=2222, sudoPassword=PASSWORD,
                                         disableRootLogin=True, deadlineSeconds=deadline)))
    check(result['code'] == 'ok', user + '_submit')
    def testing():
        reply = rpc('ssh_harden_status', id=job)
        if reply['code'] == 'ok' and reply['sshHardenResult']['phase'] in ('rolled_back', 'rollback_failed', 'failed'):
            raise AssertionError(user + ': job failed before testing')
        return reply['code'] == 'ok' and reply['sshHardenResult']['phase'] == 'testing'
    check(wait_for(testing), user + '_testing')
    return job


def check_rollback(job, user):
    check(wait_for(lambda: remote('true', check=False).returncode == 0), user + '_old_access')
    check(wait_for(lambda: rpc('ssh_harden_status', id=job).get('sshHardenResult', {}).get('aborted')), user + '_rolled_back')
    check(remote('id ' + user, check=False).returncode != 0, user + '_removed')
    check(rpc('ssh_harden_confirm', id=job)['code'] == 'ssh_harden_conflict', user + '_late_confirm_rejected')


def main():
    check(remote('hostname').stdout.strip() == b'antirkn-runner-fixture', 'disposable_vm_identity')
    inspector = BUNDLE['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))'
    before = json.loads(python_remote(inspector).stdout)
    expected = json.loads(BUNDLE['runnerBundle'])
    if before.get('release') != expected['release']:
        reply = python_remote(BUNDLE['runnerInstaller'], json.dumps(dict(fingerprint=before['fingerprint'], bundle=expected)).encode())
        check(json.loads(reply.stdout).get('active'), 'runner_v21_installed')
    # Earlier config and a Match branch must not override the final root policy.
    python_remote("from pathlib import Path\np=Path('/etc/ssh/sshd_config.d/10-audit-existing.conf');p.write_text('Port 22\\nPermitRootLogin yes\\n')\np=Path('/etc/ssh/sshd_config');s=p.read_text();p.write_text(s+'\\nMatch User root\\n PermitRootLogin yes\\n')")
    remote('sshd -t && systemctl reload-or-restart ssh.service')
    baseline = python_remote("import hashlib,json\nfrom pathlib import Path\nprint(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path('/etc/ssh/sshd_config'),*Path('/etc/ssh/sshd_config.d').glob('*.conf')]}))").stdout

    job = start_job('auditabort')
    check(remote('id -u', user='auditabort', port=NEW_PORT, password_auth=True).stdout.strip() not in (b'', b'0'), 'new_password_authentication')
    sudo = remote('sudo -k -S -p "" -- id -u', (PASSWORD+'\n').encode(), user='auditabort', port=NEW_PORT)
    check(sudo.stdout.strip() == b'0', 'new_sudo_password')
    abort = rpc('ssh_harden_abort', id=job)
    check(abort['code'] == 'ok' and abort['sshHardenResult']['phase'] in ('rolled_back', 'rolling_back'), 'manual_abort')
    check_rollback(job, 'auditabort')
    after = python_remote("import hashlib,json\nfrom pathlib import Path\nprint(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path('/etc/ssh/sshd_config'),*Path('/etc/ssh/sshd_config.d').glob('*.conf')]}))").stdout
    check(json.loads(baseline) == json.loads(after), 'exact_configuration_restored')

    job = start_job('audittimeout', deadline=30)
    remote('systemctl stop antirkn-runner.service')
    # No status RPC triggers rollback here: the independent watchdog must do it.
    check(wait_for(lambda: remote('id audittimeout', check=False).returncode != 0, seconds=45), 'watchdog_without_runner')
    remote('systemctl start antirkn-runner.service')
    check_rollback(job, 'audittimeout')

    job = start_job('auditreload')
    inject = "import sys,json\nsys.path.insert(0,'/usr/local/lib/antirkn-runner/v21')\nimport ssh_harden as h\nfrom runner import Store\nreal=h.reload_ssh_service\nstate=[True]\ndef fail_once(active=False):\n if state.pop() if state else False: raise OSError('fixture')\n return real(active)\nh.reload_ssh_service=fail_once\ns=Store('/var/lib/antirkn-runner')\nprint(json.dumps(s.request(json.loads(sys.stdin.read()))))\ns.close()"
    reply = json.loads(python_remote(inject, json.dumps(dict(version=1, action='ssh_harden_confirm', id=job)).encode()).stdout)
    check(reply['code'] == 'ssh_harden_failed', 'final_reload_failure_reported')
    check_rollback(job, 'auditreload')

    job = start_job('auditreboot')
    check(rpc('ssh_harden_confirm', id=job)['sshHardenResult']['finalized'], 'reboot_provisional_finalization')
    remote('sudo -k -S -p "" -- systemctl reboot', (PASSWORD+'\n').encode(), user='auditreboot', port=NEW_PORT, check=False)
    time.sleep(3)
    check_rollback(job, 'auditreboot')

    job = start_job('auditcommit')
    check(rpc('ssh_harden_confirm', id=job)['sshHardenResult']['finalized'], 'final_settings_provisional')
    check(remote('id -u', user='auditcommit', port=NEW_PORT, password_auth=True).stdout.strip() not in (b'', b'0'), 'final_password_login')
    check(remote('true', user='root', port=NEW_PORT, check=False).returncode != 0, 'root_login_rejected')
    check(remote('true', check=False).returncode != 0, 'old_listener_closed')
    # A new SSH connection and sudo context must perform the final commit.
    check(rpc('ssh_harden_commit', id=job, user='auditcommit')['sshHardenResult']['confirmed'], 'new_session_commits')
    check(rpc('ssh_harden_status', id=job, user='auditcommit')['sshHardenResult']['confirmed'], 'lost_commit_reply_recoverable')
    check(rpc('ssh_harden_commit', id=job, user='auditcommit')['sshHardenResult']['confirmed'], 'commit_idempotent')
    check(rpc('ssh_harden_abort', id=job, user='auditcommit')['code'] == 'ssh_harden_conflict', 'committed_access_cannot_be_aborted')
    evidence = dict(suite='ssh_harden_recovery_vm', results=RESULTS,
                    runner_release=expected['release'], timestamp_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    (ROOT / 'docs/evidence/ssh-hardening-recovery-vm.json').write_text(json.dumps(evidence, indent=2)+'\n')
    print('All SSH hardening recovery VM checks passed.', flush=True)


if __name__ == '__main__':
    main()
