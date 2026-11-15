#!/usr/bin/env sh
# ThermoCharge 守护进程构建脚本
#
# 干什么:
#   1. 交叉编译 src/thermocharge.c -> out/thermocharge
#   2. 用 patchelf 剥掉工具链自动注入的 RPATH/RUNPATH
#   3. 冒烟测试 (--version / help)
#   4. --install 时同步进 module/bin/ 并核对 hash
#
# 为什么要剥 RPATH:
#   Termux / Android Studio 的 clang wrapper 会硬塞 -rpath $PREFIX/lib
#   (为了让宿主机上的测试程序能找到 libc++)。产物在真机上照常运行,
#   但会破坏可复现性: 换台机器/换安装路径编出来的 hash 就不同。
#   --disable-new-dtags / -z nodefaultlib / -nostdlib++ 都压不住它,
#   只有事后抹掉 dynstr 里那条记录, 或者换一个不注入的工具链。
#
# 用法:
#   sh build.sh            # 构建到 out/, 不动模块
#   sh build.sh --install  # 构建并同步进 module/bin/
#
# 环境变量:
#   CC             交叉编译器 (默认自动探测 aarch64-linux-android-clang)
#   TMPDIR         构建中间目录的父目录 (Android 上 /storage 不能执行,
#                  所以必须在临时目录里编译+测试, 最后才拷出去)

set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

SRC=src/thermocharge.c
OUT=out/thermocharge
INSTALL_BIN=module/bin/thermocharge

DO_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $arg (见 sh build.sh --help)" >&2; exit 2 ;;
    esac
done

[ -f "$SRC" ] || { echo "错误: 找不到 $SRC" >&2; exit 1; }

# ---- 选编译器 ----
CC_BIN=${CC:-}
TARGET_FLAGS=
if [ -z "$CC_BIN" ]; then
    if command -v aarch64-linux-android-clang >/dev/null 2>&1; then
        CC_BIN=aarch64-linux-android-clang
    elif command -v clang >/dev/null 2>&1; then
        CC_BIN=clang
        TARGET_FLAGS=--target=aarch64-linux-android24
    else
        echo "错误: 既没有 aarch64-linux-android-clang 也没有 clang" >&2
        echo "       (Termux: pkg install clang; 或用 CC=/path/to/ndk-clang 指定)" >&2
        exit 1
    fi
fi

# 版本号是编译进二进制的, 先打出来便于核对
VER=$(sed -n 's/^#define TC_VERSION "\(.*\)"/\1/p' src/thermocharge.c | head -1)
[ -n "$VER" ] || { echo "错误: $SRC 里没有 #define TC_VERSION" >&2; exit 1; }
echo "源码版本: $VER"
echo "编译器:   $CC_BIN${TARGET_FLAGS:+ $TARGET_FLAGS}"

# ---- 临时构建目录 (必须在可执行的位置) ----
BASE=${TMPDIR:-/data/data/com.termux/files/usr/tmp}
if [ ! -d "$BASE" ] || [ ! -w "$BASE" ]; then
    echo "错误: 临时目录不可写: $BASE (设 TMPDIR 指向一个可执行目录)" >&2
    exit 1
fi
STAGE=$(mktemp -d "$BASE/tc-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM

# Android 上 /system/lib64 提供 libc/libm/libdl 的链接期影子;
# 非 Android 构建机 (NDK sysroot) 上这个目录不存在, 就不加
RPATH_LINK=
[ -d /system/lib64 ] && RPATH_LINK="-Wl,-rpath-link,/system/lib64"

echo "--- 编译 ---"
$CC_BIN $TARGET_FLAGS -O2 $RPATH_LINK -Wl,--disable-new-dtags \
    "$SRC" -lm -o "$STAGE/thermocharge"

# ---- 剥 RPATH ----
echo "--- 剥 RPATH ---"
if command -v patchelf >/dev/null 2>&1; then
    patchelf --remove-rpath "$STAGE/thermocharge"
else
    echo "警告: 没有 patchelf (pkg install patchelf)。产物将保留工具链 RPATH:" >&2
    echo "      真机仍可运行, 但 hash 不可复现, 换机器构建会对不上。" >&2
fi

# ---- 校验 ----
if command -v readelf >/dev/null 2>&1; then
    if readelf -d "$STAGE/thermocharge" | grep -qiE '\((RPATH|RUNPATH)\)'; then
        echo "错误: 产物仍带 RPATH/RUNPATH:" >&2
        readelf -d "$STAGE/thermocharge" | grep -iE '\((RPATH|RUNPATH)\)' >&2
        exit 1
    fi
    echo "校验: 动态段无 RPATH/RUNPATH ✔"
else
    echo "警告: 没有 readelf, 跳过 RPATH 校验" >&2
fi

# ---- 冒烟测试 ----
# 只有跑在 aarch64 Android 上才执行得了; 在 PC 上构建时静默跳过
if V=$("$STAGE/thermocharge" --version 2>/dev/null); then
    if [ "$V" = "$VER" ]; then
        echo "冒烟: --version = $V ✔"
    else
        echo "错误: 二进制版本 $V 与源码 $VER 不一致" >&2
        exit 1
    fi
    "$STAGE/thermocharge" help >/dev/null 2>&1 || { echo "错误: help 失败" >&2; exit 1; }
    echo "冒烟: help ✔"
else
    echo "冒烟: 跳过 (本机无法执行 aarch64-android 产物)"
fi

# ---- 落地 ----
mkdir -p out
cp "$STAGE/thermocharge" "$OUT"
chmod 0755 "$OUT" 2>/dev/null || true

if [ "$DO_INSTALL" = 1 ]; then
    mkdir -p module/bin
    cp "$OUT" "$INSTALL_BIN"
    chmod 0755 "$INSTALL_BIN" 2>/dev/null || true
    cmp "$OUT" "$INSTALL_BIN" || { echo "错误: 模块内二进制与 out/ 不一致" >&2; exit 1; }
    echo "已同步: $INSTALL_BIN (逐字节一致)"
elif [ -f "$INSTALL_BIN" ] && ! cmp -s "$OUT" "$INSTALL_BIN"; then
    # 只构建不安装时提醒一句: 打出来的 ZIP 用的是 module/bin/, 不是 out/
    echo "注意: module/bin/thermocharge 与 out/ 不一致 (打包会用 module/ 那份)" >&2
    echo "      要更新模块请跑: sh build.sh --install" >&2
fi

echo "--- 产物 ---"
ls -l "$OUT"
sha256sum "$OUT"
[ "$DO_INSTALL" = 1 ] && sha256sum "$INSTALL_BIN"
echo "完成。"
