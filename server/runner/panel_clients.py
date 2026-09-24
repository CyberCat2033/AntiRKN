"""Remove 3x-ui client records only after their last inbound was deleted."""
import json
from urllib.parse import quote

from vless import VlessError, digest

IDENTITY_FIELDS = ('uuid', 'password', 'auth', 'secret', 'publicKey')


def identity(record):
    return digest({key: record.get(key) for key in IDENTITY_FIELDS})


def capture(row, listed):
    settings = row.get('settings') or {}
    if isinstance(settings, str):
        try:
            settings = json.loads(settings)
        except ValueError:
            raise VlessError('vless_invalid') from None
    if not isinstance(settings, dict) or not isinstance(settings.get('clients', []), list):
        raise VlessError('vless_invalid')
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
    for ref in refs:
        email = ref['email']
        encoded = quote(email, safe='')
        rows = api.call('/panel/api/clients/list')
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
        after = api.call('/panel/api/clients/list')
        if any(c.get('id') == ref['id'] for c in after if isinstance(c, dict)):
            raise VlessError('vless_api_failed')
