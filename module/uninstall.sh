#!/system/bin/sh
# 卸载时还原系统默认状态, 避免留下被限流的充电器
#
# 顺序: 停 supervisor / 看门狗 / 遗留旧辨识 -> 守护进程优雅退出 -> 二进制 restore
#       -> 失败才按有效快照兜底；过温/无效温度/熔断绝不解除停充。
# 未插电只归还系统温控，不写电流与挂起票；不修改其他组件的 charge_enable。

MODDIR=${0%/*}
BIN=$MODDIR/bin/thermocharge
DATA=${TC_DATA:-/data/adb/thermocharge}
CONF=$DATA/config.conf

# 停止前记住有效节点与身份，避免退出/重载后只剩磁盘上的新配置。
# 只加载随模块发布的受信函数；绝不 source 配置或 state。
HAVE_SAFETY=0
if [ -f "$MODDIR/watchdog.sh" ]; then
  export TC_SAFETY_LIBRARY=1
  # shellcheck source=watchdog.sh
  . "$MODDIR/watchdog.sh"
  unset TC_SAFETY_LIBRARY
  safety_init "$DATA" "$CONF" "$BIN"
  HAVE_SAFETY=1
fi

# C 的最低有效硬温是 target 下限25℃+1℃；无可用解析器时保守用26℃。
# 用全部已见组共同裁决，避免旧组的冷读数覆盖新组的热态停充。
all_groups_cold() {
  safety_refresh
  hard_line=$(TC_DATA="$DATA" TC_CONFIG="$CONF" "$BIN" config-int hard_temp_x10 2>/dev/null) || hard_line=
  hard=${hard_line#hard_temp_x10=}
  case "$hard" in ''|*[!0-9]*) hard=260 ;; esac
  [ "$hard" -ge 260 ] && [ "$hard" -le 550 ] || hard=260
  effective_hard=$(safety_get "$SAFE_STATE" effective_hard_temp_x10)
  case "$effective_hard" in ''|*[!0-9]*) ;; *)
    if [ "$effective_hard" -ge 260 ] && [ "$effective_hard" -lt "$hard" ]; then hard=$effective_hard; fi ;;
  esac
  # 同一停充票可出现在多个历史组；任一组热态/读数无效都禁止其他组解挂。
  cold=1
  while IFS='|' read -r _tag _typ _susp _trem temp _ibat usb status _ctl _ichg; do
    if safety_charging "$usb" "$status"; then
      t=$(tr -d '\r\n' < "$temp" 2>/dev/null)
      awk -v t="$t" -v hard="$hard" 'BEGIN {exit !(t ~ /^[0-9]+$/ && t>0 && t<hard)}' || cold=0
    fi
  done <<EOF
$SAFE_GROUPS
EOF
  [ "$cold" = 1 ]
}

# 二进制损坏时的保守兜底：无有效温度就保留停充，绝不假定电池已经冷却。
fallback_restore() {
  [ "$HAVE_SAFETY" = 1 ] || {
    printf '%s\n' 'WARN: safety helper missing; skipping unvalidated raw writes' >&2
    return 1
  }
  all_groups_cold || :
  printf '%s\n' "$SAFE_GROUPS" | {
    failed=0
    while IFS='|' read -r tag typ susp trem temp _ibat usb status ctl ichg; do
      if safety_charging "$usb" "$status"; then
        paused=1
        t=$(tr -d '\r\n' < "$temp" 2>/dev/null)
        if [ "$cold" = 1 ] && [ ! -f "$DATA/takeover.abort" ] &&
            awk -v t="$t" -v hard="$hard" 'BEGIN {exit !(t ~ /^[0-9]+$/ && t>0 && t<hard)}'; then
          paused=0
        fi
        if safety_wr "$susp" "$tag $typ $paused"; then
          if [ "$paused" = 0 ]; then
            safety_wr "$ctl" 22000000 || failed=1
            safety_wr "$ichg" "$tag $typ 22000" || failed=1
          fi
        else
          failed=1
        fi
        # 若熔断恰在清票期间发生，立即恢复停充；保护锁从不由卸载删除。
        if [ -f "$DATA/takeover.abort" ]; then
          safety_wr "$susp" "$tag $typ 1" || failed=1
        fi
      fi
      # 配置可能已关闭接管，仍须归还快照里记录的旧接管节点。
      safety_wr "$trem" 0 || failed=1
    done
    [ "$failed" = 0 ]
  }
}

# PID 文件可能陈旧；仅停止命令行仍属于本模块的进程，并等其真正停止写入。
pid_owned() {
  case "$1" in ''|*[!0-9]*|0|1) return 1 ;; esac
  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null |
    awk -v path="$2" -v daemon="$3" '$0==path {owned=1} $0=="run" {run=1} END {exit !(owned && (!daemon || run))}'
}
stop_owned() {
  owned_pid=$1; owned_path=$2; owned_daemon=$3
  pid_owned "$owned_pid" "$owned_path" "$owned_daemon" || return 0
  kill -TERM "$owned_pid" 2>/dev/null || return 1
  n=0
  while pid_owned "$owned_pid" "$owned_path" "$owned_daemon"; do
    [ "$n" -lt 40 ] || return 1
    sleep 0.1; n=$((n + 1))
  done
}

# 0) 先停 supervisor 和看门狗：只停守护进程的话，supervisor 2 秒后会把
#    已删除的二进制再拉起来（或者 crash-loop），看门狗也可能重新写回节点。
SUP=$(cat "$DATA/supervisor.pid" 2>/dev/null)
if ! stop_owned "$SUP" "$MODDIR/service.sh" 0; then
  printf '%s\n' 'WARN: supervisor did not stop; refusing competing restore' >&2
  exit 1
fi
# 看门狗没有独立 PID 文件；用完整路径的字面参数匹配，不能当正则扩大范围。
for proc in /proc/[0-9]*; do
  p=${proc#/proc/}
  if ! stop_owned "$p" "$MODDIR/watchdog.sh" 0; then
    printf '%s\n' 'WARN: watchdog did not stop; refusing competing restore' >&2
    exit 1
  fi
done

# 升级兼容：旧版本辨识仍可能写票，先确认其退出再恢复；新入口已失败关闭。
IDENT=$(cat "$DATA/identify.lock" 2>/dev/null)
if ! stop_owned "$IDENT" "$MODDIR/tools/identify-thermal.sh" 0; then
  printf '%s\n' 'WARN: identification did not stop; refusing competing restore' >&2
  exit 1
fi

# 1) 让守护进程优雅退出并停下；停不下来不能继续解挂/放流。
if [ -x "$BIN" ] && ! TC_DATA="$DATA" "$BIN" stop 2>/dev/null; then
  printf '%s\n' 'WARN: daemon did not stop; refusing competing restore' >&2
  exit 1
fi

# pid 文件丢失时按精确 argv 兜底；没等到退出，不做解挂/放流。
for proc in /proc/[0-9]*; do
  p=${proc#/proc/}
  if ! stop_owned "$p" "$MODDIR/bin/thermocharge" 1; then
    printf '%s\n' 'WARN: daemon still owns control; refusing competing restore' >&2
    exit 1
  fi
done

# 2) 熔断优先；正常恢复已处理热态，成功后绝不能再裸写 suspend=0 覆盖它。
RESULT=0
RESTORED=0
SAFE_TO_RESTORE=1
if [ "$HAVE_SAFETY" = 1 ]; then
  all_groups_cold || SAFE_TO_RESTORE=0
  # CLI restore 仅恢复磁盘配置；存在旧有效组时由兜底逐组恢复，不能留下旧身份的挂起票。
  groups=$(printf '%s\n' "$SAFE_GROUPS" | grep -c .)
  [ "$groups" -le 1 ] || SAFE_TO_RESTORE=0
fi
if [ "$SAFE_TO_RESTORE" = 1 ] && [ ! -f "$DATA/takeover.abort" ] && [ -x "$BIN" ] &&
    TC_DATA="$DATA" TC_CONFIG="$CONF" "$BIN" restore 2>/dev/null; then
  RESTORED=1
fi

# 3) 无二进制、恢复失败或保护锁存在时，使用同源有效路径保守兜底。
if [ "$RESTORED" = 0 ] || [ -f "$DATA/takeover.abort" ]; then
  fallback_restore || RESULT=1
elif [ "$HAVE_SAFETY" = 1 ]; then
  # restore 只认识当前磁盘配置；旧接管路径也要归还，但不再改票。
  safety_refresh
  safety_return_thermal || RESULT=1
fi

# 4) 清掉 supervisor 的锁/pid，避免下次开机被陈旧记录挡住
rm -rf "$DATA/supervisor.lock.d" "$DATA/supervisor.pid" 2>/dev/null

# 保留配置和日志, 方便事后查看; 彻底清理请手动删 /data/adb/thermocharge
exit "$RESULT"
