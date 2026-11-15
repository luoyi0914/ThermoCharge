#!/system/bin/sh
# ThermoCharge 接管态看门狗
#
# 只在 thermal_remove=1（接管系统 FCC 温控）时才由 service.sh 拉起。
# 接管之后"永远不会比系统原有保护更激进"这条性质就不存在了，本脚本是最后一道闸。
#
# 它不依赖 thermocharge 进程存活，也不读它的日志：
#   - 主程序每次写 state 都会刷新 $D/heartbeat（mtime）
#   - 主程序把当前票值（mA）写入 $D/watchdog.limit
#
# 触发条件（任一成立）：
#   1. 电池温度 >= WATCH_TMAX (46.0℃)
#   2. heartbeat 超过 WATCH_HB_SEC (30s) 未更新   -> 主控卡死
#   3. 实测电流 > 1.5 x 票值，持续 WATCH_OS_SEC   -> 票没落到电流上
#   4. thermocharge 进程不存在（曾有过心跳之后）
#
# 动作：写 $D/takeover.abort（service.sh 见到就停止重启），
#       input_suspend=1（先停流）+ wired_thermal_remove=0（交还系统温控），
#       记日志，然后退出。**不自动重试** —— 出过事就别再闭环了，由人决定。

# 路径可由环境变量覆盖（仅供离机夹具测试，默认即真机路径）
D=${WD_DIR:-/data/adb/thermocharge}
LOG=$D/log/watchdog.log
ABORT=$D/takeover.abort
CF=$D/config.conf
X=${WD_XM:-/sys/class/xm_power/charger}
N_TREM=${WD_TREM:-$X/charger_thermal/wired_thermal_remove}
N_SUSP=${WD_SUSP:-$X/charge_interface/input_suspend}
N_TEMP=${WD_TEMP:-/sys/class/power_supply/battery/temp}
N_IBAT=${WD_IBAT:-/sys/class/power_supply/battery/current_now}
WD_TAG=${WD_TAG:-user}            # 与 config 的 mca_tag 一致

WATCH_TMAX=${WATCH_TMAX:-460}     # 0.1C
WATCH_HB_SEC=${WATCH_HB_SEC:-30}
WATCH_OS_SEC=${WATCH_OS_SEC:-20}
INTERVAL=${WATCH_INTERVAL:-2}

mkdir -p "$D/log"
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

rd() { IFS= read -r v < "$1" 2>/dev/null && echo "$v"; }
wr() { [ -w "$1" ] && printf '%s\n' "$2" > "$1" 2>/dev/null; }

restore_system() {
  # input_suspend 是 mca 节点，内核用 sscanf("%s %s %s") 解析，必须三 token；
  # 写裸 "1" 会被 -EINVAL 静默丢弃（实测：写 0/1 后回读不变）。
  # wired_thermal_remove 是普通整型，直接写数字。
  wr "$N_SUSP" "$WD_TAG all 1"
  wr "$N_TREM" 0
  : > "$ABORT"
  log "RESTORE reason=$1 temp=$(rd "$N_TEMP") ibat=$(rd "$N_IBAT") limit=$(cat "$D/watchdog.limit" 2>/dev/null) suspend=$(rd "$N_SUSP" | tr '\n' ' ')"
}

# 用户把接管关掉了：我们没有保护系统的职责了，安静退出
cfg_thermal_remove() {
  sed -n 's/^[[:space:]]*thermal_remove[[:space:]]*=[[:space:]]*//p' "$CF" 2>/dev/null \
    | head -1 | tr -d ' \t\r'
}

log "watchdog start (pid $$)"

# 启动宽限：等服务起来、等第一条心跳
sleep ${WATCH_START_GRACE:-15}

os_cnt=0
while true; do
  [ "$(cfg_thermal_remove)" = "1" ] || { log "thermal_remove no longer 1, exit"; exit 0; }

  now=$(date +%s)
  t=$(rd "$N_TEMP"); t=${t:-0}
  ibat=$(rd "$N_IBAT"); ibat=${ibat:-0}; ibat=${ibat#-}
  lim=$(cat "$D/watchdog.limit" 2>/dev/null); lim=${lim:-0}
  hb=$(stat -c %Y "$D/heartbeat" 2>/dev/null || echo 0)

  # 1) 温度硬线
  if [ "$t" -ge "$WATCH_TMAX" ]; then
    restore_system "temp=$t>=${WATCH_TMAX}"
    exit 0
  fi

  # 2) 心跳超时（只在曾有过心跳时判定，避免开机误杀）
  if [ "$hb" -gt 0 ] && [ $((now - hb)) -gt "$WATCH_HB_SEC" ]; then
    restore_system "heartbeat_stale=$((now - hb))s"
    exit 0
  fi

  # 3) 票不落电流：连续 N 秒 实测 > 1.5x 票
  # current_now 是 µA，票值是 mA：先换算，否则 5A 会被当成 5000000mA 而永远不触发
  ibat_ma=$((ibat / 1000))
  if [ "$lim" -gt 1000 ] && [ "$ibat_ma" -gt $((lim * 3 / 2)) ]; then
    os_cnt=$((os_cnt + 1))
  else
    os_cnt=0
  fi
  if [ $((os_cnt * INTERVAL)) -ge "$WATCH_OS_SEC" ]; then
    restore_system "vote_not_binding ibat=$ibat limit=$lim"
    exit 0
  fi

  # 4) 主控进程消失
  if ! pidof thermocharge >/dev/null 2>&1 && [ "$hb" -gt 0 ] && [ $((now - hb)) -gt 10 ]; then
    restore_system "daemon_gone"
    exit 0
  fi

  sleep $INTERVAL
done
