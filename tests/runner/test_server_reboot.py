import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import server_reboot as reboot
from runner import Store


class ServerRebootTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.boot = self.root / 'boot'
        self.boot.write_text('original-boot')
        self.store = Store(self.root)
        self.req = dict(version=1, action='submit', id='b'*32,
                        kind='server_reboot', count=2, interval=1)
        self.commands = []
        self.armed = False
        self.fail = False
        self.patches = [patch.object(reboot, 'BOOT', self.boot),
                        patch.object(reboot, 'safe_file', lambda *a: None),
                        patch.object(reboot, 'command', self.command)]
        for p in self.patches: p.start()

    def tearDown(self):
        for p in reversed(self.patches): p.stop()
        self.store.close()
        self.temp.cleanup()

    def command(self, args):
        self.commands.append(args)
        if 'is-active' in args and not self.armed: raise RuntimeError()
        if args[0] == '/usr/bin/systemd-run': self.armed = True
        if args == ['/usr/bin/systemctl', 'reboot'] and self.fail: raise RuntimeError()
        return b''

    def job(self):
        return self.store.request(dict(version=1, action='status', id=self.req['id'], cursor=0))['jobs'][0]

    def start(self):
        self.assertEqual(self.store.request(self.req)['code'], 'ok')
        self.store.tick()

    def test_boot_readback_and_replay_never_reboot_twice(self):
        self.start()
        self.assertEqual(self.job()['checkpoint'], 1)
        self.assertEqual(self.job()['status'], 'running')
        self.store.tick()
        reboot.execute(self.store, self.req['id'])
        reboot.execute(self.store, self.req['id'])
        self.store.request(self.req)
        self.store.tick()
        self.assertEqual(self.job()['status'], 'running')
        self.boot.write_text('new-boot')
        self.store.close()
        self.store = Store(self.root)
        self.store.recover()
        self.store.tick()
        self.assertEqual(self.job()['status'], 'succeeded')
        self.assertEqual(self.job()['checkpoint'], 2)
        self.store.request(self.req)
        reboot.execute(self.store, self.req['id'])
        self.assertEqual(self.commands.count(['/usr/bin/systemctl', 'reboot']), 1)
        self.assertEqual(sum(c[0] == '/usr/bin/systemd-run' for c in self.commands), 1)

    def test_failed_command_is_not_reissued(self):
        self.start()
        self.fail = True
        with self.assertRaises(reboot.RebootError): reboot.execute(self.store, self.req['id'])
        self.store.tick()
        self.assertEqual(self.job()['status'], 'needs_attention')
        reboot.execute(self.store, self.req['id'])
        self.assertEqual(self.commands.count(['/usr/bin/systemctl', 'reboot']), 1)

    def test_expired_unissued_request_cannot_reboot_late(self):
        self.start()
        path = reboot.record_path(self.store, self.req['id'])
        value = json.loads(path.read_text())
        value['created'] = time.time()-181
        reboot.save(path, value)
        with self.assertRaises(reboot.RebootError): reboot.execute(self.store, self.req['id'])
        self.store.tick()
        self.assertEqual(self.job()['status'], 'needs_attention')
        self.assertNotIn(['/usr/bin/systemctl', 'reboot'], self.commands)

    def test_cancel_before_scheduling_has_no_effect(self):
        self.store.request(self.req)
        self.store.request(dict(version=1, action='cancel', id=self.req['id']))
        self.store.tick()
        self.assertEqual(self.job()['status'], 'cancelled')
        self.assertEqual(self.commands, [])

    def test_lost_timer_reply_can_rearm_but_executor_is_one_shot(self):
        self.start()
        self.armed = False
        self.store.tick()
        reboot.execute(self.store, self.req['id'])
        reboot.execute(self.store, self.req['id'])
        self.assertEqual(self.commands.count(['/usr/bin/systemctl', 'reboot']), 1)
