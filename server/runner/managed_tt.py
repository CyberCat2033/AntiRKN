"""Existing TrustTunnel: retain its service, hosts and foreign credentials."""
import base64
from pathlib import Path

import tt_external as external
import tt_certificates as certificates
from tt_common import read, run, split_address, toml_bytes, toml_loads
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


def apply(store, p, r, plan):
    current = snapshot(store, p, r)
    if not unchanged(current, plan['before']) or current['credentials'] not in (plan['before']['credentials'], plan['after']):
        raise VlessError('vpn_adoption_conflict')
    resource = current['resource']
    if current['credentials'] != plan['after']:
        if resource['active'] != plan['before']['resource']['active']:
            raise VlessError('vpn_adoption_conflict')
        external.write_existing(Path(resource['credentials']), plan['after'].encode(), resource['ownerUid'])
    if plan['before']['resource']['active']:
        run(['/usr/bin/systemctl', 'restart', resource['unit']], timeout=60)
        certificates.verify_service(resource['unit'], r['listen'], r['port'], r['domain'], plan['certificate']['fingerprint'])


def healthy(current):
    # A stopped source remains stopped. Active-service verification happens in
    # apply; snapshots also bind the observed service state and full config.
    return True


def verify(current, plan):
    return (unchanged(current, plan['before']) and current['credentials'] == plan['after'] and
            current['resource']['active'] == plan['before']['resource']['active'])
