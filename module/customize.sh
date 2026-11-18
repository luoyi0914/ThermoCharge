#!/system/bin/sh
# KernelSU / Magisk 安装脚本
#
# v1.2.0 变化（v1.2.3 仅新增 cfg_version 4 迁移，见下方 98 行附近）:
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
ui_print "- 交流群: 377709300 (QQ)"

ABI=$(getprop ro.product.cpu.abi)
if [ "$ABI" != "arm64-v8a" ]; then
  ui_print "! 需要 arm64-v8a, 当前 $ABI"
  abort "! 架构不支持"
fi

# zip 不保留执行位, 这里逐个设一遍(不只是 bin 和两个 sh)
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
[ -d "$MODPATH/tools" ] && set_perm_recursive "$MODPATH/tools" 0 0 0755 0755
for f in service.sh watchdog.sh uninstall.sh post-fs-data.sh customize.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done
[ -f "$MODPATH/module.prop" ] && set_perm "$MODPATH/module.prop" 0 0 0644
[ -f "$MODPATH/config.conf" ] && set_perm "$MODPATH/config.conf" 0 0 0644

DATA=/data/adb/thermocharge
CF=$DATA/config.conf

# cf_has KEY -> 配置里有没有这个键
cf_has() { grep -q "^[[:space:]]*$1[[:space:]]*=" "$CF" 2>/dev/null; }

# cf_get KEY -> 打印值(去掉首尾空白)
# 取最后一处，与 cfg_load 逐行赋值的覆盖语义一致；否则配置里有重复键时，
# 迁移判断看的是第一处、守护进程用的是最后一处，两边会相反。
cf_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CF" 2>/dev/null \
    | sed 's/#.*//' | tr -d ' \t\r' | awk 'length { v = $0 } END { print v }'
}

# num_eq VALUE EXPECTED -> 数值相等（15 / 15.0 / 1.5e1 视为同一个值）
# 格式先用正则卡死（十进制，可带指数），与 cfg_load 的 strtod 接受范围对齐；
# 不能只查字符白名单：那会把 6e-2 判成非数字，α 的旧值就漏掉不迁移了。
num_eq() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    if (a !~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/) exit 1
    exit !(a + 0 == b + 0)
  }'
}

# cf_set KEY VALUE -> 改掉所有同名行，没有就追加
# 统一走 "awk 写临时文件再 rename"，三个原因：
#   1) 追加分支不能直接 echo >>：原文件如果缺尾换行，新键会粘到最后一行上
#      （`mca_type=allpred_enable=1`），整行失效，mca 投票类型被写坏；
#   2) 同名重复行全部改写成同一个值，与 cfg_load 的覆盖语义对齐；
#   3) rename 换 inode 后按 umask 会变 0644，这里补回安装时设的 0600。
cf_set() {
  [ -f "$CF" ] || { : > "$CF"; chmod 0600 "$CF" 2>/dev/null; }
  # 临时文件名带 pid：升级安装期间用户可能同时在 WebUI 点「恢复默认配置」，
  # 两边都写同一个 .tmp 会互相截断，最后 rename 出去的是混合内容。
  tmp="$CF.tmp.$$"
  if awk -v k="$1" -v val="$2" '
    BEGIN { re = "^[ \t]*" k "[ \t]*="; found = 0 }
    $0 ~ re { print k "=" val; found = 1; next }
    { print }
    END { if (!found) print k "=" val }' "$CF" > "$tmp"; then
    chmod 0600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$CF" || MIG_FAIL=1
  else
    MIG_FAIL=1
  fi
  [ -f "$tmp" ] && rm -f "$tmp"
  :
}

# upgrade_one KEY OLDVAL NEWVAL -> 只有当值仍是旧默认值时才改
upgrade_one() {
  if cf_has "$1"; then
    cur=$(cf_get "$1")
    if num_eq "$cur" "$2"; then
      cf_set "$1" "$3"
      ui_print "  $1: $cur -> $3"
    fi
  else
    cf_set "$1" "$3"
    ui_print "  $1: (缺) -> $3"
  fi
}

# pf_get FILE KEY -> 从任意 key=value 文件取最后一处值（剥行尾注释、去空白）
pf_get() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null \
    | sed 's/#.*//' | tr -d ' \t\r' | awk 'length { v = $0 } END { print v }'
}

PROFILE_DIR=$MODPATH/profiles
PROFILE_DEFAULT=k90-ultra

