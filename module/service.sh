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
DATA=/data/adb/thermocharge
LOG=$DATA/log/supervisor.log
OUT=$DATA/log/daemon.out
BIN=$MODDIR/bin/thermocharge
CONF=$DATA/config.conf

mkdir -p "$DATA/log"

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

# 最近 5 分钟内的崩溃时间戳(用 /proc/uptime 秒数记录)
CRASHLOG=$DATA/log/crash.times

crash_count_recent() {
  NOW=$(cut -d. -f1 /proc/uptime)
  [ -f "$CRASHLOG" ] || { echo 0; return; }
  awk -v now="$NOW" '$1 > now-300' "$CRASHLOG" 2>/dev/null | wc -l
}

while true; do
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    log "模块被停用, 还原后退出"
    stop_daemon
    break
  fi

  START=$(cut -d. -f1 /proc/uptime)

  # 后台跑, 主循环轮询模块状态
  "$BIN" run >> "$OUT" 2>&1 &
  DPID=$!

  while kill -0 "$DPID" 2>/dev/null; do
    sleep 3
    rotate_out
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
      log "模块被停用, 通知守护进程退出"
      kill -TERM "$DPID" 2>/dev/null
      wait "$DPID" 2>/dev/null
      DPID=""
      break
    fi
  done
  [ -n "$DPID" ] && wait "$DPID" 2>/dev/null
  RC=$?
  RAN=$(( $(cut -d. -f1 /proc/uptime) - START ))

  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    log "模块被停用, 还原后退出"
    stop_daemon
    break
  fi

  log "daemon exit rc=$RC after ${RAN}s"
  echo "$(cut -d. -f1 /proc/uptime)" >> "$CRASHLOG"
  # 只保留最近 5 分钟的记录，防止长期崩溃时文件无界增长
  NOW_T=$(cut -d. -f1 /proc/uptime)
  awk -v now="$NOW_T" '$1 > now-300' "$CRASHLOG" > "$CRASHLOG.tmp" 2>/dev/null \
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
