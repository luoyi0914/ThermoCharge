#!/system/bin/sh
# identify-thermal.sh —— 开环阶跃辨识 α（热阻系数）与 τ（热时间常数）
#
# 为什么必须开环：闭环数据里电流被控制器锁在 9.7A 附近，只有一个工况点，
# 拟合不出 T∞=Tamb+αI²。这里让脚本独占限流通道，做 6A→10A→12A 三段、
# 每段 180 秒的阶跃，采样温度。
#
# 占住哪条通道：跟守护进程的 ctl_mode 一致（0/2 写 wired_chg_curr，1/2 写
# ichg_limit）。只写 ichg_limit 在电荷泵阶段不约束电流 —— 实测 2026-11-17 23:18
# 请求 6A、实际 15A，整轮数据作废。所以这里必须双写，并且每 5 秒重投一次
# （mi_thermald 会周期覆写 wired_chg_curr，守护进程平时也靠 reassert_ms 对抗）。
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
# 第二个执行通道。真机实测：电荷泵阶段只投 ichg_limit 不起约束作用
# （投 1184mA 实测照样 6860mA），实际电流由 wired_chg_curr 压住。
# 守护进程平时靠 ctl_mode=2 双写两通道；本脚本冻结它之后必须自己接手，
# 否则 6/10/12A 三档会全部落在同一个系统默认电流上（实测 15A），辨识结果无意义。
WIRED=/sys/class/xm_power/charger/charger_thermal/wired_chg_curr   # 单位 µA
SUSP=/sys/class/xm_power/charger/charge_interface/input_suspend
BAT=/sys/class/power_supply/battery
MARK=$D/identify.lock
TS=$(date +%Y%m%d-%H%M%S)
CSV=$D/log/ident-$TS.csv
# WebUI 的机器可读结果：拿到单实例锁后才删旧的，跑完（成功或拟合失败）再写。
# 界面靠这个文件区分「还在跑」和「上一轮的结果」。
JSON=$D/log/ident-last.json
HARD_X10=455
PID=$(cat $D/daemon.pid 2>/dev/null)
rd() { cat "$1" 2>/dev/null | tr -d '\n'; }

# 失败也要留下机器可读结果：WebUI 靠它区分"没跑过"和"跑了但失败了"。
# 错误文本只放中文/数字，不含引号和反斜杠，可以直接塞进 JSON。
write_fail() {
  printf '{"ok":false,"error":"%s","csv":"%s"}\n' "$1" "$CSV" > "$JSON" 2>/dev/null
}

# 取配置项。取**最后一处**：cfg_load 是逐行赋值，重复键以后出现的为准，
# 这里必须与它一致，否则脚本和守护进程会按两个不同的 tag / 类型投票。
cf_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$D/config.conf" 2>/dev/null \
    | sed 's/#.*//' | tr -d ' \t\r' | awk 'length { v = $0 } END { print v }'
}

# 投票标签必须与守护进程的 mca_tag / mca_type 一致：同一个投票者才会覆盖它的票。
# 用别的标签的话，守护进程仍在投的 user 票会把我们的 12A 档压下去。
TAG=$(cf_get mca_tag)
TYPE=$(cf_get mca_type)
TAG=${TAG:-user}
TYPE=${TYPE:-all}

# 与守护进程的 ctl_mode 一致：0/2 要写 wired_chg_curr，1/2 要写 ichg_limit。
# 只写一个通道在 CP 阶段等于没限（见 WIRED 处的说明）。
CTL_MODE=$(cf_get ctl_mode)
CTL_MODE=${CTL_MODE:-2}
# 配置文件可能被手改坏；非法值会让下面两个 case 全部跳过、脚本静默不限流
case "$CTL_MODE" in 0|1|2) ;; *) CTL_MODE=2 ;; esac

charging() { [ "$(rd /sys/class/power_supply/usb/online)" = "1" ]; }
charging || { echo "未在充电，退出。"; write_fail "未在充电"; exit 2; }

