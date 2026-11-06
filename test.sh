#!/bin/bash
# Source only function definitions; never invoke real PF or root commands.
set -eu
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
sed '/^case "${1:-status}"/,$d' claude-lockdown.sh > "$TMP/lib"
source "$TMP/lib"
PF_CONF="$TMP/pf.conf"; BACKUP="$TMP/backup"; ANCHOR_FILE="$TMP/anchor"
CIDR_FILE="$TMP/cidrs"; STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
TOKEN_FILE="$STATE_DIR/token"; GENERATION_FILE="$STATE_DIR/generation"
printf 'current unrelated rules\n' > "$PF_CONF"
printf 'obsolete unrelated rules\n' > "$BACKUP"
pfctl() { return 0; }
remove_rules
if ! grep -q 'current unrelated rules' "$PF_CONF"; then
  echo 'FAIL: off overwrote unrelated pf.conf changes'; exit 1
fi
pfctl() { return 1; }
if (install_rules 'en0' '160.79.104.0/21'); then
  echo 'FAIL: PF failure reported as success'; exit 1
fi
echo 'PASS: isolated removal and PF failure propagation'
# Exercise real install/rollback code against a simulated kernel PF interface.
KERNEL="$TMP/kernel"; CALLS="$TMP/calls"; : > "$CALLS"
MODE=ok
pfctl() {
  [ "${1:-}" != -o ] || shift 2
  printf '%s\n' "$*" >> "$CALLS"
  case "$*" in
    '-sr') echo 'anchor "com.apple/*" all';;
    '-si') echo 'Status: Enabled';;
    '-E') echo 'Token : 12345';;
    '-X 12345') return 0;;
    '-n '*) [ "$MODE" != syntax_fail ];;
    "-a $ANCHOR -sr"|"-a $ANCHOR -vvsr") cat "$KERNEL";;
    "-a $ANCHOR -F rules") : > "$KERNEL";;
    "-a $ANCHOR -f "*)
      if [ "$MODE" = load_fail ] && [[ "$4" == *rules.* ]]; then return 1; fi
      cat "$4" > "$KERNEL";;
    *) echo "Unexpected mock call: $*" >&2; return 1;;
  esac
}
phys_ifaces() { echo 'en0 en7'; }
printf '160.79.104.0/21\n2607:6bc0::/32\n' > "$CIDR_FILE"
apply_rules
[ "$(grep -c '^block' "$KERNEL")" = 4 ]
[ "$(cat "$TOKEN_FILE")" = 12345 ]
cp "$KERNEL" "$TMP/expected"
MODE=load_fail
if apply_rules; then echo 'FAIL: failed load returned success'; exit 1; fi
cmp "$KERNEL" "$TMP/expected"
MODE=syntax_fail
if apply_rules; then echo 'FAIL: invalid syntax returned success'; exit 1; fi
cmp "$KERNEL" "$TMP/expected"
MODE=ok
# Input injection must fail before loading candidate rules.
printf '160.79.104.0/21\npass all\n' > "$CIDR_FILE"
if apply_rules; then echo 'FAIL: injected rules accepted'; exit 1; fi
cmp "$KERNEL" "$TMP/expected"
# Old trial must not remove a newer persistent generation.
lock() { :; }; unlock() { :; }
TRIAL_ID=old; echo new > "$GENERATION_FILE"
trial_cleanup
cmp "$KERNEL" "$TMP/expected"
echo old > "$GENERATION_FILE"
trial_cleanup
[ ! -s "$KERNEL" ]; [ ! -f "$TOKEN_FILE" ]; [ ! -f "$GENERATION_FILE" ]
grep -q 'current unrelated rules' "$PF_CONF"
echo 'PASS: dual-stack multi-interface rules, rollback, injection rejection, generation cancellation, token release'
# Execute the real status branch under mocks: no request to any target is permitted.
(
  need_root() { :; }
  curl() { echo 'Unexpected network request' >&2; exit 97; }
  set -- status
  source <(sed -n '/^case "${1:-status}"/,$p' claude-lockdown.sh)
) > "$TMP/status"
grep -q '未向 Claude/Anthropic' "$TMP/status"
echo 'PASS: status is passive and sends no Claude requests'

