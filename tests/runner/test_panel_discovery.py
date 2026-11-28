import hashlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from panel import install_cli, PanelError
from panel_discovery import discover, read_database
from runner import Store


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.path = self.directory / 'x-ui.db'
        db = sqlite3.connect(self.path)
        db.executescript('CREATE TABLE settings (key TEXT, value TEXT); '
            'CREATE TABLE inbounds (id INTEGER, remark TEXT, enable INTEGER, '
            'listen TEXT, port INTEGER, protocol TEXT, stream_settings TEXT); '
            "INSERT INTO settings VALUES ('webPort','4321'),('webListen','127.0.0.1'),"
            "('webBasePath','wgI1mnzsb9DYDpWUDv'),('secret','never-export');")
        db.execute('INSERT INTO inbounds VALUES (1, ?, 1, ?, 443, ?, ?)',
            ('Existing inbound', '::', 'vless', json.dumps(dict(network='xhttp', security='reality',
                realitySettings=dict(privateKey='never-export-private')))))
        db.commit(); db.close()
        self.store = Store(self.directory)
        self.safe = patch('panel_discovery.safe_file').start()
    def tearDown(self):
        patch.stopall(); self.store.close(); self.temp.cleanup()

    def test_existing_panel_settings_and_inbounds_are_read_without_credentials_or_writes(self):
        before = self.path.read_bytes()
        result = read_database(self.path, 'systemd')
        self.assertEqual((result['port'], result['basePath'], result['listen']), (4321, '/wgI1mnzsb9DYDpWUDv/', '127.0.0.1'))
        self.assertEqual(result['inbounds'][0]['transport'], 'xhttp')
        self.assertNotIn('never-export', json.dumps(result))
        self.assertEqual(before, self.path.read_bytes())
        self.assertFalse((self.directory / 'x-ui.db-journal').exists())

    def test_temporary_target_probe_inbounds_are_not_listed(self):
        db = sqlite3.connect(self.path)
        db.execute('INSERT INTO inbounds VALUES (2, ?, 1, ?, 23456, ?, ?)',
            ('AntiRKN:probe:' + 'e' * 32, '', 'vless', json.dumps(dict(network='tcp', security='reality'))))
        db.commit(); db.close()
        result = read_database(self.path, 'systemd')
        self.assertEqual([row['id'] for row in result['inbounds']], [1])

    def test_failed_read_is_not_an_empty_success(self):
        with patch('panel_discovery.databases', return_value=[(self.path, 'systemd')]), patch('panel_discovery.safe_file', side_effect=PanelError('panel_conflict')):
            result, access = discover(self.store)
        self.assertTrue(result['failed']); self.assertEqual(result['panels'], []); self.assertIsNone(access)

    def test_recovery_uses_panel_history_even_if_latest_job_is_diagnostic(self):
        request = dict(version=1, action='submit', id='a'*32, kind='panel_install', count=6, interval=1, port=4321, fingerprint='b'*64)
        self.store.request(request)
        self.store.db.execute("UPDATE jobs SET status='succeeded'"); self.store.db.commit()
        db = sqlite3.connect(self.path); db.execute("UPDATE settings SET value='/' WHERE key='webBasePath'"); db.commit(); db.close()
        self.store.request(dict(version=1, action='submit', id='c'*32, kind='diagnostic', count=1, interval=1))
        self.store.db.execute("UPDATE jobs SET status='succeeded'"); self.store.db.commit()
        with patch('panel_discovery.databases', return_value=[(self.path, 'systemd')]), patch('panel_discovery.PanelInstaller.assert_owned'), patch('panel_discovery.access_for', return_value=dict(id='a'*32, port=4321)):
            _, access = discover(self.store)
        self.assertEqual(access['id'], 'a'*32)

    def test_official_cli_is_hash_checked_executable_and_never_overwrites_existing(self):
        cli = self.directory / 'x-ui-menu'
        (self.directory / 'x-ui').write_bytes(b'fixture binary')
        raw = b'#!/bin/bash\nexit 0\n'
        response = io.BytesIO(raw); response.geturl = lambda: 'https://fixture.invalid/official'
        with patch('panel.CLI', cli), patch('panel.PANEL', self.directory), patch('panel.safe_file'), patch('panel.RELEASE', {'cli': {'url':'https://fixture.invalid/official','sha256': hashlib.sha256(raw).hexdigest(),'bytes':len(raw)}}), patch('panel.urllib.request.build_opener') as opener:
            opener.return_value.open.return_value = response
            install_cli()
            self.assertEqual(cli.read_bytes(), raw); self.assertEqual(cli.stat().st_mode & 0o777, 0o755)
            cli.write_bytes(b'administrator menu')
            install_cli()
            self.assertEqual(cli.read_bytes(), b'administrator menu'); self.assertEqual(opener.call_count, 1)


class RealityScanTests(unittest.TestCase):
    def test_scan_uses_official_panel_endpoint_with_form_fields(self):
        from runner import Store
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as directory:
            store = Store(directory)
            api = Mock()
            result = dict(feasible=True, tls13=True, h2=True, x25519=True, certValid=True, host='example.com')
            api.call.return_value = result
            try:
                with patch('runner.panel_for', return_value=api):
                    response = store.request(dict(version=1, action='reality_scan', id='a'*32, target='example.com:443', sni='example.com'))
                self.assertEqual(response['realityScan'], result)
                api.call.assert_called_once_with('/panel/api/server/scanRealityTarget', dict(target='example.com:443', sni='example.com', xver='0', allowPrivate='false'), form=True)
                self.assertEqual(store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 0)
                for target in ['example.com;id', 'https://example.com', 'example.com\n']:
                    with self.assertRaises(ValueError): store.request(dict(version=1, action='reality_scan', id='a'*32, target=target, sni=''))
            finally: store.close()
