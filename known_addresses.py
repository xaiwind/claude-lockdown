#!/usr/bin/env python3
"""Merge DNS observations of known Claude hosts into an existing IP block list.

All DNS queries use HTTPS CONNECT via the local SFM proxy. No direct fallback.
"""
import argparse
import concurrent.futures
import http.client
import ipaddress
import json
import ssl
import sys
import urllib.parse

# Exact hostnames from Anthropic documentation; wildcards cannot be enumerated.
HOSTS = (
    'anthropic.com', 'api.anthropic.com', 'a-api.anthropic.com',
    'a-cdn.anthropic.com', 's-cdn.anthropic.com', 'assets-proxy.anthropic.com',
    'mcp-proxy.anthropic.com', 'claude.ai', 'a.claude.ai', 'assets.claude.ai',
    'downloads.claude.ai', 'claude.com', 'platform.claude.com', 'sso.claude.com',
    'code.claude.com', 'claude.app', 'claudeusercontent.com',
    'bridge.claudeusercontent.com', 'claudemcpcontent.com',
)
FAKE_IPV4 = ipaddress.ip_network('198.18.0.0/15')
MAX_NETWORKS = 256


class NoAnswers(RuntimeError):
    pass


class ProxyConflict(RuntimeError):
    pass


def proxy_servers(profile):
    servers = set()
    for outbound in profile.get('outbounds', []):
        value = outbound.get('server')
        if value:
            try:
                servers.add(ipaddress.ip_address(value))
            except ValueError:
                raise ValueError('代理服务器使用域名，无法安全确认服务器地址；不更新名单。')
    if not servers:
        raise ValueError('配置中没有固定 IP 代理服务器；不更新名单。')
    return servers


def public_address(value):
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return None
    if not ip.is_global or ip.is_multicast or (ip.version == 4 and ip in FAKE_IPV4):
        return None
    return ip


def parse_networks(text):
    networks = set()
    for line in text.splitlines():
        if not line.strip(): continue
        network = ipaddress.ip_network(line.strip(), strict=True)
        if network.prefixlen == 0: raise ValueError('A default route cannot be blocked')
        networks.add(network)
    if not networks: raise ValueError('Existing list is empty')
    return networks


def merge(previous, hosts, resolver, protected=frozenset()):
    networks = parse_networks(previous)
    if any(ip.version == net.version and ip in net for ip in protected for net in networks):
        raise ProxyConflict('已有阻断网段包含代理服务器 IP；不更新名单。')
    results, errors, successes = set(), [], 0
    host_results = {name: set() for name in hosts}
    jobs = [(name, family) for name in hosts for family in ('A','AAAA')]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(resolver, name, family): (name, family) for name, family in jobs}
        for future in concurrent.futures.as_completed(futures):
            name, family = futures[future]
            try:
                answers = future.result()
                successes += 1
                for value in answers:
                    ip = public_address(value)
                    if ip and (ip.version == (4 if family == 'A' else 6)):
                        results.add(ip)
                        host_results[name].add(ip)
            except (OSError, ValueError, http.client.HTTPException) as exc:
                errors.append(f'{name} {family}: {type(exc).__name__}')
    if successes == 0 or not results:
        raise NoAnswers('DNS 未取得可用地址；保持原名单。')
    for name, addresses in host_results.items():
        if not addresses:
            errors.append(f'{name}: 未取得地址，旧名单保持不变')
    for ip in results:
        if ip in protected:
            raise ProxyConflict('查询结果与代理服务器 IP 冲突；不更新名单。')
        if not any(ip.version == net.version and ip in net for net in networks):
            networks.add(ipaddress.ip_network(f'{ip}/{ip.max_prefixlen}'))
    if len(networks) > MAX_NETWORKS:
        raise ValueError('名单超过安全上限；请人工审查，旧名单保持不变。')
    ordered=sorted(networks, key=lambda net: (net.version, int(net.network_address), net.prefixlen))
    return ''.join(str(net)+'\n' for net in ordered), sorted(errors)


def proxy_resolver(port):
    if not 1 <= port <= 65535: raise ValueError('Invalid local proxy port')
    def resolve(name, family):
        path='/dns-query?' + urllib.parse.urlencode({'name':name,'type':family})
        conn=http.client.HTTPSConnection('127.0.0.1', port, timeout=8, context=ssl.create_default_context())
        conn.set_tunnel('cloudflare-dns.com',443)
        try:
            conn.request('GET',path,headers={'Accept':'application/dns-json'})
            resp=conn.getresponse()
            if resp.status != 200: raise OSError(f'DNS HTTP {resp.status}')
            body=resp.read(262145)
            if len(body)>262144: raise ValueError('DNS response too large')
            data=json.loads(body)
            if data.get('Status') not in (0,3): raise OSError('DNS server failure')
            typ=1 if family=='A' else 28
            return [r['data'] for r in data.get('Answer',[]) if r.get('type')==typ and isinstance(r.get('data'),str)]
        finally:
            conn.close()
    return resolve


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--current',required=True)
    parser.add_argument('--output',required=True)
    parser.add_argument('--proxy-port',type=int,default=2345)
    parser.add_argument('--sfm-profile',required=True)
    args=parser.parse_args()
    with open(args.current) as f: original=f.read()
    with open(args.sfm_profile) as f: protected=proxy_servers(json.load(f))
    result,errors=merge(original,HOSTS,proxy_resolver(args.proxy_port),protected)
    with open(args.output,'w') as f: f.write(result)
    print(f'已查询已知域名；原有网段保留。查询异常 {len(errors)} 项。',file=sys.stderr)
    for error in errors: print('  '+error,file=sys.stderr)


if __name__=='__main__':
    try: main()
    except (OSError,ValueError,NoAnswers,ProxyConflict) as exc:
        print('更新地址失败：'+str(exc),file=sys.stderr);sys.exit(1)