(
  pfctl() {
    case "$*" in
      -sr) printf '%s\n' 'scrub-anchor "com.apple/*" all fragment reassemble' 'anchor "com.apple/*" all' 'anchor "com.claude.lockdown" all';;
      '-a com.claude.lockdown -sr') [ "${BUSY:-0}" = 0 ] || echo 'block drop out quick on en0 inet from any to 160.79.104.0/21';;
      *) return 1;;
    esac
  }
  check_root_anchor
  BUSY=1
  if check_root_anchor; then echo 'FAIL: live legacy rules accepted'; exit 1; fi
)
echo 'PASS: default scrub anchor and empty legacy migration entry accepted, active legacy rejected'
# A successful pfctl exit with stale kernel rules must not be reported as success.
(
  STATE_DIR="$TMP/verify-state"; mkdir -p "$STATE_DIR"
  ANCHOR_FILE="$STATE_DIR/rules"; TOKEN_FILE="$STATE_DIR/token"; CIDR_FILE="$STATE_DIR/cidrs"
  printf '12345\n' > "$TOKEN_FILE"
  printf '160.79.104.0/21\n' > "$CIDR_FILE"
  printf 'block drop out quick on en0 inet from any to 160.79.104.0/21\n' > "$ANCHOR_FILE"
  phys_ifaces() { echo en0; }
  pfctl() {
    [ "${1:-}" != -o ] || shift 2
    case "$*" in
      '-sr') echo 'anchor "com.apple/*" all';;
      '-si') echo 'Status: Enabled';;
      "-a $ANCHOR -sr") echo 'block drop out quick on en0 inet from any to 160.79.104.0/21';;
      '-n '*|"-a $ANCHOR -f "*) return 0;;
      *) return 1;;
    esac
  }
  printf '160.79.104.0/21\n34.120.108.227/32\n' > "$CIDR_FILE"
  if apply_rules; then echo 'FAIL: stale PF output incorrectly accepted' >&2; exit 1; fi
)
echo 'PASS: stale kernel rules rejected'
# A failed DNS update or failed rule load cannot discard the existing block list.
(
  STATE_DIR="$TMP/refresh-state"; mkdir -p "$STATE_DIR"
  HISTORY_FILE="$STATE_DIR/known-ip-history.json"
  pfctl() { return 0; }
  CIDR_FILE="$STATE_DIR/cidrs"
  printf '160.79.104.0/21\n' > "$CIDR_FILE"
  collect_known() { return 1; }
  apply_rules() { return 0; }
  if refresh_known; then echo 'FAIL: DNS failure reported success' >&2; exit 1; fi
  [ "$(cat "$CIDR_FILE")" = '160.79.104.0/21' ]
  collect_known() { printf '160.79.104.0/21\n34.120.108.227/32\n' > "$1"; printf '{"version":1,"last_seen":{}}' > "$2"; }
  apply_rules() { return 1; }
  if refresh_known; then echo 'FAIL: PF failure reported success' >&2; exit 1; fi
  [ "$(cat "$CIDR_FILE")" = '160.79.104.0/21' ]
  collect_known() { printf '160.79.104.0/21\n34.120.108.227/32\n' > "$1"; printf '{"version":1,"last_seen":{}}' > "$2"; }
  apply_rules() { return 0; }
  refresh_known
  grep -q '^34.120.108.227/32$' "$CIDR_FILE"
  grep -q '^160.79.104.0/21$' "$CIDR_FILE"
)
echo 'PASS: daily refresh keeps previous list on failures and adds only verified addresses'
# Only states matching newly added destinations are cleared.
(
  STATE_DIR="$TMP/kill-state"; mkdir -p "$STATE_DIR"
  printf '160.79.104.0/21\n' > "$STATE_DIR/old"
  printf '160.79.104.0/21\n34.120.108.227/32\n2606:4700::1/128\n' > "$STATE_DIR/new"
  pfctl() { printf '%s\n' "$*" >> "$STATE_DIR/calls"; }
  kill_added_states "$STATE_DIR/old" "$STATE_DIR/new"
  grep -q -- '-k 0.0.0.0/0 -k 34.120.108.227/32' "$STATE_DIR/calls"
  grep -q -- '-k ::/0 -k 2606:4700::1/128' "$STATE_DIR/calls"
  if grep -q '160.79.104.0/21' "$STATE_DIR/calls"; then echo 'FAIL: old states were cleared' >&2; exit 1; fi
)
echo 'PASS: reset only newly blocked destination states'
# Fresh installs must persist the baseline before their first daily update.
(
  STATE_DIR="$TMP/fresh-state"; mkdir -p "$STATE_DIR"; CIDR_FILE="$STATE_DIR/cidrs"
  ensure_cidrs
  [ "$(wc -l < "$CIDR_FILE" | tr -d ' ')" = 4 ]
  printf '160.79.104.0/21\n34.120.108.227/32\n' > "$CIDR_FILE"
  ensure_cidrs
  grep -q '^34.120.108.227/32$' "$CIDR_FILE"
  : > "$CIDR_FILE"
  if ensure_cidrs; then echo 'FAIL: empty existing CIDR list accepted' >&2; exit 1; fi
)
echo 'PASS: baseline persists and existing list is never replaced'
# A failed connection-state cleanup stays visible and is retried next time.
(
  STATE_DIR="$TMP/pending-state"; mkdir -p "$STATE_DIR"; CIDR_FILE="$STATE_DIR/cidrs"
  HISTORY_FILE="$STATE_DIR/known-ip-history.json"
  printf '160.79.104.0/21\n' > "$CIDR_FILE"
  collect_known() { printf '160.79.104.0/21\n34.120.108.227/32\n' > "$1"; printf '{"version":1,"last_seen":{}}' > "$2"; }
  apply_rules() { return 0; }
  attempts=0
  kill_added_states() { attempts=$((attempts+1)); [ "$attempts" -gt 1 ]; }
  if refresh_known; then echo 'FAIL: cleanup failure hidden' >&2; exit 1; fi
  [ -s "$STATE_DIR/pending-previous" ]
  refresh_known
  [ ! -e "$STATE_DIR/pending-previous" ]
  [ "$attempts" = 2 ]
)
echo 'PASS: failed state cleanup is retained and retried'
# Expired dynamic IPs are removed only after successful rule verification;
# metadata is not committed if applying rules fails.
(
  STATE_DIR="$TMP/expiration-state"; mkdir -p "$STATE_DIR"
  CIDR_FILE="$STATE_DIR/cidrs"; HISTORY_FILE="$STATE_DIR/known-ip-history.json"
  printf '160.79.104.0/21\n34.120.108.227/32\n' > "$CIDR_FILE"
  printf '{"version":1,"last_seen":{"34.120.108.227":100}}' > "$HISTORY_FILE"
  collect_known() { printf '160.79.104.0/21\n' > "$1"; printf '{"version":1,"last_seen":{}}' > "$2"; }
  apply_rules() { return 1; }
  if refresh_known; then echo 'FAIL: expiration commit succeeded on PF failure' >&2; exit 1; fi
  grep -q '^34.120.108.227/32$' "$CIDR_FILE"
  grep -q '34.120.108.227' "$HISTORY_FILE"
  apply_rules() { return 0; }
  refresh_known
  if grep -q '34.120.108.227' "$CIDR_FILE" "$HISTORY_FILE"; then echo 'FAIL: expired IP retained' >&2; exit 1; fi
  grep -q '^160.79.104.0/21$' "$CIDR_FILE"
)
echo 'PASS: expired addresses and metadata change only after rules verify'
