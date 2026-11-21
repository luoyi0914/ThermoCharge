#!/usr/bin/env sh
# service.sh 的"应用冻结组"守卫必须在两种控制组上给出不同结论：
#   - KernelSU 开机执行时在 memory:/apps 根上 —— 必须放行（v1.3.16 曾一刀切拦死开机）
#   - 应用内 setsid 起的进程落在 /apps/uid_NNN/pid_NNN 叶子组 —— 必须拒绝
#
# 直接从 module/service.sh 里抽出 in_app_leaf() 来测（不抄副本），
# 用 TC_CGROUP_FILE 指向夹具文件，不依赖本机 cgroup 布局。
#
# 用法：sh tests/cli/test_service_guard.sh

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SVC=$ROOT/module/service.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/svc-guard.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

awk '/^in_app_leaf\(\) \{/{p=1} p; p && /^}/{exit}' "$SVC" > "$WORK/fn.sh"
[ -s "$WORK/fn.sh" ] || { echo "抽取 in_app_leaf 失败"; exit 1; }

pass=0
fail=0
check() { # $1=描述 $2=夹具内容 $3=期望返回值（0=判定为应用叶子组并拦截，1=放行）
    printf '%b' "$2" > "$WORK/cg"
    if sh -c '. "$1"; in_app_leaf "$2"' sh "$WORK/fn.sh" "$WORK/cg"; then got=0; else got=1; fi
    if [ "$got" = "$3" ]; then
        echo "  ✓ $1"; pass=$((pass + 1))
    else
        echo "  ✗ $1: 期望返回值 $3，实际 $got"; fail=$((fail + 1))
    fi
}

echo "== 应用冻结组守卫 =="
check "KernelSU 开机：memory:/apps 根，必须放行" '4:memory:/apps\n0::/\n' 1
check "应用内启动：uid/pid 叶子组，必须拒绝" '4:memory:/apps/uid_10341/pid_8225\n0::/apps/uid_10341/pid_8225\n' 0
check "只有 cpuset 命中叶子组也拒绝" '3:cpuset:/apps/uid_10341/pid_8225\n4:memory:/apps\n' 0
check "开机 init 服务：全根路径放行" '4:memory:/\n1:blkio:/\n0::/\n' 1
check "另一个应用的叶子组同样拒绝" '4:memory:/apps/uid_103410/pid_9000\n' 0
check "uid 后缀带字母不误判" '4:memory:/apps/uid_10341x/pid_9000\n' 1
check "/apps 下的非 uid 路径放行" '4:memory:/apps/other_thing\n' 1

echo
echo "== 结果 =="
echo "  通过 $pass 项, 失败 $fail 项"
[ "$fail" -eq 0 ]