# 接管前先确认节点存在。注意：脚本以 root 运行，test -w 对 0444 的 sysfs 属性
# 也会返回真（CAP_DAC_OVERRIDE），所以这里只能查存在性；真正能不能写，
# 由第一档 60 秒后的电流核对来判定。
case "$CTL_MODE" in
  0|2)
    if [ ! -e "$WIRED" ]; then
      echo "! 找不到 $WIRED（ctl_mode=$CTL_MODE 需要这个通道）"
      echo "  电荷泵阶段只投 ichg_limit 不起约束作用，辨识会失败。"
      echo "  确认机型节点路径，或临时把 ctl_mode 改成 1 后重跑。"
      write_fail "找不到限流节点 $WIRED"
      exit 2
    fi
    ;;
esac
[ -n "${PID:-}" ] || { echo "找不到守护进程 pid，退出。"; write_fail "找不到守护进程"; exit 2; }

# 只按 /proc 存在判断会误伤：上次被 SIGKILL 留下的 daemon.pid 在重启后
# 很容易被无关进程复用，而脚本最长会冻结它 9 分钟。
pid_is_daemon() {
  [ -d "/proc/$1" ] || return 1
  set -- $(tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null)
  [ "$(basename "${1:-}")" = "thermocharge" ] || return 1
  for a in "$@"; do [ "$a" = "run" ] && return 0; done
  return 1
}
pid_is_daemon "$PID" || {
  echo "pid $PID 不是 thermocharge 守护进程（陈旧 daemon.pid？），退出。"
  write_fail "daemon.pid 指向的不是守护进程"
  exit 2
}

# 已经到硬上限就先别投大电流：检查循环每 5 秒才看一次温度，
# 启动前热着的电池会白吃几秒 6A。
T0=$(rd "$BAT/temp")
case "$T0" in
  ""|*[!0-9-]*) echo "读不到电池温度（$BAT/temp），退出。"; write_fail "读不到电池温度"; exit 2 ;;
esac
[ "$T0" -lt "$HARD_X10" ] || {
  echo "电池温度 $((T0 / 10)).$((T0 % 10))℃ 已到硬上限，等凉下来再跑。"
  write_fail "电池温度已到 45.5C，先降温再辨识"
  exit 2
}

# vote <mA>：按 ctl_mode 同守护进程一样双写
vote() {
  case "$CTL_MODE" in
    0|2) printf '%s\n' "$(( $1 * 1000 ))" > $WIRED 2>/dev/null ;;   # µA
  esac
  case "$CTL_MODE" in
    1|2) printf '%s %s %s\n' "$TAG" "$TYPE" "$1" > $ICHG 2>/dev/null ;;
  esac
}
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
  # 只打到终端，不 tee 进 CSV：拟合按第 2 列分组，这行人会让数据文件多出一个
  # 逗号列数不足的行（用户上传的 CSV 里就能看到它混在数据尾部）。
  echo "[cleanup] 限流票降到 ${RELEASE_MA}mA，守护进程交由 supervisor 恢复"
}
trap cleanup EXIT
# 信号必须退出：只调 cleanup 而不 exit 的话，脚本会接着往下跑、继续投票（已实测）
trap 'cleanup; exit 130' INT TERM

echo "epoch,level_ma,step_s,temp_c,current_a,soc" > "$CSV"
echo "=== 开环辨识开始 $(date "+%Y-%m-%dT%H:%M:%S") ==="

# 单实例：两份辨识会同时往同一通道投不同档位、互相覆盖锁文件，数据全废。
# set -C（noclobber）让重定向在文件已存在时失败，是这里最轻的原子创建方式。
if [ -f "$MARK" ]; then
  opid=$(cat "$MARK" 2>/dev/null)
  case "$(tr '\0' ' ' < "/proc/$opid/cmdline" 2>/dev/null)" in
    *identify-thermal*)
      echo "已有辨识在运行（pid $opid），退出。"
      exit 3 ;;
  esac
  rm -f "$MARK"
fi
( set -C; echo $$ > "$MARK" ) 2>/dev/null || {
  echo "无法创建锁 $MARK（可能有另一个辨识刚启动），退出。"
  exit 3
}
rm -f "$JSON" 2>/dev/null

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
    echo "无法停止守护进程（pid $PID），退出"
    write_fail "无法停止守护进程"
    exit 2
  fi
  FREEZE_MODE=stopped
  echo "守护进程已停止，限流通道由本脚本独占"
fi
suspend 0

