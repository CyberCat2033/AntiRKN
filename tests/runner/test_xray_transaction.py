import copy
import io
from unittest.mock import Mock
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'server/runner'))
import xray_transaction as x
from runner import Store
REAL_DOWNLOAD=x.download
REAL_RESTART=x.restart
REAL_PANEL_API=x.panel_api

class XrayTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.store=Store(self.root);self.binary=self.root/'xray';self.binary.write_bytes(b'old');self.binary.chmod(0o751)
        self.panel='a'*32;self.key='b'*32;self.lease='c'*32;self.running='26.7.28';self.panel_version='3.8.0';self.panel_down=False
        self.configuration={'settings':{'route':'preserve'},'inbounds':[dict(id=1,enable=True,protocol='vless',remark='one',port=443,settings={'clients':[{'id':'existing'}]})]}
        self.events=[];self.patches=[]
        self.patch(x,'TARGET',{**x.TARGET,'prerelease':False})
        for name,value in [('BINARY',self.binary),('UNITS',self.root/'units')]:self.patch(x,name,value)
        self.patch(x,'safe_file',lambda *a,**k:None)
        self.patch(x,'snapshot',self.snapshot)
        self.patch(x,'leases',lambda *a:[dict(status='active',protocol='vless',rowId=1,saved={'panelId':self.panel},expires=time.time()+900)])
        self.patch(x,'arm',self.arm)
        self.patch(x,'retire',lambda info:self.events.append('retired'))
        self.patch(x,'command',lambda *a,**k:b'')
        self.patch(x,'download',self.download)
        self.patch(x,'config_test',lambda *a:None)
        self.patch(x,'restart',self.restart)
        self.patch(x.os,'chown',lambda *a:None)
        self.patch(x,'panel_api',self.panel_api)
    def arm(self,info):
        # Like the real arm(): the unit file exists before anything else runs.
        (self.root/'units').mkdir(exist_ok=True);(self.root/'units'/x.unit(info['id'],'rollback')).write_text('unit')
        self.events.append('armed')
    def patch(self,obj,name,value):
        p=patch.object(obj,name,value);p.start();self.patches.append(p)
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.store.close();self.temp.cleanup()
    def panel_api(self,store,info):
        self.events.append('panel_api')
        if self.panel_down:raise x.UpdateError('xray_check_panel_api')
    def snapshot(self,*args):
        return dict(panelId=self.panel,panelVersion=self.panel_version,xrayVersion=self.running,
                    configuration=copy.deepcopy(self.configuration),files={str(self.binary):hashlib.sha256(self.binary.read_bytes()).hexdigest()},release='fixture')
    def download(self,path,target):
        self.downloaded=target
        p=path/'candidate';p.write_bytes(b'new');return p
    def restart(self,store,info,version):
        self.events.append('restart');self.running=version
    def request(self,candidate=None,**extra):
        payload=dict(panelId=self.panel,fingerprint=x.vless.digest(self.snapshot()),leases=[self.lease],network='wifi',core='ac017cdd246ce8bd547653d927e7bf77d7ee73d5',baseline=[dict(lease=self.lease,tcp=True,udp=True)],**extra)
        if candidate is not None:payload['candidate']=candidate
        return dict(id=self.key,payload=json.dumps(payload))
    def begin(self,candidate=None):return x.begin(self.store,self.request(candidate))
    @staticmethod
    def chosen(version,sha='a'*64,url=None):
        return dict(version=version,url=url or x.OFFICIAL.format(version),sha256=sha)
    def test_prerelease_target_is_not_offered_or_started(self):
        with patch.object(x,'TARGET',{**x.TARGET,'prerelease':True}):
            candidate=x.plan(self.store,self.panel)
            self.assertIsNone(candidate['candidate'])
            self.assertFalse(candidate['available'])
            with self.assertRaises(x.UpdateError) as error:self.begin()
            self.assertEqual(error.exception.code,'xray_check_invalid')
            self.assertEqual(self.binary.read_bytes(),b'old')
            self.assertEqual(self.events,[])
    def finish(self,begin,commit=True,**overrides):
        payload=dict(nonce=begin['nonce'],manifest=begin['manifest'],network='wifi',checks=[dict(lease=self.lease,tcp=True,udp=True)])
        payload.update(overrides)
        return x.finish(self.store,dict(id=self.key,action='xray_check_commit' if commit else 'xray_check_abort',payload=json.dumps(payload)))
    def test_success_commits_only_after_exact_comparison_and_preserves_mode(self):
        begin=self.begin();self.assertEqual(self.binary.read_bytes(),b'old');self.assertEqual(self.events,['armed'])
        x.apply(self.store,self.key);self.assertEqual(x.load(self.store,self.key)['phase'],'awaiting_checks')
        self.assertEqual(self.binary.stat().st_mode&0o777,0o751)
        self.assertEqual(self.finish(begin)['phase'],'committed');self.assertEqual(self.finish(begin)['phase'],'committed')
        self.assertEqual(self.configuration['settings'],{'route':'preserve'})
    def test_timeout_and_late_commit_restore_previous_binary(self):
        begin=self.begin();x.apply(self.store,self.key)
        info=x.load(self.store,self.key);info['deadline']=time.time()-1;x.save(self.store,info)
        self.assertEqual(self.finish(begin)['phase'],'rolled_back');self.assertEqual(self.binary.read_bytes(),b'old')
        with self.assertRaises(x.UpdateError) as error:self.finish(begin)
        self.assertEqual(error.exception.code,'xray_check_late')
    def test_changed_network_aborts_even_with_successful_checks(self):
        begin=self.begin();x.apply(self.store,self.key)
        self.assertEqual(self.finish(begin,network='mobile')['phase'],'rolled_back')
    def test_missing_or_failed_udp_never_commits(self):
        begin=self.begin();x.apply(self.store,self.key)
        for checks in ([],[dict(lease=self.lease,tcp=True,udp=False)]):
            with self.assertRaises(x.UpdateError):self.finish(begin,checks=checks)
        self.assertEqual(self.finish(begin,commit=False)['phase'],'rolled_back')
    def test_zero_or_missing_coverage_never_mutates(self):
        req=self.request();self.configuration['inbounds'].append(dict(id=2,enable=True,protocol='vless',remark='two',port=444,settings={'clients':[]}))
        req=self.request()
        with self.assertRaises(x.UpdateError):x.begin(self.store,req)
        self.assertEqual(self.binary.read_bytes(),b'old');self.assertEqual(self.events,[])
    def test_watchdog_failure_precedes_all_mutations(self):
        with patch.object(x,'arm',side_effect=OSError()):
            with self.assertRaises(x.UpdateError):self.begin()
        self.assertEqual(self.binary.read_bytes(),b'old');self.assertEqual(x.load(self.store,self.key)['phase'],'not_changed')
    def test_crash_after_manifest_or_after_replace_can_rollback(self):
        for replaced in (False,True):
            with self.subTest(replaced=replaced):
                if replaced:self.key='d'*32
                begin=self.begin();info=x.load(self.store,self.key)
                if replaced:
                    info.update(phase='replacing',newHash=hashlib.sha256(b'new').hexdigest());x.save(self.store,info);self.binary.write_bytes(b'new')
                result=x.rollback(self.store,info)
                self.assertEqual(result['phase'],'rolled_back' if replaced else 'not_changed')
                self.assertEqual(self.binary.read_bytes(),b'old')
    def test_config_validation_failure_leaves_old_binary(self):
        self.begin()
        with patch.object(x,'config_test',side_effect=x.UpdateError('xray_check_config')):x.apply(self.store,self.key)
        self.assertEqual(x.load(self.store,self.key)['phase'],'not_changed');self.assertEqual(self.binary.read_bytes(),b'old')
    def test_foreign_binary_conflict_keeps_backup_and_blocks_mutations(self):
        begin=self.begin();x.apply(self.store,self.key);self.binary.write_bytes(b'foreign')
        with self.assertRaises(x.UpdateError):self.finish(begin,commit=False)
        self.assertEqual(self.binary.read_bytes(),b'foreign');self.assertTrue(x.active(self.store))
        self.assertEqual((x.location(self.store,self.key)/'previous').read_bytes(),b'old')
        response=self.store.request(dict(version=1,action='submit',kind='diagnostic',id='e'*32,count=1,interval=1))
        self.assertEqual(response['code'],'xray_check_busy')
    def test_external_settings_survive_rollback_and_prevent_commit(self):
        begin=self.begin();x.apply(self.store,self.key);self.configuration['settings']['route']='foreign'
        self.assertEqual(self.finish(begin)['phase'],'rolled_back');self.assertEqual(self.configuration['settings']['route'],'foreign')
    def test_reboot_or_clock_rollback_does_not_extend_deadline(self):
        self.begin();info=x.load(self.store,self.key)
        with patch.object(x,'boot',return_value='other'):self.assertTrue(x.expired(info))
        info['uptimeDeadline']=x.uptime()-1;info['deadline']=time.time()+99999;self.assertTrue(x.expired(info))
    def test_wrong_nonce_or_manifest_never_commits(self):
        begin=self.begin();x.apply(self.store,self.key)
        for values in (dict(nonce='wrong'),dict(manifest='wrong')):
            with self.assertRaises(x.UpdateError):self.finish(begin,**values)
        self.assertEqual(x.load(self.store,self.key)['phase'],'awaiting_checks')
    def test_second_device_and_id_replay_cannot_replace_twice(self):
        request=self.request();begin=x.begin(self.store,request)
        self.assertEqual(x.begin(self.store,request)['nonce'],begin['nonce']);self.assertEqual(self.events,['armed'])
        request['id']='f'*32
        with self.assertRaises(x.UpdateError):x.begin(self.store,request)

    def test_wrong_archive_digest_is_rejected_before_extraction(self):
        folder=self.root/'download';folder.mkdir()
        response=io.BytesIO(b'invalid');response.geturl=lambda:'https://fixture.invalid/release'
        client=Mock();client.open.return_value=response
        with patch.object(x.urllib.request,'build_opener',return_value=client):
            with self.assertRaises(x.UpdateError) as error:REAL_DOWNLOAD(folder,x.chosen_target(None)[0])
        self.assertEqual(error.exception.code,'xray_check_digest')
        self.assertFalse((folder/'candidate').exists());self.assertEqual(self.binary.read_bytes(),b'old')

    def test_restart_updates_version_observation_after_authenticated_readback(self):
        self.begin();info=x.load(self.store,self.key);api=Mock()
        actual=dict(panelVersion='3.8.0',xrayVersion=x.TARGET['version'])
        with patch.object(x.vless,'access_for_panel',return_value={'xrayVersion':'26.7.28'}), patch.object(x.panel,'client',return_value=api), patch.object(x.panel,'versions',return_value=actual), patch.object(x,'cache_versions') as cache:
            REAL_RESTART(self.store,info,x.TARGET['version'])
            cache.assert_called_once_with(self.store,info,actual)

    def test_stopped_panel_is_restarted_to_recover_its_core(self):
        self.begin();info=x.load(self.store,self.key);api=Mock()
        with patch.object(x.vless,'access_for_panel',return_value={}), patch.object(x.panel,'client',side_effect=[x.PanelError('panel_api_failed'),api]), patch.object(x.panel,'versions',return_value=dict(panelVersion='3.8.0',xrayVersion=info['current'])), patch.object(x,'cache_versions'), patch.object(x,'command') as command:
            REAL_RESTART(self.store,info,info['current'])
            command.assert_called_once_with(['/usr/bin/systemctl','restart','x-ui.service'])

    def watchdog(self):
        with patch('runner.Store', side_effect=lambda d: Store(self.root)), patch('runner.STATE', self.root), \
             patch.object(x.time, 'sleep'):
            x.watchdog(self.key)

    def expire(self):
        info = x.load(self.store, self.key); info['deadline'] = time.time() - 1; x.save(self.store, info)

    def test_watchdog_rolls_back_an_unchecked_upgrade_even_when_it_looks_healthy(self):
        # No device checks arrived before the window ended: never auto-commit.
        self.begin(); x.apply(self.store, self.key)
        self.assertEqual(x.load(self.store, self.key)['phase'], 'awaiting_checks')
        self.expire()
        with patch('socket.create_connection'):  # Every inbound port answers.
            self.watchdog()
        self.assertEqual(x.load(self.store, self.key)['phase'], 'rolled_back')
        self.assertEqual(self.binary.read_bytes(), b'old')
        self.assertIn('retired', self.events)

    def test_failed_rollback_is_bounded_and_terminal(self):
        self.begin(); x.apply(self.store, self.key); self.expire()
        restarts = []
        def unconfirmed(store, info, version):
            restarts.append(version); raise x.UpdateError('xray_check_restart')
        with patch.object(x, 'restart', unconfirmed):
            self.watchdog()  # Returns instead of raising into Restart=on-failure.
            info = x.load(self.store, self.key)
            self.assertEqual(info['phase'], 'recovery_required')
            self.assertEqual(info['code'], 'xray_check_restart')
            self.assertEqual(len(restarts), x.MAX_ROLLBACK_ATTEMPTS)
            self.assertIn('retired', self.events)
            # A restarted watchdog retires at once, without touching x-ui again.
            self.events.clear(); self.watchdog()
            self.assertEqual(len(restarts), x.MAX_ROLLBACK_ATTEMPTS); self.assertEqual(self.events, ['retired'])
            # RPCs only report busy: no rollback (and no restart) inside them.
            self.assertTrue(x.active(self.store)); self.assertEqual(len(restarts), x.MAX_ROLLBACK_ATTEMPTS)
        # An explicit abort is the manual retry.
        abort = dict(id=self.key, action='xray_check_abort', payload=json.dumps(dict(nonce=info['nonce'], manifest=info['manifest'])))
        self.assertEqual(x.finish(self.store, abort)['phase'], 'rolled_back')
        self.assertFalse(x.active(self.store))

    def test_crash_inside_rollback_counts_as_an_attempt(self):
        self.begin(); x.apply(self.store, self.key)
        info = x.load(self.store, self.key); info.update(phase='rolling_back', rollbackAttempts=x.MAX_ROLLBACK_ATTEMPTS); x.save(self.store, info)
        with patch.object(x, 'restart', side_effect=AssertionError('x-ui must not restart again')):
            self.watchdog()
        self.assertEqual(x.load(self.store, self.key)['phase'], 'recovery_required')

    def test_active_does_not_roll_back_inside_an_rpc(self):
        self.begin(); x.apply(self.store, self.key); self.expire()
        self.events.clear()
        self.assertTrue(x.active(self.store))
        self.assertEqual(self.binary.read_bytes(), b'new'); self.assertEqual(self.events, [])
        self.assertEqual(x.load(self.store, self.key)['phase'], 'awaiting_checks')

    def test_begin_that_crashed_before_arming_does_not_block(self):
        with patch.object(x, 'arm', side_effect=SystemExit):
            with self.assertRaises(SystemExit): self.begin()
        self.assertEqual(x.load(self.store, self.key)['phase'], 'preparing')
        self.assertFalse(x.active(self.store))
        self.assertEqual(x.load(self.store, self.key)['phase'], 'not_changed')

    def test_finished_transactions_are_retired(self):
        keys = ['1' * 32, '2' * 32, '3' * 32]
        for number, key in enumerate(keys):
            self.key = key; self.running = '26.7.28'; self.binary.write_bytes(b'old')
            begin = self.begin(); x.apply(self.store, key)
            info = x.load(self.store, key); info['created'] = 1000 + number; x.save(self.store, info)
            (x.location(self.store, key) / 'candidate.zip').write_bytes(b'zip')
            self.assertEqual(self.finish(begin)['phase'], 'committed')
        # Only the newest record per panel stays, without its binaries.
        self.assertEqual(sorted(p.name for p in x.directory(self.store).iterdir()), [keys[-1]])
        self.assertEqual(sorted(p.name for p in x.location(self.store, keys[-1]).iterdir()), ['state.json'])
        self.assertEqual(x.latest(self.store, self.panel)['id'], keys[-1])
        # A stuck transaction keeps everything a manual recovery needs.
        self.key = '4' * 32; self.running = '26.7.28'; self.binary.write_bytes(b'old')
        self.begin(); x.apply(self.store, self.key); self.binary.write_bytes(b'foreign')
        with self.assertRaises(x.UpdateError): x.rollback(self.store, x.load(self.store, self.key))
        x.prune(self.store)
        self.assertTrue((x.location(self.store, self.key) / 'previous').exists())

    def test_parse_semver_robustness(self):
        self.assertEqual(x.parse_semver('3.8.0'), (3, 8, 0))
        self.assertEqual(x.parse_semver('v3.8.0'), (3, 8, 0))
        self.assertEqual(x.parse_semver('V3.8.0'), (3, 8, 0))
        self.assertEqual(x.parse_semver('3.11.0'), (3, 11, 0))
        self.assertEqual(x.parse_semver('v3.11.0'), (3, 11, 0))
        self.assertEqual(x.parse_semver('26.9.9'), (26, 9, 9))
        self.assertEqual(x.parse_semver('v26.9.9'), (26, 9, 9))
        self.assertEqual(x.parse_semver('3.11.1'), (3, 11, 1))
        self.assertEqual(x.parse_semver('3.9'), (3, 9, 0))
        self.assertEqual(x.parse_semver('3.11.0-rc1'), (3, 11, 0))
        self.assertEqual(x.parse_semver('v3.11.1+build2026'), (3, 11, 1))
        self.assertEqual(x.parse_semver('Xray 26.7.28 (Xray, Penetrates Everything.)'), (26, 7, 28))
        self.assertEqual(x.parse_semver('Xray 26.11.9'), (26, 11, 9))
        self.assertEqual(x.parse_semver(' 26.7.28 \n'), (26, 7, 28))
        for bad in ('', 'v', 'abc', '3.x.0', 123, None):
            with self.assertRaises(ValueError):
                x.parse_semver(bad)

    def test_plan_semver_range_and_candidate_matching(self):
        # Test supported panel range (3.7.0 up to 3.11.x)
        for panel, supported in [
            ('3.7.0', True), ('3.8.0', True), ('3.9.0', True), ('3.9.2', True),
            ('3.10.0', True), ('3.11.0', True), ('3.11.1', True), ('v3.11.0', True),
            ('3.11.99', True), ('3.6.0', False), ('3.12.0', False), ('2.8.0', False)
        ]:
            with patch.object(x, 'snapshot', return_value=dict(
                panelId=self.panel, panelVersion=panel, xrayVersion='26.7.28',
                configuration=copy.deepcopy(self.configuration),
                files={str(self.binary): 'hash'}, release='fixture'
            )):
                p = x.plan(self.store, self.panel)
                self.assertEqual(p['supported'], supported, f'panel {panel} supported should be {supported}')

        # Test candidate vs current xray matching
        for xray, expected_supp, expected_avail in [
            ('26.7.28', True, True),
            ('v26.7.28', True, True),
            ('26.10.21', True, True),
            ('26.11.9', True, False),
            ('v26.11.9', True, False),
            ('27.0.0', False, False),
        ]:
            with patch.object(x, 'snapshot', return_value=dict(
                panelId=self.panel, panelVersion='3.8.0', xrayVersion=xray,
                configuration=copy.deepcopy(self.configuration),
                files={str(self.binary): 'hash'}, release='fixture'
            )):
                p = x.plan(self.store, self.panel)
                self.assertEqual(p['supported'], expected_supp, f'xray {xray} supported should be {expected_supp}')
                self.assertEqual(p['available'], expected_avail, f'xray {xray} available should be {expected_avail}')

    # UI-45: a version chosen on the device goes through this transaction.
    def test_explicitly_chosen_older_version_is_installed_with_all_checks(self):
        begin=self.begin(self.chosen('26.5.1'))
        info=x.load(self.store,self.key)
        self.assertEqual((info['candidate'],info['current']),('26.5.1','26.7.28'))
        self.assertEqual(info['target'],dict(version='26.5.1',url=x.OFFICIAL.format('26.5.1'),sha256='a'*64))
        x.apply(self.store,self.key)
        self.assertEqual(self.downloaded,info['target'])
        self.assertEqual(self.events,['armed','restart','panel_api'])
        self.assertEqual(self.running,'26.5.1')
        self.assertEqual(x.load(self.store,self.key)['phase'],'awaiting_checks')
        self.assertEqual(self.finish(begin)['phase'],'committed')
        self.assertEqual(self.events[-2:],['panel_api','retired'])

    def test_explicit_newer_version_beyond_the_pinned_target(self):
        self.begin(self.chosen('27.1.2'));x.apply(self.store,self.key)
        self.assertEqual(self.running,'27.1.2');self.assertEqual(x.load(self.store,self.key)['phase'],'awaiting_checks')

    def test_downgrade_only_when_explicitly_chosen(self):
        self.running='27.0.0'
        with self.assertRaises(x.UpdateError) as error:self.begin()
        self.assertEqual(error.exception.code,'xray_check_changed')
        self.assertEqual(self.events,[])
        self.key='d'*32;self.begin(self.chosen(x.TARGET['version'],x.TARGET['sha256']))
        self.assertEqual(x.load(self.store,self.key)['candidate'],x.TARGET['version'])

    def test_explicit_choice_keeps_the_panel_compatibility_check(self):
        self.panel_version='3.6.0'
        with self.assertRaises(x.UpdateError) as error:self.begin(self.chosen('26.5.1'))
        self.assertEqual(error.exception.code,'xray_check_changed')
        self.panel_version='3.8.0'
        with self.assertRaises(x.UpdateError) as error:self.begin(self.chosen(self.running))
        self.assertEqual(error.exception.code,'xray_check_changed')
        self.assertEqual(self.events,[]);self.assertEqual(self.binary.read_bytes(),b'old')

    def test_only_the_official_asset_with_a_full_digest_is_accepted(self):
        bad=[(dict(version='26.5.1',url=x.OFFICIAL.format('26.5.1')),'xray_check_invalid'),
             ({**self.chosen('26.5.1'),'bytes':1},'xray_check_invalid'),
             (self.chosen('26.5.1',url=x.OFFICIAL.format('26.5.1').replace('https','http',1)),'xray_check_invalid'),
             (self.chosen('26.5.1',url=x.OFFICIAL.format('26.5.2')),'xray_check_invalid'),
             (self.chosen('26.5.1',url='https://github.com/other/Xray-core/releases/download/v26.5.1/Xray-linux-64.zip'),'xray_check_invalid'),
             (self.chosen('26.5.1',url=x.OFFICIAL.format('26.5.1').replace('linux-64','linux-arm64-v8a')),'xray_check_invalid'),
             (self.chosen('../26.5.1'),'xray_check_invalid'),(self.chosen('26.5.1-rc1'),'xray_check_invalid'),
             (self.chosen('26.5.1',sha='A'*64),'xray_check_digest'),(self.chosen('26.5.1',sha='a'*63),'xray_check_digest'),
             (self.chosen('26.5.1',sha='sha256:'+'a'*64),'xray_check_digest'),
             (self.chosen(x.TARGET['version'],sha='a'*64),'xray_check_digest'),
             ('26.5.1','xray_check_invalid'),(dict(version=26,url='',sha256=''),'xray_check_invalid')]
        for candidate,code in bad:
            with self.subTest(candidate=candidate):
                with self.assertRaises(x.UpdateError) as error:self.begin(candidate)
                self.assertEqual(error.exception.code,code)
        with self.assertRaises(x.UpdateError) as error:x.begin(self.store,self.request(extra='field'))
        self.assertEqual(error.exception.code,'xray_check_invalid')
        self.assertEqual(self.events,[]);self.assertEqual(self.binary.read_bytes(),b'old')
        self.assertIsNone(x.load(self.store,self.key))

    def test_pinned_target_keeps_its_pinned_hashes(self):
        target,explicit=x.chosen_target(self.chosen(x.TARGET['version'],x.TARGET['sha256']))
        self.assertTrue(explicit)
        self.assertEqual((target['bytes'],target['binarySha256']),(x.TARGET['bytes'],x.TARGET['binarySha256']))
        self.assertEqual(x.chosen_target(None),(target,False))

    def test_config_test_failure_of_a_chosen_version_leaves_old_binary(self):
        self.begin(self.chosen('26.5.1'))
        with patch.object(x,'config_test',side_effect=x.UpdateError('xray_check_config')) as test:x.apply(self.store,self.key)
        test.assert_called_once()
        self.assertEqual(x.load(self.store,self.key)['phase'],'not_changed');self.assertEqual(self.binary.read_bytes(),b'old')

    def test_panel_api_failure_after_restart_rolls_back_without_commit(self):
        self.begin(self.chosen('26.5.1'));self.panel_down=True
        x.apply(self.store,self.key)
        info=x.load(self.store,self.key)
        self.assertEqual((info['phase'],info['code']),('rolled_back','xray_check_panel_api'))
        self.assertEqual(self.binary.read_bytes(),b'old');self.assertEqual(self.running,'26.7.28')

    def test_panel_api_failure_before_commit_rolls_back(self):
        begin=self.begin();x.apply(self.store,self.key);self.panel_down=True
        result=self.finish(begin)
        self.assertEqual((result['phase'],result['code']),('rolled_back','xray_check_panel_api'))
        self.assertEqual(self.binary.read_bytes(),b'old')
        with self.assertRaises(x.UpdateError) as error:self.finish(begin)
        self.assertEqual(error.exception.code,'xray_check_late')

    def test_watchdog_rolls_back_when_the_panel_api_stops_answering(self):
        begin=self.begin();x.apply(self.store,self.key);self.panel_down=True
        with patch.object(x,'PANEL_CHECK_SECONDS',0):self.watchdog()
        info=x.load(self.store,self.key)
        self.assertEqual((info['phase'],info['code']),('rolled_back','xray_check_panel_api'))
        self.assertEqual(self.binary.read_bytes(),b'old');self.assertIn('retired',self.events)

    def test_watchdog_keeps_a_healthy_panel_until_the_window_ends(self):
        self.begin();x.apply(self.store,self.key)
        checks=[]
        def healthy(store,info):
            checks.append(1)
            if len(checks)==3:self.expire()
        with patch.object(x,'PANEL_CHECK_SECONDS',0),patch.object(x,'panel_api',healthy):self.watchdog()
        info=x.load(self.store,self.key)
        self.assertEqual(len(checks),3)
        self.assertEqual(info['phase'],'rolled_back');self.assertNotEqual(info['code'],'xray_check_panel_api')

    def test_panel_api_needs_a_fresh_login_and_the_same_inbound_ids(self):
        self.begin();info=x.load(self.store,self.key)
        api=Mock()
        with patch.object(x.vless,'access_for_panel',return_value={}) as access,patch.object(x.panel,'client',return_value=api) as client:
            api.call.return_value=[dict(id=1)]
            REAL_PANEL_API(self.store,info)
            access.assert_called_once_with(self.store,self.panel);client.assert_called_once()
            api.call.assert_called_once_with('/panel/api/inbounds/list')
            for rows in ([],[dict(id=1),dict(id=2)],[dict(id=2)],None):
                api.call.return_value=rows
                with self.assertRaises(x.UpdateError) as error:REAL_PANEL_API(self.store,info)
                self.assertEqual(error.exception.code,'xray_check_panel_api')
            client.side_effect=ValueError('panel_auth_failed')
            with self.assertRaises(x.UpdateError) as error:REAL_PANEL_API(self.store,info)
            self.assertEqual(error.exception.code,'xray_check_panel_api')

    def test_release_redirects_stay_on_https(self):
        handler=x.HttpsRedirects();request=x.urllib.request.Request(x.OFFICIAL.format('26.5.1'))
        with self.assertRaises(x.UpdateError):handler.redirect_request(request,None,302,'Found',{},'http://objects.githubusercontent.com/x')
        self.assertIsNotNone(handler.redirect_request(request,None,302,'Found',{},'https://objects.githubusercontent.com/x'))

    def test_chosen_archive_is_size_bounded_and_must_report_its_version(self):
        folder=self.root/'download';folder.mkdir()
        target=x.chosen_target(self.chosen('26.5.1'))[0]
        response=io.BytesIO(b'x'*(x.MAX_ARCHIVE+1));response.geturl=lambda:'https://fixture.invalid/release'
        client=Mock();client.open.return_value=response
        with patch.object(x.urllib.request,'build_opener',return_value=client):
            with self.assertRaises(x.UpdateError):REAL_DOWNLOAD(folder,target)
        self.assertFalse((folder/'candidate.zip').exists())
        import zipfile
        archive=folder/'candidate.zip'
        with zipfile.ZipFile(archive,'w') as z:z.writestr('xray',b'binary')
        target['sha256']=hashlib.sha256(archive.read_bytes()).hexdigest()
        for output,ok in ((b'Xray 26.5.1 (Xray, Penetrates Everything.)',True),(b'Xray 26.5.10 (Xray)',False),(b'Xray 26.7.28 (Xray)',False)):
            with self.subTest(output=output),patch.object(x,'command',return_value=output):
                if ok:self.assertEqual(REAL_DOWNLOAD(folder,target),folder/'candidate')
                else:
                    with self.assertRaises(x.UpdateError):REAL_DOWNLOAD(folder,target)

    def test_plan_reports_explicit_choice_for_a_newer_core(self):
        self.running='27.0.0'
        offer=x.plan(self.store,self.panel)
        self.assertEqual((offer['supported'],offer['available'],offer['choosable']),(False,False,True))
        self.panel_version='3.6.0'
        self.assertFalse(x.plan(self.store,self.panel)['choosable'])
