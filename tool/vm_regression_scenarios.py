#!/usr/bin/env python3
"""Scenarios of the VM regression suite. Each gets its own overlay of golden."""
import json
import secrets
import time

import vm_regression_lib as lib
from vm_regression_lib import remote, python, upload

OPTIONS = {}
PREVIOUS_RELEASE_COMMIT = '685307d'  # runner v66
PREVIOUS_RELEASE_VERSION = 'v66'


def active(unit='antirkn-runner'):
    return remote('systemctl is-active ' + unit, check=False).stdout.decode().strip() == 'active'


def enabled(unit='antirkn-runner'):
    return remote('systemctl is-enabled ' + unit, check=False).stdout.decode().strip() == 'enabled'


def diagnostic(rpc, count=3):
    request = dict(version=1, action='submit', id=secrets.token_hex(16), kind='diagnostic', count=count, interval=1)
    job = rpc.run_job(request, timeout=120)
    return request, job


# ---------------------------------------------------------------- runner_upgrade

# Fault injected into the installer text in memory only: after the normal
# installation it erases the job history (database stays valid), as an
# installer that recreated or migrated the journal incorrectly would.
DROP_JOBS = ("\nimport sqlite3 as _sqlite3\n"
             "_db = _sqlite3.connect('/var/lib/antirkn-runner/jobs.sqlite', timeout=30)\n"
             "_db.execute('DELETE FROM events'); _db.execute('DELETE FROM jobs'); _db.commit(); _db.close()\n")


def runner_upgrade(ctx, vm, mutation=None):
    current = ctx.bundle
    # (a) fresh install of the current runner.
    vm.start(lib.new_overlay('runner-fresh', lib.BASE / 'golden.qcow2'))
    plan = lib.inspect_runner(current)
    ctx.check(plan['supported'] and plan['state'] == 'missing', 'fresh_vm_supported_and_runner_missing')
    result = lib.install_runner(current)
    ctx.check(result['active'], 'fresh_install_reports_active')
    ctx.check(active() and enabled(), 'fresh_daemon_active_and_enabled')
    ctx.check(ctx.rpc(dict(version=1, action='list')).get('code') == 'ok', 'fresh_rpc_works')
    _, job = diagnostic(ctx.rpc)
    ctx.check(job['status'] == 'succeeded', 'fresh_diagnostic_job_succeeds')
    vm.stop()
    # (b) upgrade from the previous release, with a job in the old journal.
    vm.start(lib.new_overlay('runner-upgrade', lib.BASE / 'golden.qcow2'))
    old = lib.bundle_from_git(PREVIOUS_RELEASE_COMMIT)
    ctx.check(old['version'] == PREVIOUS_RELEASE_VERSION and old['release'] != current['release'], 'previous_release_is_distinct')
    ctx.check(lib.install_runner(old)['active'], 'previous_release_installed')
    old_rpc = lib.Rpc(old['version'])
    request, before = diagnostic(old_rpc)
    ctx.check(before['status'] == 'succeeded' and len(lib.codes(before)) >= 3, 'old_release_job_ran')
    plan = lib.inspect_runner(current)
    ctx.check(plan['upgradable'], 'previous_release_recognised_as_upgradable')
    installer = current['runnerInstaller'] + (DROP_JOBS if mutation == 'installer_drops_jobs_db' else '')
    result = lib.install_runner(current, installer=installer)
    ctx.check(result['active'] and active(), 'upgraded_daemon_active')
    ctx.check(ctx.rpc(dict(version=1, action='list')).get('code') == 'ok', 'upgraded_rpc_works')
    response = ctx.rpc.status(request['id'])
    jobs = response.get('jobs') or []
    ctx.check(jobs and jobs[0]['status'] == 'succeeded', 'upgrade_preserves_old_job')
    ctx.check(lib.codes(jobs[0]) == lib.codes(before), 'upgrade_preserves_old_job_events')
    pid = lib.main_pid()
    ctx.check(pid not in ('', '0'), 'upgraded_daemon_has_pid')
    state = lib.inspect_runner(current)
    ctx.check(state['state'] == 'installed' and not state['upgradable'], 'repeat_plan_reports_installed')
    lib.install_runner(current)
    ctx.check(lib.main_pid() == pid, 'repeat_install_is_noop_same_mainpid')
    _, job = diagnostic(ctx.rpc, 1)
    ctx.check(job['status'] == 'succeeded', 'upgraded_runner_runs_new_jobs')


SCENARIOS = {
    'runner_upgrade': dict(run=runner_upgrade, timeout=900,
                           mutations={'installer_drops_jobs_db': 'upgrade_preserves_old_job'}),
}
ORDER = ['runner_upgrade']
