#!/system/bin/sh
# 充电期"谁在限流"追踪
#
# 守护进程只记自己投的上限（limit_ma），系统的投票只在 ichg_limit 节点里——
# 那是一个 mca votable 的聚合结果，形如：
#     buck eff_client:volt_thermal_limit 3000
#     buck eff_client:user 12000
# 最后一段就是当前生效的**最小值**，标签说明是谁投的。
#
# 本脚本等插电后每 2 秒记一行，拔电退出。用来回答：
#   "功率上不去时，到底是我们压的，还是系统压的？"
#
# 用法:  sh charge-trace.sh [输出路径] [最长小时数]
#        默认 /sdcard/cccodroid/charge-trace.csv，最长 8 小时

OUT=${1:-/sdcard/cccodroid/charge-trace.csv}
MAXH=${2:-8}
S=/sys/class/power_supply
X=/sys/class/xm_power/charger

CT=""
for z in /sys/class/thermal/thermal_zone*; do
    if [ "$(cat "$z/type" 2>/dev/null)" = "charger_therm" ]; then CT=$z; break; fi
done

rd()  { cat "$1" 2>/dev/null; }
# mca 节点是多行的，压成一行并去掉逗号，免得破坏 CSV
flat() { tr '\n' '|' < "$1" 2>/dev/null | tr -d ','; }

# 单实例：setsid 在 su 下可能多 fork 一个，重复实例会把同一行写两遍
PIDF=/sdcard/cccodroid/.charge-trace.pid
if [ -f "$PIDF" ]; then
    old=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        echo "已有实例在跑 (pid $old)，退出" >&2
        exit 0
    fi
fi
echo $$ > "$PIDF"
trap 'rm -f "$PIDF"' EXIT INT TERM

WAIT_MAX=$((MAXH * 3600 / 5))
n=0
while [ "$(rd $S/usb/online)" != "1" ]; do
    sleep 5
    n=$((n + 1))
    [ $n -gt $WAIT_MAX ] && { echo "等待插电超时，退出" >&2; exit 0; }
done

echo "epoch,temp_c,soc,cur_ua,volt_uv,ichg_limit,wired_chg_curr,charger_therm,usb_online,smart_chg" > "$OUT"

n=0
while [ "$(rd $S/usb/online)" = "1" ] && [ $n -le $WAIT_MAX ]; do
    echo "$(date +%s),$(rd $S/battery/temp),$(rd $S/battery/capacity),$(rd $S/battery/current_now),$(rd $S/battery/voltage_now),\"$(flat $X/charge_interface/ichg_limit)\",$(rd $X/charger_thermal/wired_chg_curr),$(rd $CT/temp),$(rd $S/usb/online),$(rd $X/smart_charge/smart_chg)" >> "$OUT"
    n=$((n + 1))
    sleep 2
done

echo "充电结束，记录 $n 行 -> $OUT" >&2
