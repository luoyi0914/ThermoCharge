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
BIN=${TC_TEST_BINARY:-$ROOT/out/thermocharge}
T=${TMPDIR:-/tmp}/tc-defaults-test
PASS=0
FAIL=0

[ -f "$BIN" ] || { echo "找不到 $BIN，先跑 sh build.sh" >&2; exit 1; }

rm -rf "$T"
mkdir -p "$T/data" "$T/bin"
cp "$BIN" "$T/bin/thermocharge"
chmod 755 "$T/bin/thermocharge"
TC=$T/bin/thermocharge

run() { TC_DATA="$T/data" TC_CONFIG="$T/data/config.conf" "$TC" "$@"; }

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望 $3, 实际 $2)"; fi; }

# 一份"被用户改过"的配置：混着自定义值、注释、不在键表里的键
cat > "$T/data/config.conf" <<'EOF'
# 用户注释：这一行必须活下来
cfg_version=6
target_temp=40
hard_temp=44
kd=15 # 退役参数的说明仍然保留
max_ma=9000
pred_alpha=0.06
pred_custom_2=1
soft_future=1
power_mode=0
unknown_user_key=keep
mca_tag=mine
mca_type=all
EOF
chmod 600 "$T/data/config.conf"

echo "== 打印模式 =="
N=$(run defaults | wc -l | tr -d ' ')
check "打印行数 = 21" "$N" "21"
[ "$(run defaults | grep -c '^[a-z_0-9]*=')" -eq "$N" ] && ok "每行都是 key=value" || bad "存在非 key=value 行"

echo "== apply =="
run defaults --apply >/dev/null
EXPECT=$(run defaults)
GOT=$(grep -E '^[a-z_0-9]*=' "$T/data/config.conf" | grep -vE '^(cfg_version|unknown_user_key)=' | sort)
check "配置值与打印值一致" "$GOT" "$(echo "$EXPECT" | sort)"
check "target_temp=43.0" "$(grep '^target_temp=' "$T/data/config.conf" | cut -d= -f2)" "43.0"
if grep -Eq '^(power_mode|kp|ki|kd|deadband|tdot_tau_s|min_regulate_ma|pred_[a-z_0-9]+|soft_[a-z_0-9]+)=' "$T/data/config.conf"; then
  bad "恢复默认不应留下退役参数"
else
  ok "恢复默认已清理退役参数"
fi
check "max_ma=20000"    "$(grep '^max_ma=' "$T/data/config.conf" | cut -d= -f2)" "20000"
if run set power_mode 0 >/dev/null 2>&1; then bad "退役控制模式不可set"; else ok "退役控制模式不可set"; fi
check "power_max_w=0" "$(grep '^power_max_w=' "$T/data/config.conf" | cut -d= -f2)" "0"

echo "== 保留项 =="
grep -q '^# 用户注释：这一行必须活下来$' "$T/data/config.conf" \
  && ok "注释保留" || bad "注释被吃掉"
check "未知用户键保留" "$(grep '^unknown_user_key=' "$T/data/config.conf" | cut -d= -f2)" keep
check "退役行的注释保留" "$(grep -c '^# 退役参数的说明仍然保留$' "$T/data/config.conf")" 1
check "cfg_version 不被默认值覆盖" "$(grep '^cfg_version=' "$T/data/config.conf" | cut -d= -f2)" "6"

echo "== 权限 =="
check "仍是 0600" "$(stat -c '%a' "$T/data/config.conf")" "600"

echo "== 字符串键不开放 set =="
run set mca_tag evil >/dev/null 2>&1 && R=0 || R=$?
check "set mca_tag 被拒" "$R" "3"

echo "== 长行保持与读取失败 =="
python3 -I - "$T/data/config.conf" <<'PY'
from pathlib import Path
import sys

config = Path(sys.argv[1])
comment = b"#" + b"x" * 510 + b"enabled=0\n"
unknown = b"unknown_user_key=" + b"z" * 2048 + b"\n"
config.write_bytes(comment + unknown + b"cfg_version=6\npred_alpha=0.2\n")
config.with_suffix(".expected").write_bytes(comment + unknown + b"cfg_version=6\n")
PY
check "长注释不能被解析成停用配置" "$(run config-int enabled)" "enabled=1"
run defaults --apply >/dev/null
if python3 -I - "$T/data/config.conf" <<'PY'
from pathlib import Path
import sys

config = Path(sys.argv[1])
assert config.read_bytes().startswith(config.with_suffix(".expected").read_bytes())
PY
then ok "恢复默认逐字保留长注释与未知行"; else bad "恢复默认改坏长行"; fi
check "长注释续块不能停用模块" "$(run config-int enabled)" "enabled=1"

# 目录可被 fopen 但不能作为配置读取；失败必须保留原目标，不能 rename 覆盖。
mkdir "$T/data/unreadable-config"
if TC_DATA="$T/data" TC_CONFIG="$T/data/unreadable-config" "$TC" set target_temp 42 >/dev/null 2>&1; then
  bad "读取配置失败必须拒绝写入"
else
  ok "读取配置失败拒绝写入"
fi
[ -d "$T/data/unreadable-config" ] && ok "读取失败不替换原目标" || bad "原目标被替换"

echo "== 结果 =="
echo "  通过 $PASS 项, 失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
