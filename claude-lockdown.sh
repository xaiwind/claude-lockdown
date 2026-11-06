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
  boot=$(sysctl -n kern.boottime) || return 1
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
load_cidrs() { if [ -s "$CIDR_FILE" ]; then cat "$CIDR_FILE"; else printf '%s\n' $DEFAULT_CIDRS; fi; }
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
  mv "$tmp" "$ANCHOR_FILE" || return 1
  if [ ! -s "$TOKEN_FILE" ]; then
    local output token
    output=$(pfctl -E 2>&1) || { printf '%s\n' "$output" >&2; return 1; }
    token=$(printf '%s\n' "$output" | awk '/Token/ {print $NF}')
    [[ "$token" =~ ^[0-9]+$ ]] || { fail 'PF 未返回可追踪的引用 token，请检查 pfctl -s References'; return 1; }
    printf '%s\n' "$token" > "$TOKEN_FILE" || return 1
  fi
  pfctl -si | grep -q 'Status: Enabled' || { fail 'PF 未启用'; return 1; }
  pfctl -a "$ANCHOR" -sr | grep -q '^block' || { fail '内核中未发现阻断规则'; return 1; }
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
refresh_cidrs() {
  command -v python3 >/dev/null || { fail 'refresh 需要 Python 3'; return 1; }
  python3 - "$CIDR_FILE" <<'PY'
import ipaddress, json, os, sys, tempfile, urllib.request
req=urllib.request.Request('https://rdap.arin.net/registry/entity/AP-2440',headers={'User-Agent':'claude-lockdown/2.0'})
with urllib.request.urlopen(req,timeout=25) as r: d=json.load(r)
if d.get('handle') != 'AP-2440': raise ValueError('Unexpected ARIN entity')
cidrs=[]
for n in d.get('networks',[]):
    start,end=map(ipaddress.ip_address,(n['startAddress'],n['endAddress']))
    cidrs.extend(ipaddress.summarize_address_range(start,end))
if not cidrs: raise ValueError('ARIN returned no networks; old list preserved')
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(sys.argv[1]))
try:
    with os.fdopen(fd,'w') as f: f.write('\n'.join(sorted(set(map(str,cidrs))))+'\n')
    os.replace(tmp,sys.argv[1])
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
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
    echo '只读检查完成；未向 Claude/Anthropic 发送任何请求。'
    ;;
  on)
    need_root
    [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = --keep ]; } || { fail '用法: on [--keep]'; exit 1; }
    lock; trap unlock EXIT
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
      rm -f "$INSTALL_PATH" "$CIDR_FILE"
      echo '已先撤销规则，再删除开机任务、安装脚本及网段缓存。'
    else echo '已撤销规则并移除自动启用任务；需要自动启用时重新 install。'; fi
    ;;
  refresh)
    need_root; lock; trap unlock EXIT
    old_cidrs=$(mktemp "$STATE_DIR/old-cidrs.XXXXXX")
    load_cidrs > "$old_cidrs"
    if ! refresh_cidrs; then rm -f "$old_cidrs"; exit 1; fi
    if [ -f "$ANCHOR_FILE" ] && ! apply_rules; then
      mv "$old_cidrs" "$CIDR_FILE"; exit 1
    fi
    rm -f "$old_cidrs"
    if [ -f "$ANCHOR_FILE" ]; then kill_target_states; fi
    echo '已更新网段缓存；不代表完整域名覆盖。'
    ;;
  reconcile)
    need_root; lock; trap unlock EXIT
    # Reapply for new interfaces or an externally reloaded PF ruleset.
    apply_rules
    ;;
  install)
    need_root
    # Validate/apply before registering automation. No shell background processes.
    bash "$SELF" on --keep
    lock; trap unlock EXIT
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
    stop_daemon
    unlock
    launchctl bootstrap system "$DAEMON_PLIST"
    echo '已注册开机及每 86400 秒（24 小时）规则刷新。开机/新网卡存在未覆盖窗口，不是无缝 kill switch。'
    ;;
  *) echo '用法: sudo bash claude-lockdown.sh {status|on [--keep]|off|refresh|install|uninstall}'; exit 2;;
esac
