#!/usr/bin/env bash
# macOS: block direct traffic to a reviewed CIDR list; NOT a domain kill switch.
# on: foreground 60-second trial; on --keep: keep until off/reboot.
# install: boot + periodic refresh; uninstall: remove rules before removing files.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
ANCHOR="com.apple/claude-lockdown"
STATE_DIR="/var/db/claude-lockdown"
CIDR_FILE="$STATE_DIR/cidrs"
ANCHOR_FILE="$STATE_DIR/rules"
TOKEN_FILE="$STATE_DIR/pf-token"
GENERATION_FILE="$STATE_DIR/generation"
INSTALL_PATH="/usr/local/sbin/claude-lockdown.sh"
HELPER="/usr/local/libexec/claude-lockdown/known_addresses.py"
PROFILE_FILE="$STATE_DIR/sfm-profile"
PROXY_PORT_FILE="$STATE_DIR/proxy-port"
DAEMON_LABEL="com.claude.lockdown"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# Original supplied list, not a guarantee of present ownership or complete coverage.
DEFAULT_CIDRS="153.61.0.0/16 160.79.104.0/21 216.73.216.0/22 2607:6bc0::/32"
LOCKED=0
fail() { echo "错误: $*" >&2; return 1; }
need_root() { [ "$(uname -s)" = Darwin ] || fail '仅支持 macOS'; [ "$(id -u)" -eq 0 ] || fail '请用 sudo 运行'; }
lock() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  local n=0
  until mkdir "$STATE_DIR/lock" 2>/dev/null; do
    n=$((n+1)); [ "$n" -lt 10 ] || { fail '另一操作运行中，或存在残留锁；确认没有脚本进程后再清理 /var/db/claude-lockdown/lock'; return 1; }
    sleep 1
  done
  LOCKED=1
  local boot
  boot=$(sysctl -n kern.boottime) || { rmdir "$STATE_DIR/lock"; LOCKED=0; return 1; }
  if [ ! -f "$STATE_DIR/boot" ] || [ "$(cat "$STATE_DIR/boot")" != "$boot" ]; then
    rm -f "$TOKEN_FILE"
    printf '%s\n' "$boot" > "$STATE_DIR/boot"
  fi
}
unlock() { if [ "$LOCKED" = 1 ]; then rmdir "$STATE_DIR/lock"; LOCKED=0; fi; }
phys_ifaces() {
  # Include interfaces without addresses: later DHCP must not bypass the rule.
  ifconfig -l | tr ' ' '\n' | awk '/^(en[0-9]+|eth[0-9]+|pdp_ip[0-9]+|bridge[0-9]+)$/ {printf "%s ", $0}'
}
ensure_cidrs() {
  if [ -e "$CIDR_FILE" ]; then
    [ -s "$CIDR_FILE" ] || { fail '已有名单为空；拒绝覆盖，请先人工检查'; return 1; }
    return 0
  fi
  local tmp
  tmp=$(mktemp "$STATE_DIR/initial-cidrs.XXXXXX") || return 1
  printf '%s\n' $DEFAULT_CIDRS > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$CIDR_FILE"
}
load_cidrs() { cat "$CIDR_FILE"; }
check_root_anchor() {
  local rules
  rules=$(pfctl -sr) || return 1
  printf '%s\n' "$rules" | grep -Eq '^anchor "com.apple/\*"' || {
    fail '当前 PF 未加载 com.apple/* 调用入口；为避免覆盖其他规则，不自动重载 /etc/pf.conf'; return 1;
  }
  # Last-match semantics: do not assume this child anchor overrides custom root rules.
  if printf '%s\n' "$rules" | grep -Ev '^[[:space:]]*$|^anchor "com.apple/\*" all$|^scrub-anchor "com.apple/\*" all( fragment reassemble)?$|^anchor "com.claude.lockdown" all$' | grep -q .; then
    fail '检测到自定义主过滤规则；需人工审查规则顺序，不自动修改'; return 1
  fi
  # Migration leaves a harmless empty legacy call in the running root ruleset
  # until reboot, avoiding a global PF reload that could affect other services.
  if printf '%s\n' "$rules" | grep -q '^anchor "com.claude.lockdown" all$'; then
    local legacy
    legacy=$(pfctl -a com.claude.lockdown -sr) || return 1
    [ -z "$legacy" ] || { fail '旧版 anchor 仍有规则，请先迁移'; return 1; }
  fi
}
verify_rules() {
  # PF may normalize /32, IPv6 text, or combine networks. Compare semantics,
  # including the interface, rather than merely checking for any block rule.
  python3 - "$1" "$2" <<'PYCODE'
import ipaddress, re, sys
pattern = re.compile(r'^block drop out quick on (\S+) (inet6?) from any to (\S+)(?:\s|$)')
def parse(path):
    result = []
    for line in open(path):
        match = pattern.match(line.strip())
        if match:
            interface, family, target = match.groups()
            result.append((interface, family, ipaddress.ip_network(target, strict=False)))
    return result
expected, actual = parse(sys.argv[1]), parse(sys.argv[2])
if not expected or any(not any(i == j and f == g and n.version == m.version and n.subnet_of(m)
                               for j, g, m in actual) for i, f, n in expected):
    sys.exit(1)
PYCODE
}
install_rules() {
  local ifs="$1" cidrs="$2" i c fam tmp
  [ -n "$ifs" ] || { fail '未识别到物理网卡'; return 1; }
  check_root_anchor || return 1
  tmp=$(mktemp "$STATE_DIR/rules.XXXXXX") || return 1
  for i in $ifs; do
    [[ "$i" =~ ^(en|eth|pdp_ip|bridge)[0-9]+$ ]] || { rm -f "$tmp"; fail '非法网卡名'; return 1; }
    for c in $cidrs; do
      # Reject PF syntax injection; pfctl -n performs the full network validation.
      [[ "$c" =~ ^[0-9a-fA-F:.]+/[0-9]+$ ]] || { rm -f "$tmp"; fail '非法 CIDR'; return 1; }
      case "$c" in *:*) fam=inet6;; *) fam=inet;; esac
      printf 'block drop out quick on %s %s from any to %s\n' "$i" "$fam" "$c" >> "$tmp"
    done
  done
  [ -s "$tmp" ] || { rm -f "$tmp"; fail '空规则'; return 1; }
  if ! pfctl -n -a "$ANCHOR" -f "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! pfctl -a "$ANCHOR" -f "$tmp"; then rm -f "$tmp"; return 1; fi
  if [ ! -s "$TOKEN_FILE" ]; then
    local output token
    output=$(pfctl -E 2>&1) || { printf '%s\n' "$output" >&2; return 1; }
    token=$(printf '%s\n' "$output" | awk '/Token/ {print $NF}')
    [[ "$token" =~ ^[0-9]+$ ]] || { fail 'PF 未返回可追踪的引用 token，请检查 pfctl -s References'; return 1; }
    printf '%s\n' "$token" > "$TOKEN_FILE" || return 1
  fi
  pfctl -si | grep -q 'Status: Enabled' || { rm -f "$tmp"; fail 'PF 未启用'; return 1; }
  local readback
  readback=$(mktemp "$STATE_DIR/readback.XXXXXX") || { rm -f "$tmp"; return 1; }
  if ! pfctl -a "$ANCHOR" -sr > "$readback"; then rm -f "$tmp" "$readback"; return 1; fi
  if ! verify_rules "$tmp" "$readback"; then
    rm -f "$tmp" "$readback"
    fail '内核规则未完整覆盖预期网卡和地址'; return 1
  fi
  rm -f "$readback"
  mv "$tmp" "$ANCHOR_FILE" || return 1
}
apply_rules() {
  local previous had_rules=0
  previous=$(mktemp "$STATE_DIR/previous.XXXXXX")
  if [ -f "$ANCHOR_FILE" ]; then cp "$ANCHOR_FILE" "$previous"; had_rules=1; fi
  if install_rules "$(phys_ifaces)" "$(load_cidrs)"; then
    rm -f "$previous"
  else
    echo '加载失败，尝试恢复脚本自身的旧规则。' >&2
    if [ "$had_rules" = 1 ]; then
      pfctl -a "$ANCHOR" -f "$previous" || { rm -f "$previous"; fail '回滚失败，必须人工检查 PF'; return 1; }
      mv "$previous" "$ANCHOR_FILE"
    else
      rm -f "$previous"
      remove_rules || { fail '回滚失败，必须人工检查 PF'; return 1; }
    fi
    return 1
  fi
}
remove_rules() {
  # Never restore or reload the user's global pf.conf, never flush global states.
  pfctl -a "$ANCHOR" -F rules || return 1
  if [ -s "$TOKEN_FILE" ]; then
    pfctl -X "$(cat "$TOKEN_FILE")" || return 1
    rm -f "$TOKEN_FILE"
  fi
  rm -f "$ANCHOR_FILE" "$GENERATION_FILE"
}
kill_target_states() {
  local c
  for c in $(load_cidrs); do
    case "$c" in *:*) pfctl -k ::/0 -k "$c";; *) pfctl -k 0.0.0.0/0 -k "$c";; esac
  done
}
kill_added_states() {
  local added target failed=0
  added=$(mktemp "$STATE_DIR/added.XXXXXX") || return 1
  if ! python3 - "$1" "$2" > "$added" <<'PYADDED'
import ipaddress, sys

def load(path):
    with open(path) as f:
        return [ipaddress.ip_network(line.strip()) for line in f if line.strip()]
old, new = load(sys.argv[1]), load(sys.argv[2])
for net in new:
    if not any(net.version == previous.version and net.subnet_of(previous) for previous in old):
        print(net)
PYADDED
  then rm -f "$added"; return 1; fi
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    case "$target" in
      *:*) pfctl -k ::/0 -k "$target" || failed=1;;
      *) pfctl -k 0.0.0.0/0 -k "$target" || failed=1;;
    esac
  done < "$added"
  rm -f "$added"
  [ "$failed" -eq 0 ]
}

