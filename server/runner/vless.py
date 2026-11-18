"""Managed VLESS resources. All panel effects use the pinned session API.

The worker owns serialization/checkpoints. Input contains no credentials; stable
client/key material is derived with HMAC from the existing private runner key.
Only public REALITY material and personal UUIDs leave the server over SSH.
"""
import base64
from client_revocations import check as check_revocations
import copy
import hashlib
import hmac
import ipaddress
import json
from pathlib import Path
import re
import socket
import subprocess
import time
import uuid
from urllib.error import HTTPError
from urllib.parse import urlsplit

from panel import KEY, PANEL, PanelError, PanelInstaller, access_for, atomic_file, command, safe_file
from panel_api import PanelApi
from vless_contract import validate_schema


class VlessError(Exception):
    def __init__(self, code='vless_invalid'):
        self.code = code


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def parse_payload(raw):
    def pairs(entries):
        result = {}
        for k, v in entries:
            if k in result: raise VlessError()
            result[k] = v
        return result
    value = json.loads(raw, object_pairs_hook=pairs)
    validate_schema(value)
    for key in ('users', 'resources'):
        if len({x['id'] for x in value[key]}) != len(value[key]): raise VlessError()
    for r in value['resources']:
        if 'adoption' in r:
            import managed_existing
            managed_existing.validate_spec(r, 'vless')
            continue
        try:
            listen = ipaddress.ip_address(r['listen'])
            if listen.is_multicast: raise ValueError()
            if r['endpoint'] in ('0.0.0.0', '::'): raise ValueError()
            if ':' in r['endpoint']: ipaddress.ip_address(r['endpoint'])
            if r['security'] == 'tls' and (r['transport'] != 'xhttp' or not r['certificate'] or not r['certificateKey']): raise ValueError()
            if r['transport'] == 'raw' and r['security'] != 'reality': raise ValueError()
            # REALITY supports the HTTP/2 stream-one client. Other modes are
            # admitted only for TLS and tested individually in the fixture.
            if r['transport'] == 'xhttp' and r['security'] == 'reality' and r['mode'] not in ('auto', 'stream-one'): raise ValueError()
            target = urlsplit('//' + r['target'])
            if not target.hostname or not target.port: raise ValueError()
            if '..' in Path(r['certificate']).parts or '..' in Path(r['certificateKey']).parts: raise ValueError()
            extra = r.get('xhttp', {})
            if extra and r['transport'] != 'xhttp': raise ValueError()
            if any(k.lower() == 'host' for k in extra.get('headers', {})): raise ValueError()
            if (extra.get('uplinkHTTPMethod') == 'GET' or extra.get('uplinkDataPlacement') in ('header','cookie')) and r['mode'] != 'packet-up': raise ValueError()
            lower = lambda v: int(str(v).split('-')[0])
            upper = lambda v: int(str(v).split('-')[-1])
            if 'xPaddingBytes' in extra and lower(extra['xPaddingBytes']) == 0 and upper(extra['xPaddingBytes']) > 0: raise ValueError()
            xmux = extra.get('xmux', {})
            if upper(xmux.get('maxConcurrency',0)) > 0 and upper(xmux.get('maxConnections',0)) > 0: raise ValueError()
            if 'sessionIDTable' in extra and not 10 <= lower(extra.get('sessionIDLength','16-32')) <= upper(extra.get('sessionIDLength','16-32')) <= 128: raise ValueError()
            if r['deleted'] and r['enabled']: raise ValueError()
        except (ValueError, TypeError): raise VlessError()
    import managed_existing
    managed_existing.validate_payload(value, 'vless')
    return value


def marker(workspace, resource):
    return 'AntiRKN:' + workspace + ':' + resource


def secret(label):
    safe_file(KEY, 32)
    key = KEY.read_bytes()
    if len(key) != 32: raise VlessError('vless_conflict')
    return hmac.new(key, ('vless-v1/' + label).encode(), hashlib.sha256).digest()


def material(workspace, resource, seed=None):
    label = workspace + '/' + resource + ('/' + seed if seed is not None else '')
    private = secret('reality/' + label)
    # PKCS#8 X25519 private key; OpenSSL does the curve operation. No homemade
    # crypto and no private key in process arguments.
    der = bytes.fromhex('302e020100300506032b656e04220420') + private
    public = command(['/usr/bin/openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'], input_data=der)
    if len(public) != 44: raise VlessError()
    b64 = lambda b: base64.urlsafe_b64encode(b).decode().rstrip('=')
    return dict(privateKey=b64(private), publicKey=b64(public[-32:]), shortId=secret('short/' + label).hex()[:16],
        shortIds=[secret('short/' + label + '/' + str(n)).hex()[:2*n] for n in range(1, 8)] + [secret('short/' + label).hex()[:16]])


def client_id(workspace, resource, user):
    return str(uuid.UUID(bytes=secret('client/' + workspace + '/' + resource + '/' + user)[:16], version=4))


