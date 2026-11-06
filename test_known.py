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

if __name__=='__main__': unittest.main()
