import ipaddress
import unittest
import known_addresses as k

class TestKnownAddresses(unittest.TestCase):
    def test_union_and_partial_dns_failure_keep_old_entries(self):
        previous='153.61.0.0/16\n160.79.104.0/21\n'
        def resolver(name, family):
            if name == 'claude.ai' and family == 'A': return ['34.120.108.227','160.79.104.10']
            if name == 'api.anthropic.com': raise OSError('proxy down')
            return []
        output, errors = k.merge(previous, ['claude.ai','api.anthropic.com'], resolver)
        self.assertIn('34.120.108.227/32',output.splitlines())
        self.assertIn('153.61.0.0/16',output.splitlines())
        self.assertNotIn('160.79.104.10/32',output.splitlines())
        self.assertTrue(errors)
    def test_total_failure_must_not_claim_update(self):
        def down(*args): raise OSError('offline')
        with self.assertRaises(k.NoAnswers):k.merge('160.79.104.0/21\n',['claude.ai'],down)
    def test_bad_dns_answers_do_not_add_private_or_fake_ip(self):
        def resolver(name, family): return ['127.0.0.1','10.1.2.3','198.18.0.1','34.120.108.227']
        output,_=k.merge('160.79.104.0/21\n',['claude.ai'],resolver)
        self.assertIn('34.120.108.227/32',output.splitlines())
        self.assertNotIn('198.18.0.1/32',output.splitlines())
        self.assertNotIn('127.0.0.1/32',output.splitlines())
    def test_known_hostnames_include_official_domains(self):
        self.assertIn('api.anthropic.com',k.HOSTS)
        self.assertIn('bridge.claudeusercontent.com',k.HOSTS)
        self.assertIn('platform.claude.com',k.HOSTS)
    def test_cannot_accept_invalid_existing_list(self):
        with self.assertRaises(ValueError):k.merge('0.0.0.0/0\n',['claude.ai'],lambda *x:[])


class TestProxyServerSafety(unittest.TestCase):
    def test_refuse_new_dns_address_matching_proxy_server(self):
        def answer(name, family):
            return ['34.120.108.227'] if family == 'A' else []
        with self.assertRaises(k.ProxyConflict):
            k.merge('160.79.104.0/21\n',['claude.ai'],answer, protected={ipaddress.ip_address('34.120.108.227')})
    def test_refuse_domain_based_proxy_without_safe_address(self):
        with self.assertRaises(ValueError):
            k.proxy_servers({'outbounds':[{'type':'vless','server':'proxy.example.test'}]})
    def test_extracts_actual_fixed_proxy_and_ignores_direct(self):
        ips=k.proxy_servers({'outbounds':[{'type':'vless','server':'8.8.8.8'},{'type':'direct'}]})
        self.assertEqual(ips,{ipaddress.ip_address('8.8.8.8')})


class TestStoredServerIps(unittest.TestCase):
    def test_minimal_snapshot_contains_no_credentials(self):
        profile={'outbounds':[{'type':'vless','server':'8.8.8.8','uuid':'secret-value','tls':{'private_key':'sensitive'}},{'type':'direct'}]}
        snapshot=k.server_snapshot(profile)
        self.assertEqual(snapshot, {'servers':['8.8.8.8']})
        self.assertNotIn('secret', str(snapshot))
    def test_refuse_empty_or_domain_snapshot(self):
        for data in ({'servers':[]},{'servers':['host.example']}):
            with self.assertRaises(ValueError): k.read_server_snapshot(data)


class TestRetention(unittest.TestCase):
    def setUp(self):
        self.old='160.79.104.0/21\n34.120.108.227/32\n'
        self.now=2_000_000_000
        self.history={'version':1,'last_seen':{'34.120.108.227':self.now-31*86400},'missing_since':{'34.120.108.227':self.now-31*86400},'last_complete_at':self.now-3600}
    def test_old_dynamic_address_expires_after_30_days(self):
        def resolve(name,kind):return ['35.190.46.17'] if kind=='A' else []
        out,_,hist=k.merge_with_history(self.old,['claude.ai'],resolve,self.history,self.now)
        self.assertNotIn('34.120.108.227/32',out.splitlines())
        self.assertIn('160.79.104.0/21',out.splitlines())
        self.assertIn('35.190.46.17/32',out.splitlines())
        self.assertNotIn('34.120.108.227',hist['last_seen'])
    def test_partial_lookup_failure_never_removes_old(self):
        def resolve(name,kind):
            if kind=='AAAA':raise OSError('proxy down')
            return ['35.190.46.17']
        out,errors,_=k.merge_with_history(self.old,['claude.ai'],resolve,self.history,self.now)
        self.assertIn('34.120.108.227/32',out.splitlines());self.assertTrue(errors)
    def test_untracked_existing_address_gets_full_grace(self):
        out,_,hist=k.merge_with_history(self.old,['claude.ai'],lambda n,f:['35.190.46.17'] if f=='A' else [],{},self.now)
        self.assertIn('34.120.108.227/32',out.splitlines());self.assertEqual(hist['last_seen']['34.120.108.227'],self.now)
    def test_seen_old_address_is_refreshed(self):
        out,_,hist=k.merge_with_history(self.old,['claude.ai'],lambda n,f:['34.120.108.227'] if f=='A' else [],self.history,self.now)
        self.assertIn('34.120.108.227/32',out.splitlines());self.assertEqual(hist['last_seen']['34.120.108.227'],self.now)
    def test_long_offline_gap_restarts_retention_clock(self):
        self.history['last_complete_at']=self.now-3*86400
        out,_,hist=k.merge_with_history(self.old,['claude.ai'],lambda n,f:['35.190.46.17'] if f=='A' else [],self.history,self.now)
        self.assertIn('34.120.108.227/32',out.splitlines())
        self.assertEqual(hist['missing_since']['34.120.108.227'],self.now)
    def test_fresh_history_never_immediately_expires(self):
        historical={'version':1,'last_seen':{'34.120.108.227':self.now-31*86400}}
        out,_,_=k.merge_with_history(self.old,['claude.ai'],lambda n,f:['35.190.46.17'] if f=='A' else [],historical,self.now)
        self.assertIn('34.120.108.227/32',out.splitlines())
    def test_corrupted_history_does_not_delete(self):
        with self.assertRaises(ValueError):
            k.merge_with_history(self.old,['claude.ai'],lambda n,f:['35.190.46.17'] if f=='A' else [],{'version':1,'last_seen':{'34.120.108.227':'bad'}},self.now)

if __name__=='__main__': unittest.main()
