"""Revoked record IDs; client names and logins remain reusable."""


def check(store, payload, persist=False):
    # The runner serializes jobs. Tombstones also protect resumed, older jobs
    # whose immutable payload predates a successful client deletion.
    db = store.db
    workspace = payload['workspaceId']
    requested = set(payload.get('revokedUsers', []))
    revoked = {row[0] for row in db.execute('SELECT user FROM revoked_clients WHERE workspace=?', (workspace,))} | requested
    if any(user['enabled'] and user['id'] in revoked for user in payload['users']):
        raise ValueError('revoked_client')
    if persist and requested:
        with db:
            db.executemany('INSERT OR IGNORE INTO revoked_clients VALUES (?,?)', [(workspace, user) for user in sorted(requested)])
