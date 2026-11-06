# 命令清单

先在终端进入下载的项目目录：

```bash
cd claude-lockdown
```

除配置查找外，下面的脚本命令需要 `sudo`。也可以用已安装的绝对路径 `/usr/local/sbin/claude-lockdown.sh` 代替 `claude-lockdown.sh`。

## 安装或重新启用自动更新

```bash
python3 find_sfm_profiles.py
sudo bash claude-lockdown.sh install
```

第二条保留了旧版命令写法，但新版会**交互询问 SFM 配置的绝对路径和本地 HTTP/mixed 端口**；输入第一条命令中与 SFM 当前配置对应的值。SFM 应保持连接。

也可以直接传入参数，适合复制使用：

```bash
sudo bash claude-lockdown.sh install --sfm-profile "/你的/SFM配置文件.json" --proxy-port 2345
```

替换成自己的路径和端口。安装后会开机启动并每小时检查；要换 SFM 配置、节点或端口时，重新安装以更新代理服务器 IP 快照。

## 查看和更新

```bash
# 只读查看 PF 状态、规则、名单数量和最近 DNS 查询时间
sudo bash /usr/local/sbin/claude-lockdown.sh status

# SFM 已连接、阻断规则已启用时，手动查询并更新一次
sudo bash /usr/local/sbin/claude-lockdown.sh refresh

# 查看自动更新日志
sudo tail -n 80 /var/log/claude-lockdown.log

# 查看开机任务
sudo launchctl print system/com.claude.lockdown | head -20
```

`status` 不访问 Claude。`refresh` 通过 SFM 本地代理查询已知域名的 DNS；它不访问 Claude 网站，也不会在规则已停止时悄悄重新启用规则。

## 临时开启、关闭、卸载

```bash
# 前台试开：60 秒后撤销；已有规则或自动任务时会拒绝试开
sudo bash /usr/local/sbin/claude-lockdown.sh on

# 开启并保持当前规则；不单独注册开机任务
sudo bash /usr/local/sbin/claude-lockdown.sh on --keep

# 关闭当前规则并停止、移除自动任务
sudo bash /usr/local/sbin/claude-lockdown.sh off

# 卸载本工具；会删除其名单和动态 IP 历史
sudo bash /usr/local/sbin/claude-lockdown.sh uninstall
```

**与旧版不同：`off` 会移除自动任务，重启不会自动恢复。** 再次安装才能恢复开机和每小时更新。`on --keep` 会清理目标网段的已有连接状态，可能导致这些连接重新建立。

## 验证时不要误判

查看 `status` 中的 `Status: Enabled` 和 `block drop out quick`，可以确认 PF 启用、规则已加载。`Packets: 0` 不代表规则失效；规则存在也不能证明所有 Claude 地址都被覆盖。

旧教程中的两条 `curl https://claude.ai` 不足以证明安全：`000` 也可能是超时或 DNS 失败，`302/403` 也不能证明连接必然经过代理。不要使用真实 Claude 账号做 VPN 断线测试。

## 文件位置

```text
/usr/local/sbin/claude-lockdown.sh                已安装脚本
/usr/local/libexec/claude-lockdown/known_addresses.py  地址更新组件
/Library/LaunchDaemons/com.claude.lockdown.plist  自动任务
/var/db/claude-lockdown/cidrs                    当前阻断名单
/var/db/claude-lockdown/known-ip-history.json    动态 IP 时间记录
/var/log/claude-lockdown.log                     更新日志
```

PF 规则位于 `com.apple/claude-lockdown`，不再使用旧版的 `/etc/pf.anchors/com.claude.lockdown`。更新项目代码后重新运行 `install` 即可同步已安装的脚本，不需要手改两个文件。