collect_known() {
  [ -r "$HELPER" ] && [ -s "$PROFILE_FILE" ] && [ -s "$PROXY_PORT_FILE" ] || {
    fail '未配置 SFM 文件或 DNS 更新组件；旧规则保持不变'; return 1;
  }
  local profile port
  profile=$(cat "$PROFILE_FILE"); port=$(cat "$PROXY_PORT_FILE")
  python3 "$HELPER" --current "$CIDR_FILE" --output "$1" --sfm-profile "$profile" --proxy-port "$port"
}

refresh_known() {
  local candidate backup
  [ -s "$CIDR_FILE" ] || { fail '旧名单不存在，拒绝覆盖'; return 1; }
  if [ -s "$STATE_DIR/pending-previous" ]; then
    if ! kill_added_states "$STATE_DIR/pending-previous" "$CIDR_FILE"; then
      echo '上次新增地址的旧连接仍未能清理，请检查日志。' >&2; return 1
    fi
    rm -f "$STATE_DIR/pending-previous"
  fi
  candidate=$(mktemp "$STATE_DIR/candidate.XXXXXX") || return 1
  backup=$(mktemp "$STATE_DIR/cidrs-backup.XXXXXX") || { rm -f "$candidate"; return 1; }
  if ! cp "$CIDR_FILE" "$backup"; then rm -f "$candidate" "$backup"; return 1; fi
  if ! collect_known "$candidate"; then
    rm -f "$candidate" "$backup"
    echo 'DNS 更新失败，保留旧名单。' >&2; return 1
  fi
  if cmp -s "$candidate" "$CIDR_FILE"; then
    rm -f "$candidate" "$backup"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/last-dns-success"
    echo 'DNS 已检查，无新增地址。'; return 0
  fi
  if ! mv "$candidate" "$CIDR_FILE"; then rm -f "$candidate" "$backup"; return 1; fi
  if ! apply_rules; then
    mv "$backup" "$CIDR_FILE"
    if ! apply_rules; then echo '恢复旧规则失败，请立即人工检查 PF。' >&2; fi
    echo '新规则未通过核验，已恢复旧名单。' >&2; return 1
  fi
  if ! kill_added_states "$backup" "$CIDR_FILE"; then
    mv "$backup" "$STATE_DIR/pending-previous"
    echo '新规则已加载，但部分旧连接未能清理；下次更新会重试。' >&2; return 1
  fi
  rm -f "$backup"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/last-dns-success"
  echo '已合并新 IP、验证内核规则并清理对应旧连接。'
}

