#!/system/bin/sh
# ThermoCharge v1.4.0 接管态看门狗：停流、交还系统温控、熔断，不自动重试。
# safety_* 也供 supervisor / uninstall 使用；只加载受信脚本，不执行配置或 state。
safety_get() {
  printf '%s\n' "$1" | awk -v key="$2" 'index($0,key "=")==1 {v=substr($0,length(key)+2)} END {print v}'
}
safety_path() {
  [ "${#1}" -lt 256 ] || return 1
  case "$1" in *'|'*|*'
'*|*'	'*|*'/../'*|*'/..') return 1 ;; esac
  case "$1" in /sys/*) return 0 ;; esac
  [ -n "${TC_ALLOW_FAKE_SYSFS:-}" ] && case "$1" in /*) return 0 ;; esac
  return 1
}
safety_word() {
  # cfg_load 先截到 31 字节，再逐个空格/tab 换下划线；不能删除或压缩空白。
  printf '%s' "$1" | LC_ALL=C cut -b 1-31 | tr ' \t' '__'
}
safety_cfg() {
  value=$(safety_get "$SAFE_CONFIG" "$1")
  if [ -z "$value" ]; then
    value=$(awk -v key="$1" -v fake="${TC_ALLOW_FAKE_SYSFS:-}" '
      { sub(/#.*/, ""); eq=index($0,"="); if (!eq) next;
        k=substr($0,1,eq-1); v=substr($0,eq+1);
        gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", k); gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", v);
        if (k!=key) next;
        if (key=="ctl_mode" && v !~ /^[+-]?[0-9]+$/) next;
        if (key ~ /^p_/ && (length(v)>=256 || v ~ /\/\.\.(\/|$)/ || v ~ /[|\t]/ ||
            !(v ~ /^\/sys\// || (fake!="" && v ~ /^\//)))) next;
        out=v }
      END {print out}' <<EOF
$SAFE_RAW_CONFIG
EOF
)
    case "$1" in mca_tag|mca_type) value=$(safety_word "$value") ;; esac
  fi
  printf '%s\n' "${value:-$2}"
}
safety_value() {
  value=$(safety_cfg "$1" "$2")
  # 显式假节点覆盖不能被新二进制导出的 /sys 默认值吞掉；有效 state 仍优先。
  if [ -n "${TC_ALLOW_FAKE_SYSFS:-}" ]; then
    case "$1" in
      p_suspend) value=${WD_SUSP:-$value} ;;
      p_thermal_remove)
        if [ -n "${WD_TREM:-}" ]; then value=$WD_TREM
        elif [ -n "${WD_XM:-}" ]; then value=$SAFE_X/charger_thermal/wired_thermal_remove
        fi ;;
      p_temp) value=${WD_TEMP:-$value} ;;
      p_current) value=${WD_IBAT:-$value} ;;
      p_usb_online) value=${WD_USB_ONLINE:-$value} ;;
      p_status) value=${WD_STATUS:-$value} ;;
      p_ctl) value=${WD_CTL:-$value} ;;
      p_ichg) value=${WD_ICHG:-$value} ;;
    esac
    if [ "$1" = p_suspend ] && [ -z "${WD_SUSP:-}" ] && [ -n "${WD_XM:-}" ]; then
      value=$SAFE_X/charge_interface/input_suspend
    fi
  fi
  if [ "$SAFE_SOURCE" = state ]; then
    effective=$(safety_get "$SAFE_STATE" "effective_$1")
    if [ -n "$effective" ]; then
      case "$1" in
        p_*) if safety_path "$effective"; then value=$effective; fi ;;
        *) value=$effective ;;
      esac
    fi
  fi
  case "$1" in
    p_*) safety_path "$value" || value=$2 ;;
    mca_*) value=$(safety_word "$value"); case "$value" in *'|'*|*'
