#!/usr/bin/env sh
# ThermoCharge 假 sysfs 闭环台架 —— 运行器
#
# 在没有 root 的机器上跑完整的"感知 -> PID -> 投票 -> 电池温度变化"闭环:
#   - 守护进程的 p_* 全部指向台架造的普通文件 (TC_ALLOW_FAKE_SYSFS=1)
#   - 数据目录重定向到临时目录 (TC_DATA)，不碰 /data/adb
#   - 台架进程按 Min 聚合 + 一阶热模型回写温度
#
# 用法:
#   sh tests/sim/run_sim.sh                          # 默认 120 秒、环境 25℃
#   sh tests/sim/run_sim.sh --ambient 34 --duration 90
#   sh tests/sim/run_sim.sh --unit-eff 0.85          # 系统只肯给 85%
#
# 需要先有 out/thermocharge (sh build.sh)。台架目录默认在 $TMPDIR/tc-sim，
# 因为 /storage 不能执行程序，二进制必须拷到可执行的位置再跑。

set -e

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN_SRC=$ROOT/out/thermocharge
WORK=${WORK:-${TMPDIR:-/tmp}/tc-sim}

[ -f "$BIN_SRC" ] || { echo "错误: 没有 $BIN_SRC，先跑 sh build.sh" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/sys" "$WORK/data/log"
cp "$BIN_SRC" "$WORK/bin/thermocharge"
chmod 0755 "$WORK/bin/thermocharge"

SYS=$WORK/sys
DATA=$WORK/data

# ---- 积分增益 ----
# 台架默认把热时间常数 τ 缩到 20s（真机大约 300s），3 分钟就能看到收敛。
# 但**不要**试图从台架的 ki 反推真机参数：台架对象的直流增益（℃/mA）和真机
# 差一个数量级，同一套 ki 在两边的相位裕度完全不同。实测真机默认 ki=600 在
# 本台架上会跑成极限环，那是台架灵敏度过高造成的假象，不是控制律的 bug。
# 所以这里的 ki 是**按台架对象标定**的一个独立参数，默认 40（τ=20s 时裕度约
# 45°）；换 τ 之后请重新标一次。
KI=40
PLANT_ARGS=
prev=
skip=0
for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
        --ki)   skip=1 ;;          # 台架自己的参数，不转给 plant.py
        --ki=*) KI=${a#--ki=} ;;
        *)      PLANT_ARGS="$PLANT_ARGS $a" ;;
    esac
done

# ---- 台架配置：p_* 指向假 sysfs ----
cat > "$DATA/config.conf" <<EOF
# 闭环台架配置（自动生成，勿手改）
enabled=1
dry_run=0
target_temp=42
hard_temp=45
deadband=0.2
ki=$KI
kd=40
tdot_tau_s=8
max_ma=20000
min_ma=500
startup_ma=2000
slew_ma_s=15000
sample_ms=200
fast_write_ms=200
log_interval_ms=1000
startup_grace_ms=0
reassert_ms=2000
ctl_mode=2
pred_enable=0
soft_landing=0
p_temp=$SYS/battery/temp
p_voltage=$SYS/battery/voltage_now
p_current=$SYS/battery/current_now
p_status=$SYS/battery/status
p_capacity=$SYS/battery/capacity
p_usb_online=$SYS/usb/online
p_ichg=$SYS/charger/charge_interface/ichg_limit
p_ctl=$SYS/charger/charger_thermal/wired_chg_curr
p_suspend=$SYS/charger/charge_interface/input_suspend
p_thermal_remove=$SYS/charger/charger_thermal/wired_thermal_remove
p_stop_handle=$SYS/charger/charger_common/stop_handle_charge
EOF
mkdir -p "$SYS/charger/charger_common"
: > "$SYS/charger/charger_common/stop_handle_charge"

echo "台架目录: $WORK"

# ---- 先起台架（它负责初始化假 sysfs）----
# shellcheck disable=SC2086  # PLANT_ARGS 需要按空格拆成多个参数
python3 "$ROOT/tests/sim/plant.py" --root "$SYS" --trace "$WORK/plant.csv" $PLANT_ARGS &
PLANT=$!
trap 'kill $PLANT 2>/dev/null; kill $DAEMON 2>/dev/null' EXIT INT TERM
sleep 0.5

# ---- 起守护进程 ----
echo "--- 启动守护进程 ---"
TC_DATA=$DATA TC_CONFIG=$DATA/config.conf TC_ALLOW_FAKE_SYSFS=1 \
    "$WORK/bin/thermocharge" run > "$WORK/daemon.out" 2>&1 &
DAEMON=$!

# 等台架跑完（它按 --duration 自己退出）
wait $PLANT 2>/dev/null || true
trap 'kill $DAEMON 2>/dev/null' EXIT INT TERM

# ---- 收尾：让守护进程走正常退出路径（它会还原）----
TC_DATA=$DATA "$WORK/bin/thermocharge" stop > /dev/null 2>&1 || true
wait $DAEMON 2>/dev/null || true
trap - EXIT INT TERM

# ---- 结果 ----
echo
echo "--- curve.csv 尾段 ---"
if [ -f "$DATA/log/curve.csv" ]; then
    head -1 "$DATA/log/curve.csv"
    tail -8 "$DATA/log/curve.csv"
else
    echo "(没有 curve.csv)"
fi

echo
echo "--- daemon.log 尾段 ---"
tail -12 "$DATA/log/daemon.log" 2>/dev/null || echo "(没有 daemon.log)"

echo
echo "产物: $DATA/log/curve.csv  $WORK/plant.csv"
