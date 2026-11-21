#!/system/bin/sh
# KernelSU / Magisk 安装脚本 v1.4.0
#
# cfg_version=7：仅保留电池温度趋势控制，移除旧控制律及环境模型配置。
# 迁移保留用户温度/电流/功率上限和安全开关；失败回滚，不运行任何充电控制。

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
# 不能只查字符白名单：科学计数法也可能是用户保留的温度/电流边界。
num_eq() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    if (a !~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/) exit 1
    exit !(a + 0 == b + 0)
  }'
}

# cf_set KEY VALUE -> 改掉所有同名行，没有就追加
# 统一走 "awk 写临时文件再 rename"，三个原因：
#   1) 追加分支不能直接 echo >>：原文件如果缺尾换行，新键会粘到最后一行上
#      （例如 `mca_type=allpower_max_w=0`），整行失效，mca 投票类型被写坏；
#   2) 同名重复行全部改写成同一个值，与 cfg_load 的覆盖语义对齐；
#   3) rename 换 inode 后按 umask 会变 0644，这里补回安装时设的 0600。
cf_set() {
  if [ ! -f "$CF" ]; then
    if ! { : > "$CF" && chmod 0600 "$CF" 2>/dev/null; }; then
      MIG_FAIL=1
      return
    fi
  fi
  # 临时文件名带 pid：升级安装期间用户可能同时在 WebUI 点「恢复默认配置」，
  # 两边都写同一个 .tmp 会互相截断，最后 rename 出去的是混合内容。
  tmp="$CF.tmp.$$"
  if awk -v k="$1" -v val="$2" '
    BEGIN { re = "^[ \t]*" k "[ \t]*="; found = 0 }
    $0 ~ re { print k "=" val; found = 1; next }
    { print }
    END { if (!found) print k "=" val }' "$CF" > "$tmp"; then
    if ! chmod 0600 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$CF"; then
      MIG_FAIL=1
    fi
  else
    MIG_FAIL=1
  fi
  [ -f "$tmp" ] && rm -f "$tmp"
  :
}

# 删除已退役的参数行；逐键匹配，其他配置与用户注释原样保留。
remove_legacy_config() {
  tmp="$CF.tmp.$$"
  if awk '
    { raw=$0; probe=$0; sub(/#.*/, "", probe); eq=index(probe,"=");
      key=substr(probe,1,eq-1); gsub(/^[ \t\r]+|[ \t\r]+$/, "", key) }
    eq && (key ~ /^(power_mode|kp|ki|kd|deadband|tdot_tau_s|min_regulate_ma)$/ || key ~ /^(pred_|soft_)/) {
      hash=index(raw,"#"); if (hash) print substr(raw,hash); next
    }
    { print }' "$CF" > "$tmp"; then
    if ! chmod 0600 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$CF"; then
      MIG_FAIL=1
    fi
  else
    MIG_FAIL=1
  fi
  [ ! -f "$tmp" ] || rm -f "$tmp"
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
    # 档案只可调整仍在使用的温度/电流边界与限速，旧模型键不能重新写回。
    case "$k" in target_temp|hard_temp|max_ma|min_ma|slew_ma_s) ;; *) continue ;; esac
    [ -n "$v" ] || continue
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
  # 默认配置与档案先在私有副本上完成，失败不发布半份新配置。
  final_cf=$CF
  CF="$CF.new.$$"
  if ! mkdir -p "$DATA/log" || ! cp "$MODPATH/config.conf" "$CF" || ! chmod 0600 "$CF"; then
    rm -f "$CF"
    abort "! 默认配置创建失败, 未发布新配置"
  fi
  MIG_FAIL=0
  apply_profile
  if [ "$MIG_FAIL" = "1" ] || ! mv -f "$CF" "$final_cf"; then
    rm -f "$CF"
    abort "! 机型配置写入失败, 未发布新配置"
  fi
  CF=$final_cf
  ui_print "- 已写入默认配置 $CF"
else
  ui_print "- 保留已有配置, 检查是否需要迁移"

  # 备份成功后才允许迁移，否则失败时无可靠原件可回滚。
  cp -f "$CF" "$CF.bak" 2>/dev/null || abort "! 配置备份失败, 未修改原配置"
  MIG_FAIL=0

  CV=$(cf_get cfg_version)
  [ -z "$CV" ] && CV=0
  # 归一成整数再比较。`cfg_version=5.0` / `abc` 这类值会让 `[ "5.0" -lt N ]`
  # 直接报错，错误被 2>/dev/null 吞掉后**所有迁移块都跳过**，而末尾照样写
  # 错误版本号并跳过必需迁移。
  # 非法值按 0 处理，与"缺键当 0"的既有意图一致。
  CV=$(awk -v v="$CV" 'BEGIN {
    if (v ~ /^[0-9]+(\.[0-9]+)?$/) printf "%d", v; else print 0
  }')

  if [ "$CV" -lt 2 ] 2>/dev/null; then
    ui_print "- 迁移到 v1.1.0"
    # 已存在的电流上限不因历史默认值迁移而提高，缺失时才补入。
    if ! cf_has max_ma; then cf_set max_ma 20000; fi
    # 仅补缺省项，不再把用户的 1.5 秒等待迁回旧默认 20 秒。
    if ! cf_has startup_grace_ms; then cf_set startup_grace_ms 1500; fi
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

  # 旧预测/软着陆/PID 不再运行，不再迁移或自动开启这些参数。
  # 无论已有配置版本号是否损坏，退役键都不能重新激活旧功能。
  remove_legacy_config
  if ! cf_has power_max_w; then cf_set power_max_w 0; fi

  # 迁移完成后再套机型档案：新装时就是机型参数，升级时只补缺失键和
  # 仍是通用默认值的键，用户自己整定过的值不动。
  apply_profile

  # 版本号也是一次配置写入，必须纳入同一失败检查。
  if [ "$CV" -le 7 ] 2>/dev/null && [ "$MIG_FAIL" = "0" ]; then
    cf_set cfg_version 7
  fi
  # 任一写入失败都不得标记迁移完成；回滚备份并中止安装。
  if [ "$MIG_FAIL" = "1" ]; then
    ui_print "! 配置迁移写入失败, 正在从备份恢复"
    if ! cp -f "$CF.bak" "$CF" 2>/dev/null || ! chmod 0600 "$CF"; then
      abort "! 配置回滚失败, 原始备份保留在 $CF.bak"
    fi
    abort "! 配置迁移失败 (/data/adb/thermocharge 不可写?)"
  fi

  if [ "$CV" -gt 7 ] 2>/dev/null; then
    # 用旧版模块覆盖新版配置时不要做"降级标记"，但退役键仍已清理。
    ui_print "- 配置版本 $CV 高于本模块支持的 7, 保留原版本号"
  else
    ui_print "- 配置版本 $CV -> 7"
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
