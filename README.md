# claude-lockdown

macOS 上的出站网段阻断工具，配合 **sing-box for macOS（SFM）** 使用：保留已知 Anthropic 网段，并通过 SFM 查询一组已知 Claude 域名的 IP，阻止这些地址从物理网卡直连。默认每天检查一次。

> **使用前请先读：** 这是一种按 IP 地址阻断的方法。它能降低已知地址意外直连的风险，但不能识别全部动态子域名、未收录地址或 DNS 返回之外的 IP，也不能保证账号不受限制。部分地址由第三方共用，阻断可能影响其他网站。若你的 SFM 配置把 Claude 流量分到直连，规则可能阻断 Claude；请先确认 SFM 自身的分流设置。
>
> 此版本只经过模拟 PF 测试和通过 SFM 的 DNS 查询测试，**尚未在真实 PF/VPN 断开场景验证**。不要用真实 Claude 账号做断网测试。

## 它如何工作

- 开机及每 24 小时：先加载已保存的阻断名单，再尝试更新地址。
- 更新时通过本机 SFM HTTP/mixed 代理向 Cloudflare DNS 查询已知域名的 A/AAAA 记录；不向 Claude 网站发送请求，不读取账号信息。
- 将新地址追加到名单；DNS 或代理不可用时，保留旧名单。对共享云地址只添加查询得到的单个 IP，不封锁整个第三方网段。
- 对每个网卡核对实际 PF 规则，加载失败时恢复旧名单与规则；新增加的地址会尝试清理对应旧连接状态。
- 检查所配置的 SFM 服务器 IP，防止新增规则阻断代理服务器。代理服务器是域名而不是固定 IP 时，拒绝自动更新。

已知域名范围、来源和限制见 [域名与覆盖边界](KNOWN-DOMAINS.md)。Chrome、Claude Code 都受相同的 IP 规则约束；本项目不按应用或域名识别流量。

## 准备

需要 macOS、已安装的 SFM、Python 3、Git，以及管理员权限。准备好：

1. **SFM 当前配置文件的绝对路径**，例如 `.../configs/config_5.json`。文件中可能包含代理凭据，请勿上传或发送给他人。
2. SFM 配置中的本地 **HTTP 或 mixed 代理端口**，例如 `2345`；配置须监听 `127.0.0.1`。实际端口以你的配置为准。
3. 保持 SFM 连接，确认 Claude 相关请求在 SFM 的规则中走代理。

项目不修改 SFM 配置，也不替你购买服务器。更换 SFM 配置文件或本地代理端口后，需要重新安装以更新路径和端口。

## 安装或升级

下载本仓库到本机，终端进入目录。将下面两处替换成你自己的配置路径和端口：

```bash
git clone https://github.com/xaiwind/claude-lockdown.git
cd claude-lockdown
sudo bash claude-lockdown.sh install --sfm-profile "/你的/SFM配置文件.json" --proxy-port 2345
```

安装会保留现有名单，启动时和每 24 小时刷新；立即运行一次可手动更新：

```bash
sudo bash claude-lockdown.sh refresh
```

开机时如果 SFM 尚未连接，查询可能失败；旧规则依然保留。SFM 连接后可手动运行 `refresh`，否则等待下一次定时检查。不要在公开场所粘贴配置文件内容或代理凭据。

若之前使用过修改 `/etc/pf.conf` 的**最早版本**，先检查和迁移旧版；不要直接覆盖历史 PF 备份。若已迁移到 `com.apple/claude-lockdown` 版本，可按以上步骤升级。安装前会检查旧版入口、代理配置和当前规则；发现不兼容时停止，不清空全局防火墙。

## 怎么确认是否生效

保持 VPN 开启，运行只读检查：

```bash
sudo bash claude-lockdown.sh status
```

查看三项：

1. PF 状态显示 `Status: Enabled`。
2. `com.apple/claude-lockdown` 规则中有当前物理网卡的 `block drop out quick` 和目标地址。
3. 查看最近 DNS 查询时间和日志；如提示查询失败，说明仍在使用旧名单。

查看日志：

```bash
sudo tail -n 80 /var/log/claude-lockdown.log
```

`Packets: 0` 不代表规则失效；`No ALTQ support` 通常只是系统提示。规则存在不等于完整防泄漏。**不要关闭 VPN 后在真实 Claude 账号上试错。** 要验证断线行为，应关闭真实 Claude 会话，在隔离环境中用自有测试服务、测试地址、抓包和 PF 计数交叉验证。

## 停止和卸载

```bash
sudo bash claude-lockdown.sh off        # 停止自动更新并清除本工具规则
sudo bash claude-lockdown.sh uninstall  # 停止规则并移除本工具安装文件
```

两者会移除自动任务。需要重新启用自动更新时，再运行上面的安装命令。它们不恢复整份历史 `/etc/pf.conf`，不主动禁用其他程序使用的 PF 引用。此前的迁移备份位于 `/var/db/claude-lockdown-migration/`，不要直接覆盖现有系统配置。

## 开发验证

```bash
bash -n claude-lockdown.sh
bash test.sh
python3 -m unittest test_known.py test_integration.py
```

测试使用模拟 PF，不更改电脑防火墙。真实环境仍须单独验证。系统重启到任务启动前、新网卡出现、其他程序重载 PF，以及 DNS 更新间隔内，均可能出现保护空档。
