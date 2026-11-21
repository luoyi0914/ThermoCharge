"""Run uninstall in a private fixture; never execute the installed module."""

import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "module/uninstall.sh"


def run_case(
    name,
    *,
    hot=False,
    abort=False,
    offline=False,
    broken=False,
    bad_temp=False,
    no_helper=False,
    stop_failure=False,
    stale_hot_group=False,
    failed_node=None,
    old_group=False,
    taken_path=False,
):
    with tempfile.TemporaryDirectory(prefix="tc-uninstall-") as tmp:
        base = Path(tmp)
        module = base / "module"
        data = base / "data"
        nodes = base / "nodes"
        for folder in (module / "bin", data, nodes):
            folder.mkdir(parents=True, exist_ok=True)
        paths = {
            key: nodes / key
            for key in (
                "p_ctl",
                "p_ichg",
                "p_suspend",
                "p_thermal_remove",
                "p_temp",
                "p_usb_online",
                "p_status",
            )
        }
        for key, path in paths.items():
            path.write_text(
                {
                    "p_ctl": "500000",
                    "p_ichg": "my_tag all 500",
                    "p_suspend": "my_tag all 1",
                    "p_thermal_remove": "1",
                    "p_temp": "invalid" if bad_temp else "470" if hot else "250",
                    "p_usb_online": "0" if offline else "1",
                    "p_status": "Discharging" if offline else "Charging",
                }[key]
                + "\n"
            )
        (data / "config.conf").write_text(
            "mca_tag=my tag\nmca_type=all\nhard_temp=45\nthermal_remove=1\n"
            + "".join(f"{key}={path}\n" for key, path in paths.items())
        )
        if stale_hot_group:
            old_temp = nodes / "old_temp"
            old_temp.write_text("470\n")
            (data / "state").write_text(
                f"effective_p_temp={old_temp}\neffective_hard_temp_x10=450\n"
            )
        old_paths = {}
        if old_group:
            for key in ("p_ctl", "p_ichg", "p_suspend", "p_thermal_remove"):
                path = nodes / f"old_{key}"
                path.write_text(paths[key].read_text().replace("my_tag", "old_tag"))
                old_paths[key] = path
            (data / "state").write_text(
                "effective_mca_tag=old_tag\neffective_hard_temp_x10=450\n"
                + "".join(
                    f"effective_{key}={path}\n" for key, path in old_paths.items()
                )
            )
        old_thermal = nodes / "old_thermal"
        if taken_path:
            old_thermal.write_text("1\n")
            (data / "state").write_text(f"thermal_taken_path={old_thermal}\n")
        if abort:
            (data / "takeover.abort").touch()
        # Redirect the old fixed DATA path in the fixture copy, never on the device.
        script = SOURCE.read_text().replace("/data/adb/thermocharge", str(data))
        (module / "uninstall.sh").write_text(script)
        if not no_helper:
            (module / "watchdog.sh").write_text(
                (ROOT / "module/watchdog.sh").read_text()
            )
        if not broken:
            binary = module / "bin/thermocharge"
            binary.write_text(
                "#!/bin/sh\n"
                'printf \'%s\\n\' "$*" >> "$TC_DATA/calls"\n'
                'case "$1" in\n'
                f"stop) exit {1 if stop_failure else 0} ;;\n"
                # A successful restore may intentionally keep a safety pause.
                f"restore) printf 'my_tag all {1 if hot or abort or bad_temp else 0}\\n' > '{paths['p_suspend']}' ;;\n"
                "config-str|config-int) exit 2 ;;\n"
                "esac\n"
            )
            binary.chmod(0o755)
        if failed_node:
            paths[failed_node].unlink()
            paths[failed_node].mkdir()
        env = os.environ.copy()
        env.update(TC_DATA=str(data), TC_ALLOW_FAKE_SYSFS="1")
        result = subprocess.run(
            ["sh", str(module / "uninstall.sh")],
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        if failed_node:
            assert result.returncode == 1, (name, result.stderr)
            assert paths["p_thermal_remove"].read_text().strip() == "0", name
            if failed_node == "p_suspend":
                assert paths["p_ctl"].read_text().strip() == "500000", name
                assert paths["p_ichg"].read_text().strip() == "my_tag all 500", name
            print(f"PASS {name}")
            return
        if stop_failure or no_helper:
            assert result.returncode == 1, (name, result.stderr)
            for key, expected in (
                ("p_ctl", "500000"),
                ("p_ichg", "my_tag all 500"),
                ("p_suspend", "my_tag all 1"),
                ("p_thermal_remove", "1"),
            ):
                assert paths[key].read_text().strip() == expected, name
            assert "WARN:" in result.stderr, name
            print(f"PASS {name}")
            return
        assert result.returncode == 0, (name, result.stderr)
        suspend = paths["p_suspend"].read_text().strip()
        if offline:
            assert suspend == "my_tag all 1", (name, suspend)
            assert paths["p_ctl"].read_text().strip() == "500000", name
            assert paths["p_ichg"].read_text().strip() == "my_tag all 500", name
        else:
            expected = 1 if hot or abort or bad_temp or stale_hot_group else 0
            assert suspend == f"my_tag all {expected}", (name, suspend)
        assert paths["p_thermal_remove"].read_text().strip() == "0", name
        if taken_path:
            assert old_thermal.read_text().strip() == "0", name
        if old_group:
            assert old_paths["p_suspend"].read_text().strip() == "old_tag all 0", name
            assert old_paths["p_ctl"].read_text().strip() == "22000000", name
            assert old_paths["p_ichg"].read_text().strip() == "old_tag all 22000", name
            assert old_paths["p_thermal_remove"].read_text().strip() == "0", name
        if abort:
            assert (data / "takeover.abort").exists(), name
            assert "restore --force" not in (data / "calls").read_text(), name
        print(f"PASS {name}")


def run_legacy_case(*, owned, abort=False):
    """Old identification is stopped, unrelated reused PIDs are never signaled."""
    with tempfile.TemporaryDirectory(prefix="tc-uninstall-legacy-") as tmp:
        base = Path(tmp)
        module = base / "module"
        data = base / "data"
        (module / "tools").mkdir(parents=True)
        data.mkdir()
        paths = {}
        for key, value in (
            ("p_suspend", "user all 1"),
            ("p_thermal_remove", "1"),
            ("p_ctl", "500000"),
            ("p_ichg", "user all 500"),
            ("p_temp", "250"),
            ("p_current", "0"),
            ("p_usb_online", "1"),
            ("p_status", "Charging"),
        ):
            paths[key] = base / key
            paths[key].write_text(value)
        (data / "config.conf").write_text(
            "".join(f"{key}={path}\n" for key, path in paths.items())
        )
        (module / "uninstall.sh").write_text(SOURCE.read_text())
        (module / "watchdog.sh").write_text((ROOT / "module/watchdog.sh").read_text())
        marker = base / "legacy-cleaned"
        (module / "bin").mkdir()
        binary = module / "bin/thermocharge"
        binary.write_text(
            '#!/bin/sh\ncase "$1" in\n'
            "stop) exit 0 ;;\n"
            f"restore) [ -f '{marker}' ] || exit 1; "
            f"printf restored > '{data / 'restored'}' ;;\n"
            "config-str|config-int) exit 2 ;;\nesac\n"
        )
        binary.chmod(0o755)
        holder = (
            module / "tools/identify-thermal.sh"
            if owned
            else base / "identify-thermal-unrelated.sh"
        )
        holder.write_text(
            f"trap 'printf cleaned > {marker}; exit 0' TERM\n"
            "while :; do sleep 0.05; done\n"
        )
        active = subprocess.Popen(["sh", str(holder)], start_new_session=True)
        (data / "identify.lock").write_text(str(active.pid))
        if abort:
            (data / "takeover.abort").touch()
        if not owned:
            # No matching writer exists, so restoration can proceed immediately.
            marker.touch()
        time.sleep(0.1)
        try:
            result = subprocess.run(
                ["sh", str(module / "uninstall.sh")],
                env=dict(os.environ, TC_DATA=str(data), TC_ALLOW_FAKE_SYSFS="1"),
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            assert result.returncode == 0, result.stderr
            if owned:
                active.wait(timeout=3)
                assert marker.read_text() == "cleaned"
            else:
                assert active.poll() is None
            if abort:
                assert (data / "takeover.abort").exists()
                assert not (data / "restored").exists()
                assert paths["p_suspend"].read_text().strip() == "user all 1"
            else:
                assert (data / "restored").exists()
            assert paths["p_thermal_remove"].read_text().strip() == "0"
            print(f"PASS legacy identification owned={owned} abort={abort}")
        finally:
            try:
                os.killpg(active.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            active.wait(timeout=3)


if __name__ == "__main__":
    for args in (
        ("hot exit preserves pause", {"hot": True}),
        ("latched exit preserves pause", {"abort": True}),
        ("cold fallback restores normalized identity", {"broken": True}),
        ("hot fallback preserves pause", {"hot": True, "broken": True}),
        ("invalid temperature fails safe", {"bad_temp": True, "broken": True}),
        (
            "offline leaves current and suspend votes untouched",
            {"offline": True, "broken": True},
        ),
        (
            "missing helper does not run unvalidated raw writes",
            {"broken": True, "no_helper": True},
        ),
        ("failed daemon stop prevents competing restore", {"stop_failure": True}),
        ("cold config cannot clear hot effective group", {"stale_hot_group": True}),
        (
            "returns recorded thermal_taken_path after failed handback",
            {"taken_path": True},
        ),
        (
            "cold exit restores both old effective and current groups",
            {"old_group": True},
        ),
        (
            "failed suspend write retains current limit and reports failure",
            {"broken": True, "failed_node": "p_suspend"},
        ),
        (
            "failed current restore still returns thermal control",
            {"broken": True, "failed_node": "p_ctl"},
        ),
    ):
        run_case(args[0], **args[1])
    run_legacy_case(owned=True)
    run_legacy_case(owned=True, abort=True)
    run_legacy_case(owned=False)
