#!/system/bin/sh
# identify-thermal.sh —— 开环阶跃辨识 α（热阻系数）与 τ（热时间常数）
#
# 为什么必须开环：闭环数据里电流被控制器锁在 9.7A 附近，只有一个工况点，
# 拟合不出 T∞=Tamb+αI²。这里把守护进程 SIGSTOP 冻结（不是杀掉，进程还在，
# 看门狗不会拉起第二个实例），由本脚本自己持有限流通道，做 6A→10A→12A
# 三段、每段 180 秒的阶跃，采样温度。
#
# 安全：全程前台上限保护——温度 ≥ 45.5℃ 立即 input_suspend=1 并中止；
#       任何退出路径都会 CONT 守护进程、把限流还原成"无约束票"、解除挂起。
#
# 用法：sh identify-thermal.sh confirm   （必须带 confirm，且必须在充电中）
# 输出：/data/adb/thermocharge/log/ident-<ts>.csv + 终端给出建议配置

set -u
[ "${1:-}" = "confirm" ] || { echo "用法: sh identify-thermal.sh confirm  （要在充电中跑）"; exit 2; }

TC=/data/adb/modules/thermocharge/bin/thermocharge
D=/data/adb/thermocharge
ICHG=/sys/class/xm_power/charger/charge_interface/ichg_limit
SUSP=/sys/class/xm_power/charger/charge_interface/input_suspend
BAT=/sys/class/power_supply/battery
TS=$(date +%Y%m%d-%H%M%S)
CSV=$D/log/ident-$TS.csv
HARD_X10=455
PID=$(cat $D/daemon.pid 2>/dev/null)
rd() { cat "$1" 2>/dev/null | tr -d '\n'; }

charging() { [ "$(rd /sys/class/power_supply/usb/online)" = "1" ]; }
charging || { echo "未在充电，退出。"; exit 2; }
[ -n "${PID:-}" ] || { echo "找不到守护进程 pid，退出。"; exit 2; }

vote() { printf 'thermo all %s\n' "$1" > $ICHG; }      # mA
suspend() { printf 'thermo all %s\n' "$1" > $SUSP; }

cleanup() {
  suspend 0 >/dev/null 2>&1
  vote 20500 >/dev/null 2>&1        # 投"无约束"票，让系统保护重新当家
  kill -CONT "$PID" 2>/dev/null
  echo "[cleanup] daemon CONT, 限流票已交还" | tee -a "$CSV"
}
trap cleanup EXIT INT TERM

echo "epoch,level_ma,step_s,temp_c,current_a,soc" > "$CSV"
echo "=== 开环辨识开始 $(date "+%Y-%m-%dT%H:%M:%S") ==="
kill -STOP "$PID"                   # 冻结守护进程：它不再覆写我们投的票
sleep 1
suspend 0

sample() {  # $1=level $2=step_s
  local t i s
  t=$(rd $BAT/temp); i=$(rd $BAT/current_now); s=$(rd $BAT/capacity)
  [ -z "$t" ] && return
  printf '%s,%s,%s,%s.%s,%.2f,%s\n' "$(date +%s)" "$1" "$2" \
    $((t/10)) $((t%10)) "$(awk -v i="$i" 'BEGIN{print (i<0?-i:i)/1e6}')" "$s" >> "$CSV"
  if [ "$t" -ge "$HARD_X10" ]; then
    echo "[ABORT] T=$((t/10)).$((t%10))℃ 达到 45.5，立即挂起输入" | tee -a "$CSV"
    suspend 1; cleanup; trap - EXIT; exit 3
  fi
}

STEP=180
for LV in 6000 10000 12000; do
  echo "--- 阶跃到 ${LV}mA，持续 ${STEP}s ---"
  vote "$LV"
  S=0
  while [ "$S" -lt "$STEP" ]; do
    sleep 5; S=$((S+5)); sample "$LV" "$S"
    [ $((S % 30)) -eq 0 ] && echo "  ${LV}mA 已 ${S}s  T=$(rd $BAT/temp | awk '{printf "%.1f", $1/10}')℃"
  done
done

cleanup; trap - EXIT

echo "=== 拟合 ==="
# 每段取最后 60s 的平均温度作为该电流下的准稳态，最小二乘拟合 T∞ = Tamb + alpha*I^2
awk -F, '
  NR==1 { next }
  { key=$2; t=$3+0;
    if (!(key in tmax) || t>tmax[key]) tmax[key]=t;
    if (t > tmax[key]-60) { s[key]+=$4; n[key]++ } }
  END {
    m=0;
    for (k in s) { T[k]=s[k]/n[k]; I[k]=k/1000.0; m++ }
    if (m<3) { print "数据不足（少于 3 个电流档），无法拟合"; exit 1 }
    for (k in T) { x=I[k]*I[k]; sx+=x; sy+=T[k]; sxx+=x*x; sxy+=x*T[k]; nn++ }
    den=nn*sxx-sx*sx;
    if (den==0) { print "三个电流档退化（x 无差异），无法拟合"; exit 1 }
    B=(nn*sxy-sx*sy)/den; A=(sy-B*sx)/nn;
    if (B<=0) { print "alpha<=0（温度随电流不升），数据不可用"; exit 1 }
    printf "alpha = %.5f C/A^2\nTamb  = %.2f C\n", B, A;
    for (k in T) printf "  校验 I=%.1fA -> Tinf=%.2fC (实测平台 %.2fC, 残差 %+.2fC)\n", I[k], A+B*I[k]*I[k], T[k], T[k]-(A+B*I[k]*I[k]);
    i43=sqrt((43-A)/B);
    printf "43C 可持续电流 ~ %.2f A ~ %.0f W (4.4V)\n", i43, 4.4*i43;
  }' "$CSV"

echo
echo "tau 粗估：取 12000mA 段从 10A 平台起步的曲线，找达到 (T0+0.632*(Tinf-T0)) 的时刻，"
echo "        该时刻减去阶跃起点即 tau（单位秒）。Tinf 用上面 alpha/Tamb 代入 I=12A 算。"
echo "建议配置（alpha 合理后再逐项开启）："
echo "  pred_alpha=<上面的 alpha>  pred_tau_s=<tau>  pred_ambient=<Tamb>"
echo "  pred_enable=1  pred_horizon_s=60  pred_margin=0.5"
echo "  min_regulate_ma=9000  soft_landing=1"
echo "数据：$CSV"
