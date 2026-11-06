# claude-lockdown（修订版）

macOS 上针对指定 IPv4/IPv6 网段的物理网卡出站阻断工具，可配合 TUN VPN 使用。它不是域名级或进程级 kill switch，不能保证所有 Claude/Anthropic 流量都被覆盖，也不代表账号免封或匿名保证。

已知域名与当前 IP 规则的差异见 [域名与覆盖边界](KNOWN-DOMAINS.md)。

## 使用

先查看并理解脚本，再运行。`status` 仅查看本地规则，不发起任何 Claude/Anthropic 网络请求：

```bash
sudo bash claude-lockdown.sh status
sudo bash claude-lockdown.sh on          # 前台试用 60 秒；Ctrl-C 撤销
sudo bash claude-lockdown.sh on --keep   # 保持至 off 或重启
sudo bash claude-lockdown.sh refresh     # Python 3；ARIN 更新网段缓存
sudo bash claude-lockdown.sh install     # 安装启动任务，每 24 小时刷新规则
sudo bash claude-lockdown.sh off         # 撤销规则，同时取消自动启用任务
sudo bash claude-lockdown.sh uninstall   # 先撤销规则，再移除安装文件
```

试用期间可在另一终端 `on --keep` 接管；旧试用不会再撤销新一代规则。已有持久规则或自动任务时拒绝直接进入临时试用，避免覆盖原状态。强制杀死进程或掉电不能保证试用清理执行，需检查状态并手动 off。操作锁若因强杀残留，确认没有脚本进程后才可删除 `/var/db/claude-lockdown/lock`。

`off` 释放本工具取得的 PF 引用，不全局禁用 PF；其他程序的 PF 引用不受影响。`refresh` 查询失败返回非零并保留原名单，名单更新不证明完整覆盖。内置名单来自用户提供的旧脚本，本次未核验其当前所有权和完整性。

## 兼容性与前提

仅适用于 macOS。需要系统自带 bash、pfctl、curl、launchctl 等；刷新 ARIN 名单额外需要 Python 3。脚本复用内核中已有的 `com.apple/*` PF anchor 入口，使用独立子 anchor `com.apple/claude-lockdown`，不写入或重载 `/etc/pf.conf`。

如果系统尚未加载该入口，或主过滤规则存在自定义内容，脚本拒绝自动安装。需要先审查实际 PF 配置，不应为了安装直接覆盖或重载未知规则。其他 `com.apple/*` 子 anchor 的规则也可能影响最终判定，仍需要真实网络测试。

物理接口匹配 `enN`、`ethN`、`pdp_ipN`、`bridgeN`，包括暂时没有 IP 的接口。其他接口命名不自动覆盖。TUN 隧道中的包和 VPN 外层包如何经过 PF，必须按实际 VPN 实测，不承诺所有客户端兼容。

## 与旧版的区别

- 只更新、清空自己的 anchor，不恢复旧版整份 pf.conf 备份。
- 校验 PF 语法、加载结果、启用状态和内核规则；不吞掉加载错误。
- 候选规则加载失败时尝试恢复本工具旧规则；回滚失败会明确报错。
- PF 引用 token 独立保存，重启后丢弃过期 token。
- 试用保持前台，使用 generation 标识防止旧计时器误撤销新设置。
- `status` 改为被动检查：只读取 PF 状态与规则，不再主动访问 Claude，也不尝试绑定物理网卡访问 Claude。
- 手动启用/更新名单时仅清理目标网段的既有 PF 状态，不清空所有连接；目标范围内的隧道连接可能需要重连。
- off 先停止自动任务，uninstall 先撤销规则再删除脚本。

## 旧版迁移

如果以前运行过旧版，先检查 `/etc/pf.conf`、`/etc/pf.conf.bak.claude-lockdown` 和原 `com.claude.lockdown` anchor。新版检测到旧备份会拒绝叠加启用。

不要直接用旧备份覆盖现有 pf.conf：其中可能已有其他软件后来添加的设置。需比较差异，仅移除旧脚本添加的 anchor/load anchor 项，审查并验证候选配置后，由操作者决定如何应用。停止旧 `com.claude.lockdown` LaunchDaemon，清理旧 anchor 及旧脚本文件，然后保留旧备份作为归档并移走原检测路径。新版 off 不负责自动迁移旧版全局配置。

## 验收与限制

自动测试只模拟 PF/网络命令，不改本机防火墙：

```bash
bash -n claude-lockdown.sh
bash test.sh
```

交付时已通过以上检查，尚未在真实 PF、VPN 及重启环境验证。

实际验收不使用真实 Claude 账号，也不通过关闭 VPN 后发送 Claude 请求来试错。先退出已登录的 Claude 客户端、CLI 和相关浏览器页面，在独立测试环境中用自有测试服务器及临时测试网段验证 VPN 开启/关闭、IPv4/IPv6、已有连接、网卡切换和重启。结合抓包、测试服务器日志和 PF 计数交叉确认。测试通过只能证明该场景中的规则机制，不能证明 Anthropic 网段名单完整。

新插入网卡、开机到任务启动之间，以及外部程序刷新 PF 后，都可能有覆盖窗口。24 小时刷新不是实时保证，期间新网卡或被外部重载的规则可能长时间不受保护。未在名单内的 CDN/IP、其他代理或网络扩展、非匹配接口不在保证范围内。需要严格“隧道一停所有指定应用立即断网”时，应另行设计应用级或更完整的网络策略，不能把本脚本当作替代品。

## 选择哪种方案

本仓库当前实现的是 macOS 网段阻断方案，适合继续使用现有桌面客户端和浏览器、希望减少指定网段直连风险的用户。不改变原有登录或文件使用方式，但无法承诺零遗漏。

严格隔离属于另一套部署方式：将程序放入专用环境，仅允许连接指定代理出口，并确保代理自身不回退直连。它需要单独处理登录、文件共享和代理配置，不自动保护宿主机上的 Claude 桌面版或浏览器。本仓库尚未实现或验证这一方案，不要将现有脚本误认为严格隔离。
