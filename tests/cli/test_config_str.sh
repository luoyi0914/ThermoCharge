#!/bin/sh
# Exercise the same normalized string configuration consumed by safety scripts.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cfgstr.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
BIN=$WORK/thermocharge
cp "${TC_TEST_BINARY:-$ROOT/out/thermocharge}" "$BIN" || exit 1
chmod 755 "$BIN" || exit 1
CONF=$WORK/config.conf
PASS=0
FAIL=0

check() {
  name=$1 config=$2 key=$3 want=$4
  printf '%b' "$config" > "$CONF"
  got=$(TC_CONFIG="$CONF" "$BIN" config-str "$key" 2>/dev/null) || got='<error>'
  if [ "$got" = "$key=$want" ]; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s: got [%s], expected [%s]\n' "$name" "$got" "$key=$want"
    FAIL=$((FAIL + 1))
  fi
}

check 'default identity' '' mca_tag user
check 'embedded spaces preserved as underscores' 'mca_tag=my tag\n' mca_tag my_tag
check 'tab becomes underscore' 'mca_type=quick\tmain\n' mca_type quick_main
check 'last value wins' 'mca_tag=first\nmca_tag=second # comment\n' mca_tag second
check 'long identity matches C buffer length' 'mca_tag=123456789012345678901234567890123456789\n' mca_tag 1234567890123456789012345678901
check 'valid sysfs path' 'p_suspend=/sys/example/suspend\n' p_suspend /sys/example/suspend
check 'invalid later path ignored' 'p_suspend=/sys/example/suspend\np_suspend=/tmp/unsafe\n' p_suspend /sys/example/suspend
check 'invalid path falls back' 'p_suspend=/tmp/unsafe\n' p_suspend /sys/class/xm_power/charger/charge_interface/input_suspend
check 'multiple spaces are not collapsed' 'mca_tag=my  tag\n' mca_tag my__tag
check 'trim CRLF whitespace' 'mca_tag=  my tag  \r\n' mca_tag my_tag
check 'empty identity uses default' 'mca_tag=\n' mca_tag user
check 'parent traversal rejected' 'p_suspend=/sys/example/suspend\np_suspend=/sys/../tmp/unsafe\n' p_suspend /sys/example/suspend
check 'terminal parent rejected' 'p_suspend=/sys/example/suspend\np_suspend=/sys/example/..\n' p_suspend /sys/example/suspend
long_path="/sys/$(printf '%0256d' 0)"
check 'overlength path rejected without truncation' "p_suspend=/sys/example/suspend\np_suspend=$long_path\n" p_suspend /sys/example/suspend

printf 'mca_tag=test tag\nmca_type=all\n' > "$CONF"
got=$(TC_CONFIG="$CONF" "$BIN" config-str mca_tag mca_type 2>/dev/null) || got='<error>'
if [ "$got" = "$(printf 'mca_tag=test_tag\nmca_type=all')" ]; then
  printf '  PASS  multiple keys\n'; PASS=$((PASS + 1))
else
  printf '  FAIL  multiple keys: [%s]\n' "$got"; FAIL=$((FAIL + 1))
fi
for args in unknown ''; do
  if [ -n "$args" ]; then
    TC_CONFIG="$CONF" "$BIN" config-str "$args" > "$WORK/result" 2>/dev/null
  else
    TC_CONFIG="$CONF" "$BIN" config-str > "$WORK/result" 2>/dev/null
  fi
  rc=$?
  if [ "$rc" = 2 ] && [ ! -s "$WORK/result" ]; then
    printf '  PASS  invalid request [%s] rejected with rc=2\n' "$args"; PASS=$((PASS + 1))
  else
    printf '  FAIL  invalid request [%s]: rc=%s\n' "$args" "$rc"; FAIL=$((FAIL + 1))
  fi
done
printf '\n通过 %s 项，失败 %s 项\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
