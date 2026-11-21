#!/usr/bin/env sh
# 全部离机：实际脚本 + 临时 state/config/节点，不运行非隔离 service、不 su。
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
python3 -I - "$ROOT" <<'PY'
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(sys.argv[1])
wd = root / "module/watchdog.sh"
ident = root / "module/tools/identify-thermal.sh"
svc = root / "module/service.sh"
passed = 0


def check(name, condition):
    global passed
    if not condition:
        raise AssertionError(name)
    passed += 1
    print("PASS", name, flush=True)


def fn(path, name):
    text = path.read_text()
    match = re.search(r"^" + name + r"\(\) \{.*?^\}", text, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError("missing function " + name)
    return match.group()


with tempfile.TemporaryDirectory(prefix="tc-script-safety-") as work:
    base = pathlib.Path(work)
    data = base / "data"
    data.mkdir()
    (data / "log").mkdir()
    nodes = base / "nodes"
    nodes.mkdir()
    for name, value in {
        "susp": "original", "trem": "1", "temp": "350", "ibat": "-9000000",
        "usb": "1", "status": "Charging", "ctl": "6000000", "ichg": "6000",
    }.items():
        (nodes / name).write_text(value)
    paths = dict(zip(
        ("p_suspend", "p_thermal_remove", "p_temp", "p_current", "p_usb_online", "p_status", "p_ctl", "p_ichg"),
        (nodes / n for n in ("susp", "trem", "temp", "ibat", "usb", "status", "ctl", "ichg")),
    ))
    config = "thermal_remove=1\nctl_mode=2\nmca_tag=my  tag\nmca_type=quick\n"
    config += "".join(f"{k}={v}\n" for k, v in paths.items())
    cf = data / "config.conf"
    cf.write_text(config)
    state = data / "state"
    state.write_text("")
    cg = base / "cgroup"
    cg.write_text("4:memory:/apps\n0::/\n")
    env = dict(os.environ, TC_DATA=str(data), TC_ALLOW_FAKE_SYSFS="1", TC_BIN="/nonexistent",
               TC_CGROUP_FILE=str(cg), WD_DIR=str(data), WD_BIN="/nonexistent",
               WATCH_START_GRACE="0", WATCH_INTERVAL="1", WATCH_OS_SEC="3", WATCH_HB_SEC="60")
    for key, name in (("WD_SUSP", "susp"), ("WD_TREM", "trem"), ("WD_TEMP", "temp"),
                      ("WD_IBAT", "ibat"), ("WD_USB_ONLINE", "usb"), ("WD_STATUS", "status"),
                      ("WD_CTL", "ctl"), ("WD_ICHG", "ichg")):
        env[key] = str(nodes / name)
    prefix = 'TC_SAFETY_LIBRARY=1; . "$1"; unset TC_SAFETY_LIBRARY; safety_init "$TC_DATA" "$TC_DATA/config.conf" /nonexistent;\n'

    def shell(code, timeout=10):
        result = subprocess.run(["sh", "-c", prefix + code, "sh", str(wd)], check=False, env=env,
                                text=True, capture_output=True, timeout=timeout)
        if result.returncode:
            raise AssertionError(f"shell rc={result.returncode}\n{result.stdout}\n{result.stderr}")
        return result.stdout.strip()

    check("E fallback preserves repeated whitespace as underscores", shell('printf "%s/%s" "$G_TAG" "$G_TYPE"') == "my__tag/quick")
    cf.write_text(config + "mca_tag=\nmca_type=\n")
    check("E empty last MCA identity uses C defaults", shell('printf "%s/%s" "$G_TAG" "$G_TYPE"') == "user/all")
    cf.write_text(config + "mca_tag=" + "a" * 40 + "\n")
    check("E fallback truncates MCA to 31 bytes", shell('printf "%s" "$G_TAG"') == "a" * 31)
    cf.write_text(config + "p_suspend=/sys/../invalid\n")
    check("D invalid duplicate path retains prior valid path", shell('printf "%s" "$G_SUSP"') == str(nodes / "susp"))
    cf.write_text(config + "p_suspend=/sys/" + "x" * 256 + "\n")
    check("D overlong duplicate path retains prior valid path", shell('printf "%s" "$G_SUSP"') == str(nodes / "susp"))
    cf.write_text(config)
    check("D missing write reports failure", shell('if safety_wr "$TC_DATA/missing" 1; then exit 1; fi; printf ok') == "ok")
    check("C USB/status OR follows C including Full", shell('safety_charging "$G_USB" "$G_STATUS"; printf ok') == "ok")
    (nodes / "usb").write_text("0")
    (nodes / "status").write_text("Full")
    check("C Full fallback remains charging", shell('safety_charging "$G_USB" "$G_STATUS"; printf ok') == "ok")
    (nodes / "status").write_text("Discharging")
    check("C offline Discharging is not charging", shell('if safety_charging "$G_USB" "$G_STATUS"; then exit 1; fi; printf ok') == "ok")

    abort = data / "takeover.abort"
    # 库模式只加载函数，不能创建数据目录或触碰节点。
    library_data = base / "library-only"
    result = subprocess.run(
        ["sh", "-c", 'TC_SAFETY_LIBRARY=1; . "$1"', "sh", str(wd)], check=False,
        env=dict(env, TC_DATA=str(library_data), WD_DIR=str(library_data)),
        capture_output=True, text=True, timeout=5,
    )
    check("library import has no initialization writes", result.returncode == 0 and not library_data.exists())

    # service 的冻结组守卫仍独立于已删除的辨识功能。
    guard = fn(svc, "in_app_leaf")
    for cgroup, blocked in (("4:memory:/apps/uid_12345/pid_9\n", True), ("4:memory:/apps\n0::/\n", False)):
        cg.write_text(cgroup)
        result = subprocess.run(
            ["sh", "-c", guard + '\nin_app_leaf "$TC_CGROUP_FILE"'], check=False,
            env=env, capture_output=True, text=True, timeout=5,
        )
        check("service app-leaf guard " + ("rejects leaf" if blocked else "allows KernelSU root"), (result.returncode == 0) == blocked)

    # 同时覆盖有效历史组/配置组/thermal_taken_path，验证原子 state 优先。
    old_susp = nodes / "old-susp"
    old_trem = nodes / "old-trem"
    taken = nodes / "taken"
    for path in (old_susp, old_trem, taken):
        path.write_text("1")
    state.write_text(f"effective_mca_tag=old\neffective_mca_type=all\neffective_p_suspend={old_susp}\neffective_p_thermal_remove={old_trem}\nthermal_taken_path={taken}\n")
    shell('printf "effective_mca_tag=new\\neffective_p_suspend=%s/new-susp\\n" "${G_SUSP%/*}" > "$TC_DATA/state"; : > "${G_SUSP%/*}/new-susp"; safety_assert')
    check("D protects previous effective, current config and taken paths", old_susp.read_text().strip() == "old all 1" and old_trem.read_text().strip() == "0" and taken.read_text().strip() == "0" and (nodes / "susp").read_text().strip() == "my__tag quick 1" and (nodes / "new-susp").read_text().strip() == "new quick 1")
    legacy_taken = nodes / "legacy-taken"
    legacy_taken.write_text("1")
    state.write_text(f"thermal_taken_path={taken}\neffective_thermal_taken_path={legacy_taken}\n")
    taken.write_text("1")
    shell('safety_return_thermal')
    check("D real thermal_taken_path wins over legacy effective key", taken.read_text().strip() == "0" and legacy_taken.read_text() == "1")
    state.write_text(f"thermal_taken_path=\neffective_thermal_taken_path={legacy_taken}\n")
    shell('safety_return_thermal')
    check("D empty real taken-path means no takeover", legacy_taken.read_text() == "1")
    state.write_text(f"thermal_taken_path={nodes / 'missing-taken'}\n")
    (nodes / "trem").write_text("1")
    result = shell('if safety_return_thermal; then exit 1; fi; printf ok')
    check("D real thermal_taken_path failure aggregates but returns other groups", result == "ok" and (nodes / "trem").read_text().strip() == "0")
    state.write_text(f"effective_thermal_taken_path={legacy_taken}\n")
    shell('safety_return_thermal')
    check("D legacy taken-path key remains compatible", legacy_taken.read_text().strip() == "0")
    poison = base / "poison"
    state.write_text(f"effective_mca_tag=$(touch {poison})\n")
    shell('safety_assert')
    check("D/E state is never source/eval executed", not poison.exists())
    state.write_text("effective_p_suspend=/sys/../invalid\n")
    check("D malformed state path falls back to current valid config", shell('printf "%s" "$G_SUSP"') == str(nodes / "susp"))
    state.write_text("")

    # service 只抽取函数，绝不运行 service 顶层初始化/chmod/真节点等待。
    service_functions = "\n".join(fn(svc, n) for n in ("identify_owned", "stop_identify", "protect_abort", "stop_daemon"))
    service_setup = '''
DATA=$TC_DATA; MODDIR=$DATA/module; ABORT=$DATA/takeover.abort; IDMARK=$DATA/identify.lock; OUT=$DATA/log/out; DPID=
BIN=$TC_DATA/fake-bin
assert_failsafe() { safety_assert; }
log() { :; }
'''
    fake = data / "fake-bin"
    fake.write_text('#!/system/bin/sh\nprintf "%s\\n" "$*" >> "$TC_DATA/calls"\n')
    # 可执行夹具只落 TMPDIR，非 /storage；指定本机 sh shebang。
    fake.write_text(fake.read_text().replace("#!/system/bin/sh", "#!" + shutil.which("sh")))
    fake.chmod(0o755)
    abort.touch()
    shell(service_setup + service_functions + '\nstop_daemon')
    check("F service disable under abort never force-restores", "restore" not in (data / "calls").read_text() and (nodes / "susp").read_text().strip().endswith(" 1"))
    abort.unlink()
    # 升级兼容只终止精确属于模块的旧进程；同名其他路径/陈旧 PID 不误杀。
    holder = data / "module/tools/identify-thermal.sh"
    holder.parent.mkdir(parents=True)
    holder.write_text("trap 'exit 0' TERM\nwhile :; do sleep 0.05; done\n")
    alien = base / "identify-thermal-other.sh"
    alien.write_text(holder.read_text())
    for script, owned, latched, ignore_term in (
        (alien, False, False, False),
        (holder, True, False, False),
        (holder, True, True, False),
        (holder, True, False, True),
    ):
        if latched:
            abort.touch()
        script.write_text("trap '' TERM\nwhile :; do sleep 0.05; done\n" if ignore_term else "trap 'exit 0' TERM\nwhile :; do sleep 0.05; done\n")
        active = subprocess.Popen(["sh", str(script)], start_new_session=True)
        marker = data / "identify.lock"
        marker.write_text(str(active.pid))
        time.sleep(0.1)
        try:
            shell(service_setup + service_functions + '\nstop_identify')
            if owned:
                active.wait(timeout=3)
                check(f"service stops legacy writer latched={latched} force={ignore_term}", not marker.exists() and (not latched or (abort.exists() and (nodes / "susp").read_text().strip().endswith(" 1"))))
            else:
                check("service does not kill same-name process outside module", active.poll() is None and marker.read_text() == str(active.pid))
        finally:
            try:
                os.killpg(active.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            active.wait(timeout=3)
            abort.unlink(missing_ok=True)
    marker.unlink(missing_ok=True)
    for stale in ("0", "1", "-1", "not-a-pid", "99999999"):
        marker.write_text(stale)
        shell(service_setup + service_functions + '\nstop_identify')
        check("service ignores stale legacy lock " + stale, marker.read_text() == stale)
    marker.unlink()
    service_text = svc.read_text()
    check("service has no identification wait or crash/STOP exemption", "wait_identify" not in service_text and "id_active" not in service_text and "kill -STOP" not in service_text)

    (data / "calls").unlink()
    shell(service_setup + service_functions + '\nstop_identify() { return 1; }; stop_daemon')
    check("service failed legacy stop latches and never restores", abort.exists() and "restore" not in (data / "calls").read_text() and (nodes / "susp").read_text().strip().endswith(" 1"))
    abort.unlink()

    # stop 失败时不能用 --force 绕过仍存活的控制进程再恢复放流。
    (data / "calls").unlink()
    fake.write_text("#!" + shutil.which("sh") + '\nprintf "%s\\n" "$*" >> "$TC_DATA/calls"\n[ "$1" != stop ]\n')
    shell(service_setup + service_functions + '\nstop_daemon')
    check("service failed daemon stop latches and never restores", abort.exists() and "restore" not in (data / "calls").read_text() and (nodes / "susp").read_text().strip().endswith(" 1"))
    abort.unlink(missing_ok=True)
    fake.write_text("#!" + shutil.which("sh") + '\nprintf "%s\\n" "$*" >> "$TC_DATA/calls"\n')
    (data / "calls").unlink()
    shell(service_setup + service_functions + '\nstop_daemon')
    check("service confirmed stop still allows normal restore", not abort.exists() and (data / "calls").read_text().splitlines() == ["stop", "restore --force"])

    # 已删除入口不论参数、abort、旧锁或冻结组如何，均失败关闭且没有任何文件写入。
    # 快照包括内容和 mtime，既挡住新增采集输出，也挡住写后还原的控制动作。
    def snapshot():
        return {
            str(path.relative_to(base)): (path.read_bytes(), path.stat().st_mtime_ns)
            for path in base.rglob("*") if path.is_file()
        }, {str(path.relative_to(base)) for path in base.rglob("*") if path.is_dir()}

    cases = (
        (entry, args, latched)
        for entry in (ident, root / "tools/identify-thermal.sh")
        for args, latched in (([], False), (["confirm"], False), (["--help"], False), (["confirm"], True))
    )
    for entry, args, latched in cases:
        marker.write_text("existing-owner")
        if latched:
            abort.touch()
        cg.write_text("4:memory:/apps/uid_12345/pid_9\n")
        before = snapshot()
        result = subprocess.run(
            ["sh", str(entry), *args], check=False, env=dict(env, TC_BIN=str(fake)),
            capture_output=True, text=True, timeout=3,
        )
        check("removed entry fails closed without I/O " + str(entry.relative_to(root)) + repr((args, latched)), result.returncode == 2 and "已移除" in result.stderr and snapshot() == before)
        abort.unlink(missing_ok=True)
        marker.unlink()
    # 连数据目录不存在也不能由兼容入口创建。
    absent = base / "absent-data"
    result = subprocess.run(["sh", str(ident), "confirm"], check=False, env=dict(env, TC_DATA=str(absent)), capture_output=True, text=True, timeout=3)
    check("removed entry never creates data directory", result.returncode == 2 and not absent.exists())

    # 实际看门狗：持续拔线大电流不可由旧 limit 触发。
    (nodes / "susp").write_text("baseline")
    (nodes / "trem").write_text("1")
    (data / "watchdog.limit").write_text("5000")
    proc = subprocess.Popen(["sh", str(wd)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(4.2)
        check("C stale limit while unplugged never trips", not abort.exists() and proc.poll() is None)
        (nodes / "status").write_text("Charging")
        proc.wait(timeout=15)
        check("C same current while charging still trips", abort.exists() and "vote_not_binding" in (data / "log/watchdog.log").read_text())
    finally:
        if proc.poll() is None:
            proc.terminate()
        proc.wait(timeout=5)
    abort.unlink()
    (nodes / "status").write_text("Charging")
    reset_env = dict(env, WATCH_OS_SEC="4")
    proc = subprocess.Popen(["sh", str(wd)], env=reset_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1.4)
        (nodes / "status").write_text("Discharging")
        time.sleep(2)
        (nodes / "status").write_text("Charging")
        time.sleep(1.5)
        check("C unplug clears accumulated overshoot counter", not abort.exists() and proc.poll() is None)
    finally:
        proc.terminate()
        proc.wait(timeout=5)


print(f"\nPassed {passed} isolated safety checks")
PY