def access_for_panel(store, panel_id):
    row = store.db.execute("SELECT request FROM jobs WHERE id=? AND status='succeeded'", (panel_id,)).fetchone()
    if row is None:
        from panel_discovery import external_access
        access = external_access()
        if not access or access['id'] != panel_id: raise VlessError('vless_conflict')
    else:
        req = json.loads(row[0])
        if req.get('kind') != 'panel_install': raise VlessError('vless_conflict')
        PanelInstaller(store, req).assert_owned()
        access = access_for(panel_id, req['port'])
    return access


def panel_for(store, panel_id, _retry=True):
    access = access_for_panel(store, panel_id)
    sessions = getattr(store, '_panel_sessions', None)
    if sessions is None:
        sessions = store._panel_sessions = {}
    cached = sessions.get(panel_id)
    api = cached[1] if cached and cached[0] == access else None
    using_cached = api is not None
    if api is None:
        api = PanelApi(access['port'], access.get('basePath', '/'), tls=access.get('tls', False),
            certificate=access.get('certificate'), host=access.get('host', '127.0.0.1'))
        api.login(access['username'], access['password'])
        sessions[panel_id] = (access, api)
    # During an API-triggered core restart the status cache briefly omits the
    # Xray version. A missing value is pending, not evidence of another binary.
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            status = api.call('/panel/api/server/status')
        except HTTPError as error:
            if error.code not in (401, 403, 404) or not using_cached or not _retry:
                raise
            sessions.pop(panel_id, None)
            return panel_for(store, panel_id, _retry=False)
        if isinstance(status, dict) and isinstance(status.get('xray'), dict):
            panel_version, xray_version = status.get('panelVersion'), status['xray'].get('version')
            if (panel_version and panel_version != access.get('panelVersion')) or (xray_version and xray_version != access.get('xrayVersion')):
                from panel_discovery import external_access, EXTERNAL_ACCESS
                from panel import atomic_file, DATABASE
                ext = external_access()
                if ext and ext.get('id') == panel_id:
                    if panel_version: ext['panelVersion'] = access['panelVersion'] = panel_version
                    if xray_version: ext['xrayVersion'] = access['xrayVersion'] = xray_version
                    atomic_file(EXTERNAL_ACCESS, json.dumps(ext).encode())
                    sessions[panel_id] = (access, api)
                    return api
                version_file = DATABASE / '.antirkn-versions'
                owner_file = DATABASE / '.antirkn-owner'
                is_owner = False
                if owner_file.exists():
                    try:
                        from panel import safe_file
                        safe_file(owner_file, 64)
                        is_owner = (owner_file.read_text().strip() == panel_id)
                    except Exception:
                        pass
                if is_owner or access.get('id') == panel_id:
                    ver = {}
                    if version_file.exists():
                        try:
                            ver = json.loads(version_file.read_text())
                        except Exception:
                            pass
                    if not ver or ver.get('id') == panel_id:
                        ver['id'] = panel_id
                        if panel_version: ver['panelVersion'] = access['panelVersion'] = panel_version
                        if xray_version: ver['xrayVersion'] = access['xrayVersion'] = xray_version
                        atomic_file(version_file, json.dumps(ver).encode())
                        sessions[panel_id] = (access, api)
                        return api
                raise VlessError('vless_conflict')
            if panel_version == access.get('panelVersion') and xray_version == access.get('xrayVersion'):
                return api
        time.sleep(.25)
    raise VlessError('vless_api_failed')


def normal(row):
    """Semantic fingerprint, excluding counters maintained by the panel."""
    # /inbounds/list annotates these read-only fields, while /get/:id does
    # not. They cannot participate in the saved readback fingerprint: doing so
    # makes a successful point readback look like drift on the next list call.
    value = {k: copy.deepcopy(v) for k, v in row.items() if k not in
             ('up', 'down', 'total', 'allTime', 'lastTrafficResetTime', 'clientStats', 'userId',
              'originNodeGuid', 'fallbackParent')}
    for key in ('settings', 'streamSettings', 'sniffing', 'allocate'):
        if isinstance(value.get(key), str):
            try: value[key] = json.loads(value[key])
            except (ValueError, TypeError): pass
    settings = value.get('settings')
    if isinstance(settings, dict):
        for client in settings.get('clients', []):
            if not client.get('flow'): client.pop('flow', None)
            for key in ('created_at', 'updated_at', 'createdAt', 'updatedAt'):
                client.pop(key, None)
        settings['clients'] = sorted(settings.get('clients', []), key=lambda c: c.get('id', ''))

    # Clean optional empty/null transport sections and canonicalize sets
    stream = value.get('streamSettings')
    if isinstance(stream, dict):
        for opt_sec in ('xhttpSettings', 'wsSettings', 'grpcSettings', 'httpSettings', 'quicSettings', 'kcpSettings', 'tcpSettings'):
            if opt_sec in stream and (stream[opt_sec] is None or stream[opt_sec] == {}):
                stream.pop(opt_sec, None)
    return value


