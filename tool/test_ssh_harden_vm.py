#!/usr/bin/env python3
"""Integration tests for SSH hardening (FR-SSH-02) on the test VM."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
CLIENT_KEY = ROOT / 'artifacts/local-server/client'
KNOWN_HOSTS = ROOT / 'artifacts/local-server/known_hosts'
PORT = 2222


def remote(command, data=None, timeout=30, check=True):
    args = [
        'ssh', '-i', str(CLIENT_KEY),
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=5',
        '-o', f'UserKnownHostsFile={KNOWN_HOSTS}',
        '-o', 'StrictHostKeyChecking=no',
        '-p', str(PORT),
        f'root@127.0.0.1',
        command,
    ]
    res = subprocess.run(
        args,
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if check and res.returncode != 0:
        raise RuntimeError(f'Remote command failed ({res.returncode}): {res.stderr.decode()}')
    return res


def python_remote(source, data=None):
    cmd = '/usr/bin/python3 -I -c ' + shlex.quote(source)
    return remote(cmd, data=data)


def rpc(req):
    cmd = '/usr/bin/python3 -I /usr/local/lib/antirkn-runner/v18/runner.py rpc'
    res = remote(cmd, data=json.dumps(req).encode())
    return json.loads(res.stdout)


def bundle_strings():
    source = (ROOT / 'packages/ssh_transport/lib/src/runner_bundle.g.dart').read_text()
    return {
        name: re.search(r'const ' + name + r" =\s*r'''(.*?)''';", source, re.S).group(1)
        for name in ('runnerBundle', 'runnerInspector', 'runnerInstaller')
    }


def main():
    print('--- Starting SSH Hardening VM Integration Test ---', flush=True)
    results = {}

    def check(condition, name):
        if not condition:
            raise AssertionError(f'FAILED: {name}')
        results[name] = True
        print(f'PASS: {name}', flush=True)

    # 1. Upgrade runner to v18 on the VM
    bundle = bundle_strings()
    inspect_code = bundle['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))'
    before = json.loads(python_remote(inspect_code).stdout)
    check(before['supported'], 'vm_supported')
    print(f'Runner before: state={before["state"]}, release={before.get("release")}, upgradable={before.get("upgradable")}', flush=True)

    if before.get('release') != json.loads(bundle['runnerBundle'])['release']:
        print('Installing runner v18...', flush=True)
        install_input = json.dumps({
            'fingerprint': before['fingerprint'],
            'bundle': json.loads(bundle['runnerBundle']),
        }).encode()
        install_res = python_remote(bundle['runnerInstaller'], data=install_input)
        installed = json.loads(install_res.stdout)
        check(installed.get('active', False), 'runner_v18_installed')
    else:
        check(True, 'runner_v18_already_installed')

    after = json.loads(python_remote(inspect_code).stdout)
    check(after['active'] and after['state'] == 'installed', 'runner_v18_active')

    # 2. Test ssh_harden_plan
    plan_req = {
        'version': 1,
        'action': 'ssh_harden_plan',
        'payload': json.dumps({'username': 'mustang', 'port': 2223}),
    }
    plan_resp = rpc(plan_req)
    check(plan_resp['code'] == 'ok', 'ssh_harden_plan_ok')
    plan = plan_resp['sshHardenPlan']
    check(plan['supported'] is True, 'plan_supported')
    check(plan['proposedUser'] == 'mustang', 'plan_proposed_user')
    check(plan['userAvailable'] is True, 'plan_user_available')
    check(bool(plan['fingerprint']), 'plan_has_fingerprint')

    # 3. Test submission and auto-rollback abort
    job_id_abort = 'a' * 32
    submit_req = {
        'version': 1,
        'action': 'submit',
        'id': job_id_abort,
        'kind': 'ssh_harden',
        'count': 7,
        'interval': 1,
        'payload': json.dumps({
            'username': 'mustang',
            'port': 2223,
            'sudoPassword': 'SudoPassword123!',
            'disableRootLogin': True,
            'deadlineSeconds': 300,
        }),
        'fingerprint': plan['fingerprint'],
    }
    submit_resp = rpc(submit_req)
    check(submit_resp['code'] == 'ok', 'submit_ssh_harden_ok')

    # Wait for checkpoint 6 (testing phase)
    print('Waiting for staging to reach checkpoint 6 (testing phase)...', flush=True)
    deadline = time.monotonic() + 30
    reached_testing = False
    while time.monotonic() < deadline:
        st = rpc({'version': 1, 'action': 'status', 'id': job_id_abort, 'cursor': 0})
        job = st['jobs'][0] if st.get('jobs') else None
        if job and job['checkpoint'] >= 6:
            reached_testing = True
            break
        time.sleep(0.5)

    check(reached_testing, 'ssh_harden_reached_testing_checkpoint')

    # Verify user mustang was created and sudoers exists
    check_user = remote('id mustang', check=False)
    check(check_user.returncode == 0, 'user_mustang_created')
    check_sudoers = remote('test -f /etc/sudoers.d/99-antirkn-mustang', check=False)
    check(check_sudoers.returncode == 0, 'sudoers_file_created')

    # Verify watchdog process/unit exists
    check_wd = remote(f'systemctl is-active antirkn-ssh-watchdog-{job_id_abort}', check=False)
    check(check_wd.returncode == 0, 'watchdog_active')

    # Now abort and test rollback
    print('Testing ssh_harden_abort...', flush=True)
    abort_resp = rpc({'version': 1, 'action': 'ssh_harden_abort', 'id': job_id_abort})
    check(abort_resp['code'] == 'ok' and abort_resp['sshHardenResult']['aborted'] is True, 'ssh_harden_aborted_ok')

    time.sleep(1)
    # Verify user was deleted
    check_del = remote('id mustang', check=False)
    check(check_del.returncode != 0, 'user_mustang_deleted_after_abort')
    check_nosudo = remote('test -f /etc/sudoers.d/99-antirkn-mustang', check=False)
    check(check_nosudo.returncode != 0, 'sudoers_deleted_after_abort')
    check_noconf = remote('test -f /etc/ssh/sshd_config.d/99-antirkn-harden.conf', check=False)
    check(check_noconf.returncode != 0, 'dropin_deleted_after_abort')

    # 4. Now test full lifecycle with confirm for user `edward`
    print('Testing full lifecycle with confirm for edward on port 2223...', flush=True)
    plan_resp2 = rpc({
        'version': 1,
        'action': 'ssh_harden_plan',
        'payload': json.dumps({'username': 'edward', 'port': 2223}),
    })
    plan2 = plan_resp2['sshHardenPlan']
    check(plan2['userAvailable'] is True, 'edward_user_available')

    job_id_confirm = 'b' * 32
    submit_confirm = {
        'version': 1,
        'action': 'submit',
        'id': job_id_confirm,
        'kind': 'ssh_harden',
        'count': 7,
        'interval': 1,
        'payload': json.dumps({
            'username': 'edward',
            'port': 2223,
            'sudoPassword': 'EdwardPassword456!',
            'disableRootLogin': True,
            'deadlineSeconds': 300,
        }),
        'fingerprint': plan2['fingerprint'],
    }
    submit_resp2 = rpc(submit_confirm)
    check(submit_resp2['code'] == 'ok', 'submit_edward_ok')

    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        st = rpc({'version': 1, 'action': 'status', 'id': job_id_confirm, 'cursor': 0})
        job = st['jobs'][0] if st.get('jobs') else None
        if job and job['checkpoint'] >= 6:
            break
        time.sleep(0.5)

    check(remote('id edward', check=False).returncode == 0, 'user_edward_created')

    # Test that user edward can authenticate with the client SSH key on dual-port 2223
    edward_ssh = subprocess.run([
        'ssh', '-i', str(CLIENT_KEY),
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=5',
        '-o', f'UserKnownHostsFile={KNOWN_HOSTS}',
        '-o', 'StrictHostKeyChecking=no',
        '-p', '2223',
        'edward@127.0.0.1',
        'echo EdwardPassword456! | sudo -S id -u',
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    check(edward_ssh.returncode == 0 and edward_ssh.stdout.strip() == b'0', 'edward_ssh_and_sudo_verified')

    # Confirm the hardening job
    print('Confirming edward hardening...', flush=True)
    confirm_resp = rpc({'version': 1, 'action': 'ssh_harden_confirm', 'id': job_id_confirm})
    check(confirm_resp['code'] == 'ok' and confirm_resp['sshHardenResult']['confirmed'] is True, 'edward_confirmed_ok')

    time.sleep(1)

    # Check that PermitRootLogin no and Port 2223 are active in sshd config via edward sudo
    edward_read_conf = subprocess.run([
        'ssh', '-i', str(CLIENT_KEY),
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=5',
        '-o', f'UserKnownHostsFile={KNOWN_HOSTS}',
        '-o', 'StrictHostKeyChecking=no',
        '-p', '2223',
        'edward@127.0.0.1',
        'echo EdwardPassword456! | sudo -S cat /etc/ssh/sshd_config.d/99-antirkn-harden.conf',
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    check(edward_read_conf.returncode == 0, 'edward_access_preserved_after_confirm')
    conf_text = edward_read_conf.stdout.decode()
    check('PermitRootLogin no' in conf_text, 'permit_root_login_disabled')
    check('Port 2223' in conf_text, 'port_2223_in_sshd_config')

    # Verify root login is REJECTED on port 2223
    root_ssh_2223 = subprocess.run([
        'ssh', '-i', str(CLIENT_KEY),
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=5',
        '-o', f'UserKnownHostsFile={KNOWN_HOSTS}',
        '-o', 'StrictHostKeyChecking=no',
        '-p', '2223',
        'root@127.0.0.1',
        'id',
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    check(root_ssh_2223.returncode != 0, 'root_login_rejected_on_port_2223')

    # Save evidence
    evidence = {
        'suite': 'ssh_harden_vm_test',
        'timestamp': time.time(),
        'results': results,
    }
    evidence_path = ROOT / 'docs/evidence/ssh-harden-vm-test.json'
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_text(json.dumps(evidence, indent=2) + '\n')
    print('Evidence written to docs/evidence/ssh-harden-vm-test.json', flush=True)
    print('ALL SSH HARDENING VM TESTS PASSED!', flush=True)


if __name__ == '__main__':
    main()
