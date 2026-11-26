"""3x-ui client records: bring an inbound to a wanted row, and remove client
records only after their last inbound was deleted.

Since 3x-ui 3.9 ``/panel/api/inbounds/update/:id`` keeps the stored client list
and the stored ``enable`` flag; clients change through ``/panel/api/clients/*``
(applied to the running Xray without a restart) and the inbound switch through
``/panel/api/inbounds/setEnable/:id``. Older panels (3.7, 3.8) still apply
both through update, where the reconciliation below then finds nothing to do.
"""
import copy
import json
from urllib.parse import quote

from vless import VlessError, canonical, digest, normal, normalize_3xui_inbound, subset, verify_inbound_spec

IDENTITY_FIELDS = ('uuid', 'password', 'auth', 'secret', 'publicKey')
# A record field and the inbound client field holding the same credential.
CREDENTIALS = (('uuid', 'id'), ('password', 'password'), ('auth', 'auth'))


def identity(record):
    return digest({key: record.get(key) for key in IDENTITY_FIELDS})


def settings_of(row, code='vless_api_failed'):
    """A parsed copy of the row's settings."""
    settings = copy.deepcopy(row.get('settings') or {})
    if isinstance(settings, str):
        try:
            settings = json.loads(settings)
        except ValueError:
            raise VlessError(code) from None
    if not isinstance(settings, dict) or not isinstance(settings.get('clients', []), list):
        raise VlessError(code)
    return settings


def clients_of(row):
    return settings_of(row).get('clients', [])


def client_key(client):
    """VLESS/VMess clients carry an id, Trojan/Shadowsocks a password."""
    if not isinstance(client, dict):
        return None
    return client.get('id') or client.get('password') or client.get('auth') or client.get('email')


def keyed(clients):
    """Clients by identity, or None when one has none or two share it."""
    result = {}
    for client in clients:
        key = client_key(client)
        if not isinstance(key, str) or not key or key in result:
            return None
        result[key] = client
    return result


def _norm(client):
    return normalize_3xui_inbound(dict(settings=dict(clients=[client])))['settings']['clients']


def differs(want, have):
    """have lacks a value of want. The panel may annotate a client with more
    fields; flow is compared both ways, since an absent flow is a value."""
    ok, _ = verify_inbound_spec(dict(settings=dict(clients=[want])), dict(settings=dict(clients=[have])))
    return not ok or (want.get('flow') or '') != (have.get('flow') or '')


def changed_clients(before, wanted):
    """Identities whose client the transition from before to wanted adds,
    removes or edits. Every other client stays as the panel holds it."""
    old, new = clients_of(before), clients_of(wanted)
    if canonical(_norm_list(old)) == canonical(_norm_list(new)):
        return set()
    b, w = keyed(old), keyed(new)
    if b is None or w is None:
        raise VlessError('vless_api_failed')
    return {k for k in set(b) | set(w) if k not in b or k not in w or _norm(b[k]) != _norm(w[k])}


def _norm_list(clients):
    return sorted((canonical(_norm(c)) for c in clients))


def read(api, inbound_id):
    detail = api.call('/panel/api/inbounds/get/%d' % inbound_id)
    if not isinstance(detail, dict) or detail.get('id') != inbound_id:
        raise VlessError('vless_api_failed')
    return detail


def client_ops(wanted, current, scope):
    if scope is not None and not scope:
        return []
    want_list, have_list = clients_of(wanted), clients_of(current)
    if canonical(_norm_list(want_list)) == canonical(_norm_list(have_list)):
        return []
    want, have = keyed(want_list), keyed(have_list)
    if want is None or have is None:
        raise VlessError('vless_api_failed')
    touched = (lambda k: True) if scope is None else (lambda k: k in scope)
    ops = [('remove', c, None) for k, c in sorted(have.items()) if k not in want and touched(k)]
    for k, c in sorted(want.items()):
        if not touched(k):
            continue
        if k not in have:
            ops.append(('add', c, None))
        elif differs(c, have[k]):
            ops.append(('update', c, have[k]))
    return ops


def same_credentials(record, client):
    return all(not client.get(field) or not record.get(column) or record[column] == client[field]
               for column, field in CREDENTIALS)


def _email(client):
    email = client.get('email')
    if not isinstance(email, str) or not email:
        raise VlessError('vless_api_failed')
    return email, quote(email, safe='')


def apply_client(api, inbound_id, op, client, observed, records):
    """One client route. A client record is global and may be attached to
    other inbounds too: removal detaches it from this inbound unless it is the
    record's last one, and a re-added email reuses its record by attaching."""
    if op == 'update':
        _, encoded = _email(observed)
        api.call('/panel/api/clients/update/' + encoded, client)
        return
    email, encoded = _email(client)
    record = records.get(email)
    if record is not None and not same_credentials(record, client):
        raise VlessError('vless_conflict')
    if op == 'remove':
        others = [i for i in (record or {}).get('inboundIds') or [] if i != inbound_id]
        if others:
            api.call('/panel/api/clients/%s/detach' % encoded, dict(inboundIds=[inbound_id]))
        else:
            api.call('/panel/api/clients/del/' + encoded, {})
    elif record is not None:
        api.call('/panel/api/clients/%s/attach' % encoded, dict(inboundIds=[inbound_id]))
    else:
        api.call('/panel/api/clients/add', dict(inboundIds=[inbound_id], client=client))


