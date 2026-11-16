#!/system/bin/sh
# identify-thermal.sh —— 开环阶跃辨识 α（热阻系数）与 τ（热时间常数）
#
# 为什么必须开环：闭环数据里电流被控制器锁在 9.7A 附近，只有一个工况点，
# 拟合不出 T∞=Tamb+αI²。这里让脚本独占限流通道，做 6A→10A→12A 三段、
# 每段 180 秒的阶跃，采样温度。
#
# 怎么"占住"通道（两种模式，脚本自动选择）：
#   sigstop  —— SIGSTOP 冻结守护进程。进程不退出，结束后 CONT 即可。
#   stopped  —— 正常停止守护进程。**实测本机（HyperOS）内核直接忽略 SIGSTOP**：
#               kill 返回 0 但状态始终是 S，原生 raise(SIGSTOP) 也照样继续执行。
#               所以先回读 /proc 状态验证，无效就退回这条路径；结束后由 supervisor 拉起。
#
# 退出与恢复：
#   · 正常结束、Ctrl-C / SIGTERM、拔电、温度中止，都会经过 cleanup：
#     解除挂起、把票降到 RELEASE_MA，sigstop 模式下 CONT 守护进程。
#   · 温度中止（≥45.5℃）时票降到 500mA 而不是放开到 20500mA，守护进程
#     重新接管后按它自己的 hard_temp 逻辑处理，不会留下"挂起但没人解"的状态。
#   · 锁文件 $D/identify.lock 存的是脚本 pid；脚本被 SIGKILL 时 cleanup 不会跑，
#     supervisor 与看门狗会按 pid + cmdline 判断它是否还活着。
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
MARK=$D/identify.lock
TS=$(date +%Y%m%d-%H%M%S)
CSV=$D/log/ident-$TS.csv
HARD_X10=455
PID=$(cat $D/daemon.pid 2>/dev/null)
rd() { cat "$1" 2>/dev/null | tr -d '\n'; }

# 投票标签必须与守护进程的 mca_tag / mca_type 一致：同一个投票者才会覆盖它的票。
# 用别的标签的话，守护进程仍在投的 user 票会把我们的 12A 档压下去。
TAG=$(sed -n 's/^[[:space:]]*mca_tag[[:space:]]*=[[:space:]]*//p' $D/config.conf 2>/dev/null | head -1 | tr -d ' \t\r')
TYPE=$(sed -n 's/^[[:space:]]*mca_type[[:space:]]*=[[:space:]]*//p' $D/config.conf 2>/dev/null | head -1 | tr -d ' \t\r')
TAG=${TAG:-user}
TYPE=${TYPE:-all}

charging() { [ "$(rd /sys/class/power_supply/usb/online)" = "1" ]; }
charging || { echo "未在充电，退出。"; exit 2; }
[ -n "${PID:-}" ] || { echo "找不到守护进程 pid，退出。"; exit 2; }
[ -d "/proc/$PID" ] || { echo "守护进程 $PID 不在运行，退出。"; exit 2; }

vote() { printf '%s %s %s\n' "$TAG" "$TYPE" "$1" > $ICHG; }      # mA
suspend() { printf '%s %s %s\n' "$TAG" "$TYPE" "$1" > $SUSP; }

FREEZE_MODE=""
RELEASE_MA=20500                    # 正常结束时投"无约束"票；热中止时改成小值
CLEANED=0
proc_state() { cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null; }

cleanup() {
  [ "$CLEANED" = 1 ] && return 0     # EXIT 与信号处理可能都会调到这里，只做一次
  CLEANED=1
  suspend 0 >/dev/null 2>&1
  vote "$RELEASE_MA" >/dev/null 2>&1
  [ "$FREEZE_MODE" = "sigstop" ] && kill -CONT "$PID" 2>/dev/null
  rm -f "$MARK"
  echo "[cleanup] 限流票降到 ${RELEASE_MA}mA，守护进程交由 supervisor 恢复" | tee -a "$CSV"
}
trap cleanup EXIT
# 信号必须退出：只调 cleanup 而不 exit 的话，脚本会接着往下跑、继续投票（已实测）
trap 'cleanup; exit 130' INT TERM

echo "epoch,level_ma,step_s,temp_c,current_a,soc" > "$CSV"
echo "=== 开环辨识开始 $(date "+%Y-%m-%dT%H:%M:%S") ==="
echo $$ > "$MARK"                   # 让 supervisor / 看门狗知道别动守护进程

kill -STOP "$PID" 2>/dev/null
sleep 1
if [ "$(proc_state "$PID")" = "T" ]; then
  FREEZE_MODE=sigstop
  echo "已冻结守护进程 (SIGSTOP)"
else
  # 本机内核忽略 SIGSTOP：kill 成功返回但状态仍是 S，必须自己接管
  kill -CONT "$PID" 2>/dev/null
  echo "本机内核忽略 SIGSTOP，改为正常停止守护进程（结束后 supervisor 自动拉起）"
  "$TC" stop >/dev/null 2>&1
  n=0
  while [ -d "/proc/$PID" ] && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n+1)); done
  if [ -d "/proc/$PID" ]; then
    echo "无法停止守护进程（pid $PID），退出" | tee -a "$CSV"
    exit 2
  fi
  FREEZE_MODE=stopped
  echo "守护进程已停止，限流通道由本脚本独占"
