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
import time
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



def server_snapshot(profile):
    # Persist only the IPs, never credentials or the SFM profile itself.
    return {'servers': sorted(str(ip) for ip in proxy_servers(profile))}


def read_server_snapshot(data):
    values = data.get('servers')
    if not isinstance(values, list) or not values:
        raise ValueError('代理服务器 IP 快照为空；不更新名单。')
    try:
        return {ipaddress.ip_address(value) for value in values}
    except ValueError:
        raise ValueError('代理服务器 IP 快照无效；不更新名单。')

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


def collect_addresses(hosts, resolver):
    results, errors, successes, complete = set(), [], 0, True
    host_results = {name: set() for name in hosts}
    jobs = [(name, family) for name in hosts for family in ('A', 'AAAA')]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(resolver, name, family): (name, family) for name, family in jobs}
        for future in concurrent.futures.as_completed(futures):
            name, family = futures[future]
            try:
                answers = future.result()
                successes += 1
                for value in answers:
                    ip = public_address(value)
                    if ip and ip.version == (4 if family == 'A' else 6):
                        results.add(ip)
                        host_results[name].add(ip)
            except (OSError, ValueError, http.client.HTTPException) as exc:
                complete = False
                errors.append(f'{name} {family}: {type(exc).__name__}')
    if successes == 0 or not results:
        raise NoAnswers('DNS 未取得可用地址；保持原名单。')
    for name, addresses in host_results.items():
        if not addresses:
            errors.append(f'{name}: 未取得地址')
    return results, sorted(errors), complete


def merge_with_history(previous, hosts, resolver, history, now, protected=frozenset(), prune=True):
    networks = parse_networks(previous)
    if any(ip.version == net.version and ip in net for ip in protected for net in networks):
        raise ProxyConflict('已有阻断网段包含代理服务器 IP；不更新名单。')
    if not isinstance(history, dict) or (history and history.get('version') != 1):
        raise ValueError('历史记录格式错误；不更新名单。')
    last_seen = history.get('last_seen', {})
    missing_since = history.get('missing_since', {})
    last_complete_at = history.get('last_complete_at')
    if not isinstance(last_seen, dict) or not isinstance(missing_since, dict):
        raise ValueError('历史记录格式错误；不更新名单。')
    for mapping in (last_seen, missing_since):
        for value, stamp in mapping.items():
            ipaddress.ip_address(value)
            if type(stamp) is not int or stamp < 0 or stamp > now + 300:
                raise ValueError('历史记录时间无效；不更新名单。')
    if last_complete_at is not None and (type(last_complete_at) is not int or last_complete_at < 0 or last_complete_at > now + 300):
        raise ValueError('历史记录时间无效；不更新名单。')
    results, errors, complete = collect_addresses(hosts, resolver)
    if any(ip in protected for ip in results):
        raise ProxyConflict('查询结果与代理服务器 IP 冲突；不更新名单。')
    # A long monitoring gap cannot count as evidence of continuous absence.
    continuous = last_complete_at is not None and now - last_complete_at <= 48 * 3600
    kept, next_seen, next_missing = set(), {}, {}
    for net in networks:
        if net.prefixlen != net.max_prefixlen:
            kept.add(net)  # Existing fixed subnets are never automatically removed.
            continue
        ip = net.network_address
        key = str(ip)
        seen = now if ip in results else last_seen.get(key, now)
        since = missing_since.get(key)
        if ip in results:
            since = None
        elif complete and (since is None or not continuous):
            since = now
        expired = complete and since is not None and now - since >= 30 * 86400
        if not prune or not expired:
            kept.add(net)
            next_seen[key] = seen
            if since is not None:
                next_missing[key] = since
    for ip in results:
        if not any(ip.version == net.version and ip in net for net in kept):
            kept.add(ipaddress.ip_network(f'{ip}/{ip.max_prefixlen}'))
            next_seen[str(ip)] = now
    if len(kept) > MAX_NETWORKS:
        raise ValueError('名单超过安全上限；请人工审查，旧名单保持不变。')
    ordered = sorted(kept, key=lambda net: (net.version, int(net.network_address), net.prefixlen))
    return ''.join(str(net) + '\n' for net in ordered), errors, {'version': 1, 'last_seen': next_seen, 'missing_since': next_missing, 'last_complete_at': now if complete else last_complete_at}


def merge(previous, hosts, resolver, protected=frozenset()):
    # Compatibility for tests/callers that request a pure append-only merge.
    output, errors, _ = merge_with_history(previous, hosts, resolver, {}, 0, protected, prune=False)
    return output, errors

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
    parser.add_argument('--history',required=True)
    parser.add_argument('--history-output',required=True)
    source=parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--sfm-profile')
    source.add_argument('--server-list')
    args=parser.parse_args()
    with open(args.current) as f: original=f.read()
    with open(args.sfm_profile or args.server_list) as f: source_data=json.load(f)
    protected=proxy_servers(source_data) if args.sfm_profile else read_server_snapshot(source_data)
    try:
        with open(args.history) as f: history=json.load(f)
    except FileNotFoundError:
        history={}
    result,errors,history_next=merge_with_history(original,HOSTS,proxy_resolver(args.proxy_port),history,int(time.time()),protected)
    with open(args.output,'w') as f: f.write(result)
    with open(args.history_output,'w') as f: json.dump(history_next,f,sort_keys=True)
    print(f'已查询已知域名；原有网段保留。查询异常 {len(errors)} 项。',file=sys.stderr)
    for error in errors: print('  '+error,file=sys.stderr)


if __name__=='__main__':
    try: main()
    except (OSError,ValueError,NoAnswers,ProxyConflict) as exc:
        print('更新地址失败：'+str(exc),file=sys.stderr);sys.exit(1)