def normalize_3xui_inbound(raw_inbound):
    """Приводит ответ 3x-ui 3.11+ к каноническому виду, очищая пустые дефолты."""
    if not isinstance(raw_inbound, dict):
        return {}
    value = {k: copy.deepcopy(v) for k, v in raw_inbound.items() if k not in
             ('up', 'down', 'total', 'allTime', 'lastTrafficResetTime', 'clientStats', 'userId',
              'originNodeGuid', 'fallbackParent')}
    for key in ('settings', 'streamSettings', 'sniffing', 'allocate'):
        if isinstance(value.get(key), str):
            try: value[key] = json.loads(value[key])
            except (ValueError, TypeError): pass

    # Clean streamSettings
    stream = value.get('streamSettings')
    if isinstance(stream, dict):
        for empty_field in ('externalProxy', 'dialerProxy', 'sockopt'):
            if empty_field in stream and (stream[empty_field] is None or stream[empty_field] == [] or stream[empty_field] == "" or stream[empty_field] == {}):
                stream.pop(empty_field, None)
        for opt_sec in ('xhttpSettings', 'wsSettings', 'grpcSettings', 'httpSettings', 'quicSettings', 'kcpSettings', 'tcpSettings'):
            if opt_sec in stream and (stream[opt_sec] is None or stream[opt_sec] == {}):
                stream.pop(opt_sec, None)

    # Clean settings clients
    settings = value.get('settings')
    if isinstance(settings, dict):
        clients = settings.get('clients')
        if isinstance(clients, list):
            cleaned_clients = []
            for client in clients:
                if not isinstance(client, dict):
                    continue
                c = copy.deepcopy(client)
                if not c.get('flow'):
                    c.pop('flow', None)
                for key in ('created_at', 'updated_at', 'createdAt', 'updatedAt',
                            'subId', 'tgId', 'reset', 'delayedTime', 'totalGB', 'expiryTime', 'limitIp'):
                    if key in c and (c[key] == 0 or c[key] == '' or c[key] is None or key in ('created_at', 'updated_at', 'createdAt', 'updatedAt')):
                        c.pop(key, None)
                cleaned_clients.append(c)
            settings['clients'] = sorted(cleaned_clients, key=lambda c: c.get('id', ''))

    return value


KNOWN_STREAM_KEYS = {
    'network', 'security', 'external', 'realitySettings', 'tlsSettings',
    'tcpSettings', 'kcpSettings', 'wsSettings', 'httpSettings',
    'grpcSettings', 'xhttpSettings', 'sockopt',
}


