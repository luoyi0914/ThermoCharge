#!/system/bin/sh
# 卸载时还原系统默认状态, 避免留下被限流的充电器
#
# 顺序: 守护进程优雅退出(它自己的 SIGTERM 会还原) -> 二进制 restore 兜底
#       -> 按配置里的 p_* 路径裸写兜底(不再写死官方路径)
#
# v1.2.0 变化:
#   - 用 `$BIN stop` 代替裸 kill, 它会等进程真退出
#   - restore 带 --force: 卸载时不管守护进程是否还在都必须真写
#   - 路径优先取 config.conf 里的 p_*, 用户改过路径也能正确还原
#   - 不再写 charge_enable(守护进程从不碰它, 写它反而可能改变系统行为)
#   - pkill 模式收窄, 只杀本模块目录下的二进制

MODDIR=${0%/*}
BIN=$MODDIR/bin/thermocharge
DATA=/data/adb/thermocharge
CONF=$DATA/config.conf

# 从配置里读路径, 读不到就用官方默认值
cfg_get() {
  # 取最后一处：cfg_load 逐行赋值，重复键以后出现的为准
  v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null \
      | sed 's/#.*//' | tr -d ' \t\r' | awk 'length { v = $0 } END { print v }')
  case "$v" in
    /*) echo "$v" ;;
    *)  echo "$2" ;;
  esac
}

P_CTL=$(cfg_get p_ctl    /sys/class/xm_power/charger/charger_thermal/wired_chg_curr)
P_ICHG=$(cfg_get p_ichg  /sys/class/xm_power/charger/charge_interface/ichg_limit)
P_SUSP=$(cfg_get p_suspend /sys/class/xm_power/charger/charge_interface/input_suspend)
P_TREM=$(cfg_get p_thermal_remove /sys/class/xm_power/charger/charger_thermal/wired_thermal_remove)
# 与守护进程实际写入的投票者/类型保持一致（用户可能改过 mca_tag/mca_type）
# 注意: cfg_get 只接受 / 开头的路径，这里用普通字符串读取
cfg_str() {
  v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null \
      | sed 's/#.*//' | tr -d ' \t\r' | awk 'length { v = $0 } END { print v }')
  [ -n "$v" ] && echo "$v" || echo "$2"
}
# 与 cfg_load 一致：空白换成下划线，避免投出 4 个 token 的畸形票
MCA_TAG=$(cfg_str mca_tag user  | tr -s ' \t' '_')
MCA_TYPE=$(cfg_str mca_type all | tr -s ' \t' '_')

# 0) 先停 supervisor 和看门狗：只停守护进程的话，supervisor 2 秒后会把
#    已删除的二进制再拉起来（或者 crash-loop），看门狗也可能重新写回节点。
SUP=$(cat "$DATA/supervisor.pid" 2>/dev/null)
if [ -n "$SUP" ] && [ -d "/proc/$SUP" ]; then
  case "$(tr '\0' ' ' < "/proc/$SUP/cmdline" 2>/dev/null)" in
    *service.sh*) kill -TERM "$SUP" 2>/dev/null ;;
  esac
fi
pkill -TERM -f "$MODDIR/watchdog.sh" 2>/dev/null

# 1) 让守护进程优雅退出并停下
if [ -x "$BIN" ]; then
  "$BIN" stop 2>/dev/null
fi

# pid 文件丢失时按命令行兜底(模式限定在本模块目录, 不会误杀)
pkill -TERM -f "$MODDIR/bin/thermocharge run" 2>/dev/null
sleep 0.3

# 2) 二进制还在就直接调 restore(--force: 守护进程不在也要真写)
[ -x "$BIN" ] && "$BIN" restore --force 2>/dev/null

# 3) 裸写兜底, 防止二进制损坏或缺失
echo 22000000 > "$P_CTL"   2>/dev/null
echo "$MCA_TAG $MCA_TYPE 22000" > "$P_ICHG" 2>/dev/null
echo "$MCA_TAG $MCA_TYPE 0" > "$P_SUSP"     2>/dev/null
# thermal_remove 只在守护进程真的接管过时才还原（与 do_restore 的 thermal_taken 语义一致）；
# 默认 thermal_remove=0 时不去动系统温控节点。
TR=$(cfg_str thermal_remove 0)
if [ "$(awk -v v="$TR" 'BEGIN { print (v ~ /^[0-9]+$/ && v + 0 == 1) ? 1 : 0 }')" = "1" ]; then
  echo 0 > "$P_TREM" 2>/dev/null
fi

# 4) 清掉 supervisor 的锁/pid，避免下次开机被陈旧记录挡住
rm -rf "$DATA/supervisor.lock.d" "$DATA/supervisor.pid" 2>/dev/null

# 保留配置和日志, 方便事后查看; 彻底清理请手动删 /data/adb/thermocharge
