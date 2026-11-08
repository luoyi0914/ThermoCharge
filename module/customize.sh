#!/system/bin/sh
# KernelSU / Magisk 安装脚本
#
# v1.2.0 变化:
#   - 迁移改成按键名逐项判断「值仍等于旧默认值才更新」, 不再靠整行字符串 sed
#     (旧写法会把用户特意设成 15000 的值也改回 20000, 且带空格的
#      `max_ma = 15000` 匹配不到)
#   - 用 cfg_version 记录迁移进度, 模块自带的 config.conf 里也写这个键,
#     否则"是否迁移过"的判断每次升级都成立, 迁移会反复重跑
#   - 补全所有文件的权限(zip 不保留 mode 位, 之前只设了三个)
#   - 安装末尾做一次 --version 冒烟测试, 二进制跑不起来就直接 abort

SKIPUNZIP=0

ui_print "- 恒温充电 ThermoCharge"
ui_print "- 设备: $(getprop ro.product.marketname 2>/dev/null)"

ABI=$(getprop ro.product.cpu.abi)
if [ "$ABI" != "arm64-v8a" ]; then
  ui_print "! 需要 arm64-v8a, 当前 $ABI"
  abort "! 架构不支持"
fi

# zip 不保留执行位, 这里逐个设一遍(不只是 bin 和两个 sh)
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
for f in service.sh uninstall.sh post-fs-data.sh customize.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done
[ -f "$MODPATH/module.prop" ] && set_perm "$MODPATH/module.prop" 0 0 0644
[ -f "$MODPATH/config.conf" ] && set_perm "$MODPATH/config.conf" 0 0 0644

DATA=/data/adb/thermocharge
CF=$DATA/config.conf

# cf_has KEY -> 配置里有没有这个键
cf_has() { grep -q "^[[:space:]]*$1[[:space:]]*=" "$CF" 2>/dev/null; }

# cf_get KEY -> 打印值(去掉首尾空白)
cf_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CF" 2>/dev/null \
    | head -1 | tr -d ' \t\r'
}

# cf_set KEY VALUE -> 换掉已有行, 没有就追加
cf_set() {
  if cf_has "$1"; then
    sed -i "s|^[[:space:]]*$1[[:space:]]*=.*|$1=$2|" "$CF"
  else
    echo "$1=$2" >> "$CF"
  fi
}

# upgrade_one KEY OLDVAL NEWVAL -> 只有当值仍是旧默认值时才改
upgrade_one() {
  if cf_has "$1"; then
    cur=$(cf_get "$1")
    if [ "$cur" = "$2" ]; then
      cf_set "$1" "$3"
      ui_print "  $1: $2 -> $3"
    fi
  else
    cf_set "$1" "$3"
    ui_print "  $1: (缺) -> $3"
  fi
}

if [ ! -f "$CF" ]; then
  mkdir -p "$DATA/log"
  cp "$MODPATH/config.conf" "$CF"
  chmod 0600 "$CF"
  ui_print "- 已写入默认配置 $CF"
else
  ui_print "- 保留已有配置, 检查是否需要迁移"

  # 备份一份, 迁移出问题能回滚
  cp -f "$CF" "$CF.bak" 2>/dev/null

  CV=$(cf_get cfg_version)
  [ -z "$CV" ] && CV=0

  if [ "$CV" -lt 2 ] 2>/dev/null; then
    ui_print "- 迁移到 v1.1.0"
    # 原厂快充就是 17.6A, 旧的 15000 上限白让了功率
    upgrade_one max_ma            15000  20000
    # 插电瞬间写限流会打断快充握手/CP 起泵
    upgrade_one startup_grace_ms  1500   20000
  fi

  if [ "$CV" -lt 3 ] 2>/dev/null; then
    ui_print "- 迁移到 v1.2.0"
    # 新增: 同值重投间隔(系统可能把我们的票关掉)
    if ! cf_has reassert_ms; then
      cf_set reassert_ms 5000
      ui_print "  reassert_ms: (缺) -> 5000"
    fi
  fi

  cf_set cfg_version 3
  ui_print "- 配置版本 $CV -> 3"
fi

# 冒烟测试: 二进制跑不起来就别让用户带着一个坏模块重启
if [ -x "$MODPATH/bin/thermocharge" ]; then
  V=$("$MODPATH/bin/thermocharge" --version 2>/dev/null)
  if [ -z "$V" ]; then
    ui_print "! 二进制无法执行, 模块已安装但不会工作"
    abort "! thermocharge --version 失败"
  fi
  ui_print "- 二进制自检通过 (v$V)"
else
  abort "! 找不到 bin/thermocharge"
fi

TGT=$(cf_get target_temp); [ -z "$TGT" ] && TGT=43.0
HRD=$(cf_get hard_temp);   [ -z "$HRD" ] && HRD=45.0
ui_print "- 目标温度 ${TGT}C, 上限 ${HRD}C"
ui_print "- 重启生效"
