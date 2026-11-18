#!/usr/bin/env sh
# customize.sh 配置迁移的夹具测试：不需要 root，不碰真机 /data
#
# 做法：把 customize.sh 里的 DATA / MODPATH 换成临时目录，再用桩函数顶掉
# KernelSU 提供的 ui_print / set_perm / abort / getprop，然后跑真脚本。
#
# 覆盖点：
#   1) v4 老配置（kd=15、tdot=12、max=9000、pred_enable=0）迁移到 6 后全部修正
#   2) v5 已辨识的 α（0.0584）不被 0.07 覆盖
#   3) v6 配置原样保留，且迁移不改变文件权限（仍是 0600）
#   4) 没有配置文件的全新安装能写出默认配置

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=${TMPDIR:-/tmp}/tc-migrate-test
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望 $3, 实际 $2)"; fi; }

rm -rf "$T"
mkdir -p "$T"

# 每个用例一个独立沙箱：mod/ 是模块目录，data/ 是 /data/adb/thermocharge
mkcase() {
  local name=$1
  local d=$T/$name
  mkdir -p "$d/mod/bin" "$d/data/log"
  cp "$ROOT/module/customize.sh" "$ROOT/module/config.conf" "$ROOT/module/CHANGELOG-current.txt" "$d/mod/"
  printf '#!/system/bin/sh\necho 1.3.10\n' > "$d/mod/bin/thermocharge"
  chmod 0755 "$d/mod/bin/thermocharge"
  # 把写死的真机路径换成沙箱路径
  sed -i "s#^DATA=/data/adb/thermocharge#DATA=$d/data#" "$d/mod/customize.sh"
  cat > "$d/stubs.sh" <<EOF
ui_print() { echo "\$*"; }
set_perm() { :; }
set_perm_recursive() { :; }
abort() { echo "ABORT: \$*" >&2; exit 1; }
getprop() { case "\$1" in ro.product.cpu.abi) echo arm64-v8a ;; esac; }
MODPATH=$d/mod
EOF
}

runinstall() {  # runinstall <沙箱名>
  ( cd "$T/$1" && sh -c '. ./stubs.sh; . ./mod/customize.sh' ) > "$T/$1/out.txt" 2>&1
}

# ---------------- 用例 1: v4 -> 6 ----------------
mkcase v4
cat > "$T/v4/data/config.conf" <<'EOF'
# 用户注释保留
cfg_version=4
target_temp=42
hard_temp=44
kd=15
tdot_tau_s=12
max_ma=9000
min_ma=500
ki=120
pred_enable=0
soft_landing=0
mca_tag=user
mca_type=all
EOF
chmod 600 "$T/v4/data/config.conf"
runinstall v4
CF=$T/v4/data/config.conf
check "cfg_version=6"        "$(grep '^cfg_version=' "$CF" | cut -d= -f2)" "6"
check "pred_enable=1"        "$(grep '^pred_enable=' "$CF" | cut -d= -f2)" "1"
check "soft_landing=1"       "$(grep '^soft_landing=' "$CF" | cut -d= -f2)" "1"
check "min_regulate_ma=9000" "$(grep '^min_regulate_ma=' "$CF" | cut -d= -f2)" "9000"
check "pred_alpha=0.07"      "$(grep '^pred_alpha=' "$CF" | cut -d= -f2)" "0.07"
check "pred_tau_s=300"       "$(grep '^pred_tau_s=' "$CF" | cut -d= -f2)" "300"
check "kd=40"                "$(grep '^kd=' "$CF" | cut -d= -f2)" "40"
check "tdot_tau_s=6.0"       "$(grep '^tdot_tau_s=' "$CF" | cut -d= -f2)" "6.0"
check "max_ma=15000"         "$(grep '^max_ma=' "$CF" | cut -d= -f2)" "15000"
check "target_temp 保留 42"  "$(grep '^target_temp=' "$CF" | cut -d= -f2)" "42"
check "注释保留"             "$(grep -c '^# 用户注释保留$' "$CF")" "1"
check "权限仍是 0600"        "$(stat -c '%a' "$CF")" "600"

