#!/system/bin/sh
# 恒温充电 ThermoCharge v1.4.0 —— late_start service
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

# 安装/热重载时若是被 SIGKILL 或断电打断，会留下 config.conf.tmp.<pid>。
# 名字带 pid 不会被后续进程复用，不清就慢慢攒；开机顺手收一次。
rm -f "$DATA"/config.conf.tmp.* 2>/dev/null

# 应用内用 setsid 起的进程不会脱离应用的冻结控制组，整组会被冻结而心跳停更。
# 只拒绝"落在某个 App 的叶子组里"（/apps/uid_NNN/pid_NNN），
# 不能拒绝 /apps 本身：KernelSU 开机执行 service.sh 时就在 memory:/apps 根上。

# ---- 单实例 ----
# KernelSU 开机拉起一次，WebUI 的"重启守护进程"也可能再拉起一次。两个
# supervisor 会各自 spawn 一个守护进程，退避和熔断计数还互相打架。
#
# 用 mkdir 的原子性做锁：mksh 的 `exec 9>file` 打开的 fd 带 CLOEXEC，
# 子进程看不到它，`flock -n 9` 会直接报 "Bad file descriptor"（真机实测），
# 而 toybox 的 flock 又没有 -c 选项。mkdir 在所有 shell 下行为一致。
# 锁里记 pid，持有者已经不存在就当作陈旧锁接管。
# 只按 /proc 存在判断不够：上次被 KILL 后留下的 pid，重启时很容易被别的
# 进程复用（开机早期 pid 很稳定），于是这个模块整整一次开机都不启动、
# 还不留日志。锁里记 boot_id + 核对 cmdline 才可靠。
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BOOT_ID" ] || BOOT_ID=unknown

LOCKDIR=$DATA/supervisor.lock.d
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  OLD_SUP=
  OLD_BOOT=
  read -r OLD_SUP OLD_BOOT < "$LOCKDIR/pid" 2>/dev/null
  SUP_ALIVE=0
  if [ -n "$OLD_SUP" ] && [ -d "/proc/$OLD_SUP" ]; then
    case "$OLD_BOOT" in
      ""|"$BOOT_ID")
        case "$(tr '\0' ' ' < "/proc/$OLD_SUP/cmdline" 2>/dev/null)" in
          *service.sh*) SUP_ALIVE=1 ;;
        esac ;;
    esac
  fi
  if [ "$SUP_ALIVE" = "1" ]; then
    exit 0
  fi
  LOCK_STALE=1
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
printf '%s %s\n' "$$" "$BOOT_ID" > "$LOCKDIR/pid"
printf '%s\n' "$$" > "$DATA/supervisor.pid"
trap 'rm -rf "$LOCKDIR"; rm -f "$DATA/supervisor.pid"' EXIT

# /storage 与 zip 都不保留执行位, 这里兜底补一次
chmod 0755 "$BIN" 2>/dev/null
chmod 0755 "$MODDIR"/*.sh 2>/dev/null

LOG_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
log() { printf '%s [%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "${LOG_VERSION:-unknown}" "$*" >> "$LOG"; }

[ "$LOCK_STALE" = "1" ] && log "陈旧 supervisor 锁已接管（pid $OLD_SUP 不是 service.sh）"

# 应用内 setsid 起的进程仍留在该应用的冻结叶子组（/apps/uid_NNN/pid_NNN），
# 整组被冻结就会心跳停更却还显示"运行中"。
# 只拒绝这些叶子组；**不能**拒绝 /apps 根 —— KernelSU 开机执行 service.sh
# 时就在 memory:/apps 上，按"含 apps"一刀切会拦死正常开机（v1.3.16 实测）。
in_app_leaf() {
  grep -Eq ':/apps/uid_[0-9]+(/|$)' "$1" 2>/dev/null
}
CG_FILE=${TC_CGROUP_FILE:-/proc/self/cgroup}
if in_app_leaf "$CG_FILE"; then
  log "拒绝从应用冻结组启动（$(tr '\n' ' ' < "$CG_FILE" 2>/dev/null)），请通过系统启动模块服务"
  exit 1
fi

# 共用受信脚本中的数据解析器；保留进程内已见过的有效节点/投票身份。
export TC_SAFETY_LIBRARY=1
. "$MODDIR/watchdog.sh"
unset TC_SAFETY_LIBRARY
safety_init "$DATA" "$CONF" "$BIN"

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
IDMARK=$DATA/identify.lock     # 仅用于终止升级前遗留的辨识进程，不授予控制权或保护豁免
WD_PID=
# 熔断标记只由人工排查后清除，重启脚本不是解除保护。

cfg_get() {
  # 取最后一处：cfg_load 逐行赋值，重复键以后出现的为准
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null \
    | sed 's/#.*//' | tr -d ' \t\r' | awk 'length { v = $0 } END { print v }'
}