def verify_inbound_spec(desired, actual_raw):
    """
    Pure-функция сверки спецификации.
    Возвращает (True, []) при полном семантическом совпадении
    или (False, ['reason_code_1', ...]) при расхождении.
    ЗАПРЕЩЕНО обращаться к БД внутри этой функции.
    """
    if not isinstance(desired, dict) or not isinstance(actual_raw, dict):
        return False, ["invalid_input"]

    norm_desired = normalize_3xui_inbound(desired)
    actual = normalize_3xui_inbound(actual_raw)
    reasons = []

    # 1. Base inbound fields
    for field in ('enable', 'port', 'protocol'):
        if norm_desired.get(field) is not None and actual.get(field) != norm_desired.get(field):
            reasons.append(f"mismatch_{field}")

    d_listen = norm_desired.get('listen') or ''
    a_listen = actual.get('listen') or ''
    if d_listen and d_listen not in ('0.0.0.0', '::') and a_listen and a_listen not in ('0.0.0.0', '::'):
        if d_listen != a_listen:
            reasons.append("mismatch_listen")

    # 2. Clients validation
    d_clients = norm_desired.get('settings', {}).get('clients', []) if isinstance(norm_desired.get('settings'), dict) else []
    a_clients = actual.get('settings', {}).get('clients', []) if isinstance(actual.get('settings'), dict) else []
    d_uuids = {c['id'] for c in d_clients if isinstance(c, dict) and 'id' in c}
    a_uuids = {c['id'] for c in a_clients if isinstance(c, dict) and 'id' in c}

    if a_uuids - d_uuids:
        reasons.append("rogue_clients_detected")
    if d_uuids - a_uuids:
        reasons.append("missing_clients_detected")

    a_client_map = {c['id']: c for c in a_clients if isinstance(c, dict) and 'id' in c}
    for d_c in d_clients:
        if not isinstance(d_c, dict) or 'id' not in d_c:
            continue
        c_id = d_c['id']
        if c_id in a_client_map:
            a_c = a_client_map[c_id]
            if d_c.get('enable') is not None and a_c.get('enable') is not None:
                if bool(d_c.get('enable')) != bool(a_c.get('enable')):
                    reasons.append(f"client_enable_mismatch:{c_id}")
            if (d_c.get('flow') or '') != (a_c.get('flow') or ''):
                reasons.append(f"client_flow_mismatch:{c_id}")

    # 3. StreamSettings validation
    d_stream = norm_desired.get('streamSettings', {}) if isinstance(norm_desired.get('streamSettings'), dict) else {}
    a_stream = actual.get('streamSettings', {}) if isinstance(actual.get('streamSettings'), dict) else {}

    for k in a_stream:
        if k not in KNOWN_STREAM_KEYS:
            reasons.append(f"unknown_stream_key:{k}")

    if d_stream.get('network') and a_stream.get('network') != d_stream.get('network'):
        reasons.append("mismatch_network")
    if d_stream.get('security') and a_stream.get('security') != d_stream.get('security'):
        reasons.append("mismatch_security")

    if d_stream.get('network') == 'xhttp':
        d_xhttp = d_stream.get('xhttpSettings', {})
        a_xhttp = a_stream.get('xhttpSettings', {})
        for field in ('path', 'host', 'mode'):
            if field in d_xhttp and d_xhttp[field] != a_xhttp.get(field):
                reasons.append(f"mismatch_xhttp_{field}")

    if d_stream.get('security') == 'reality':
        d_rs = d_stream.get('realitySettings', {})
        a_rs = a_stream.get('realitySettings', {})
        if set(d_rs.get('serverNames') or []) != set(a_rs.get('serverNames') or []):
            reasons.append("mismatch_reality_serverNames")
        if set(d_rs.get('shortIds') or []) != set(a_rs.get('shortIds') or []):
            reasons.append("mismatch_reality_shortIds")
        d_target = d_rs.get('target') or d_rs.get('dest')
        a_target = a_rs.get('target') or a_rs.get('dest')
        if d_target and a_target and d_target != a_target:
            reasons.append("mismatch_reality_target")
        d_pub = (d_rs.get('settings') or {}).get('publicKey') or d_rs.get('publicKey')
        a_pub = (a_rs.get('settings') or {}).get('publicKey') or a_rs.get('publicKey')
        if d_pub and a_pub and d_pub != a_pub:
            reasons.append("mismatch_reality_publicKey")
        d_priv = d_rs.get('privateKey')
        a_priv = a_rs.get('privateKey')
        if d_priv and a_priv and a_priv not in ('', '***', 'masked', None):
            if d_priv != a_priv:
                reasons.append("mismatch_reality_privateKey")

    if d_stream.get('security') == 'tls':
        d_tls = d_stream.get('tlsSettings', {})
        a_tls = a_stream.get('tlsSettings', {})
        if d_tls.get('serverName') and a_tls.get('serverName') != d_tls.get('serverName'):
            reasons.append("mismatch_tls_serverName")
        if set(d_tls.get('alpn') or []) != set(a_tls.get('alpn') or []):
            reasons.append("mismatch_tls_alpn")

    return (len(reasons) == 0, reasons)


def subset(desired, actual, _key=""):
    """
    Семантическое сравнение desired против actual с учетом особенностей 3x-ui.
    Делегирует проверку verify_inbound_spec при сравнении корневых инбаундов.
    """
    if _key == "" and isinstance(desired, dict) and isinstance(actual, dict):
        if 'settings' in desired or 'streamSettings' in desired:
            ok, _ = verify_inbound_spec(desired, actual)
            return ok
    if _key in ('alpn', 'destOverride'):
        if isinstance(desired, list) and isinstance(actual, list):
            return set(desired) == set(actual)
    if _key == 'streamSettings' and isinstance(actual, dict):
        if any(k not in KNOWN_STREAM_KEYS for k in actual):
            return False
    if _key == 'clients':
        if not isinstance(desired, list) or not isinstance(actual, list):
            return False
        if len(desired) != len(actual):
            return False
        def client_key(c):
            if isinstance(c, dict):
                return c.get('id') or c.get('email') or ''
            return str(c)
        desired_sorted = sorted(desired, key=client_key)
        actual_sorted = sorted(actual, key=client_key)
        for d_client, a_client in zip(desired_sorted, actual_sorted):
            if client_key(d_client) != client_key(a_client):
                return False
            if not subset(d_client, a_client, 'client'):
                return False
        return True
    if isinstance(desired, dict):
        if not isinstance(actual, dict):
            return False
        for k, v in desired.items():
            if k not in actual:
                if v is None or v == {}:
                    continue
                return False
            if not subset(v, actual[k], k):
                return False
        return True
    if isinstance(desired, list):
        if not isinstance(actual, list) or len(desired) != len(actual):
            return False
        if desired and isinstance(desired[0], dict) and 'id' in desired[0]:
            actual_sorted = sorted(actual, key=lambda c: c.get('id', ''))
            desired_sorted = sorted(desired, key=lambda c: c.get('id', ''))
            return all(subset(a, b, '') for a, b in zip(desired_sorted, actual_sorted))
        return all(subset(a, b, '') for a, b in zip(desired, actual))
    return desired == actual


