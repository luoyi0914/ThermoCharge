#!/bin/sh
# test_cfg_num.sh —— supervisor 的 cfg_num 必须与守护进程 cfg_load 的取值一致
#
# 最小复现：enabled=0 后跟 enabled=0.0。C 跳过无效行而退出 3，
# 旧 cfg_num 却返回默认值 1，使 supervisor 不经等待就重拉。
#
# 用法：sh tests/cli/test_cfg_num.sh

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SVC=$ROOT/module/service.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cfgnum.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

BIN=$WORK/thermocharge
cp "${TC_TEST_BINARY:-$ROOT/out/thermocharge}" "$BIN" || exit 1
chmod 755 "$BIN" || exit 1
# 抽出真正运行的 supervisor 包装层，调用同版本守护进程的配置解析器。
awk '/^cfg_num\(\) \{/{p=1} p; p && /^}/{exit}' "$SVC" > "$WORK/fn.sh"
[ -s "$WORK/fn.sh" ] || { echo "抽取 cfg_num 失败"; exit 1; }
CONF=$WORK/c.conf
export CONF BIN

pass=0; fail=0
check() {  # $1=描述 $2=配置内容(printf 格式) $3=键 $4=默认值 $5=期望
  printf '%b' "$2" > "$CONF"
  got=$(sh -c '. "$1"; cfg_num "$2"' sh "$WORK/fn.sh" "$3")
  if [ "$got" = "$5" ]; then
    echo "  ✓ $1 -> $got"; pass=$((pass+1))
  else
    echo "  ✗ $1: 期望 $5，实际 $got"; fail=$((fail+1))
  fi
}

echo "== cfg_num 与守护进程一致 =="
check "单行 0"                       'enabled=0\n'            enabled 1 0
check "0 在前、无效 0.0 在后"         'enabled=0\nenabled=0.0\n' enabled 1 0
check "1、0、无效 abc 依次出现"       'enabled=1\nenabled=0\nenabled=abc\n' enabled 1 0
check "有效值在后覆盖前面的"           'enabled=0\nenabled=1\n' enabled 1 1
check "空值视为缺失，取默认"           'enabled=\n'             enabled 1 1
check "00 按 0 处理"                  'enabled=00\n'           enabled 1 0
check "行内注释"                      'enabled=0 # 停用\n'     enabled 1 0
check "CRLF 行尾"                     'enabled=0\r\n'          enabled 1 0
check "键不存在取默认"                 'other=1\n'              enabled 1 1
check "内部空白不是合法整数"          'enabled=0\nenabled=0 1\n' enabled 1 0
check "越界值不覆盖 0"                'enabled=0\nenabled=2147483648\n' enabled 1 0
check "最小整数可解析"                'enabled=-2147483648\n' enabled 1 -2147483648
check "接管开关沿用最后有效值"         'thermal_remove=1\nthermal_remove=abc\n' thermal_remove 0 1
check "非零整数按接管处理"            'thermal_remove=+2\n' thermal_remove 0 2
check "演练模式不能接管"               'thermal_remove=1\ndry_run=1\n' thermal_remove 0 0
printf 'power_mode=0\npred_enable=1\npred_ambient=55\n' > "$CONF"
if TC_CONFIG="$CONF" "$BIN" config-int power_mode >/dev/null 2>&1; then
  echo '  ✗ 旧控制模式键不应再导出'; fail=$((fail+1))
else
  rc=$?
  if [ "$rc" = 2 ]; then echo '  ✓ 旧控制模式键已移除'; pass=$((pass+1))
  else echo "  ✗ 旧模式键应返回2，实际$rc"; fail=$((fail+1)); fi
fi
check "功率上限跳过越界值"            'power_max_w=20\npower_max_w=121\n' power_max_w 0 20

echo
echo "== 结果 =="
echo "  通过 $pass 项, 失败 $fail 项"
[ "$fail" -eq 0 ]