# 直接读取 C 侧配置，避免重复项、溢出和注释的处理分歧。
cfg_num() {
  line=$(TC_CONFIG="$CONF" "$BIN" config-int "$1" 2>/dev/null) || return 1
  printf '%s\n' "${line#*=}"
}

# 字符串配置项：与 cfg_load 一样把空白换成下划线（mca_tag=my tag -> my_tag）。
# 不换的话投票会变成 4 个 token，节点按畸形格式拒写。
cfg_word() { safety_refresh; safety_value "$1" ""; }

# 升级兼容：只认旧锁指向且 argv 完整路径匹配的本模块脚本，避免 PID 复用误杀。
# 这里只用于终止遗留写节点进程，绝不据此等待辨识或豁免 daemon 保护。
identify_owned() {
  case "$1" in ''|*[!0-9]*|0|1) return 1 ;; esac
  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null |
    awk -v path="$MODDIR/tools/identify-thermal.sh" '$0==path {owned=1} END {exit !owned}'
}

start_watchdog() {
  [ -n "$WD_PID" ] && kill -0 "$WD_PID" 2>/dev/null && return 0
  [ -x "$MODDIR/watchdog.sh" ] || { log "WARN: watchdog.sh 缺失, 接管态无兜底"; return 0; }
  # 把投票身份传给看门狗：类型不能在这里硬编码 all，用户可能改过 mca_type
  WD_TAG=$(cfg_word mca_tag);   [ -n "$WD_TAG" ]  || WD_TAG=user
  WD_TYPE=$(cfg_word mca_type); [ -n "$WD_TYPE" ] || WD_TYPE=all
  WD_DIR=$DATA WD_BIN=$BIN WD_TAG=$WD_TAG WD_TYPE=$WD_TYPE sh "$MODDIR/watchdog.sh" &
  WD_PID=$!
  log "watchdog started (pid $WD_PID, thermal_remove=1, tag=$WD_TAG/$WD_TYPE)"
}

stop_watchdog() {
  [ -n "$WD_PID" ] && kill "$WD_PID" 2>/dev/null
  WD_PID=
}

# 接管开关可能在守护进程运行期间被改（WebUI 保存 -> SIGHUP）。守护进程会
# 在下次插电时自己接管，但看门狗只在"spawn 之后"启动过一次，不补这一步
# 就会出现"系统温控已关、外部兜底不存在"。内层循环每 3 秒调一次。
sync_watchdog() {
  # 每轮保存有效组，避免重载后旧节点失去退出保护。
  safety_refresh
  # 不主动杀看门狗：它确认内核已交还温控后会自己退出。
  if [ "$(cfg_num thermal_remove)" != "0" ] || [ "$(safety_get "$SAFE_STATE" effective_thermal_remove)" = 1 ] ||
      [ -n "$taken" ]; then
    start_watchdog
  fi
}

# 接管失败保护：停流 + 交还系统温控。守护进程被 KILL 前可能又覆盖过节点，
# 所以这里再确认一次（input_suspend 是 mca 节点，必须三 token）。
assert_failsafe() {
  safety_assert || log "WARN: 部分安全节点写入失败，保留熔断标记"
}
stop_identify() {
  target=$(cat "$IDMARK" 2>/dev/null)
  identify_owned "$target" || return 0
  kill -TERM "$target" 2>/dev/null
  count=0
  while identify_owned "$target" && [ "$count" -lt 3 ]; do sleep 1; count=$((count+1)); done
  if identify_owned "$target"; then
    kill -KILL "$target" 2>/dev/null
    count=0
    while identify_owned "$target" && [ "$count" -lt 3 ]; do sleep 1; count=$((count+1)); done
  fi
  identify_owned "$target" && return 1
  [ "$(cat "$IDMARK" 2>/dev/null)" != "$target" ] || rm -f "$IDMARK"
  [ ! -f "$ABORT" ] || assert_failsafe
}
protect_abort() {
  # 先阻止旧辨识/daemon 再重投，禁止它们的退出路径撤掉熔断票。
  stop_identify || log "WARN: 遗留辨识进程未退出，保持熔断保护"
  "$BIN" stop >> "$OUT" 2>&1
  if [ -n "${DPID:-}" ]; then kill -KILL "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=; fi
  assert_failsafe
}

