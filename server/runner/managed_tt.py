import base64
import contextlib
from pathlib import Path

import tt_external as external
import tt_certificates as certificates
from tt_common import file_lock, lock, read, run, split_address, toml_bytes, toml_loads
from managed_existing import derive, intent, user_enabled
from vless import VlessError, digest


def snapshot(store, p, r):
    resource, settings, hosts, vpn, host_config, fingerprint = external.snapshot(r['adoption']['sourceId'])
    if not resource['credentials']:
        raise VlessError('vpn_adoption_unsupported')
    credentials = read(resource['credentials'], resource['ownerUid']).decode()
    return dict(resource=resource, settings=settings.decode(), hosts=hosts.decode(),
                credentials=credentials, fingerprint=fingerprint)


def certificate(current, r):
    hosts = toml_loads(current['hosts']).get('main_hosts', [])
    host = next((host for host in hosts if host['hostname'] == r['domain']), None)
    if host is None:
        raise VlessError('vpn_adoption_conflict')
    paths = [str(Path(host[k]) if Path(host[k]).is_absolute() else Path(current['resource']['base']) / host[k])
             for k in ('cert_chain_path', 'private_key_path')]
    return certificates.inspect_pair(*paths, r['domain'])


def build(store, p, r, old, current, preview=False):
    if not old and r['enabled'] != current['resource']['active']:
        raise VlessError('vpn_adoption_conflict')
    vpn = toml_loads(current['settings'])
    if (tuple(split_address(vpn['listen_address'])) != (r['listen'], r['port']) or
            ('quic' in vpn.get('listen_protocols', {})) != r['quic']):
        raise VlessError('vpn_adoption_conflict')
    certificate(current, r)
    credentials = toml_loads(current['credentials'])
    own_names = {c['username'] for c in (old or {}).get('clients', [])}
    foreign = [c for c in credentials.get('client', []) if c['username'] not in own_names]
    clients = []
    for user in sorted(p['users'], key=lambda u: u['id']):
        previous = next((c for c in (old or {}).get('clients', []) if c['id'] == user['id']), None)
        username = previous['username'] if previous else user['login']
        if any(c['username'].lower() == username.lower() for c in foreign):
            username = 'ar_' + r['id'][:12] + '_' + user['id']
        if any(c['username'].lower() == username.lower() for c in foreign + clients):
            raise VlessError('tt_login_conflict')
        password = base64.urlsafe_b64encode(derive(store, p, r, 'tt/' + user['id'], preview)).decode().rstrip('=')
        clients.append(dict(id=user['id'], username=username, password=password, enabled=user_enabled(r, user)))
    credentials['client'] = foreign + [dict(username=c['username'], password=c['password']) for c in clients if c['enabled']]
    if not credentials['client']:
        credentials['client'] = [dict(username='_antirkn_no_clients',
                                      password=derive(store, p, r, 'tt-deny-all', preview).hex())]
    result = intent(old, current, toml_bytes(credentials).decode(), clients,
                    dict(type='trusttunnel', sni=r['domain'], quic=r['quic'], udp=True))
    result['certificate'] = certificate(current, r)
    return result


def unchanged(current, before):
    ignored = {'credentialsHash', 'active'}
    return (current['settings'] == before['settings'] and current['hosts'] == before['hosts'] and
            {k: v for k, v in current['resource'].items() if k not in ignored} ==
            {k: v for k, v in before['resource'].items() if k not in ignored})


def reconcile_credentials(current_raw, plan_before_raw, plan_after_raw, record_clients, store, p, r):
    if current_raw == plan_after_raw or current_raw == plan_before_raw:
        return plan_after_raw

    current_creds = toml_loads(current_raw)
    before_creds = toml_loads(plan_before_raw)
    after_creds = toml_loads(plan_after_raw)

    new_names = {c['username'] for c in record_clients}
    foreign_names = {c['username'] for c in after_creds.get('client', [])
                     if any(b.get('username') == c['username'] for b in before_creds.get('client', [])) and c['username'] not in new_names}
    old_names = {c['username'] for c in before_creds.get('client', []) if c.get('username') not in foreign_names}

    current_foreign = [c for c in current_creds.get('client', [])
                       if c.get('username') not in old_names and c.get('username') != '_antirkn_no_clients']

    foreign_usernames_lower = {f['username'].lower() for f in current_foreign}
    our_active = [dict(username=c['username'], password=c['password']) for c in record_clients if c.get('enabled', True)]
    if any(c['username'].lower() in foreign_usernames_lower for c in our_active):
        raise VlessError('tt_login_conflict')

    merged = current_foreign + our_active
    if not merged:
        merged = [dict(username='_antirkn_no_clients',
                       password=derive(store, p, r, 'tt-deny-all').hex())]
    merged_creds = dict(current_creds, client=merged)
    return toml_bytes(merged_creds).decode()


def apply(store, p, r, plan):
    cred_path = Path(plan['before']['resource']['credentials']) if 'resource' in plan.get('before', {}) and plan['before']['resource'].get('credentials') else None
    lock_ctx = file_lock(cred_path) if cred_path else contextlib.nullcontext()
    with lock(), lock_ctx:
        current = snapshot(store, p, r)
        if not unchanged(current, plan['before']):
            raise VlessError('vpn_adoption_conflict')
        resource = current['resource']
        target_creds = reconcile_credentials(current['credentials'], plan['before']['credentials'], plan['after'],
                                             plan.get('record', {}).get('clients', []), store, p, r)
        plan['after'] = target_creds
        if current['credentials'] != target_creds:
            if resource['active'] != plan['before']['resource']['active']:
                raise VlessError('vpn_adoption_conflict')
            external.write_existing(Path(resource['credentials']), target_creds.encode(), resource['ownerUid'])
        if plan['before']['resource']['active']:
            run(['/usr/bin/systemctl', 'restart', resource['unit']], timeout=60)
            certificates.verify_service(resource['unit'], r['listen'], r['port'], r['domain'], plan['certificate']['fingerprint'])


def healthy(current):
    # A stopped source remains stopped. Active-service verification happens in
    # apply; snapshots also bind the observed service state and full config.
    return True


def verify(current, plan):
    if not (unchanged(current, plan['before']) and
            current['resource']['active'] == plan['before']['resource']['active']):
        return False
    if current['credentials'] == plan['after']:
        return True
    try:
        current_creds = toml_loads(current['credentials'])
        expected = {c['username']: c['password'] for c in plan.get('record', {}).get('clients', []) if c.get('enabled', True)}
        actual = {c['username']: c['password'] for c in current_creds.get('client', [])}
        return all(actual.get(u) == p for u, p in expected.items())
    except Exception:
        return False

