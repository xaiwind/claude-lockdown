# Claude 域名与当前规则的覆盖边界

此文档只记录官方网络要求，**不会增加 PF 阻断规则，也不能证明域名已经得到保护**。当前脚本只对名单中的目标 IP 网段生效。

[Claude 桌面版官方网络要求](https://code.claude.com/docs/en/desktop#network-access-requirements)列出以下域名范围，部分功能使用动态生成的子域名：

- `anthropic.com` 与 `*.anthropic.com`
- `claude.ai` 与 `*.claude.ai`
- `claude.com` 与 `*.claude.com`
- `claude.app` 与 `*.claude.app`
- `*.claudeusercontent.com`
- `*.claudemcpcontent.com`

具体主机例如 `api.anthropic.com`、`assets-proxy.anthropic.com`、`downloads.claude.ai`、`platform.claude.com` 和 `bridge.claudeusercontent.com`。官方说明 CLI、桌面端、第三方云模型、MCP 和插件所需地址可能不同，见 [Claude Code 网络说明](https://code.claude.com/docs/en/network-config)。上面不是所有第三方网络请求的完整列表。

PF 的当前规则只匹配目标 IP，不识别 HTTPS 域名或通配符。查询若干域名的 A/AAAA 记录并加入规则，只覆盖当时查询到的具体地址，无法枚举动态子域名或预知 DNS/CDN 变化，也不能保证其他设备或进程使用相同的解析结果。共享 CDN 地址可能被其他网站使用，将整个第三方网段加入阻断会误伤无关网站。

因此，**不能声称当前脚本覆盖全部已知或未来 Claude 域名，不能将它作为绝对防直连保障**。需要 VPN 不可用时防止任何外网连接，应采用经过实际验收的系统级 VPN kill switch；在满足条件前不要关闭 VPN 并使用真实 Claude 账号进行验证。测试应使用用户控制的服务和测试地址。
