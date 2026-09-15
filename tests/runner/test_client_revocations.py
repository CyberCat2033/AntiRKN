import copy
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from runner import Store
from client_revocations import check
import awg
import tt
import vless


class ClientRevocationsTests(unittest.TestCase):
    def test_plan_is_read_only_and_same_login_with_new_id_is_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory)
            try:
                revoked = dict(workspaceId='a'*32, revokedUsers=['c'*32],
                    users=[dict(id='c'*32, login='USER', enabled=False)])
                before = store.db.total_changes
                check(store, revoked)
                self.assertEqual(store.db.total_changes, before)
                self.assertEqual(store.db.execute('SELECT COUNT(*) FROM revoked_clients').fetchone()[0], 0)
                check(store, revoked, persist=True)
                check(store, revoked, persist=True)
                self.assertEqual(store.db.execute('SELECT COUNT(*) FROM revoked_clients').fetchone()[0], 1)
                stale = dict(workspaceId='a'*32, users=[dict(id='c'*32, login='USER', enabled=True)])
                for module in [vless, awg, tt]:
                    with self.subTest(protocol=module.__name__), self.assertRaisesRegex(ValueError, 'revoked_client'):
                        if module is vless:
                            module.preflight(store, stale, None)
                        else:
                            module.preflight(store, stale)
                recreated = copy.deepcopy(stale)
                recreated['users'][0]['id'] = 'd'*32
                check(store, recreated, persist=True)
                # The same textual ID in an independent workspace is unrelated.
                stale['workspaceId'] = 'b'*32
                check(store, stale)
            finally:
                store.close()


if __name__ == '__main__':
    unittest.main()