sample() {  # $1=level $2=step_s
  local t i s
  t=$(rd $BAT/temp); i=$(rd $BAT/current_now); s=$(rd $BAT/capacity)
  # 读不到温度就中止：继续跑会让 `[ "$t" -ge 455 ]` 只报一条错，
  # 然后在不知道温度的情况下把电流维持在 6~12A
  case "$t" in
    ""|*[!0-9-]*)
      echo "[ABORT] 读不到电池温度（$BAT/temp），中止辨识"
      RELEASE_MA=500
      write_fail "读不到电池温度，已中止"
      cleanup
      exit 6 ;;
  esac
  # 温度统一用 awk 换算：0.1℃ 单位下负值用 $((t/10)).$((t%10)) 会输出 "0.-1"
  printf '%s,%s,%s,%s,%.2f,%s\n' "$(date +%s)" "$1" "$2" \
    "$(awk -v t="$t" 'BEGIN{printf "%.1f", t/10}')" \
    "$(awk -v i="$i" 'BEGIN{print (i<0?-i:i)/1e6}')" "$s" >> "$CSV"
  if [ "$t" -ge "$HARD_X10" ]; then
    echo "[ABORT] T=$(awk -v t="$t" 'BEGIN{printf "%.1f", t/10}')℃ 达到 45.5，中止辨识"
    RELEASE_MA=500                   # 守护进程接管前别放开电流
    write_fail "温度到 45.5C，已自动中止；等更凉快时再辨识"
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
    charging || { echo "[ABORT] 辨识中途拔电"; write_fail "辨识中途拔电"; cleanup; exit 5; }
    # 每 5 秒重投一次：mi_thermald / micharge HAL 会周期覆写 wired_chg_curr，
    # 守护进程平时也是靠 reassert_ms=5000 对抗的。冻结之后这条得由脚本接手，
    # 否则票投一次就被系统顶回去，档位根本维持不住。
    vote "$LV"
    sample "$LV" "$S"
    [ $((S % 30)) -eq 0 ] && echo "  ${LV}mA 已 ${S}s  T=$(rd $BAT/temp | awk '{printf "%.1f", $1/10}')℃"
    # 第一档 60 秒后核对：票没被接受就早点退出，别白跑 9 分钟。
    # 两个方向都要查——只查"太低"会漏掉"根本没限住"那种情况
    # （真机 2026-11-17 23:18：请求 6A，实测 15A，脚本一路跑到底，数据全废）。
    if [ "$LV" = "6000" ] && [ "$S" -eq 60 ]; then
      cur=$(awk -v i="$(rd $BAT/current_now)" 'BEGIN{printf "%.2f", (i<0?-i:i)/1e6}')
      if awk -v c="$cur" 'BEGIN{exit !(c < 3.0)}'; then
        echo "[ABORT] 60 秒后实测只有 ${cur}A，6A 的票没有生效（可能被系统限流压住）"
        write_fail "6A 的票没有生效（可能被系统限流压住）"
        cleanup; exit 4
      fi
      if awk -v c="$cur" 'BEGIN{exit !(c > 9.0)}'; then
        echo "[ABORT] 60 秒后实测 ${cur}A，远高于请求的 6A —— 限流通道没有接管"
        echo "        检查 ctl_mode=${CTL_MODE} 对应的节点是否可写：$WIRED / $ICHG"
        write_fail "限流通道没有接管，检查 ctl_mode 对应的节点"
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
FIT=$(awk -F, '
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
  }' "$CSV")
FIT_RC=$?
echo "$FIT"
# 拟合失败必须把退出码传出去：以前 awk exit 1 被忽略，脚本仍打印
# 「建议配置」并以 0 退出，自动化/用户都以为成功了。
if [ "$FIT_RC" -ne 0 ]; then
  echo "拟合失败（原因见上）；原始数据保留在 $CSV，可手工分析。"
  write_fail "数据不足，拟合失败"
  exit 6
fi

# 从拟合输出里取回 alpha / Tamb。它们各自独占一行、顶格输出
# （校验行有前导空格，不会误匹配）。
ALPHA=$(printf '%s\n' "$FIT" | sed -n 's/^alpha = \([0-9.]*\).*/\1/p')
TAMB=$(printf '%s\n' "$FIT" | sed -n 's/^Tamb  = \([0-9.-]*\).*/\1/p')
case "$ALPHA" in ""|*[!0-9.-]*) echo "拟合结果解析失败: alpha=$ALPHA"; exit 6 ;; esac
case "$TAMB"  in ""|*[!0-9.-]*) echo "拟合结果解析失败: Tamb=$TAMB"; exit 6 ;; esac

