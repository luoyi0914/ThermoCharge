#!/usr/bin/env sh
# ThermoCharge 假 sysfs 闭环台架 —— 运行器
#
# 在没有 root 的机器上跑完整的"感知 -> 电池温度趋势 -> 投票 -> 电池温度变化"闭环:
#   - 守护进程的 p_* 全部指向台架造的普通文件 (TC_ALLOW_FAKE_SYSFS=1)
#   - 数据目录重定向到临时目录 (TC_DATA)，不碰 /data/adb
#   - 台架进程按 Min 聚合 + 一阶热模型回写温度
#
# 用法:
#   sh tests/sim/run_sim.sh                          # 默认 120 秒、环境 25℃
#   sh tests/sim/run_sim.sh --ambient 34 --duration 90
#   sh tests/sim/run_sim.sh --unit-eff 0.85          # 系统只肯给 85%
#
# 必须显式选择已核对的 TC_TEST_BINARY；不构建、不安装、不访问真 sysfs。
# /storage 不能执行程序，二进制复制到新的可执行临时目录再跑。

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
: "${TC_TEST_BINARY:?必须显式指定已核对的测试二进制绝对路径}"
BIN_SRC=$TC_TEST_BINARY
case "$BIN_SRC" in
    /*) ;;
    *) printf '%s\n' '错误: TC_TEST_BINARY 必须是绝对路径' >&2; exit 1 ;;
esac
[ -f "$BIN_SRC" ] || { printf '错误: 没有 %s\n' "$BIN_SRC" >&2; exit 1; }

# 不再 rm -rf 固定目录；显式 WORK 必须不存在或为空，防止删掉其他任务产物。
if [ -n "${WORK:-}" ]; then
    mkdir -p "$WORK"
    [ -z "$(ls -A "$WORK")" ] || { printf '%s\n' '错误: WORK 必须为空' >&2; exit 1; }
else
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/tc-sim.XXXXXX")
fi
WORK=$(cd "$WORK" && pwd)
mkdir -p "$WORK/bin" "$WORK/sys" "$WORK/data/log"
cp "$BIN_SRC" "$WORK/bin/thermocharge"
chmod 0755 "$WORK/bin/thermocharge"

SYS=$WORK/sys
DATA=$WORK/data

# 台架热模型参数只改变被控对象，不传给控制器。
# 守护进程不能读取台架的环境温度、热阻或热时间常数。

# ---- 台架配置：p_* 指向假 sysfs ----
cat > "$DATA/config.conf" <<EOF
# 闭环台架配置（自动生成，勿手改）
enabled=1
dry_run=0
target_temp=42
hard_temp=45
max_ma=20000
min_ma=500
startup_ma=2000
power_max_w=0
slew_ma_s=15000
sample_ms=200
fast_write_ms=200
log_interval_ms=1000
startup_grace_ms=0
reassert_ms=2000
ctl_mode=2
p_temp=$SYS/battery/temp
p_voltage=$SYS/battery/voltage_now
p_current=$SYS/battery/current_now
p_status=$SYS/battery/status
p_capacity=$SYS/battery/capacity
p_usb_online=$SYS/usb/online
p_ichg=$SYS/charger/charge_interface/ichg_limit
p_ctl=$SYS/charger/charger_thermal/wired_chg_curr
p_suspend=$SYS/charger/charge_interface/input_suspend
p_thermal_remove=$SYS/charger/charger_thermal/wired_thermal_remove
p_stop_handle=$SYS/charger/charger_common/stop_handle_charge
EOF
# SIM_EXTRA_CONF 在下面的监督器中校验后追加，禁止覆盖任何 p_* 假节点路径。
mkdir -p "$SYS/charger/charger_common"
: > "$SYS/charger/charger_common/stop_handle_charge"

# exec 后只有一个监督器；独立进程组 + 有界 TERM/KILL + wait 回收，
# 不依赖可能卡住/误认 cmdline 的 stop 子命令，不吞 wait 异常。
exec python3 -I - "$ROOT" "$WORK" "$BIN_SRC" "$@" <<'PY'
import argparse
import csv
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root, work, source = map(Path, sys.argv[1:4])
args = sys.argv[4:]
processes = {}
errors = []
statuses = {}


def interrupted(sig, frame):
    raise InterruptedError(f"收到信号 {sig}")


def signal_group(proc, sig):
    try:
        os.killpg(proc.pid, sig)
    except ProcessLookupError:
        pass  # 已退出的组不是 kill/wait 失败。


def group_exists(proc):
    try:
        os.killpg(proc.pid, 0)
        return True
    except ProcessLookupError:
        return False


def cleanup():
    # 同时通知所有组，统一 3 秒宽限，随后 KILL；即使组长已退出也清子孙。
    for proc in processes.values():
        signal_group(proc, signal.SIGTERM)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        for proc in processes.values():
            proc.poll()  # 回收已经结束的直接子进程。
        if not any(group_exists(p) for p in processes.values()):
            break
        time.sleep(0.05)
    for name, proc in processes.items():
        if group_exists(proc):
            errors.append(f"{name}: TERM 清理超时，已发 KILL")
            signal_group(proc, signal.SIGKILL)
    for name, proc in processes.items():
        try:
            statuses[name] = proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            errors.append(f"{name}: KILL 后回收超时")
    # Linux subreaper 收养组长先退出留下的子孙，避免把僵尸留给 Android init。
    deadline = time.monotonic() + 2
    while True:
        try:
            pid, rc = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if pid:
            # exec 包装层可留下正常退出的子孙，回收成功本身不是故障。
            if os.waitstatus_to_exitcode(rc) != 0:
                errors.append(f"额外子孙退出失败 pid={pid}, status={rc}")
        elif time.monotonic() >= deadline:
            errors.append("额外子孙回收超时")
            break
        else:
            time.sleep(0.02)


def require_live(name):
    rc = processes[name].poll()
    if rc is not None:
        raise RuntimeError(f"{name} 提前退出，rc={rc}")


def check_samples():
    with (work / "plant.csv").open(newline="") as f:
        rows = list(csv.DictReader(f))
    if len(rows) < 5:
        raise RuntimeError("plant.csv 少于 5 个样本")
    previous = -1.0
    for row in rows:
        for key in ("t", "temp_c", "curr_a", "soc", "voltage_v", "allowed_ma",
                    "usb_online", "ambient_c"):
            if not math.isfinite(float(row[key])):
                raise RuntimeError(f"plant.csv 无效字段 {key}")
        stamp = float(row["t"])
        if stamp <= previous:
            raise RuntimeError("plant.csv 时间未严格递增")
        previous = stamp
    with (work / "data/log/curve.csv").open(newline="") as f:
        curve = list(csv.reader(f))
    if len(curve) < 2 or len(curve[0]) < 2:
        raise RuntimeError("curve.csv 缺少守护进程样本")
    if any(len(row) != len(curve[0]) or not all(row) for row in curve[1:]):
        raise RuntimeError("curve.csv 存在不完整样本")


signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)
try:
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER (Linux/Android)
        raise OSError(ctypes.get_errno(), "无法启用子孙回收")
    # 禁止 CLI/附加配置把隔离节点改回真实路径；plant 禁止参数缩写。
    if any(a.split("=", 1)[0] in ("--root", "--trace") for a in args):
        raise ValueError("run_sim 不允许覆盖 --root/--trace")
    timing = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    timing.add_argument("--duration", type=float, default=120.0)
    requested, _ = timing.parse_known_args(args)
    if not math.isfinite(requested.duration) or requested.duration <= 0:
        raise ValueError("duration 必须是正有限数")
    overall_deadline = time.monotonic() + requested.duration + 15.0
    extra = os.environ.get("SIM_EXTRA_CONF", "")
    for line in extra.splitlines():
        key = line.split("=", 1)[0].strip()
        if key.startswith("p_"):
            raise ValueError("SIM_EXTRA_CONF 不允许覆盖 p_* 假节点路径")
    with (work / "data/config.conf").open("a") as f:
        f.write(extra + "\n")
    binary = work / "bin/thermocharge"
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    (work / "binary.sha256").write_text(f"{digest}  bin/thermocharge\n")
    (work / "binary-source.txt").write_text(str(source) + "\n")
    print(f"台架目录: {work}\n测试副本 SHA-256: {digest}", flush=True)
    # 只使用明确隔离的数据/config；不继承外部 TC_* 路径。
    env = {k: v for k, v in os.environ.items() if not k.startswith("TC_")}
    env.update(TC_DATA=str(work / "data"),
               TC_CONFIG=str(work / "data/config.conf"), TC_ALLOW_FAKE_SYSFS="1")
    with (work / "plant.out").open("w") as plant_out, \
            (work / "daemon.out").open("w") as daemon_out:
        processes["plant"] = subprocess.Popen(
            [sys.executable, "-I", str(root / "tests/sim/plant.py"),
             *args, "--root", str(work / "sys"), "--trace", str(work / "plant.csv")],
            stdout=plant_out, stderr=subprocess.STDOUT, env=env,
            start_new_session=True)
        deadline = time.monotonic() + 5
        ready = work / "sys/charger/charger_thermal/wired_thermal_remove"
        while not ready.exists():
            require_live("plant")
            if time.monotonic() >= deadline:
                raise RuntimeError("plant 假节点初始化超时")
            time.sleep(0.02)
        require_live("plant")
        print("--- 启动守护进程 ---", flush=True)
        processes["daemon"] = subprocess.Popen(
            [str(binary), "run"], stdout=daemon_out, stderr=subprocess.STDOUT,
            env=env, start_new_session=True)
        while True:
            if time.monotonic() >= overall_deadline:
                raise RuntimeError("仿真总超时，停止并回收测试进程")
            require_live("daemon")
            rc = processes["plant"].poll()
            if rc is not None:
                if rc != 0:
                    raise RuntimeError(f"plant 失败，rc={rc}，见 plant.out")
                break
            time.sleep(0.05)
        # 不留同步退出竞态：正常完成前 daemon 必须仍然存活。
        require_live("daemon")
        check_samples()
except Exception as exc:
    errors.append(str(exc))
finally:
    # 第二个信号也不能打断回收；KILL 仅针对自己创建的进程组。
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    try:
        cleanup()
    except Exception as exc:
        errors.append(f"清理失败: {exc}")
    if statuses.get("daemon", 0) != 0:
        errors.append(f"daemon 退出失败，rc={statuses['daemon']}")
    if statuses.get("plant", 0) != 0:
        errors.append(f"plant 退出失败，rc={statuses['plant']}")
    (work / "exit_status.json").write_text(
        json.dumps({"returncodes": statuses, "errors": errors}, ensure_ascii=False) + "\n")

for name in ("plant.out", "data/log/curve.csv", "data/log/daemon.log"):
    path = work / name
    if path.is_file():
        print(f"\n--- {name} 尾段 ---")
        print("\n".join(path.read_text(errors="replace").splitlines()[-8:]))
for error in errors:
    print(f"台架失败: {error}", file=sys.stderr)
print(f"产物: {work}/plant.csv  {work}/data/log/curve.csv  {work}/exit_status.json")
sys.exit(1 if errors else 0)
PY
