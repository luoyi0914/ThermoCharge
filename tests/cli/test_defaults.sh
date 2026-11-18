#!/usr/bin/env sh
# `defaults` 子命令的夹具测试：不需要 root，不碰真机节点
#
# 覆盖点：
#   1) 打印模式逐项输出，数量与键表一致
#   2) --apply 后配置里每个键都等于打印值
#   3) 不在键表里的行（cfg_version）与注释原样保留
#   4) 文件权限不被 rename 冲掉（原来是 0600 就还是 0600）
#   5) kind=3 的字符串键仍然拒绝 set（不因建表而意外获得写入口）
#
# 二进制不在 /storage 上直接执行（那里没有 exec 权限），先拷到 TMPDIR。

set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN=$ROOT/out/thermocharge
T=${TMPDIR:-/tmp}/tc-defaults-test
PASS=0
FAIL=0

[ -f "$BIN" ] || { echo "找不到 $BIN，先跑 sh build.sh" >&2; exit 1; }

rm -rf "$T"
mkdir -p "$T/data" "$T/bin"
cp "$BIN" "$T/bin/thermocharge"
chmod 755 "$T/bin/thermocharge"
TC=$T/bin/thermocharge

run() { TC_DATA="$T/data" "$TC" "$@"; }

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望 $3, 实际 $2)"; fi; }

# 一份"被用户改过"的配置：混着自定义值、注释、不在键表里的键
cat > "$T/data/config.conf" <<'EOF'
# 用户注释：这一行必须活下来
cfg_version=6
target_temp=40
hard_temp=44
kd=15
max_ma=9000
pred_alpha=0.06
mca_tag=mine
mca_type=all
EOF
chmod 600 "$T/data/config.conf"

echo "== 打印模式 =="
N=$(run defaults | wc -l | tr -d ' ')
check "打印行数 = 36" "$N" "36"
[ "$(run defaults | grep -c '^[a-z_0-9]*=')" -eq "$N" ] && ok "每行都是 key=value" || bad "存在非 key=value 行"

echo "== apply =="
run defaults --apply >/dev/null
EXPECT=$(run defaults)
GOT=$(grep -E '^[a-z_0-9]*=' "$T/data/config.conf" | grep -v '^cfg_version=' | sort)
check "配置值与打印值一致" "$GOT" "$(echo "$EXPECT" | sort)"
check "target_temp=43.0" "$(grep '^target_temp=' "$T/data/config.conf" | cut -d= -f2)" "43.0"
check "kd=40"           "$(grep '^kd=' "$T/data/config.conf" | cut -d= -f2)" "40"
check "pred_alpha=0.07" "$(grep '^pred_alpha=' "$T/data/config.conf" | cut -d= -f2)" "0.07"
check "max_ma=20000"    "$(grep '^max_ma=' "$T/data/config.conf" | cut -d= -f2)" "20000"

echo "== 保留项 =="
grep -q '^# 用户注释：这一行必须活下来$' "$T/data/config.conf" \
  && ok "注释保留" || bad "注释被吃掉"
check "cfg_version 不被默认值覆盖" "$(grep '^cfg_version=' "$T/data/config.conf" | cut -d= -f2)" "6"

echo "== 权限 =="
check "仍是 0600" "$(stat -c '%a' "$T/data/config.conf")" "600"

echo "== 字符串键不开放 set =="
run set mca_tag evil >/dev/null 2>&1 && R=0 || R=$?
check "set mca_tag 被拒" "$R" "3"

echo "== 结果 =="
echo "  通过 $PASS 项, 失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