# tau：用 12000mA 段对 T(t)=Tinf-(Tinf-T0)·exp(-t/tau) 做线性回归
# （y=ln((Tinf-T)/(Tinf-T0)) 对 t 的斜率 = -1/tau）。180s 只到 0.82τ，
# 用"达到 63.2%"的取点法根本取不到，容易误判成"数据不足"。
# T0 取 10A 段最后一拍，Tinf 用每拍实测电流代入拟合模型。
TAU=$(awk -F, -v A="$TAMB" -v B="$ALPHA" '
  NR==1 { next }
  {
    lvl=$2+0; ts=$1+0; tc=$4+0; ia=$5+0;
    if (lvl==12000 && !in12){ in12=1; t0=ts; T0=prev; have0=prevset }
    else if (in12 && lvl!=12000) in12=0
    if (in12 && have0){
      tinf=A+B*ia*ia;
      if (tinf-T0 > 0.3){
        u=(tinf-tc)/(tinf-T0);
        if (u>0.02 && u<1){ x=ts-t0; y=log(u); sx+=x; sy+=y; sxx+=x*x; sxy+=x*y; n++ }
      }
    }
    prev=tc; prevset=1
  }
  END{
    if (n<5){ print 0; exit }
    den=n*sxx-sx*sx;
    if (den==0){ print 0; exit }
    slope=(n*sxy-sx*sy)/den;
    if (slope>=0){ print 0; exit }
    tau=-1/slope;
    if (tau<30 || tau>1800){ print 0; exit }
    printf "%.0f\n", tau
  }' "$CSV")
TAU=${TAU:-0}

HORIZON=60
if [ "$TAU" -ge 30 ]; then
  HORIZON=$(( (TAU + 1) / 2 ))
  [ "$HORIZON" -lt 30 ] && HORIZON=30
  [ "$HORIZON" -gt 1800 ] && HORIZON=1800
fi

echo
if [ "$TAU" -gt 0 ]; then
  echo "tau = ${TAU}s（12A 段指数拟合）"
else
  echo "tau = 无法可靠估计（12A 段太短/噪声过大），建议值里不会包含 pred_tau_s"
fi
echo "建议配置（alpha 合理后再逐项开启）："
echo "  pred_alpha=${ALPHA}  pred_ambient=${TAMB}  pred_horizon_s=${HORIZON}"
[ "$TAU" -gt 0 ] && echo "  pred_tau_s=${TAU}"
echo "  pred_enable=1  pred_margin=0.5  min_regulate_ma=9000  soft_landing=1"
echo "数据：$CSV"

# WebUI 读取的机器可读结果。JSON 里只放数值和 CSV 路径（路径不带引号/反斜杠），
# 不做转义处理；新增字段时保持这个约束。
ALPHA_J=$(awk -v a="$ALPHA" 'BEGIN{printf "%.5f", a}')
TAMB_J=$(awk -v t="$TAMB" 'BEGIN{printf "%.2f", t}')
REC_ALPHA=$(awk -v a="$ALPHA" 'BEGIN{printf "%.3f", a}')
REC_TAMB=$(awk -v t="$TAMB" 'BEGIN{printf "%.1f", t}')
REC_TAU=""
[ "$TAU" -gt 0 ] && REC_TAU=",\"pred_tau_s\":${TAU}"
{
  printf '{"ok":true,"alpha":%s,"tamb":%s,"tau":%s,"csv":"%s","recommend":{"pred_alpha":%s,"pred_ambient":%s,"pred_horizon_s":%d,"pred_margin":0.5,"min_regulate_ma":9000,"soft_landing":1%s}}\n' \
    "$ALPHA_J" "$TAMB_J" "$TAU" "$CSV" "$REC_ALPHA" "$REC_TAMB" "$HORIZON" "$REC_TAU"
} > "$JSON" 2>/dev/null
[ -f "$JSON" ] && echo "机器可读结果：$JSON"
