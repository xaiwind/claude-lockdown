# claude-lockdown

一个配合 **sing-box for macOS（SFM）** 使用的防火墙脚本：阻止名单中的 Claude 相关 IP 从物理网卡直连。

- 保留已有固定网段，每小时查询已知域名，发现新 IP 就加入名单。
- 动态 IP 连续 30 天未再查到时清理；查询失败时保留旧名单。开机自动启动。
- 仅按 IP 阻断，**不能保证覆盖所有 Claude 地址或保证账号不受限制**。共享 IP 可能影响其他网站。

## 安装

需要 macOS、SFM、Python 3 和管理员权限。先保持 SFM 连接，然后下载项目：

```bash
git clone https://github.com/xaiwind/claude-lockdown.git
cd claude-lockdown
```

将下面的路径和端口替换为**你自己的 SFM 配置文件路径和本地 HTTP/mixed 代理端口**：

```bash
sudo bash claude-lockdown.sh install --sfm-profile "/你的/SFM配置文件.json" --proxy-port 2345
```

配置中的代理服务器必须使用固定 IP，本地代理需监听 `127.0.0.1`。配置文件可能包含密钥，不要上传或分享。切换 SFM 配置、节点或端口后，需要重新安装，以更新服务器 IP 快照。

如果使用的是曾修改 `/etc/pf.conf` 的最早版本，先检查并迁移旧版，不要直接用旧备份覆盖当前配置。

## 查看和更新

以下命令在项目目录里运行：

```bash
sudo bash claude-lockdown.sh status   # 查看 PF 状态、规则和最近查询时间
sudo bash claude-lockdown.sh refresh  # 立即查询并更新一次
```

`status` 不访问 Claude。要查看更新详情：

```bash
sudo tail -n 80 /var/log/claude-lockdown.log
```

确认 `Status: Enabled`，并查看各网卡的 `block drop out quick` 规则。`Packets: 0` 不代表规则无效；`No ALTQ support` 通常只是系统提示。规则存在只能证明已加载，不能证明所有 Claude 地址都被覆盖。

如果 SFM 未连接、查询失败或名单达到安全上限，脚本保留旧规则。**不要用真实 Claude 账号做断线测试。**

## 停止或卸载

```bash
sudo bash claude-lockdown.sh off        # 停止自动任务并清除本工具规则
sudo bash claude-lockdown.sh uninstall  # 停止规则并移除安装文件
```

重新启用自动更新时，再运行安装命令。脚本不会恢复整份旧 `/etc/pf.conf`，也不会主动禁用其他程序使用的 PF 引用。

## 更多信息

[已知域名与覆盖范围](KNOWN-DOMAINS.md) ｜ [开发与测试](#开发测试)

### 开发测试

```bash
bash -n claude-lockdown.sh
bash test.sh
python3 -m unittest test_known.py test_integration.py test_pf_dryrun.py
```

测试包含模拟 PF 和 macOS PF 解析器检查。曾用非 Claude 测试地址验证同类 IPv4 规则的断线行为；没有逐个测试真实 Claude 地址，也不能据此保证全部地址受保护。
