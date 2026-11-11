#!/system/bin/sh
# probe-actuator.sh —— 执行器判别实验（充电中进行，约 40 秒，只改一个变量 mca_tag）
#
# 目的：回答"我们投的限流票到底有没有被驱动接受"。
# 做法：把投票标签从 user 换成 thermo（避开系统同名票），保持其他一切不变，
#       读 ichg_limit 的回读内容，看是否出现 "eff_client:thermo"。
# 判定：
#   出现 eff_client:thermo 且 effective 值 == 我们的值 -> 票被接受且成为赢家
#   出现 eff_client:thermo 但 effective 更小          -> 票被接受，但被更严格的票压住（正常）
#   完全不出现 thermo                                  -> 写入没生效（标签/格式/通道问题）
# 结束自动还原 mca_tag=user。
#
# 用法：sh probe-actuator.sh [观察秒数，默认 40]

set -u
TC=/data/adb/modules/thermocharge/bin/thermocharge
D=/data/adb/thermocharge
ICHG=/sys/class/xm_power/charger/charge_interface/ichg_limit
QC=/sys/class/xm_power/charger/quick_charge
PUMP=/sys/class/xm_power/charger/chargerpump
BAT=/sys/class/power_supply/battery
SECS=${1:-40}
OUT=$D/log/actuator-probe-$(date +%Y%m%d-%H%M%S).log

log() { echo "$@" | tee -a "$OUT"; }
rd()  { cat "$1" 2>/dev/null | tr -d '\n'; }

charging() {
  local u s
  u=$(rd /sys/class/power_supply/usb/online)
  s=$(rd $BAT/status)
  [ "$u" = "1" ] || [ "$s" = "Charging" ] || [ "$s" = "Full" ]
}

snapshot() {
  local t i v soc st
  t=$(rd $BAT/temp); i=$(rd $BAT/current_now); v=$(rd $BAT/voltage_now); soc=$(rd $BAT/capacity)
  st=$(grep '^state=' $D/state 2>/dev/null | cut -d= -f2)
  log "  T=$((t/10)).$((t%10))C I=$(awk -v i="$i" 'BEGIN{printf "%.2f", (i<0?-i:i)/1e6}')A soc=${soc}% state=${st:-?}"
  log "  ichg_limit: $(rd $ICHG)"
  log "  stage=$(rd $QC/charging_stage) cp_mode='$(rd $PUMP/cp_mode)' ibus=$(rd $PUMP/ibus_total) div1=$(rd $QC/current_limit/div1_s) power_max=$(rd $QC/power_max)"
}

if ! charging; then
  echo "未在充电：这个实验必须在充电中做。插上线再跑。" ; exit 2
fi

log "=== actuator probe $(date -Is) ==="
log "[0] 实验前基线（tag=user）"
snapshot

restore() {
  $TC set mca_tag user >/dev/null 2>&1
  log "[end] mca_tag 已还原为 user"
}
trap restore EXIT INT TERM

log "[1] set mca_tag thermo（唯一变量）"
$TC set mca_tag thermo
sleep 6

log "[2] 观察 ${SECS}s：等系统重投 + 我们的票登记"
i=0
while [ $i -lt $SECS ]; do
  sleep 5; i=$((i+5))
  snapshot
done

log "[3] 汇总"
N=$(grep -c 'eff_client:thermo' "$OUT" 2>/dev/null || echo 0)
log "  thermo 票在回读中出现次数：$N"
if [ "$N" -gt 0 ]; then
  log "  结论：票能被驱动接受（通道/标签都没问题）"
else
  log "  结论：thermo 从未出现 -> 写入没生效；下一变量建议 mca_type=quick 再测一次"
fi
log "  原始记录：$OUT"
