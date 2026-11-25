#!/usr/bin/env python3
"""Minimal automated VM regression suite for the server runner.

Usage: python3 tool/vm_regression.py [--only a,b] [--keep-vm] [--rebuild-golden] [--mutation]
Local disposable VMs only (artifacts/regression-vm, SSH port 2232). Exit code 1
on any failure. See docs/local-test-server.md.
"""
import argparse
import datetime
import json
import os
import sys
import time
import traceback

import vm_regression_lib as lib
import vm_regression_scenarios as scenarios


def run_scenario(name, mode, vm, run_dir, bundle, timeout):
    """Run one scenario (or its mutation); returns the report entry."""
    ctx = lib.Ctx(name, run_dir, bundle)
    started = time.monotonic()
    entry = dict(name=name, mode=mode, status='PASS', checks=ctx.checks)
    print('== %s%s' % (name, ' [mutation: %s]' % mode if mode != 'normal' else ''), flush=True)
    try:
        with lib.hard_timeout(timeout):
            scenarios.SCENARIOS[name]['run'](ctx, vm, None if mode == 'normal' else mode)
    except lib.CheckFailed as failure:
        entry.update(status='FAIL', failed_check=failure.name)
    except BaseException as error:  # includes Timeout and harness errors
        entry.update(status='ERROR', error=type(error).__name__ + ': ' + str(error)[:300])
        traceback.print_exc(limit=3)
    entry['seconds'] = round(time.monotonic() - started, 1)
    entry['checks'] = list(ctx.checks)
    if entry['status'] != 'PASS' and mode == 'normal':
        try:
            lib.collect_diagnostics(ctx, entry.get('error') or entry.get('failed_check'))
        except Exception:
            pass
    vm.stop()
    return entry


PROXY_VARIABLES = ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')


def enter_private_network():
    """Re-exec inside a private user+network namespace with its own loopback.

    The VM, its slirp forwards, the cloud-init seed server and ssh then talk over
    an isolated 127.0.0.1 that host loopback policies do not affect; the VM has no
    outside network, so components must come from the pinned local cache.
    """
    if os.environ.get('ANTIRKN_VM_NETNS') == '1' or '--host-network' in sys.argv or '--fetch' in sys.argv:
        return
    env = {k: v for k, v in os.environ.items() if k not in PROXY_VARIABLES}
    env['ANTIRKN_VM_NETNS'] = '1'
    script = 'ip link set lo up && exec "$@"'
    os.execvpe('unshare', ['unshare', '-rn', 'sh', '-c', script, 'sh',
                           sys.executable] + sys.argv, env)


def main():
    enter_private_network()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fetch', action='store_true', help='download and verify all pinned offline fixtures (uses host network)')
    parser.add_argument('--only', help='comma separated scenario names: ' + ','.join(scenarios.ORDER))
    parser.add_argument('--keep-vm', action='store_true', help='leave the last VM running')
    parser.add_argument('--rebuild-golden', action='store_true')
    parser.add_argument('--mutation', action='store_true', help='prove each scenario can fail')
    parser.add_argument('--host-network', action='store_true', help='do not enter a private network namespace')
    parser.add_argument('--reuse-protocols', action='store_true', help='developer: reuse a built protocols overlay')
    parser.add_argument('--previous', help='git commit for the previous runner release used by runner_upgrade')
    args = parser.parse_args()
    if args.fetch:
        lib.fetch_all()
        return 0
    names = args.only.split(',') if args.only else list(scenarios.ORDER)
    unknown = [n for n in names if n not in scenarios.SCENARIOS]
    if unknown:
        parser.error('unknown scenario: ' + ','.join(unknown))
    lib.verify_cache()
    run_dir = lib.RUNS / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    run_dir.mkdir(mode=0o700, parents=True)
    bundle = lib.current_bundle()
    if args.previous or 'runner_upgrade' in names:
        lib.previous_bundle(bundle, args.previous)
    vm = lib.Vm()
    scenarios.OPTIONS['reuse_protocols'] = args.reuse_protocols
    scenarios.OPTIONS['previous_commit'] = args.previous
    started = time.monotonic()
    entries, golden_seconds = [], None
    try:
        t = time.monotonic()
        _, built = lib.ensure_golden(vm, args.rebuild_golden)
        golden_seconds = round(time.monotonic() - t, 1) if built else 0
        print('golden snapshot %s (%ss)' % ('built' if built else 'reused', golden_seconds), flush=True)
        for name in names:
            spec = scenarios.SCENARIOS[name]
            if args.mutation:
                for mutation, expected in spec['mutations'].items():
                    entry = run_scenario(name, mutation, vm, run_dir, bundle, spec['timeout'])
                    entry['expected_check'] = expected
                    # A mutation is "caught" when the scenario fails on the expected named check.
                    entry['caught'] = entry['status'] == 'FAIL' and entry.get('failed_check') == expected
                    entries.append(entry)
            else:
                entries.append(run_scenario(name, 'normal', vm, run_dir, bundle, spec['timeout']))
    finally:
        if not args.keep_vm:
            vm.stop()
    if args.mutation:
        ok = all(e['caught'] for e in entries)
    else:
        ok = all(e['status'] == 'PASS' for e in entries)
    report = dict(git_head=lib.git_head(), runner_release=bundle['release'], runner_version=bundle['version'],
                  mutation_run=args.mutation, golden_seconds=golden_seconds,
                  total_seconds=round(time.monotonic() - started, 1), ok=ok, scenarios=entries)
    (run_dir / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('\n%-20s %-22s %-8s %7s  %s' % ('scenario', 'mode', 'result', 'sec', 'detail'))
    for e in entries:
        result = ('CAUGHT' if e['caught'] else 'MISSED') if args.mutation else e['status']
        print('%-20s %-22s %-8s %7s  %s' % (e['name'], e['mode'], result, e['seconds'],
              e.get('failed_check') or e.get('error', '')))
    print('total %ss, report %s' % (report['total_seconds'], run_dir / 'report.json'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
