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
  printf '%s\n' "$*" >> "$CALLS"
  case "$*" in
    '-sr') echo 'anchor "com.apple/*" all';;
    '-si') echo 'Status: Enabled';;
    '-E') echo 'Token : 12345';;
    '-X 12345') return 0;;
    '-n '*) [ "$MODE" != syntax_fail ];;
    "-a $ANCHOR -sr") cat "$KERNEL";;
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
# Probes must not label a DNS failure a verified block.
curl() { printf 000; return 6; }
probe > "$TMP/probe"
grep -q 'curl_exit=6' "$TMP/probe"
echo 'PASS: dual-stack multi-interface rules, load/syntax failure rollback, injection rejection, generation cancellation, token release, honest probe'