def wanted_inbound(payload, r, current=None):
    keys = material(payload['workspaceId'], r['id'], r.get('realitySeed'))
    clients = [dict(id=client_id(payload['workspaceId'], r['id'], u['id']),
        email='ar_' + r['id'] + '_' + u['id'], enable=u['enabled'],
        flow='xtls-rprx-vision' if r['transport'] == 'raw' else '',
        totalGB=0, expiryTime=0, limitIp=0, tgId=0, subId='', reset=0)
        for u in payload['users'] if not r.get('internal', False)]
    from egress_access import clients_for
    for service_client in clients_for(current):
        clients.append({**service_client, 'flow': 'xtls-rprx-vision' if r['transport'] == 'raw' else ''})
    stream = dict(network='tcp' if r['transport'] == 'raw' else 'xhttp', security=r['security'])
    if r['security'] == 'reality':
        stream['realitySettings'] = dict(show=False, target=r['target'], xver=0,
            # Owner policy: never gate REALITY clients by their reported version.
            minClientVer='0.0.0',
            serverNames=[r['sni']], privateKey=keys['privateKey'], shortIds=keys.get('shortIds', [keys['shortId']]),
            settings=dict(publicKey=keys['publicKey'], fingerprint=r.get('fingerprint', 'chrome'), serverName=r['sni'], spiderX='/'))
    else:
        stream['tlsSettings'] = dict(serverName=r['sni'], minVersion='1.2',
            alpn=['h2', 'http/1.1'], certificates=[dict(certificateFile=r['certificate'], keyFile=r['certificateKey'], usage='encipherment')])
    if r['transport'] == 'xhttp':
        stream['xhttpSettings'] = dict(path=r['path'], host=r['host'], mode=r['mode'], **copy.deepcopy(r.get('xhttp', {})))
        if 'sessionIDTable' in stream['xhttpSettings']:
            stream['xhttpSettings'].setdefault('sessionIDLength', '16-32')
    wanted = dict(remark=marker(payload['workspaceId'], r['id']), enable=r['enabled'],
        listen=r['listen'], port=r['port'], protocol='vless', expiryTime=0,
        settings=canonical(dict(clients=clients, decryption='none', fallbacks=[])),
        streamSettings=canonical(stream), sniffing=canonical(dict(enabled=True, destOverride=['http', 'tls', 'quic', 'fakedns'], metadataOnly=False, routeOnly=False)))
    if current:
        # Retain unknown unrelated panel fields. Only managed transport/client
        # configuration is replaced, after comparison with our last observation.
        return {**current, **wanted}
    return {**wanted, 'up': 0, 'down': 0, 'total': 0}


def owned_rows(store):
    return {row['id']: json.loads(row['data']) for row in store.db.execute('SELECT * FROM vless_resources')}


def locate(rows, workspace, resource):
    matches = [r for r in rows if r.get('remark') == marker(workspace, resource)]
    if len(matches) > 1: raise VlessError('vless_conflict')
    return matches[0] if matches else None


# Top-level panel columns AntiRKN never relies on for equality when they are
# absent from an older observation. 3x-ui adds such columns on upgrade with a
# default value (3.11: excludeFromSub=false); that is not a foreign edit.
_STRUCTURAL_KEYS = {'id', 'remark', 'enable', 'listen', 'port', 'protocol', 'settings', 'streamSettings', 'sniffing', 'tag'}


def _is_default(value):
    return value is None or value is False or value == 0 or value == '' or value == [] or value == {}


def observed_fingerprint(normalized, expected_hash=None):
    """digest(normalized), or expected_hash when the row differs from that observation
    only by panel-added top-level columns that still hold their default value."""
    actual = digest(normalized)
    if expected_hash is None or actual == expected_hash or not isinstance(normalized, dict):
        return actual
    import itertools
    optional = sorted(k for k, v in normalized.items() if k not in _STRUCTURAL_KEYS and _is_default(v))
    for size in range(1, min(len(optional), 6) + 1):
        for dropped in itertools.combinations(optional, size):
            if digest({k: v for k, v in normalized.items() if k not in dropped}) == expected_hash:
                return expected_hash
    return actual


def matches_observation(api, row, workspace, resource, observed_hash):
    """Confirm drift against the same endpoint used for saved readback.

    The list API may enrich a row with read-only fields absent from /get/:id.
    Only fetch the detail when the cheap list comparison differs; a genuine
    change in the persisted row must still fail the ownership check.
    """
    if row is None or observed_hash is None:
        return False
    normalized = normal(row)
    if observed_fingerprint(normalized, observed_hash) == observed_hash:
        return True
    # v41 and older saved /list fingerprints before originNodeGuid and
    # fallbackParent became read-only annotations in the current normalizer.
    # Accept that exact legacy representation during upgrade; the next
    # successful write replaces it with the current detail fingerprint.
    annotated = copy.deepcopy(normalized)
    for key in ('originNodeGuid', 'fallbackParent'):
        if key in row:
            annotated[key] = copy.deepcopy(row[key])
    if annotated != normalized and digest(annotated) == observed_hash:
        return True
    detail = api.call('/panel/api/inbounds/get/%d' % row['id'])
    if not isinstance(detail, dict) or detail.get('id') != row['id'] or detail.get('remark') != marker(workspace, resource):
        raise VlessError('vless_api_failed')
    return observed_fingerprint(normal(detail), observed_hash) == observed_hash


