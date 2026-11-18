#!/usr/bin/env sh
# identify-thermal.sh 里 τ 拟合的夹具测试（不需要真机）
#
# 做法：从脚本里把真正在跑的那段 awk 抠出来，用已知 α/τ 生成理想一阶响应 CSV，
# 看拟合能不能回到 τ。抄一份公式到测试里没有意义 —— 页面/脚本改了它发现不了。

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=${TMPDIR:-/tmp}/tc-tau-test
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望 $3, 实际 $2)"; fi; }

rm -rf "$T"; mkdir -p "$T"

# 抽 TAU=$(awk ... ) 这一段，去掉首行前缀和尾行 `' "$CSV")`。
# 用行号而不是 sed 地址：整段里既有单引号也有 `$(...)`，直接写地址很容易
# 被 shell 当成命令替换（实测报 "(" unexpected）。
SRC=$ROOT/module/tools/identify-thermal.sh
START=$(grep -nF 'TAU=$(awk -F,' "$SRC" | cut -d: -f1)
# 文件里还有 FIT 那段的同名结尾；取 START 之后的第一处
END=$(grep -nF "  }' \"\$CSV\")" "$SRC" | cut -d: -f1 | awk -v s="$START" '$1 > s { print; exit }')
[ -n "$START" ] && [ -n "$END" ] && [ "$END" -gt "$START" ] || {
  echo "无法定位 τ 拟合代码"; exit 1; }
sed -n "$((START+1)),$((END-1))p" "$SRC" > "$T/tau.awk"
printf '  }\n' >> "$T/tau.awk"
[ -s "$T/tau.awk" ] || { echo "无法从 identify-thermal.sh 抽出 τ 拟合代码"; exit 1; }

# 生成 6A/10A/12A 三段理想一阶响应，τ 已知
gen() {  # gen <tau> <file>
  awk -v tau="$1" 'BEGIN{
    A=25.0; B=0.07; T=A+B*(6000/1000)^2;
    print "epoch,level_ma,step_s,temp_c,current_a,soc";
    epoch=1000;
    n=split("6000 10000 12000", lv, " ");
    for (j=1;j<=n;j++){
      L=lv[j]+0; I=L/1000; Tinf=A+B*I*I;
      for (s=0;s<=180;s+=5){
        if (s>0) T=Tinf-(Tinf-T)*exp(-5/tau);
        printf "%d,%d,%d,%.2f,%.2f,60\n", epoch, L, s, T, I;
        epoch+=5;
      }
    }
  }' > "$2"
}

gen 300 "$T/tau300.csv"
TAU=$(awk -F, -v A=25.0 -v B=0.07 -f "$T/tau.awk" "$T/tau300.csv")
# 允许 ±10s：采样 5s、fprintf 保留两位小数
if [ "$TAU" -ge 290 ] && [ "$TAU" -le 310 ]; then
  ok "τ=300 拟合回 ${TAU}s"
else
  bad "τ=300 拟合成了 ${TAU}s"
fi

gen 220 "$T/tau220.csv"
TAU=$(awk -F, -v A=25.0 -v B=0.07 -f "$T/tau.awk" "$T/tau220.csv")
if [ "$TAU" -ge 210 ] && [ "$TAU" -le 230 ]; then
  ok "τ=220 拟合回 ${TAU}s"
else
  bad "τ=220 拟合成了 ${TAU}s"
fi

# 温度完全不动：斜率 0，必须返回 0（表示无法可靠估计），不能给个假 τ
awk 'BEGIN{
  print "epoch,level_ma,step_s,temp_c,current_a,soc";
  e=1000; split("6000 10000 12000", lv, " ");
  for(j=1;j<=3;j++){ for(s=0;s<=180;s+=5){ printf "%d,%d,%d,30.00,%.2f,60\n",e,lv[j],s,lv[j]/1000; e+=5 } }
}' > "$T/flat.csv"
TAU=$(awk -F, -v A=25.0 -v B=0.07 -f "$T/tau.awk" "$T/flat.csv")
check "温度不动时返回 0" "$TAU" "0"

# 数据不足：只有 12A 段几拍
awk 'BEGIN{
  print "epoch,level_ma,step_s,temp_c,current_a,soc";
  print "1000,12000,0,35.00,12.00,60";
  print "1005,12000,5,35.10,12.00,60";
}' > "$T/short.csv"
TAU=$(awk -F, -v A=25.0 -v B=0.07 -f "$T/tau.awk" "$T/short.csv")
check "样本不足时返回 0" "$TAU" "0"

echo "== 结果 =="
echo "  通过 $PASS 项, 失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