trial_cleanup() {
  lock || return 1
  if [ -f "$GENERATION_FILE" ] && [ "$(cat "$GENERATION_FILE")" = "$TRIAL_ID" ]; then
    remove_rules || { unlock; return 1; }
    echo '试用规则已撤销。'
  fi
  unlock
}
stop_daemon() {
  if launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    launchctl bootout "system/$DAEMON_LABEL" || return 1
  fi
}
case "${1:-status}" in
  status)
    need_root
    echo "当前识别网卡: $(phys_ifaces)"
    echo '实际 PF 状态与内核规则（文件存在不代表生效）:'
    pfctl -si; pfctl -a "$ANCHOR" -vvsr
    if [ -f "$STATE_DIR/last-dns-success" ]; then
      echo "最近 DNS 查询（UTC，完整性请看日志）: $(cat "$STATE_DIR/last-dns-success")"
    else echo '尚无成功 DNS 检查记录；请查看服务日志。'; fi
    echo '只读检查完成；未向 Claude/Anthropic 发送任何请求。'
    ;;
  on)
    need_root
    [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = --keep ]; } || { fail '用法: on [--keep]'; exit 1; }
    lock; trap unlock EXIT
    ensure_cidrs
    [ ! -f /etc/pf.conf.bak.claude-lockdown ] || { fail '检测到旧版配置备份；请先按 README 迁移，不能叠加安装'; exit 1; }
    if [ "${2:-}" != --keep ]; then
      if [ -f "$ANCHOR_FILE" ] || launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
        fail '已有规则或自动任务，不能覆盖为临时试用；请先 off，或使用 on --keep'; exit 1
      fi
    fi
    apply_rules
    uuidgen > "$GENERATION_FILE"
    TRIAL_ID=$(cat "$GENERATION_FILE")
    unlock
    echo '指定网段规则已加载；不代表全部 Claude 域名受保护。接下来清理目标连接状态。'
    if [ "${2:-}" = --keep ]; then
      kill_target_states
      echo '保持至 off 或重启；开机及网卡变更刷新需使用 install。'
    else
      trap 'trial_cleanup; unlock' EXIT
      trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
      kill_target_states
      echo '前台试用 60 秒；Ctrl-C 提前撤销。另一个终端的 on --keep 可接管。'
      sleep 60
    fi
    ;;
  off|uninstall)
    need_root
    # Stop the periodic job before locking; otherwise a waiting job can re-enable rules.
    stop_daemon
    lock; trap unlock EXIT
    remove_rules
    rm -f "$DAEMON_PLIST"
    if [ "$1" = uninstall ]; then
      rm -f "$INSTALL_PATH" "$CIDR_FILE" "$PROFILE_FILE" "$PROXY_PORT_FILE" "$STATE_DIR/last-dns-success" "$STATE_DIR/pending-previous" "$HELPER"
      rmdir /usr/local/libexec/claude-lockdown 2>/dev/null || true
      echo '已先撤销规则，再删除开机任务、安装脚本及网段缓存。'
    else echo '已撤销规则并移除自动启用任务；需要自动启用时重新 install。'; fi
    ;;
  refresh)
    need_root; lock; trap unlock EXIT
    refresh_known
    ;;
  reconcile)
    need_root; lock; trap unlock EXIT
    # Keep cached rules active even if SFM/DNS is unavailable at boot.
    ensure_cidrs
    apply_rules
    if [ -s "$PROFILE_FILE" ] && [ -r "$HELPER" ]; then
      refresh_known || echo '本次未更新 DNS；既有规则仍保留。' >&2
    fi
    ;;
  install)
    need_root
    # Require explicit profile: do not guess a server and risk blocking the VPN.
    [ "$#" -eq 5 ] && [ "$2" = --sfm-profile ] && [ "$4" = --proxy-port ] || {
      fail '用法: install --sfm-profile 配置文件路径 --proxy-port 本地代理端口'; exit 1;
    }
    PROFILE="$3"; PORT="$5"
    [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { fail '代理端口无效'; exit 1; }
    [[ "$PROFILE" = /* ]] && [ -f "$PROFILE" ] || { fail 'SFM 配置路径必须是存在的绝对路径'; exit 1; }
    SOURCE_HELPER="$(dirname "$SELF")/known_addresses.py"
    [ -r "$SOURCE_HELPER" ] || { fail '找不到同目录的 known_addresses.py'; exit 1; }
    python3 - "$SOURCE_HELPER" "$PROFILE" "$PORT" "$CIDR_FILE" "$DEFAULT_CIDRS" <<'PYVALIDATE'
import importlib.util, json, pathlib, sys
s=importlib.util.spec_from_file_location('known_addresses',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
with open(sys.argv[2]) as f: profile=json.load(f)
servers=m.proxy_servers(profile)
cidrs=pathlib.Path(sys.argv[4])
old=m.parse_networks(cidrs.read_text() if cidrs.exists() else '\n'.join(sys.argv[5].split()))
if any(ip.version == net.version and ip in net for ip in servers for net in old):
    raise SystemExit('现有阻断网段包含 SFM 服务器 IP，停止安装以免中断代理。')
if not any(i.get('type') in ('mixed','http') and i.get('listen') == '127.0.0.1' and i.get('listen_port') == int(sys.argv[3]) for i in profile.get('inbounds',[])):
    raise SystemExit('SFM 配置未找到指定的本地 HTTP/mixed 端口')
PYVALIDATE
    bash "$SELF" on --keep
    # Stop the prior periodic job before acquiring the update lock.
    stop_daemon
    lock; trap unlock EXIT
    mkdir -p /usr/local/libexec/claude-lockdown
    cp "$SOURCE_HELPER" "$HELPER"
    chmod 644 "$HELPER"; chown root:wheel "$HELPER"
    printf '%s\n' "$PROFILE" > "$PROFILE_FILE"
    printf '%s\n' "$PORT" > "$PROXY_PORT_FILE"
    mkdir -p /usr/local/sbin
    if [ "$SELF" != "$INSTALL_PATH" ]; then cp "$SELF" "$INSTALL_PATH"; fi
    chmod 755 "$INSTALL_PATH"; chown root:wheel "$INSTALL_PATH"
    sysctl -n kern.boottime > "$STATE_DIR/boot"
    cat > "$DAEMON_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$DAEMON_LABEL</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$INSTALL_PATH</string><string>reconcile</string></array>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>86400</integer>
<key>StandardOutPath</key><string>/var/log/claude-lockdown.log</string>
<key>StandardErrorPath</key><string>/var/log/claude-lockdown.log</string>
</dict></plist>
PLIST
    chmod 644 "$DAEMON_PLIST"; chown root:wheel "$DAEMON_PLIST"
    plutil -lint "$DAEMON_PLIST"
    unlock
    launchctl bootstrap system "$DAEMON_PLIST"
    echo '已注册开机及每 24 小时更新。请用 status 和服务日志检查结果。'
    ;;
  *) echo '用法: sudo bash claude-lockdown.sh {status|on [--keep]|off|refresh|install --sfm-profile 路径 --proxy-port 端口|uninstall}'; exit 2;;
esac