def converge(api, inbound_id, wanted, before=None):
    """Bring inbound ``inbound_id`` to ``wanted`` and return its readback.

    ``before`` is the row the caller planned ``wanted`` from: only the clients
    and the ``enable`` flag that this plan changes are then touched, so
    foreign clients of an adopted inbound (and their later panel edits) stay.
    Without it every client of the row follows ``wanted``. Each step is
    decided by a fresh readback, so a repeated call after a crash converges.
    The caller still verifies the returned row strictly."""
    api.call('/panel/api/inbounds/update/%d' % inbound_id, wanted)
    current = read(api, inbound_id)
    scope = None if before is None else changed_clients(before, wanted)
    # A second round updates a client that the first one re-attached.
    for _ in range(2):
        ops = client_ops(wanted, current, scope)
        if not ops:
            break
        listed = api.call('/panel/api/clients/list')
        if not isinstance(listed, list):
            raise VlessError('vless_api_failed')
        records = {r.get('email'): r for r in listed if isinstance(r, dict)}
        for op, client, observed in ops:
            apply_client(api, inbound_id, op, client, observed, records)
        current = read(api, inbound_id)
    enable = wanted.get('enable')
    if (type(enable) is bool and current.get('enable') is not enable
            and (before is None or before.get('enable') is not enable)):
        api.call('/panel/api/inbounds/setEnable/%d' % inbound_id, dict(enable=enable))
        current = read(api, inbound_id)
    return current


def in_transition(before, after, current):
    """current is a state converge() leaves on its way from before to after:
    the row update applied or not, part of the changed clients done, the
    switch either way. Anything else, such as a client neither side holds or
    a foreign edit of another field, is not."""
    if not all(isinstance(row, dict) for row in (before, after, current)):
        return False
    try:
        sides = [keyed(clients_of(row)) for row in (before, after)]
        have = keyed(clients_of(current))
    except VlessError:
        return False
    if have is None or None in sides:
        return False
    b, a = sides
    for key, client in have.items():
        if not any(key in side and not differs(side[key], client) for side in sides):
            return False
    if any(key not in have for key in set(b) & set(a)):
        return False
    if current.get('enable') not in (before.get('enable'), after.get('enable')):
        return False

    def pinned(row):
        value = copy.deepcopy(row)
        settings = settings_of(row)
        settings['clients'] = copy.deepcopy(clients_of(current))
        value['settings'] = canonical(settings)
        value['enable'] = current.get('enable')
        return normal(value)
    actual = normal(current)
    return subset(pinned(after), actual) or subset(pinned(before), actual)


def capture(row, listed):
    settings = settings_of(row, 'vless_invalid')
    by_email = {c.get('email'): c for c in listed if isinstance(c, dict) and isinstance(c.get('email'), str)}
    result = []
    for client in settings.get('clients', []):
        if not isinstance(client, dict):
            raise VlessError('vless_invalid')
        email = client.get('email')
        if not isinstance(email, str) or not email:
            continue
        record = by_email.get(email)
        if record is not None:
            if type(record.get('id')) is not int or record['id'] < 1:
                raise VlessError('vless_api_failed')
            result.append(dict(email=email, id=record['id'], identity=identity(record)))
    return result


def cleanup(api, refs):
    """A changed/reused or shared client is never removed by this operation."""
    if not refs:
        return
    # One listing for all references; each candidate is re-read point-wise
    # before its deletion, and one listing afterwards confirms the result.
    rows = api.call('/panel/api/clients/list')
    if not isinstance(rows, list):
        raise VlessError('vless_api_failed')
    removed = []
    for ref in refs:
        email = ref['email']
        encoded = quote(email, safe='')
        record = next((c for c in rows if isinstance(c, dict) and c.get('email') == email), None)
        if record is None or record.get('id') != ref['id'] or identity(record) != ref['identity']:
            continue
        if record.get('inboundIds'):
            continue
        detail = api.call('/panel/api/clients/get/' + encoded)
        if (not isinstance(detail, dict) or not isinstance(detail.get('client'), dict)
                or detail['client'].get('id') != ref['id']
                or identity(detail['client']) != ref['identity']
                or detail.get('inboundIds') is None):
            raise VlessError('vless_api_failed')
        if detail['inboundIds']:
            continue
        api.call('/panel/api/clients/del/' + encoded, {})
        removed.append(ref['id'])
    if removed:
        after = api.call('/panel/api/clients/list')
        if not isinstance(after, list) or any(
                isinstance(c, dict) and c.get('id') in removed for c in after):
            raise VlessError('vless_api_failed')
