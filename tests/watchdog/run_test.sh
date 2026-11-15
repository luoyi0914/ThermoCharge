#!/usr/bin/env sh
# 看门狗夹具测试：不需要 root，不碰真机节点
#
# 用 ../module/watchdog.sh 自带的 WD_* 覆盖把节点指到临时文件里，
# 逐个验证四种触发条件是否都会执行「停流 + 交还温控 + 写 ABORT」。

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WD=$ROOT/module/watchdog.sh
T=${TMPDIR:-/tmp}/wd-test
PASS=0
FAIL=0

[ -f "$WD" ] || { echo "找不到 $WD" >&2; exit 1; }

setup() {
  rm -rf "$T"
  mkdir -p "$T/sys/charge_interface" "$T/sys/charger_thermal" "$T/data/log" "$T/batt"
  echo "thermal_remove=1" > "$T/data/config.conf"
  : > "$T/sys/charge_interface/input_suspend"
  : > "$T/sys/charger_thermal/wired_thermal_remove"
  echo "350" > "$T/batt/temp"
  echo "-1000000" > "$T/batt/current_now"
  echo "5000" > "$T/data/watchdog.limit"
  # 心跳：默认给一个"刚刚"的时间戳
  echo 1 > "$T/data/heartbeat"
}

# run_wd <额外环境...> —— 跑 8 秒（够所有条件在测试尺度内触发）
# 注意用 sh 调起：仓库在 /storage 上，那里不能直接 exec 脚本
run_wd() {
  env WD_DIR="$T/data" WD_XM="$T/sys" WD_TEMP="$T/batt/temp" \
      WD_IBAT="$T/batt/current_now" \
      WATCH_START_GRACE=0 WATCH_INTERVAL=1 WATCH_OS_SEC=3 WATCH_HB_SEC=5 \
      "$@" sh "$WD" >/dev/null 2>&1 &
  WD_PID=$!
  sleep 8
  kill "$WD_PID" 2>/dev/null || true
  wait "$WD_PID" 2>/dev/null || true
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
run_wd; check "temp_over" "temp=470"

echo "2) 心跳超时"
setup
# toybox 的 touch -d 不一定支持 @epoch，用 python 直接改 mtime
python3 -c 'import os,sys,time; t=time.time()-100; os.utime(sys.argv[1],(t,t))' \
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

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