'*) value=$2 ;; esac ;;
  esac
  printf '%s\n' "$value"
}
safety_group() {
  G_TAG=$(safety_value mca_tag "${WD_TAG:-user}")
  G_TYPE=$(safety_value mca_type "${WD_TYPE:-all}")
  G_SUSP=$(safety_value p_suspend "${WD_SUSP:-$SAFE_X/charge_interface/input_suspend}")
  G_TREM=$(safety_value p_thermal_remove "${WD_TREM:-$SAFE_X/charger_thermal/wired_thermal_remove}")
  G_TEMP=$(safety_value p_temp "${WD_TEMP:-/sys/class/power_supply/battery/temp}")
  G_IBAT=$(safety_value p_current "${WD_IBAT:-/sys/class/power_supply/battery/current_now}")
  G_USB=$(safety_value p_usb_online "${WD_USB_ONLINE:-/sys/class/power_supply/usb/online}")
  G_STATUS=$(safety_value p_status "${WD_STATUS:-/sys/class/power_supply/battery/status}")
  G_CTL=$(safety_value p_ctl "${WD_CTL:-$SAFE_X/charger_thermal/wired_chg_curr}")
  G_ICHG=$(safety_value p_ichg "${WD_ICHG:-$SAFE_X/charge_interface/ichg_limit}")
  group="$G_TAG|$G_TYPE|$G_SUSP|$G_TREM|$G_TEMP|$G_IBAT|$G_USB|$G_STATUS|$G_CTL|$G_ICHG"
  if ! printf '%s\n' "$SAFE_GROUPS" | grep -Fxq -- "$group"; then
    SAFE_GROUPS="${SAFE_GROUPS:+$SAFE_GROUPS
}$group"
  fi
}
safety_refresh() {
  # 每个快照只打开一次，避免原子 rename 后读到混合组。未知 config-str 可退回旧配置。
  SAFE_STATE=$(cat "$SAFE_D/state" 2>/dev/null)
  SAFE_RAW_CONFIG=$(cat "$SAFE_CF" 2>/dev/null)
  SAFE_CONFIG=$(TC_DATA="$SAFE_D" TC_CONFIG="$SAFE_CF" "$SAFE_BIN" config-str \
    mca_tag mca_type p_suspend p_thermal_remove p_temp p_current p_usb_online p_status p_ctl p_ichg 2>/dev/null) || SAFE_CONFIG=
  SAFE_SOURCE=config; safety_group
  SAFE_SOURCE=state; safety_group
  if printf '%s\n' "$SAFE_STATE" | grep -q '^thermal_taken_path='; then
    taken=$(safety_get "$SAFE_STATE" thermal_taken_path)
  else
    taken=$(safety_get "$SAFE_STATE" effective_thermal_taken_path)
  fi
  if [ -n "$taken" ] && safety_path "$taken"; then
    group="$G_TAG|$G_TYPE|$G_SUSP|$taken|$G_TEMP|$G_IBAT|$G_USB|$G_STATUS|$G_CTL|$G_ICHG"
    if ! printf '%s\n' "$SAFE_GROUPS" | grep -Fxq -- "$group"; then
      SAFE_GROUPS="$SAFE_GROUPS
$group"
    fi
  fi
}
safety_init() {
  SAFE_D=$1; SAFE_CF=$2; SAFE_BIN=$3
  SAFE_X=${WD_XM:-/sys/class/xm_power/charger}
  SAFE_GROUPS=
  safety_refresh
}
safety_wr() {
  [ -w "$1" ] || return 1
  printf '%s\n' "$2" > "$1" 2>/dev/null
}
safety_assert() {
  safety_refresh
  # 历史有效组 + 当前配置组都重投，覆盖重载/退出期间的节点与身份切换。
  printf '%s\n' "$SAFE_GROUPS" | (
    failed=0
    while IFS='|' read -r tag typ susp trem _rest; do
      safety_wr "$susp" "$tag $typ 1" || failed=1
      safety_wr "$trem" 0 || failed=1
    done
    exit "$failed"
  )
}
safety_return_thermal() {
  printf '%s\n' "$SAFE_GROUPS" | (
    failed=0
    while IFS='|' read -r _tag _typ _susp trem _rest; do
      safety_wr "$trem" 0 || failed=1
    done
    exit "$failed"
  )
}
safety_charging() {
  # 与 C is_charging 一致：USB online > 0 或 battery status 含 Charging/Full。
  online=$(tr -d '\r\n' < "$1" 2>/dev/null)
  if printf '%s\n' "$online" | awk 'match($0,/^[ \t]*[+-]?[0-9]+/) {exit !(substr($0,RSTART,RLENGTH)+0>0)} END {if (!RSTART) exit 1}'; then return 0; fi
  case "$(cat "$2" 2>/dev/null)" in *Charging*|*Full*) return 0 ;; esac
  return 1
}
# 库模式在任何节点/目录写入前返回，仅由相邻受信脚本显式加载。
[ "${TC_SAFETY_LIBRARY:-0}" = 1 ] && return 0