def preflight(store, payload, api, rows=None):
    check_revocations(store, payload)
    if rows is None:
        rows = api.call('/panel/api/inbounds/list')
    if not isinstance(rows, list): raise VlessError('vless_api_failed')
    saved = owned_rows(store)
    adopted = {}
    for r in payload['resources']:
        if 'adoption' in r:
            import managed_existing
            adopted[r['id']] = managed_existing.preflight(store, payload, r, saved.get(r['id']), 'vless', inbounds=rows)
            continue
        current = locate(rows, payload['workspaceId'], r['id'])
        previous = saved.get(r['id'])
        if previous and previous['workspaceId'] != payload['workspaceId']: raise VlessError('vless_conflict')
        if current:
            matched = False
            if previous and previous.get('observedHash'):
                matched = matches_observation(api, current, payload['workspaceId'], r['id'], previous['observedHash'])
            if not matched:
                wanted = wanted_inbound(payload, r, current)
                desired = normal(wanted)
                actual = normal(current)
                for k in ('id', 'tag', 'up', 'down', 'total', 'userId', 'nodeId'):
                    desired.pop(k, None)
                    actual.pop(k, None)
                if subset(desired, actual) and not r.get('deleted'):
                    has_active_job = bool(store.db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone())
                    if not has_active_job and previous and not previous.get('deleted'):
                        try:
                            detail = api.call('/panel/api/inbounds/get/%d' % current['id'])
                            detail_row = detail if isinstance(detail, dict) and detail.get('id') == current['id'] and detail.get('remark') == marker(payload['workspaceId'], r['id']) else current
                            previous['observedHash'] = digest(normal(detail_row))
                            previous['panelId'] = payload['panelId']
                            with store.db:
                                store.db.execute('INSERT INTO vless_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data',
                                    (r['id'], canonical(previous)))
                        except Exception:
                            pass
                    matched = True
            if not matched:
                raise VlessError('vless_conflict')
        if previous and not current and not (previous.get('deleted') or r.get('deleted')): raise VlessError('vless_conflict')
    # Every currently managed resource in this workspace must participate, so a
    # stale device cannot silently drop clients/resources through a partial list.
    if any(p['workspaceId'] == payload['workspaceId'] and not p.get('deleted') and locate(rows, p['workspaceId'], rid) is not None and rid not in {r['id'] for r in payload['resources']} for rid, p in saved.items()):
        raise VlessError('vless_conflict')
    active = [r for r in payload['resources'] if r['enabled'] and not r['deleted'] and 'adoption' not in r]
    reserved = [(r['listen'], r['port'], r['id']) for r in active]
    for i, (address, port, rid) in enumerate(reserved):
        for other_address, other_port, other_id in reserved[:i]:
            if port == other_port and (address == other_address or address in ('0.0.0.0','::') or other_address in ('0.0.0.0','::')):
                raise VlessError('vless_port_busy')
        current = locate(rows, payload['workspaceId'], rid)
        for other in rows:
            if other.get('enable') and other.get('port') == port and (not current or other['id'] != current['id']):
                other_listen = other.get('listen') or ''
                # Two specific non-wildcard addresses on the same port can coexist.
                if other_listen not in ('', '0.0.0.0', '::') and address not in ('0.0.0.0', '::') and other_listen != address:
                    continue
                raise VlessError('vless_port_busy')
        if current is None or not current.get('enable') or (current.get('listen'), current.get('port')) != (address, port):
            try:
                with socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET, socket.SOCK_STREAM) as sock:
                    sock.bind((address, port))
            except OSError: raise VlessError('vless_port_busy')
    for r in active:
        if r['security'] == 'tls':
            matched = command(['/usr/bin/openssl','x509','-in',r['certificate'],'-noout','-checkhost',r['sni']])
            if b'does match certificate' not in matched: raise VlessError('vless_invalid')
            command(['/usr/bin/openssl','x509','-in',r['certificate'],'-noout','-checkend','3600'])
            # Xray validates key matching and file readability below.
        config = wanted_inbound(payload, r)
        inbound = dict(listen=r['listen'], port=r['port'], protocol='vless',
            settings=json.loads(config['settings']), streamSettings=json.loads(config['streamSettings']))
        inbound['settings']['clients'] = [c for c in inbound['settings']['clients'] if c['enable']]
        command([str(PANEL / 'bin/xray-linux-amd64'),'run','-test','-config','stdin:'], input_data=canonical(dict(inbounds=[inbound],outbounds=[dict(protocol='freedom')])).encode())
    fingerprint = digest(dict(rows=sorted([normal(r) for r in rows], key=lambda r:r['id']), saved=saved, desired=payload, adopted=adopted))
    return dict(fingerprint=fingerprint, resources=len(payload['resources']), users=len(payload['users']),
                creates=sum(locate(rows,payload['workspaceId'],r['id']) is None and not r['deleted'] for r in payload['resources']),
                deletes=sum(r['deleted'] and locate(rows,payload['workspaceId'],r['id']) is not None for r in payload['resources']),
                updates=sum(locate(rows,payload['workspaceId'],r['id']) is not None and not r['deleted'] for r in payload['resources']))