# ---------------- 用例 2: v5 已辨识 alpha ----------------
mkcase v5
cat > "$T/v5/data/config.conf" <<'EOF'
cfg_version=5
target_temp=43
kd=40
tdot_tau_s=6
max_ma=20000
min_regulate_ma=9000
pred_enable=1
soft_landing=1
pred_alpha=0.0584
pred_tau_s=120
EOF
chmod 600 "$T/v5/data/config.conf"
runinstall v5
CF=$T/v5/data/config.conf
check "辨识值 alpha 保留"    "$(grep '^pred_alpha=' "$CF" | cut -d= -f2)" "0.0584"
check "辨识值 tau 保留"      "$(grep '^pred_tau_s=' "$CF" | cut -d= -f2)" "120"
check "max_ma 保留 20000"    "$(grep '^max_ma=' "$CF" | cut -d= -f2)" "20000"

# ---------------- 用例 3: 已是 v6 ----------------
mkcase v6
cp "$ROOT/module/config.conf" "$T/v6/data/config.conf"
chmod 600 "$T/v6/data/config.conf"
before=$(sha256sum "$T/v6/data/config.conf" | cut -d' ' -f1)
runinstall v6
CF=$T/v6/data/config.conf
check "内容不变"  "$(sha256sum "$CF" | cut -d' ' -f1)" "$before"
check "权限仍是 0600" "$(stat -c '%a' "$CF")" "600"

# ---------------- 用例 4: 全新安装 ----------------
mkcase fresh
runinstall fresh
CF=$T/fresh/data/config.conf
check "生成配置"        "$([ -f "$CF" ] && echo yes)" "yes"
check "cfg_version=6"   "$(grep '^cfg_version=' "$CF" | cut -d= -f2)" "6"
check "权限 0600"       "$(stat -c '%a' "$CF")" "600"

# ---------------- 用例 5: 坏值 cfg_version ----------------
mkcase badver
printf 'cfg_version=abc\ntarget_temp=43\n' > "$T/badver/data/config.conf"
chmod 600 "$T/badver/data/config.conf"
if runinstall badver; then ok "坏 cfg_version 不中断安装"; else bad "坏 cfg_version 让安装失败"; fi
check "仍被写成 6" "$(grep '^cfg_version=' "$T/badver/data/config.conf" | cut -d= -f2)" "6"

# ---------------- 用例 6: 配置缺尾换行（追加的新键不能粘到最后一行） ----------------
mkcase nonl
printf 'cfg_version=4\ntarget_temp=43\nmca_type=all' > "$T/nonl/data/config.conf"
chmod 600 "$T/nonl/data/config.conf"
runinstall nonl
CF=$T/nonl/data/config.conf
# 所有非注释行都必须是「一个键 = 一个值」，不能出现两个等号或键名粘连
BAD=$(grep -vE '^[[:space:]]*#' "$CF" | grep -cvE '^[a-z_0-9]+=[^=]*$' || true)
check "没有粘连行"        "$BAD" "0"
check "mca_type 仍是 all" "$(grep '^mca_type=' "$CF" | cut -d= -f2)" "all"
check "pred_enable 独立成行" "$(grep -c '^pred_enable=1$' "$CF")" "1"

# ---------------- 用例 7: 浮点写法也算旧默认值 ----------------
mkcase float
cat > "$T/float/data/config.conf" <<'EOF'
cfg_version=5
target_temp=43
kd=15.0
tdot_tau_s=12.0
max_ma=9000.0
pred_alpha=0.060
pred_tau_s=45.0
EOF
chmod 600 "$T/float/data/config.conf"
runinstall float
CF=$T/float/data/config.conf
check "kd 15.0 -> 40"       "$(grep '^kd=' "$CF" | cut -d= -f2)" "40"
check "tdot 12.0 -> 6.0"    "$(grep '^tdot_tau_s=' "$CF" | cut -d= -f2)" "6.0"
check "max 9000.0 -> 15000" "$(grep '^max_ma=' "$CF" | cut -d= -f2)" "15000"
check "alpha 0.060 -> 0.07" "$(grep '^pred_alpha=' "$CF" | cut -d= -f2)" "0.07"
check "tau 45.0 -> 300"     "$(grep '^pred_tau_s=' "$CF" | cut -d= -f2)" "300"