# 正常停用可以还原；熔断时不得 restore --force 撤票。
stop_daemon() {
  if ! stop_identify; then
    : > "$ABORT"
    protect_abort
    return
  fi
  if [ -f "$ABORT" ]; then protect_abort; return; fi
  if ! "$BIN" stop >> "$OUT" 2>&1; then
    log "WARN: 守护进程未确认退出，拒绝并发恢复并熔断"
    : > "$ABORT"
    protect_abort
    return
  fi
  if [ -f "$ABORT" ]; then assert_failsafe; return; fi
  "$BIN" restore --force >> "$OUT" 2>&1
  safety_refresh
  safety_return_thermal || log "WARN: 部分温控节点归还失败"
  # 与 watchdog 并发时补偿重投，不能仅依赖调用前检查。
  [ ! -f "$ABORT" ] || assert_failsafe
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
  if [ -f "$ABORT" ]; then
    protect_abort
    stop_watchdog
    log "接管失败保护仍有效，已停止辨识/守护进程并重投停流"
    break
  fi
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    log "模块被停用, 还原后退出"
    stop_daemon
    stop_watchdog
    break
  fi

  # 升级时旧脚本可能仍持有节点；只终止它，不等待标定完成。
  if ! stop_identify; then
    log "WARN: 遗留辨识进程未退出，拒绝并发控制并熔断"
    : > "$ABORT"
    protect_abort
    stop_watchdog
    break
  fi
  [ ! -f "$ABORT" ] || continue
  START=$(cut -d. -f1 /proc/uptime)

  # 先启动外部保护，再启动可能接管系统温控的守护进程。
  sync_watchdog
  [ ! -f "$ABORT" ] || continue
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then continue; fi
  "$BIN" run >> "$OUT" 2>&1 &
  DPID=$!

  stop_cnt=0
  while kill -0 "$DPID" 2>/dev/null; do
    sleep 3
    rotate_out
    if [ -f "$ABORT" ]; then
      log "看门狗已触发接管失败保护，停止守护进程并保留停流票"
      protect_abort
      break
    fi
    sync_watchdog    # 运行期间改 thermal_remove 也要能拉起/停掉看门狗

    # ---- 被外部 STOP 的恢复 ----
    # T 状态持续 30 秒（10 次 × 3 秒）就强制 CONT；旧辨识锁不再授予冻结权。
    # /proc/PID/stat 第 3 字段是进程状态；comm 里没有空格，切分安全。
    if [ "$(cut -d' ' -f3 "/proc/$DPID/stat" 2>/dev/null)" = "T" ]; then
      stop_cnt=$((stop_cnt + 1))
      if [ "$stop_cnt" -ge 10 ]; then
        kill -CONT "$DPID" 2>/dev/null
        stop_cnt=0
        log "守护进程持续处于 STOP，已强制恢复"
      fi
    else
      stop_cnt=0
    fi
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
      log "模块被停用, 通知守护进程退出"
      stop_daemon
      [ -z "$DPID" ] || wait "$DPID" 2>/dev/null
      DPID=""
      break
    fi
  done
  # wait 只在 DPID 还有效时才有意义；abort/停用分支已经把 DPID 清空了，
  # 那时 $? 是上一个 test 的状态，不能当退出码用。
  if [ -n "$DPID" ]; then wait "$DPID" 2>/dev/null; RC=$?; else RC=0; fi
  RAN=$(( $(cut -d. -f1 /proc/uptime) - START ))

  # 熔断优先于 disable 和任何 restore。
  if [ -f "$ABORT" ]; then protect_abort; stop_watchdog; break; fi
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    stop_daemon; stop_watchdog; break
  fi

  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    log "模块被停用, 还原后退出"
    stop_daemon
    stop_watchdog
    break
  fi

  # 接管失败保护已生效: 不再重启、不再走还原(还原会把停流撤销)
  if [ -f "$ABORT" ]; then
    protect_abort
    stop_watchdog
    log "接管失败保护生效, 已停流且不再重启。需人工排查后删除 $ABORT 并重启手机"
    break
  fi

  # 退出码 3 = 配置里 enabled=0，守护进程主动退出，不是崩溃。
  # 不能计入崩溃次数（否则 5 分钟内改几次 enabled 就把熔断器打满，
  # supervisor 永久停手 —— 真机 11-14 23:32 就是这么失联的）。
  if [ "$RC" = "3" ]; then
    log "配置 enabled=0, 守护进程主动退出; 等待改回 1 (每 30s 检查)"
    stop_watchdog
    while [ "$(cfg_num enabled)" = "0" ]; do
      if [ -f "$ABORT" ]; then protect_abort; exit 0; fi
      if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
        stop_daemon
        exit 0
      fi
      sleep 30
    done
    log "enabled 已改回 1, 重新拉起"
    # 兜底：守护进程的判定若再与这里分歧，就会立刻退出 3 再回到这里；至少隔 5 秒，别原地空转
    sleep 5
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

  # 崩溃期间也可能熔断；还原前后都检查并补偿重投。
  if [ -f "$ABORT" ]; then protect_abort; stop_watchdog; break; fi
  "$BIN" restore --force >> "$OUT" 2>&1
  safety_refresh
  safety_return_thermal || log "WARN: 崩溃还原时部分温控节点归还失败"
  if [ -f "$ABORT" ]; then protect_abort; stop_watchdog; break; fi

  N=$(crash_count_recent)
  if [ "$N" -ge 5 ]; then
    [ ! -f "$ABORT" ] || assert_failsafe
    stop_watchdog
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