def plan(store, req):
    payload = parse_payload(req['payload'])
    if payload['panelId'] != req['id']: raise VlessError()
    return preflight(store, payload, panel_for(store, payload['panelId']))


def state(store, panel_id, pending_job=None):
    api = panel_for(store, panel_id)
    rows = api.call('/panel/api/inbounds/list')
    result = []
    for rid, saved in owned_rows(store).items():
        if saved.get('adopted'):
            import managed_existing
            result.append(managed_existing.state(store, saved, 'vless', pending_job, inbounds=rows))
            continue
        current = locate(rows, saved['workspaceId'], rid)
        if current is None:
            is_deleted = True
            confirmed = True
            exists = False
            if not saved.get('deleted'):
                saved['deleted'] = True
                saved['observedHash'] = None
                with store.db:
                    store.db.execute('INSERT INTO vless_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data',
                        (rid, canonical(saved)))
        else:
            is_deleted = False
            exists = True
            deleted_changed = False
            if saved.get('deleted'):
                saved['deleted'] = False
                if not saved.get('observedHash'):
                    saved['observedHash'] = digest(normal(current))
                deleted_changed = True
            panel_updated = False
            if saved.get('panelId') != panel_id:
                saved['panelId'] = panel_id
                panel_updated = True
            if deleted_changed or panel_updated:
                with store.db:
                    store.db.execute('INSERT INTO vless_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data',
                        (rid, canonical(saved)))
            confirmed = matches_observation(api, current, saved['workspaceId'], rid, saved.get('observedHash'))
            if not confirmed:
                try:
                    payload = dict(
                        workspaceId=saved['workspaceId'],
                        panelId=panel_id,
                        resources=[saved['spec']],
                        users=[{'id': c['id'], 'enabled': c.get('enable', c.get('enabled', True))} for c in saved.get('clients', [])]
                    )
                    wanted = wanted_inbound(payload, saved['spec'], current)
                    ok, _ = verify_inbound_spec(wanted, current)
                    if ok:
                        confirmed = True
                except Exception:
                    pass
        result.append(dict(id=rid, spec=saved['spec'], workspaceId=saved['workspaceId'],
            confirmed=confirmed, deleted=is_deleted, exists=exists,
            publicKey=saved['publicKey'], shortId=saved['shortId'],
            clients=saved['clients'], revision=saved['revision']))
    return result