# ---------------- 用例 8: 重复键以最后一处为准 ----------------
mkcase dup
cat > "$T/dup/data/config.conf" <<'EOF'
cfg_version=5
kd=40
max_ma=20000
kd=15
max_ma=9000.0
EOF
chmod 600 "$T/dup/data/config.conf"
runinstall dup
CF=$T/dup/data/config.conf
check "kd 不再有旧值"      "$(grep -c '^kd=15' "$CF")" "0"
check "kd 全部改为 40"     "$(grep '^kd=' "$CF" | cut -d= -f2 | sort -u)" "40"
check "max_ma 全部 15000"  "$(grep '^max_ma=' "$CF" | cut -d= -f2 | sort -u)" "15000"

# ---------------- 用例 9: 行尾注释（cfg_load 会剥掉，读配置的脚本也必须剥） ----------------
mkcase inline
cat > "$T/inline/data/config.conf" <<'EOF'
cfg_version=5 # 当前版本
kd=15 # 调试
max_ma=9000 # 小功率
tdot_tau_s=12 # 旧默认
pred_alpha=0.06 # 出厂估值
EOF
chmod 600 "$T/inline/data/config.conf"
runinstall inline
CF=$T/inline/data/config.conf
check "带注释的 cfg_version 仍能迁移" "$(grep '^cfg_version=' "$CF" | cut -d= -f2)" "6"
check "kd 15 -> 40"       "$(grep '^kd=' "$CF" | cut -d= -f2)" "40"
check "tdot 12 -> 6.0"    "$(grep '^tdot_tau_s=' "$CF" | cut -d= -f2)" "6.0"
check "max 9000 -> 15000" "$(grep '^max_ma=' "$CF" | cut -d= -f2)" "15000"
check "alpha 0.06 -> 0.07" "$(grep '^pred_alpha=' "$CF" | cut -d= -f2)" "0.07"

# ---------------- 用例 10: 科学计数法也算旧默认值 ----------------
mkcase sci
cat > "$T/sci/data/config.conf" <<'EOF'
cfg_version=5
kd=1.5e1
tdot_tau_s=1.2e1
max_ma=9e3
pred_alpha=6e-2
pred_tau_s=4.5e1
EOF
chmod 600 "$T/sci/data/config.conf"
runinstall sci
CF=$T/sci/data/config.conf
check "kd 1.5e1 -> 40"      "$(grep '^kd=' "$CF" | cut -d= -f2)" "40"
check "tdot 1.2e1 -> 6.0"   "$(grep '^tdot_tau_s=' "$CF" | cut -d= -f2)" "6.0"
check "max 9e3 -> 15000"    "$(grep '^max_ma=' "$CF" | cut -d= -f2)" "15000"
check "alpha 6e-2 -> 0.07"  "$(grep '^pred_alpha=' "$CF" | cut -d= -f2)" "0.07"
check "tau 4.5e1 -> 300"    "$(grep '^pred_tau_s=' "$CF" | cut -d= -f2)" "300"

# ---------------- 用例 11: cfg_version 写成浮点（5.0）仍能迁移 ----------------
mkcase floatver
cat > "$T/floatver/data/config.conf" <<'EOF'
cfg_version=5.0
kd=15
tdot_tau_s=12
max_ma=9000
pred_alpha=0.06
EOF
chmod 600 "$T/floatver/data/config.conf"
runinstall floatver
CF=$T/floatver/data/config.conf
check "5.0 也当 5 处理并迁移" "$(grep '^cfg_version=' "$CF" | cut -d= -f2)" "6"
check "kd 15 -> 40"          "$(grep '^kd=' "$CF" | cut -d= -f2)" "40"
check "max 9000 -> 15000"    "$(grep '^max_ma=' "$CF" | cut -d= -f2)" "15000"

# ---------------- 用例 12: 尾部空值不覆盖前一个可解析值 ----------------
mkcase emptyval
cat > "$T/emptyval/data/config.conf" <<'EOF'
cfg_version=5
pred_alpha=0.09
pred_alpha=
EOF
chmod 600 "$T/emptyval/data/config.conf"
runinstall emptyval
CF=$T/emptyval/data/config.conf
check "辨识值 0.09 不被空值遮住" "$(grep -c '^pred_alpha=0.09$' "$CF")" "1"

echo "== 结果 =="
echo "  通过 $PASS 项, 失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