D=${WD_DIR:-${TC_DATA:-/data/adb/thermocharge}}
LOG=$D/log/watchdog.log
ABORT=$D/takeover.abort
CF=$D/config.conf
BIN=${WD_BIN:-${0%/*}/bin/thermocharge}
WATCH_TMAX=${WATCH_TMAX:-460}
WATCH_HB_SEC=${WATCH_HB_SEC:-30}
WATCH_OS_SEC=${WATCH_OS_SEC:-20}
INTERVAL=${WATCH_INTERVAL:-2}
mkdir -p "$D/log"
LOG_VERSION=$(sed -n 's/^version=//p' "$(dirname "$0")/module.prop" 2>/dev/null)
log() { printf '%s [%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "${LOG_VERSION:-unknown}" "$*" >> "$LOG"; }
rd() { tr -d '\n\r' < "$1" 2>/dev/null; }
restore_system() {
  # 先发布熔断，阻止其他退出清理路径解除停流，再幂等重投。
  : > "$ABORT"
  safety_assert || log "WARN: safety write incomplete; abort retained"
  log "RESTORE reason=$1 temp=$(rd "$G_TEMP") ibat=$(rd "$G_IBAT") limit=$(cat "$D/watchdog.limit" 2>/dev/null) suspend=$(rd "$G_SUSP")"
}
safety_init "$D" "$CF" "$BIN"
log "watchdog start (pid $$)"
sleep "${WATCH_START_GRACE:-15}"
os_cnt=0
while true; do
  safety_refresh
  if [ -f "$ABORT" ]; then safety_assert; exit 0; fi
  # 只有所有已知接管节点均归还且配置明确关闭才退出。
  if [ "$(TC_DATA="$D" TC_CONFIG="$CF" "$BIN" config-int thermal_remove 2>/dev/null)" = "thermal_remove=0" ] &&
      ! printf '%s\n' "$SAFE_GROUPS" | while IFS='|' read -r tag typ susp trem rest; do
        [ "$(rd "$trem")" = 0 ] || { printf 'active\n'; break; }
      done | grep -q active; then
    log "thermal override off, exit"; exit 0
  fi
  now=$(date +%s)
  hb=$(stat -c %Y "$D/heartbeat" 2>/dev/null || printf 0)
  lim=$(cat "$D/watchdog.limit" 2>/dev/null); case "$lim" in ''|*[!0-9]*) lim=0 ;; esac
  # 历史组的温度硬线也不豁免；状态与当前配置任一高温都先停流。
  hot=$(printf '%s\n' "$SAFE_GROUPS" | while IFS='|' read -r tag typ susp trem temp rest; do
    t=$(rd "$temp"); case "$t" in ''|*[!0-9-]*) continue ;; esac
    if [ "$t" -ge "$WATCH_TMAX" ]; then printf '%s\n' "$t"; break; fi
  done)
  if [ -n "$hot" ]; then restore_system "temp=$hot>=${WATCH_TMAX}"; exit 0; fi
  if [ "$hb" -gt 0 ] && [ $((now - hb)) -gt "$WATCH_HB_SEC" ]; then
    restore_system "heartbeat_stale=$((now - hb))s"; exit 0
  fi
  ibat=$(rd "$G_IBAT"); ibat=${ibat#-}; case "$ibat" in ''|*[!0-9]*) ibat=0 ;; esac
  ibat_ma=$((ibat / 1000)); thr=$((lim * 3 / 2)); [ "$thr" -ge 2000 ] || thr=2000
  # 拔电/放电不能用旧 limit 判断票失效；也必须清掉累计时间。
  active_charging=0
  safety_charging "$G_USB" "$G_STATUS" && active_charging=1
  if [ "$active_charging" = 1 ] && [ "$lim" -gt 0 ] && [ "$ibat_ma" -gt "$thr" ]; then
    os_cnt=$((os_cnt + 1))
  else
    os_cnt=0
  fi
  if [ $((os_cnt * INTERVAL)) -ge "$WATCH_OS_SEC" ]; then
    restore_system "vote_not_binding ibat=$ibat limit=$lim"; exit 0
  fi
  if ! pidof thermocharge >/dev/null 2>&1 && [ "$hb" -gt 0 ] && [ $((now - hb)) -gt 10 ]; then
    restore_system daemon_gone; exit 0
  fi
  sleep "$INTERVAL"
done
