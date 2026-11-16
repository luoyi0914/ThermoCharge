#!/system/bin/sh
# 恒温充电 ThermoCharge —— late_start service
# 职责: 等系统起来 -> 拉起守护进程 -> 崩溃退避重启 -> 模块停用时还原
#
# v1.2.0 相对旧版的变化:
#   - 守护进程放后台跑, 主循环每 3 秒检查 disable/remove,
#     这样"守护进程健康运行期间停用模块"能立刻生效(旧版只在 run 返回后才检查)
#   - 退避改为按"最近 5 分钟崩溃次数"判定, 不再只看单次是否活够 60 秒
#     (旧版会把"每 61 秒崩一次"当成稳定, 永久 2 秒震荡)
#   - 崩溃熔断: 5 分钟内崩 5 次就停手并留日志, 不再无限重启
#   - daemon.out 在运行期就地截断轮转, 不会无限增长
#   - 停止统一走 `$BIN stop`(它自己会等进程真退出), 不再用裸 kill

MODDIR=${0%/*}
DATA=${TC_DATA:-/data/adb/thermocharge}
LOG=$DATA/log/supervisor.log
OUT=$DATA/log/daemon.out
BIN=$MODDIR/bin/thermocharge
CONF=$DATA/config.conf

mkdir -p "$DATA/log"

# ---- 单实例 ----
# KernelSU 开机拉起一次，WebUI 的"重启守护进程"也可能再拉起一次。两个
# supervisor 会各自 spawn 一个守护进程，退避和熔断计数还互相打架。
#
# 用 mkdir 的原子性做锁：mksh 的 `exec 9>file` 打开的 fd 带 CLOEXEC，
# 子进程看不到它，`flock -n 9` 会直接报 "Bad file descriptor"（真机实测），
# 而 toybox 的 flock 又没有 -c 选项。mkdir 在所有 shell 下行为一致。
# 锁里记 pid，持有者已经不存在就当作陈旧锁接管。
LOCKDIR=$DATA/supervisor.lock.d
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  OLD_SUP=$(cat "$LOCKDIR/pid" 2>/dev/null)
  if [ -n "$OLD_SUP" ] && [ -d "/proc/$OLD_SUP" ]; then
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
printf '%s\n' "$$" > "$DATA/supervisor.pid"
trap 'rm -rf "$LOCKDIR"; rm -f "$DATA/supervisor.pid"' EXIT

# /storage 与 zip 都不保留执行位, 这里兜底补一次
chmod 0755 "$BIN" 2>/dev/null
chmod 0755 "$MODDIR"/*.sh 2>/dev/null

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 日志轮转: 超过 256KB 就转存一份
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  mv -f "$LOG" "$LOG.old"
fi

# 等开机完成, 最多 120 秒
i=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  i=$((i + 1))
  [ $i -gt 240 ] && break
  sleep 0.5
done

# 再等充电节点就绪 (xm_power 是 vendor 服务创建的)
i=0
while [ ! -w /sys/class/xm_power/charger/charge_interface/ichg_limit ]; do
  i=$((i + 1))
  if [ $i -gt 120 ]; then
    log "WARN: ichg_limit 节点未就绪, 仍尝试启动"
    break
  fi
  sleep 0.5
done

# 配置不存在则用模块内默认值
[ -f "$CONF" ] || cp "$MODDIR/config.conf" "$CONF" 2>/dev/null

log "supervisor start (pid $$)"

# ---- 接管态看门狗 ----
# thermal_remove=1 时系统基于温度的 FCC 降流被交给守护进程，
# "永远不会比系统原有保护更激进"这条性质不复存在，必须由进程外看门狗兜底。
# 看门狗触发后会写 $ABORT 并停充+交还温控；本脚本见到标记就停止重启。
ABORT=$DATA/takeover.abort
WD_PID=
rm -f "$ABORT"      # 开机清掉上一次留下的接管失败标记

cfg_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null \
    | head -1 | tr -d ' \t\r'
}

start_watchdog() {
  [ "$(cfg_get thermal_remove)" = "1" ] || return 0
  [ -n "$WD_PID" ] && kill -0 "$WD_PID" 2>/dev/null && return 0
  [ -x "$MODDIR/watchdog.sh" ] || { log "WARN: watchdog.sh 缺失, 接管态无兜底"; return 0; }
  "$MODDIR/watchdog.sh" &
  WD_PID=$!
  log "watchdog started (pid $WD_PID, thermal_remove=1)"
}

stop_watchdog() {
  [ -n "$WD_PID" ] && kill "$WD_PID" 2>/dev/null
  WD_PID=
}

# 接管失败保护：停流 + 交还系统温控。守护进程被 KILL 前可能又覆盖过节点，
# 所以这里再确认一次（input_suspend 是 mca 节点，必须三 token）。
SUSP=/sys/class/xm_power/charger/charge_interface/input_suspend
TREM=/sys/class/xm_power/charger/charger_thermal/wired_thermal_remove
assert_failsafe() {
  tag=$(cfg_get mca_tag); tag=${tag:-user}
  [ -w "$SUSP" ] && printf '%s all 1' "$tag" > "$SUSP" 2>/dev/null
  [ -w "$TREM" ] && printf '0' > "$TREM" 2>/dev/null
}

# 模块被停用/卸载时: 先让守护进程退出并还原, 别把机器留在被限流的状态
stop_daemon() {
  "$BIN" stop >> "$OUT" 2>&1
  # 守护进程自己的 SIGTERM 已经还原过; 这里再兜一次底(它可能被 kill -9 过)
  "$BIN" restore --force >> "$OUT" 2>&1
}

# 运行期就地截断: 用 >> 打开的文件带 O_APPEND, 截断后写入会落到新 EOF
rotate_out() {
  if [ -f "$OUT" ] && [ "$(wc -c < "$OUT" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    cp -f "$OUT" "$OUT.old" 2>/dev/null
    : > "$OUT"
    log "daemon.out rotated"
  fi
}

# 最近 5 分钟内的崩溃次数。
#
# 记录格式 = "<开机后经过的秒数> <boot_id>"。
# 之前只记 /proc/uptime 秒数：重启后计时归零，上一次开机的几条记录就变成
# "未来时间"，永远落在 now-300 这个窗口里。真机 11-16 11:32 开机时带着
# 6 条陈旧记录，守护进程第一次正常退出就被判成"5 分钟内崩溃 6 次"，
# supervisor 永久停手 —— 用户看到的就是"进程自己停了，得手动重启"。
# 带上 boot_id 后，换一次开机旧记录自然作废；$1 <= now 再挡一次时钟异常。
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BOOT_ID" ] || BOOT_ID=unknown
CRASHLOG=$DATA/log/crash.times

crash_count_recent() {
  NOW=$(cut -d. -f1 /proc/uptime)
  [ -f "$CRASHLOG" ] || { echo 0; return; }
  awk -v now="$NOW" -v boot="$BOOT_ID" \
      '$2 == boot && $1 <= now && $1 > now-300' "$CRASHLOG" 2>/dev/null | wc -l
}

while true; do
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    log "模块被停用, 还原后退出"
    stop_watchdog
    stop_daemon
    break
  fi

  START=$(cut -d. -f1 /proc/uptime)

  # 后台跑, 主循环轮询模块状态
  "$BIN" run >> "$OUT" 2>&1 &
  DPID=$!
  start_watchdog

  while kill -0 "$DPID" 2>/dev/null; do
    sleep 3
    rotate_out
    if [ -f "$ABORT" ]; then
      log "看门狗已触发接管失败保护, 直接杀掉守护进程(不走还原, 免得撤销看门狗的动作)"
      kill -KILL "$DPID" 2>/dev/null
      wait "$DPID" 2>/dev/null
      DPID=""
      break
    fi
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
      log "模块被停用, 通知守护进程退出"
      kill -TERM "$DPID" 2>/dev/null
      wait "$DPID" 2>/dev/null
      DPID=""
      break
    fi
  done
  # wait 只在 DPID 还有效时才有意义；abort/停用分支已经把 DPID 清空了，
  # 那时 $? 是上一个 test 的状态，不能当退出码用。
  if [ -n "$DPID" ]; then wait "$DPID" 2>/dev/null; RC=$?; else RC=0; fi
  RAN=$(( $(cut -d. -f1 /proc/uptime) - START ))

  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    log "模块被停用, 还原后退出"
    stop_watchdog
    stop_daemon
    break
  fi

  # 接管失败保护已生效: 不再重启、不再走还原(还原会把停流撤销)
  if [ -f "$ABORT" ]; then
    stop_watchdog
    assert_failsafe
    log "接管失败保护生效, 已停流且不再重启。需人工排查后删除 $ABORT 并重启手机"
    break
  fi

  # 退出码 3 = 配置里 enabled=0，守护进程主动退出，不是崩溃。
  # 不能计入崩溃次数（否则 5 分钟内改几次 enabled 就把熔断器打满，
  # supervisor 永久停手 —— 真机 11-14 23:32 就是这么失联的）。
  if [ "$RC" = "3" ]; then
    log "配置 enabled=0, 守护进程主动退出; 等待改回 1 (每 30s 检查)"
    stop_watchdog
    while [ "$(cfg_get enabled)" = "0" ]; do
      if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
        stop_daemon
        exit 0
      fi
      sleep 30
    done
    log "enabled 已改回 1, 重新拉起"
    continue
  fi

  # 干净退出：rc=0 且至少跑满 60 秒。
  # 这种是"用户点了重启守护进程"或外部 `thermocharge stop`，不是崩溃。
  # 之前 WebUI 的重启就是先 stop 再自起一个野进程，这条被当成一次崩溃，
  # 叠加上面的陈旧记录，一次重启就能把熔断器打满。
  if [ "$RC" = "0" ] && [ "$RAN" -ge 60 ]; then
    log "daemon clean exit after ${RAN}s, restart in 2s (not counted as crash)"
    sleep 2
    rotate_out
    continue
  fi

  log "daemon exit rc=$RC after ${RAN}s"
  echo "$(cut -d. -f1 /proc/uptime) $BOOT_ID" >> "$CRASHLOG"
  # 只保留本次开机、最近 5 分钟的记录，防止长期崩溃时文件无界增长
  NOW_T=$(cut -d. -f1 /proc/uptime)
  awk -v now="$NOW_T" -v boot="$BOOT_ID" \
      '$2 == boot && $1 <= now && $1 > now-300' "$CRASHLOG" > "$CRASHLOG.tmp" 2>/dev/null \
    && mv -f "$CRASHLOG.tmp" "$CRASHLOG"

  # 崩溃后先还原, 别把系统留在被限流的状态
  "$BIN" restore --force >> "$OUT" 2>&1

  N=$(crash_count_recent)
  if [ "$N" -ge 5 ]; then
    log "熔断: 5 分钟内崩溃 ${N} 次, 停止重启(已还原). 排查后重启手机或手动启动"
    break
  fi

  # 退避: 崩溃频率越高退避越久
  case $N in
    0|1) BACKOFF=2 ;;
    2)   BACKOFF=8 ;;
    3)   BACKOFF=20 ;;
    *)   BACKOFF=45 ;;
  esac
  log "restart in ${BACKOFF}s (5min crash count=$N)"
  sleep $BACKOFF
  rotate_out
done