# 机型参数档案：按 ro.product.* 识别，匹配不到回退到 PROFILE_DEFAULT。
# 只在「键缺失」或「值仍等于 module/config.conf 的通用默认值」时覆盖，
# 用户手调过的值必须保留 —— 否则每次升级都会把整定结果冲掉。
apply_profile() {
  DEVICE_MODEL="$(getprop ro.product.marketname 2>/dev/null) $(getprop ro.product.model 2>/dev/null) $(getprop ro.product.device 2>/dev/null) $(getprop ro.product.name 2>/dev/null)"
  DEVICE_MODEL=$(printf '%s' "$DEVICE_MODEL" | tr -s ' ' | sed 's/^ //; s/ $//')
  [ -n "$DEVICE_MODEL" ] || DEVICE_MODEL="unknown"

  MODEL_LC=$(printf '%s' "$DEVICE_MODEL" | tr 'A-Z' 'a-z')
  # pf_get 读 match 时会把空格剥掉（它本来是为数值键设计的），
  # 所以机型串也做同样的去空格归一，两边才比得上：K90 Pro Max ↔ K90ProMax
  MODEL_NS=$(printf '%s' "$MODEL_LC" | tr -d ' \t')
  PROF_FILE=""
  if [ -d "$PROFILE_DIR" ]; then
    for f in "$PROFILE_DIR"/*.conf; do
      [ -f "$f" ] || continue
      match=$(pf_get "$f" match)
      [ -n "$match" ] || continue
      oldifs=$IFS
      IFS='|'
      for pat in $match; do
        pat_lc=$(printf '%s' "$pat" | tr 'A-Z' 'a-z')
        [ -n "$pat_lc" ] || continue
        case "$MODEL_NS" in
          *"$pat_lc"*) PROF_FILE=$f; break ;;
        esac
      done
      IFS=$oldifs
      [ -n "$PROF_FILE" ] && break
    done
    # 没有匹配机型：所有设备都用默认档案（当前是 K90 Ultra）
    [ -n "$PROF_FILE" ] || PROF_FILE="$PROFILE_DIR/$PROFILE_DEFAULT.conf"
  fi

  if [ -z "$PROF_FILE" ] || [ ! -f "$PROF_FILE" ]; then
    ui_print "- 未找到机型参数档案, 使用模块默认配置"
    return 0
  fi
  PROF_NAME=$(basename "$PROF_FILE" .conf)

  CHANGED=0
  while IFS= read -r pline || [ -n "$pline" ]; do
    pline=${pline%%#*}
    case "$pline" in *=*) ;; *) continue ;; esac
    k=$(printf '%s' "${pline%%=*}" | tr -d ' \t\r')
    v=$(printf '%s' "${pline#*=}" | tr -d ' \t\r')
    [ "$k" = "match" ] && continue
    [ -n "$k" ] && [ -n "$v" ] || continue
    cur=$(cf_get "$k")
    def=$(pf_get "$MODPATH/config.conf" "$k")
    if ! cf_has "$k"; then
      cf_set "$k" "$v"
      ui_print "  $k: (缺) -> $v"
      CHANGED=$((CHANGED+1))
    elif [ -z "$cur" ]; then
      # 空值在 cfg_load 里等于"没写"，会回退默认值；机型档案同样应该填上
      cf_set "$k" "$v"
      ui_print "  $k: (空) -> $v"
      CHANGED=$((CHANGED+1))
    elif [ -n "$def" ] && num_eq "$cur" "$def"; then
      cf_set "$k" "$v"
      ui_print "  $k: $cur -> $v"
      CHANGED=$((CHANGED+1))
    fi
  done < "$PROF_FILE"
  ui_print "- 机型: $DEVICE_MODEL"
  ui_print "- 参数档案: $PROF_NAME (应用 $CHANGED 项)"

  mkdir -p "$DATA" 2>/dev/null
  {
    printf 'model=%s\n' "$DEVICE_MODEL"
    printf 'profile=%s\n' "$PROF_NAME"
  } > "$DATA/device.profile" 2>/dev/null && chmod 0644 "$DATA/device.profile" 2>/dev/null
  return 0
}

if [ ! -f "$CF" ]; then
  mkdir -p "$DATA/log"
  cp "$MODPATH/config.conf" "$CF"
  chmod 0600 "$CF"
  ui_print "- 已写入默认配置 $CF"
  MIG_FAIL=0
  apply_profile
  [ "$MIG_FAIL" = "1" ] && ui_print "! 机型参数写入失败, 保留默认配置"
else
  ui_print "- 保留已有配置, 检查是否需要迁移"

  # 备份一份, 迁移出问题能回滚
  cp -f "$CF" "$CF.bak" 2>/dev/null
  MIG_FAIL=0

  CV=$(cf_get cfg_version)
  [ -z "$CV" ] && CV=0
  # 归一成整数再比较。`cfg_version=5.0` / `abc` 这类值会让 `[ "5.0" -lt N ]`
  # 直接报错，错误被 2>/dev/null 吞掉后**所有迁移块都跳过**，而末尾照样写
  # cfg_version=6 —— 危险参数（kd=15 等）原样留着，以后重装也不会再迁。
  # 非法值按 0 处理，与"缺键当 0"的既有意图一致。
  CV=$(awk -v v="$CV" 'BEGIN {
    if (v ~ /^[0-9]+(\.[0-9]+)?$/) printf "%d", v; else print 0
  }')

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

  if [ "$CV" -lt 4 ] 2>/dev/null; then
    ui_print "- 迁移到 v1.2.3"
    # 只有仍是旧默认值时才切双通道；缺失键补入新默认，其他自定义值保留。
    upgrade_one ctl_mode 1 2
  fi

  if [ "$CV" -lt 5 ] 2>/dev/null; then
    ui_print "- 迁移到 v1.3.9"
    # 预测限幅与软着陆改为默认开启。
    # 与上面的 upgrade_one 不同，这里**不保留旧值**：这两层从 v1.2.1 起
    # 一直默认关闭，配置里那个 0 很可能只是"从没动过"，不是有意的选择。
    # 用户装完后仍可在 WebUI 里单独关掉。
    cf_set pred_enable 1
    cf_set soft_landing 1
    # 落点必须先有，否则 cfg_load 会把 soft_landing 判为失效并关闭
    MR=$(cf_get min_regulate_ma)
    if [ -z "$MR" ] || num_eq "$MR" 0; then
      cf_set min_regulate_ma 9000
    fi
    ui_print "  pred_enable -> 1, soft_landing -> 1"
  fi

  if [ "$CV" -lt 6 ] 2>/dev/null; then
    ui_print "- 迁移到 v1.3.10"
    # α：0 是"从没辨识过"，0.06 是 v1.3.9 引入的出厂估值，两者都换成 0.07
    # （本机三份独立拟合 0.0584 / 0.0753 / 0.0793 的中位数）。
    # 用户自己辨识/手调过的其他值一律保留。
    # τ 只在它还是旧默认（45）或缺失时补 300 —— 辨识过 τ 的不动。
    # 用数值比较：0.060 / 0.0 这类写法在字符串比较下会漏掉
    A=$(cf_get pred_alpha)
    if [ -z "$A" ] || num_eq "$A" 0 || num_eq "$A" 0.06; then
      cf_set pred_alpha 0.07
      T=$(cf_get pred_tau_s)
      if [ -z "$T" ] || num_eq "$T" 45; then cf_set pred_tau_s 300; fi
      ui_print "  pred_alpha: ${A:-（缺）} -> 0.07 (本机日志拟合值)"
    fi

    # kd 与 tdot_tau_s 是"小下去没人发现、但会直接导致振荡"的两个参数。
    # 实测：kd=15 / tdot_tau_s=12 时环路相位裕度只有 20~25°，
    # 闭环仿真峰值冲到 45.1℃（越过 hard_temp），而出厂 40/6 只到 42.8℃。
    # 这不是"手感偏好"，是有明确安全后果的配置，所以恢复默认。
    K=$(cf_get kd)
    if num_eq "$K" 15; then
      cf_set kd 40
      ui_print "  kd: $K -> 40 (阻尼不足会导致温度振荡到硬停)"
    fi
    D=$(cf_get tdot_tau_s)
    if num_eq "$D" 12; then
      cf_set tdot_tau_s 6.0
      ui_print "  tdot_tau_s: $D -> 6.0 (微分滞后同样吃相位裕度)"
    fi

    # max_ma 缩到 9000 会让控制器失去向上调节的余量：
    # 实测稳住 43℃ 需要约 8350mA，9000 只剩 8% 余量，
    # 36% 的时间顶部被顶死，环境一热就守不住温度。
    # 15000 约 65W，仍低于原厂 17600mA，但给了控制器真正的调节空间。
    M=$(cf_get max_ma)
    if num_eq "$M" 9000; then
      cf_set max_ma 15000
      ui_print "  max_ma: $M -> 15000 (留出调节余量；想锁功率请用 min_regulate_ma)"
    fi
  fi

  # 迁移完成后再套机型档案：新装时就是机型参数，升级时只补缺失键和
  # 仍是通用默认值的键，用户自己整定过的值不动。
  apply_profile

  # 任何一次写入失败都不能把版本号盖成 6：否则危险旧值（kd=15 等）会原样
  # 留着，而以后重装都认为"已迁移过"、不会再修。直接回滚到备份并中止安装。
  if [ "$MIG_FAIL" = "1" ]; then
    ui_print "! 配置迁移写入失败, 正在从备份恢复"
    cp -f "$CF.bak" "$CF" 2>/dev/null && chmod 0600 "$CF"
    abort "! 配置迁移失败 (/data/adb/thermocharge 不可写?)"
  fi

  if [ "$CV" -gt 6 ] 2>/dev/null; then
    # 用旧版模块覆盖新版配置时不要做"降级标记"，否则下次升级会重跑迁移、
    # 可能把用户在更高版本里调过的值改回旧默认
    ui_print "- 配置版本 $CV 高于本模块支持的 6, 保留原版本号、跳过迁移"
  else
    cf_set cfg_version 6
    ui_print "- 配置版本 $CV -> 6"
  fi
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

# 本版本更新日志（只含当前版本，由打包时从 CHANGELOG.md 截出）
if [ -f "$MODPATH/CHANGELOG-current.txt" ]; then
  ui_print "- ----- 本版本更新日志 -----"
  while IFS= read -r line || [ -n "$line" ]; do
    ui_print "$line"
  done < "$MODPATH/CHANGELOG-current.txt"
  ui_print "- --------------------------"
fi

ui_print "- 重启生效"