class VlessApply:
    def __init__(self, store, req):
        self.store, self.req = store, req
        self.payload = parse_payload(req['payload'])
        if req['count'] != len(self.payload['resources']) + 2 or req['interval'] != 1: raise VlessError()

    def step(self, checkpoint):
        p, db = self.payload, self.store.db
        check_revocations(self.store, p)
        api = panel_for(self.store, p['panelId'])
        job_id = self.req['id']
        if checkpoint == 0:
            rows = api.call('/panel/api/inbounds/list')
            preview = preflight(self.store, p, api, rows=rows)
            if preview['fingerprint'] != self.req['fingerprint']: raise VlessError('vless_conflict')
            check_revocations(self.store, p, persist=True)
            backup = self.store.directory / ('vless-backup-' + job_id + '.json')
            if not backup.exists():
                from panel_clients import capture
                deleted = [r for r in p['resources'] if r['deleted'] and 'adoption' not in r]
                listed = api.call('/panel/api/clients/list') if deleted else []
                refs = {r['id']: capture(row, listed) for r in deleted
                        if (row := locate(rows, p['workspaceId'], r['id'])) is not None}
                atomic_file(backup, canonical(dict(rows=rows, resources=owned_rows(self.store), clientRefs=refs)).encode())
            code = 'vless_preparing'
        elif checkpoint <= len(p['resources']):
            r = p['resources'][checkpoint - 1]
            if 'adoption' in r:
                import managed_existing
                managed_existing.apply(self.store, self.req, p, r, owned_rows(self.store).get(r['id']), 'vless', checkpoint)
                return
            rows = api.call('/panel/api/inbounds/list')
            current = locate(rows, p['workspaceId'], r['id'])
            previous = owned_rows(self.store).get(r['id'])
            wanted = wanted_inbound(p, r, current)
            desired = normal(wanted)
            for k in ('id','tag','up','down','total','userId','nodeId'): desired.pop(k,None)
            already = current is None if r['deleted'] else current is not None and subset(desired, normal(current))
            created_id = None
            if not already:
                if current and (not previous or not matches_observation(api, current, p['workspaceId'], r['id'], previous['observedHash'])): raise VlessError('vless_conflict')
                if not current and previous and not (previous.get('deleted') or r.get('deleted')): raise VlessError('vless_conflict')
                if r['deleted']:
                    if current: api.call('/panel/api/inbounds/del/%d' % current['id'], {})
                elif current:
                    api.call('/panel/api/inbounds/update/%d' % current['id'], wanted)
                else:
                    created = api.call('/panel/api/inbounds/add', wanted)
                    if isinstance(created, dict) and isinstance(created.get('id'), int):
                        created_id = created['id']
            readback_id = current['id'] if current and not r['deleted'] else created_id
            if readback_id is not None:
                observed = api.call('/panel/api/inbounds/get/%d' % readback_id)
                if not isinstance(observed, dict) or observed.get('remark') != marker(p['workspaceId'], r['id']):
                    raise VlessError('vless_api_failed')
            else:
                observed = locate(api.call('/panel/api/inbounds/list'), p['workspaceId'], r['id'])
            if r['deleted']:
                if observed is not None: raise VlessError('vless_api_failed')
                from panel_clients import cleanup
                backup = self.store.directory / ('vless-backup-' + job_id + '.json')
                safe_file(backup, 16777216)
                refs = json.loads(backup.read_text()).get('clientRefs', {}).get(r['id'], [])
                cleanup(api, refs)
            elif observed is None or not subset(desired, normal(observed)):
                raise VlessError('vless_api_failed')
            keys = material(p['workspaceId'], r['id'], r.get('realitySeed'))
            data = dict(workspaceId=p['workspaceId'], panelId=p['panelId'], spec=r,
                observedHash=digest(normal(observed)) if observed else None, deleted=r['deleted'],
                publicKey=keys['publicKey'], shortId=keys['shortId'], revision=digest(p),
                clients=[dict(id=u['id'], uuid=client_id(p['workspaceId'],r['id'],u['id']),enabled=u['enabled']) for u in p['users'] if not r.get('internal', False)])
            with db:
                db.execute('INSERT INTO vless_resources VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data', (r['id'], canonical(data)))
                db.execute('UPDATE jobs SET checkpoint=? WHERE id=?',(checkpoint+1,job_id))
                self.store.event(job_id,'vless_applying',checkpoint+1,self.req['count'])
            return
        else:
            api.call('/panel/api/server/restartXrayService', {})
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                status = api.call('/panel/api/server/status')
                if isinstance(status, dict) and isinstance(status.get('xray'), dict) and status['xray'].get('state') == 'running': break
                time.sleep(.25)
            else: raise VlessError('vless_api_failed')
            for r in state(self.store, p['panelId'], pending_job=job_id):
                if r['workspaceId'] == p['workspaceId'] and not r['confirmed']: raise VlessError('vless_conflict')
            code = 'vless_checking'
        with db:
            db.execute('UPDATE jobs SET checkpoint=? WHERE id=?',(checkpoint+1,job_id))
            self.store.event(job_id,code,checkpoint+1,self.req['count'])

    def rollback(self):
        job_id = self.req['id']
        backup_file = self.store.directory / ('vless-backup-' + job_id + '.json')
        if not backup_file.exists():
            return
        try:
            if backup_file.stat().st_size > 16777216:
                return
            data = json.loads(backup_file.read_text())
            with self.store.db:
                self.store.db.execute("DELETE FROM vless_resources WHERE data LIKE ?", (f'%"workspaceId":"{self.payload["workspaceId"]}"%',))
                for r_id, r_data in data.get('resources', {}).items():
                    self.store.db.execute("INSERT OR REPLACE INTO vless_resources VALUES (?,?)", (r_id, canonical(r_data)))
            try:
                api = panel_for(self.store, self.payload['panelId'])
                current_inbounds = api.call('/panel/api/inbounds/list')
                backup_rows = data.get('rows', [])
                backup_by_id = {row['id']: row for row in backup_rows}
                for cur in current_inbounds:
                    if cur['id'] not in backup_by_id and marker(self.payload['workspaceId'], '') in cur.get('remark', ''):
                        try: api.call('/panel/api/inbounds/del/%d' % cur['id'], {})
                        except Exception: pass
                for old_row in backup_rows:
                    cur = next((c for c in current_inbounds if c['id'] == old_row['id']), None)
                    if cur and normal(cur) != normal(old_row):
                        try: api.call('/panel/api/inbounds/update/%d' % old_row['id'], old_row)
                        except Exception: pass
                try: api.call('/panel/api/server/restartXrayService', {})
                except Exception: pass
            except Exception:
                pass
        finally:
            backup_file.unlink(missing_ok=True)
