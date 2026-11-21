#!/usr/bin/env sh
# 看门狗夹具测试：不需要 root，不碰真机节点
#
# 用 ../module/watchdog.sh 自带的 WD_* 覆盖把节点指到临时文件里，
# 逐个验证四种触发条件是否都会执行「停流 + 交还温控 + 写 ABORT」。

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WD=$ROOT/module/watchdog.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wd-bin.XXXXXX")
T=$WORK/fixture
IDP=
WD_PID=
cleanup() {
  if [ -n "$WD_PID" ]; then kill "$WD_PID" 2>/dev/null || true; wait "$WD_PID" 2>/dev/null || true; fi
  if [ -n "$IDP" ]; then kill "$IDP" 2>/dev/null || true; wait "$IDP" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
PASS=0
FAIL=0

[ -f "$WD" ] || { echo "找不到 $WD" >&2; exit 1; }
cp "${TC_TEST_BINARY:-$ROOT/out/thermocharge}" "$WORK/thermocharge"
chmod 755 "$WORK/thermocharge"

setup() {
  rm -rf "$T"
  mkdir -p "$T/sys/charge_interface" "$T/sys/charger_thermal" "$T/data/log" "$T/batt"
  echo "thermal_remove=1" > "$T/data/config.conf"
  : > "$T/sys/charge_interface/input_suspend"
  : > "$T/sys/charger_thermal/wired_thermal_remove"
  echo "350" > "$T/batt/temp"
  echo "-1000000" > "$T/batt/current_now"
  echo 1 > "$T/batt/online"
  echo Charging > "$T/batt/status"
  echo "5000" > "$T/data/watchdog.limit"
  # 心跳：默认给一个"刚刚"的时间戳
  echo 1 > "$T/data/heartbeat"
}

# run_wd <额外环境...> —— 跑 8 秒（够所有条件在测试尺度内触发）
# 注意用 sh 调起：仓库在 /storage 上，那里不能直接 exec 脚本
run_wd() {
  env WD_DIR="$T/data" WD_XM="$T/sys" WD_TEMP="$T/batt/temp" \
      WD_BIN="$WORK/thermocharge" \
      TC_ALLOW_FAKE_SYSFS=1 WD_USB_ONLINE="$T/batt/online" WD_STATUS="$T/batt/status" \
      WD_IBAT="$T/batt/current_now" \
      WATCH_START_GRACE=0 WATCH_INTERVAL=1 WATCH_OS_SEC=3 WATCH_HB_SEC=5 \
      "$@" sh "$WD" >/dev/null 2>&1 &
  WD_PID=$!
  sleep 8
  kill "$WD_PID" 2>/dev/null || true
  wait "$WD_PID" 2>/dev/null || true
  WD_PID=
}

legacy_lock() {
  # 用存活且 cmdline 真含旧脚本名的进程，防止仅测到“陈旧锁本就不豁免”。
  printf 'trap "exit 0" TERM\nwhile :; do sleep 0.1; done\n' > "$WORK/identify-thermal-fixture.sh"
  sh "$WORK/identify-thermal-fixture.sh" & IDP=$!
  echo "$IDP" > "$T/data/identify.lock"
}

stop_legacy() {
  kill "$IDP" 2>/dev/null || true
  wait "$IDP" 2>/dev/null || true
  IDP=
}

check() {
  name=$1; want=$2
  got_susp=$(cat "$T/sys/charge_interface/input_suspend")
  got_trem=$(cat "$T/sys/charger_thermal/wired_thermal_remove")
  got_abort=no; [ -f "$T/data/takeover.abort" ] && got_abort=yes
  reason=$(grep -o 'reason=[^ ]*' "$T/data/log/watchdog.log" 2>/dev/null | head -1)
  ok=yes
  [ "$got_abort" = yes ] || ok=no
  [ "$got_susp" = "user all 1" ] || ok=no
  [ "$got_trem" = "0" ] || ok=no
  case "$reason" in *"$want"*) ;; *) ok=no ;; esac
  if [ "$ok" = yes ]; then
    PASS=$((PASS+1)); echo "  PASS  $name  ($reason)"
  else
    FAIL=$((FAIL+1))
    echo "  FAIL  $name  期望含 '$want'"
    echo "        abort=$got_abort susp=[$got_susp] trem=[$got_trem] reason=[$reason]"
  fi
}

echo "1) 温度硬线"
setup; echo "470" > "$T/batt/temp"
printf 'thermal_remove=+2\nthermal_remove=0.0\n' > "$T/data/config.conf"
run_wd; check "temp_over" "temp=470"

echo "2) 心跳超时"
setup
# toybox 的 touch -d 不一定支持 @epoch，用 python 直接改 mtime
python3 -I -c 'import os,sys,time; t=time.time()-100; os.utime(sys.argv[1],(t,t))' \
    "$T/data/heartbeat"
run_wd; check "heartbeat_stale" "heartbeat_stale"

echo "3) 票没落到电流上（实测 9A > 1.5 x 5A）"
setup; echo "-9000000" > "$T/batt/current_now"
run_wd WATCH_HB_SEC=30; check "vote_not_binding" "vote_not_binding"

echo "4) 正常工况不应触发"
setup
run_wd WATCH_HB_SEC=60;
got_abort=no; [ -f "$T/data/takeover.abort" ] && got_abort=yes
if [ "$got_abort" = no ]; then
  PASS=$((PASS+1)); echo "  PASS  no_false_trigger"
else
  FAIL=$((FAIL+1)); echo "  FAIL  no_false_trigger  正常工况被误触发"
  cat "$T/data/log/watchdog.log"
fi

echo "5) 存活旧辨识锁不能豁免心跳超时"
setup; legacy_lock
python3 -I -c 'import os,sys,time; t=time.time()-100; os.utime(sys.argv[1],(t,t))' \
    "$T/data/heartbeat"
run_wd; check "legacy_lock_heartbeat_stale" "heartbeat_stale"
stop_legacy

echo "6) 存活旧辨识锁不能豁免持续过流"
setup; legacy_lock
echo "-9000000" > "$T/batt/current_now"
run_wd WATCH_HB_SEC=60; check "legacy_lock_vote_not_binding" "vote_not_binding"
stop_legacy

echo "7) 存活旧辨识锁不能豁免 daemon 消失"
setup; legacy_lock
# 私有 pidof 夹具避免真机同名进程影响，只影响当前测试的 PATH。
printf '#!%s\nexit 1\n' "$(command -v sh)" > "$WORK/pidof"
chmod 755 "$WORK/pidof"
python3 -I -c 'import os,sys,time; t=time.time()-15; os.utime(sys.argv[1],(t,t))' \
    "$T/data/heartbeat"
run_wd WATCH_HB_SEC=60 PATH="$WORK:$PATH"; check "legacy_lock_daemon_gone" "daemon_gone"
stop_legacy

echo "8) 存活旧辨识锁不能豁免温度硬线"
setup; legacy_lock; echo "470" > "$T/batt/temp"
run_wd; check "legacy_lock_temp_over" "temp=470"
stop_legacy

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
