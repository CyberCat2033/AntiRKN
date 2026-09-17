#!/usr/bin/env python3
"""Reboot only the named disposable integration VM and check durable replay."""
import json
import secrets
import time
from test_mihomo_vm import remote, rpc, ROOT


def main():
    assert remote('cat /etc/hostname').stdout.decode().strip() == 'antirkn-runner-fixture'
    boot = remote('cat /proc/sys/kernel/random/boot_id').stdout
    req = dict(version=1, action='submit', kind='server_reboot',
               id=secrets.token_hex(16), count=2, interval=1)
    assert rpc(req)['code'] == 'ok'
    assert rpc(req)['code'] == 'ok'
    print('PASS durable submit/replay; waiting for fixture reboot', flush=True)
    deadline = time.monotonic()+180
    job = None
    while time.monotonic() < deadline:
        time.sleep(3)
        try:
            response = rpc(dict(version=1, action='status', id=req['id'], cursor=0))
            job = response['jobs'][0]
            if job['status'] not in ('planned', 'running'): break
        except (ValueError, KeyError, IndexError):
            pass
    assert job and job['status'] == 'succeeded', job
    new_boot = remote('cat /proc/sys/kernel/random/boot_id').stdout
    assert new_boot != boot
    assert rpc(req)['jobs'][0]['status'] == 'succeeded'
    time.sleep(8)
    assert remote('cat /proc/sys/kernel/random/boot_id').stdout == new_boot
    assert remote('systemctl is-active antirkn-runner x-ui').stdout.decode().split() == ['active', 'active']
    evidence = dict(fixture='isolated Ubuntu VM', runner='v25',
                    rebootConfirmed=True, replayBeforeAndAfterBoot=True,
                    noSecondReboot=True, runnerAndPanelActiveAfterBoot=True)
    (ROOT/'docs/evidence/server-reboot-vm.json').write_text(json.dumps(evidence, indent=2)+'\n')
    print('PASS changed boot, recovered runner/panel, replay does not reboot again', flush=True)


if __name__ == '__main__': main()
