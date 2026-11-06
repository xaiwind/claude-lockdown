# claude-lockdown

配合 Mac 上的 **sing-box（SFM）** 使用，阻止名单中的 Claude 相关 IP 从物理网卡直连。它不是 VPN，需要先有可用的 SFM 连接。

> 这是按 IP 阻断，不能保证覆盖所有 Claude 地址，也不能保证账号不受限制。部分 IP 可能由其他网站共用。

## 新电脑怎么用

### 1. 先准备 SFM

从 [sing-box 官方页面](https://sing-box.sagernet.org/clients/apple/)安装 Mac 客户端，导入你自己的服务器配置并连接。还没有服务器的，可以参考 [kexue-sing-box](https://github.com/xaiwind/kexue-sing-box)，让 AI 协助搭建。

SFM 配置需要使用**固定 IP 的代理服务器**，并有监听 `127.0.0.1` 的 HTTP 或 mixed 本地代理端口。

### 2. 下载项目

打开 Mac 的「终端」，输入：

```bash
git clone https://github.com/xaiwind/claude-lockdown.git
cd claude-lockdown
```

如果系统提示缺少 Git 或 Python 3，运行 `xcode-select --install`，按提示安装命令行工具后再继续。

### 3. 找到 SFM 配置

在 SFM 的「概述」中记下当前配置名称，然后在终端运行：

```bash
python3 find_sfm_profiles.py
```

找到**名称与 SFM 当前配置一致**的那一项，记下它显示的配置路径和本地代理端口。如果没有找到端口，请先检查 SFM 配置的 [HTTP/mixed 入站](https://sing-box.sagernet.org/configuration/inbound/mixed/)。配置文件可能包含密钥，**不要上传或分享文件内容**。

### 4. 安装

保持 SFM 连接，将下面的路径和端口替换为上一步找到的值，然后执行。系统要求输入 Mac 管理员密码时，输入密码并回车；输入过程不会显示字符。

```bash
sudo bash claude-lockdown.sh install --sfm-profile "/你的/SFM配置文件.json" --proxy-port 2345
```

安装后会开机启动，并每小时检查一次已知域名的 IP。SFM 或 DNS 暂时不可用时，保留旧名单。

### 5. 检查

```bash
sudo bash claude-lockdown.sh status
```

看到 `Status: Enabled` 和各网卡的 `block drop out quick` 规则，表示 PF 已启用且规则已加载。`Packets: 0` 不代表规则失效；规则存在也不等于所有 Claude 地址都已覆盖。

更新日志：

```bash
sudo tail -n 80 /var/log/claude-lockdown.log
```

`status` 不访问 Claude。不要用真实 Claude 账号做断线测试。

## 日常命令

完整的旧版命令对照和新版用法见 [命令清单](COMMANDS.md)。

在项目目录中运行：

```bash
sudo bash claude-lockdown.sh refresh    # 立即检查一次地址
sudo bash claude-lockdown.sh off        # 停止自动任务，移除本工具规则
sudo bash claude-lockdown.sh uninstall  # 卸载本工具
```

换了 SFM 配置、节点或本地代理端口后，需要重新运行安装命令。首次升级最早期曾修改 `/etc/pf.conf` 的版本时，先检查并迁移旧版，不要直接用旧备份覆盖当前配置。

## 更新和限制

- 原有固定网段长期保留；动态 IP 连续 30 天未再查到才清理。查询失败不清理；超过 48 小时没有完整查询时，清理计时重新开始。
- 地址名单最多 256 条；接近上限时 `status` 会提示。超过上限时保留旧规则，停止本次更新。
- DNS 查询通过 SFM 的本地代理进行，不向 Claude 网站发送请求。未收录地址、动态子域名和更新间隔内的变化可能遗漏。
- 更多信息：[已知域名与覆盖范围](KNOWN-DOMAINS.md)。

## 开发测试

```bash
bash -n claude-lockdown.sh
bash test.sh
python3 -m unittest test_find_sfm.py test_known.py test_integration.py test_commands.py test_pf_dryrun.py
```

测试包含模拟 PF 和 macOS PF 解析器检查。曾用非 Claude 测试地址验证同类 IPv4 规则的断线行为；没有逐个测试真实 Claude 地址，也不能据此保证全部地址受保护。