fi
suspend 0

sample() {  # $1=level $2=step_s
  local t i s
  t=$(rd $BAT/temp); i=$(rd $BAT/current_now); s=$(rd $BAT/capacity)
  [ -z "$t" ] && return
  # 温度统一用 awk 换算：0.1℃ 单位下负值用 $((t/10)).$((t%10)) 会输出 "0.-1"
  printf '%s,%s,%s,%s,%.2f,%s\n' "$(date +%s)" "$1" "$2" \
    "$(awk -v t="$t" 'BEGIN{printf "%.1f", t/10}')" \
    "$(awk -v i="$i" 'BEGIN{print (i<0?-i:i)/1e6}')" "$s" >> "$CSV"
  if [ "$t" -ge "$HARD_X10" ]; then
    echo "[ABORT] T=$(awk -v t="$t" 'BEGIN{printf "%.1f", t/10}')℃ 达到 45.5，中止辨识" | tee -a "$CSV"
    RELEASE_MA=500                   # 守护进程接管前别放开电流
    cleanup
    exit 3
  fi
}

STEP=180
for LV in 6000 10000 12000; do
  echo "--- 阶跃到 ${LV}mA，持续 ${STEP}s ---"
  vote "$LV"
  S=0
  while [ "$S" -lt "$STEP" ]; do
    sleep 5; S=$((S+5))
    charging || { echo "[ABORT] 辨识中途拔电" | tee -a "$CSV"; cleanup; exit 5; }
    sample "$LV" "$S"
    [ $((S % 30)) -eq 0 ] && echo "  ${LV}mA 已 ${S}s  T=$(rd $BAT/temp | awk '{printf "%.1f", $1/10}')℃"
    # 第一档 60 秒后核对：票没被接受就早点退出，别白跑 9 分钟
    if [ "$LV" = "6000" ] && [ "$S" -eq 60 ]; then
      cur=$(awk -v i="$(rd $BAT/current_now)" 'BEGIN{printf "%.2f", (i<0?-i:i)/1e6}')
      if awk -v c="$cur" 'BEGIN{exit !(c < 3.0)}'; then
        echo "[ABORT] 60 秒后实测只有 ${cur}A，6A 的票没有生效（可能被系统限流压住）" | tee -a "$CSV"
        cleanup; exit 4
      fi
    fi
  done
done

cleanup

echo "=== 拟合 ==="
# 每段取最后 60s 的均值作为该档的准稳态点。
# 自变量用**实测电流**（第 5 列），不是请求档位：系统 Min 聚合会把请求值
# 压到更低，用请求档位拟合等于拿一个没发生过的工况算斜率。
awk -F, '
  NR==1 { next }
  { key=$2; t=$3+0; i=$5+0;
    if (!(key in tmax) || t>tmax[key]) tmax[key]=t;
    if (t > tmax[key]-60) { sT[key]+=$4; sI[key]+=i; n[key]++ } }
  END {
    for (k in n) { if (n[k] == 0) continue; T[k]=sT[k]/n[k]; I[k]=sI[k]/n[k]; if (I[k] > 0) m++ }
    if (m < 3) { print "数据不足（少于 3 个有效电流档），无法拟合"; exit 1 }
    imin=1e9; imax=-1e9;
    for (k in T) { if (I[k] < imin) imin=I[k]; if (I[k] > imax) imax=I[k] }
    if (imax - imin < 0.5) {
      printf "三档实测电流几乎相同（%.1f~%.1fA），被系统限流压住了，无法拟合。\n", imin, imax;
      exit 1
    }
    for (k in T) { x=I[k]*I[k]; sx+=x; sy+=T[k]; sxx+=x*x; sxy+=x*T[k]; nn++ }
    den=nn*sxx-sx*sx;
    if (den==0) { print "三个电流档退化（x 无差异），无法拟合"; exit 1 }
    B=(nn*sxy-sx*sy)/den; A=(sy-B*sx)/nn;
    if (B<=0) { print "alpha<=0（温度随电流不升），数据不可用"; exit 1 }
    printf "alpha = %.5f C/A^2\nTamb  = %.2f C\n", B, A;
    for (k in T) printf "  校验 I=%.2fA -> Tinf=%.2fC (实测平台 %.2fC, 残差 %+.2fC)\n", I[k], A+B*I[k]*I[k], T[k], T[k]-(A+B*I[k]*I[k]);
    if (43 > A) { i43=sqrt((43-A)/B); printf "43C 可持续电流 ~ %.2f A ~ %.0f W (4.4V)\n", i43, 4.4*i43 }
    else print "43C 低于估算的 Tamb，无法给出 43C 对应的电流"
  }' "$CSV"

echo
echo "tau 粗估：取 12000mA 段从 10A 平台起步的曲线，找达到 (T0+0.632*(Tinf-T0)) 的时刻，"
echo "        该时刻减去阶跃起点即 tau（单位秒）。Tinf 用上面 alpha/Tamb 代入 I=12A 算。"
echo "建议配置（alpha 合理后再逐项开启）："
echo "  pred_alpha=<上面的 alpha>  pred_tau_s=<tau>  pred_ambient=<Tamb>"
echo "  pred_enable=1  pred_horizon_s=60  pred_margin=0.5"
echo "  min_regulate_ma=9000  soft_landing=1"
echo "数据：$CSV"
