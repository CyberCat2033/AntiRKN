#!/usr/bin/env python3
"""Current workflow on an explicitly selected disposable VM, preserving panel state."""
import copy
import hashlib
import json
import os
import re
import subprocess
import time
from test_panel_vm import ROOT, remote, python, rpc, bundle_strings
from test_vless_vm import check, results, MIHOMO, fixtures, public_spec, payload, apply, network, PANEL_ID


def main():
    if not os.environ.get('ANTIRKN_VM_DIRECTORY', '').endswith('/server-workflow-test'):
        raise SystemExit('This destructive fixture requires the dedicated server-workflow-test VM')
    source = subprocess.check_output(['git', 'show', 'a82a834:packages/ssh_transport/lib/src/runner_bundle.g.dart'], cwd=ROOT, text=True)
    old = {name: re.search(r'const ' + name + r" =\s*r'''(.*?)''';", source, re.S).group(1)
           for name in ('runnerBundle', 'runnerInspector', 'runnerInstaller')}
    new = bundle_strings()
    key_before = remote('sha256sum /etc/antirkn-runner/panel.key').stdout
    remote('systemctl stop antirkn-runner')
    # Only replace this fixture's runner code. Keep jobs, panel, inbounds and keys.
    remote('rm -rf /usr/local/lib/antirkn-runner /etc/systemd/system/antirkn-runner.service')
    remote('systemctl daemon-reload')
    def inspect(sources):
        return json.loads(python(sources['runnerInspector'] + '\nprint(json.dumps(inspect_runner()))').stdout)
    def install(sources, plan):
        return json.loads(python(sources['runnerInstaller'], json.dumps(dict(fingerprint=plan['fingerprint'], bundle=json.loads(sources['runnerBundle']))).encode()).stdout)
    check(install(old, inspect(old))['active'], 'v4_with_existing_panel')
    plan = inspect(new)
    check(plan['upgradable'], 'v4_known_predecessor')
    check(install(new, plan)['active'], 'v5_upgrade')
    check(key_before == remote('sha256sum /etc/antirkn-runner/panel.key').stdout, 'panel_keys_preserved')
    time.sleep(2)
    discovery = rpc(dict(version=1, action='panel_discover'))
    check(discovery['panelAccess']['id'] == PANEL_ID, 'existing_access_recovered')
    check(discovery['panelDiscovery']['panels'][0]['port'] == 2053, 'panel_port_discovered')
    check(discovery['panelDiscovery']['cliAvailable'], 'official_menu_detected')
    check(remote('x-ui status', check=False).returncode == 0, 'official_x_ui_command_works')
    for target, sni, verdict in [('www.cloudflare.com:443', 'www.cloudflare.com', True), ('127.0.0.1:2053', '', False)]:
        response = rpc(dict(version=1, action='reality_scan', id=PANEL_ID, target=target, sni=sni))
        scan = response.get('realityScan', {})
        check(response['code'] == 'ok' and scan.get('feasible') == verdict, 'scan_' + ('public_tls' if verdict else 'private_target_rejected'))
        if verdict:
            check(all(scan[k] for k in ['tls13', 'h2', 'x25519', 'certValid']), 'scan_official_tls_checks')
            check(bool(scan['serverNames']) and bool(scan['notAfter']), 'scan_certificate_names_and_expiry')
    check(hashlib.sha256(MIHOMO.read_bytes()).hexdigest() == '3e92df24f5e80e86b9cf9183ceb7bb575f0bd132a9dc4081dae42e80f21076ae', 'pinned_mihomo_official_amd64')
    close = fixtures()
    try:
        resources = [public_spec(1), public_spec(2, 'xhttp'), public_spec(3, 'xhttp', 'tls', 'packet-up'), public_spec(4, 'xhttp', 'tls', 'stream-up'), public_spec(5, 'xhttp', 'tls', 'stream-one')]
        resources[0]['fingerprint'] = 'firefox'
        for resource in resources[1:]:
            resource['xhttp'] = dict(xmux=dict(maxConnections='2-3', cMaxReuseTimes='4-8', hMaxRequestTimes='100-200', hMaxReusableSecs='60-120', hKeepAlivePeriod=15), xPaddingBytes='100-300', noSSEHeader=True)
        state, _ = apply(payload(resources), 'advanced_inbounds')
        for index in range(len(resources)): network(state, resources, index)
        before = copy.deepcopy(resources)
        resources[0]['internal'] = True
        locked, _ = apply(payload(resources), 'internal_lock')
        check(not locked[0]['clients'], 'internal_has_no_assigned_clients')
        network(state, before, 0, expected=False)
        resources[0]['internal'] = False
        reopened, _ = apply(payload(resources), 'internal_unlock')
        check(reopened[0]['clients'] == state[0]['clients'], 'unlock_restores_stable_credentials')
        before = copy.deepcopy(resources)
        resources[0]['realitySeed'] = 'e' * 32
        rotated, _ = apply(payload(resources), 'reality_regenerate')
        check(rotated[0]['publicKey'] != reopened[0]['publicKey'] and rotated[0]['shortId'] != reopened[0]['shortId'], 'regenerate_changes_keys_and_short_id')
        network(reopened, before, 0, expected=False)
        network(rotated, resources, 0)
        discovery = rpc(dict(version=1, action='panel_discover'))['panelDiscovery']
        check(len(discovery['panels'][0]['inbounds']) == 5, 'existing_inbounds_discovered')
        (ROOT / 'docs/evidence/server-workflow-ubuntu.json').write_text(json.dumps(dict(results=results, runner='v4 -> v5', panel='3.7.0', xray='26.7.28', mihomo='1.19.30', mihomoSha256=hashlib.sha256(MIHOMO.read_bytes()).hexdigest()), indent=2) + '\n')
    finally:
        close()


if __name__ == '__main__': main()
