"""Run only with TC_TEST_BINARY set to an explicitly authorized, fresh isolated build."""

import math
import os
import select
import shutil
import signal
import subprocess
import tempfile
import time
from itertools import pairwise
from pathlib import Path

RETIRED_CONFIG = {
    "power_mode": "0",
    "kp": "1000",
    "ki": "2000",
    "kd": "600",
    "deadband": "2",
    "tdot_tau_s": "60",
    "pred_enable": "1",
    "pred_alpha": "1",
    "pred_tau_s": "5",
    "pred_ambient": "59",
    "pred_margin": "-1",
    "pred_horizon_s": "1800",
    "pred_hit_s": "600",
    "min_regulate_ma": "20000",
    "soft_landing": "1",
    "soft_margin": "0",
    "soft_band": "3",
}
LEGACY_CONFIG = "".join(f"{key}={value}\n" for key, value in RETIRED_CONFIG.items())
RETIRED_STATE = {"pid", "active_power_mode", "pred_enable", "pred_cap_ma", "amb_est"}


def assert_state_contract(state):
    assert state["controller"] == "trend"
    assert not RETIRED_STATE.intersection(state)
    assert {"out", "temp_rate_c_min", "temp_pred_25s"}.issubset(state)
    assert {
        "effective_mca_tag",
        "effective_mca_type",
        "effective_p_suspend",
        "effective_p_thermal_remove",
        "effective_p_temp",
        "effective_p_current",
        "effective_p_usb_online",
        "effective_p_status",
        "effective_p_ctl",
        "effective_p_ichg",
        "effective_ctl_mode",
        "effective_dry_run",
        "effective_thermal_remove",
        "effective_hard_temp_x10",
        "thermal_taken_path",
    }.issubset(state)


def wait_for(test, timeout=7):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(0.025)
    raise AssertionError(f"timeout: {test.__code__.co_firstlineno}")


class Daemon:
    def __init__(self, work):
        self.work = work
        self.data = work / "data"
        self.data.mkdir(parents=True)
        self.cfg = self.data / "config.conf"
        self.binary = work / "thermocharge"
        source = os.environ.get("TC_TEST_BINARY")
        if not source:
            raise RuntimeError("TC_TEST_BINARY must name an authorized fresh build")
        shutil.copyfile(source, self.binary)
        self.binary.chmod(0o755)
        nodes = {
            "temp": "410",
            "voltage": "4000000",
            "current": "-2000000",
            "capacity": "50",
            "usb_online": "1",
            "status": "Charging",
            "ichg": "",
            "suspend": "",
            "ctl": "",
            "thermal_remove": "0",
        }
        for key, value in nodes.items():
            self.put(key, value)
        self.base = "\n".join(f"p_{k}={work / k}" for k in nodes) + "\n"
        self.base += (
            "ctl_mode=1\nthermal_remove=0\nstartup_ma=2000\n"
            "sample_ms=200\nfast_write_ms=100\nlog_interval_ms=200\n"
            "reassert_ms=500\nstartup_grace_ms=0\n"
        )

    def put(self, key, value):
        tmp = self.work / ".node.tmp"
        tmp.write_text(value)
        tmp.replace(self.work / key)

    def configure(self, extra):
        tmp = self.cfg.with_suffix(".tmp")
        tmp.write_text(self.base + extra)
        tmp.replace(self.cfg)

    def env(self):
        return dict(
            os.environ,
            TC_DATA=str(self.data),
            TC_CONFIG=str(self.cfg),
            TC_ALLOW_FAKE_SYSFS="1",
        )

    def start(self):
        return subprocess.Popen([str(self.binary), "run"], env=self.env())

    def cli(self, *args):
        return subprocess.run(
            [str(self.binary), *args],
            env=self.env(),
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    def state(self):
        try:
            state = dict(
                line.split("=", 1)
                for line in (self.data / "state").read_text().splitlines()
            )
            assert_state_contract(state)
            return state
        except FileNotFoundError:
            return {}

    def vote(self, node):
        try:
            return (self.work / node).read_text().split()
        except FileNotFoundError:
            return []


def main():
    with tempfile.TemporaryDirectory(prefix="tc-trend-daemon-") as tmp:
        # Capture the first actual write, not merely the value after startup races.
        hot_start = Daemon(Path(tmp) / "hot-start")
        hot_start.put("temp", "480")
        hot_start.configure("startup_grace_ms=3000\n")
        (hot_start.work / "ichg").unlink()
        os.mkfifo(hot_start.work / "ichg")
        fd = os.open(hot_start.work / "ichg", os.O_RDONLY | os.O_NONBLOCK)
        daemon = hot_start.start()
        try:
            assert select.select([fd], [], [], 7)[0], "no startup vote"
            assert os.read(fd, len(b"user all 500")).split() == [
                b"user",
                b"all",
                b"500",
            ]
        finally:
            hot_start.put("ichg", "")
            os.close(fd)
            daemon.terminate()
            daemon.wait(timeout=5)

        hot_exit = Daemon(Path(tmp) / "hot-exit")
        hot_exit.put("temp", "480")
        hot_exit.configure("")
        daemon = hot_exit.start()
        try:
            wait_for(lambda: hot_exit.vote("suspend") == ["user", "all", "1"])
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert hot_exit.vote("suspend") == ["user", "all", "1"]

        idle_exit = Daemon(Path(tmp) / "idle-exit")
        idle_exit.put("usb_online", "0")
        idle_exit.put("status", "Discharging")
        idle_exit.configure("")
        daemon = idle_exit.start()
        try:
            wait_for(lambda: idle_exit.state().get("state") == "idle")
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert idle_exit.vote("ichg") == [] and idle_exit.vote("suspend") == []

        deferred = Daemon(Path(tmp) / "deferred")
        deferred.put("temp", "480")
        deferred.configure("")
        daemon = deferred.start()
        try:
            wait_for(lambda: deferred.vote("suspend") == ["user", "all", "1"])
            deferred.configure("dry_run=1\nmca_tag=new\n")
            daemon.send_signal(signal.SIGHUP)
            wait_for(
                lambda: (
                    "deferred until" in (deferred.data / "log/daemon.log").read_text()
                )
            )
            wait_for(lambda: deferred.state().get("effective_mca_tag") == "user")
            assert deferred.state()["effective_dry_run"] == "0"
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert deferred.vote("suspend") == ["user", "all", "1"]

        # A real paused vote must be cleared under the old identity before dry-run.
        resume = Daemon(Path(tmp) / "resume-dry")
        resume.put("temp", "480")
        resume.configure("")
        daemon = resume.start()
        try:
            wait_for(lambda: resume.vote("suspend") == ["user", "all", "1"])
            resume.configure("dry_run=1\nmca_tag=new\n")
            daemon.send_signal(signal.SIGHUP)
            wait_for(
                lambda: "deferred until" in (resume.data / "log/daemon.log").read_text()
            )
            resume.put("temp", "410")
            wait_for(lambda: resume.state().get("effective_dry_run") == "1")
            assert resume.vote("suspend") == ["user", "all", "0"]
            assert resume.vote("ichg") == ["user", "all", "22000"]
            assert resume.state()["effective_mca_tag"] == "new"
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert resume.vote("suspend") == ["user", "all", "0"]
        assert resume.vote("ichg") == ["user", "all", "22000"]

        # Invalid sensor, hot-at-boundary and safe shutdown share restore semantics.
        for name, temp, expected in [
            ("invalid", "bad", "1"),
            ("zero", "0", "1"),
            ("boundary", "450", "1"),
            ("cool", "410", "0"),
        ]:
            stop = Daemon(Path(tmp) / ("stop-" + name))
            stop.configure("")
            daemon = stop.start()
            try:
                wait_for(lambda stop=stop: bool(stop.state()))
                stop.put("temp", temp)
            finally:
                daemon.terminate()
                daemon.wait(timeout=5)
            assert stop.vote("suspend") == ["user", "all", expected], name

        # Rescue follows the same guards, including --force offline and abort latch.
        rescue = Daemon(Path(tmp) / "rescue")
        rescue.configure("dry_run=1\n")
        for temp, expected in [("450", "1"), ("bad", "1"), ("410", "0")]:
            rescue.put("temp", temp)
            assert rescue.cli("restore").returncode == 0
            assert rescue.vote("suspend") == ["user", "all", expected]
        rescue.put("usb_online", "0")
        rescue.put("status", "Discharging")
        rescue.put("suspend", "keep all 1")
        rescue.put("ichg", "keep all 500")
        assert rescue.cli("restore", "--force").returncode == 0
        assert rescue.vote("suspend") == ["keep", "all", "1"]
        assert rescue.vote("ichg") == ["keep", "all", "500"]
        (rescue.data / "takeover.abort").touch()
        assert rescue.cli("restore").returncode == 4
        assert rescue.cli("restore", "--force").returncode == 4
        assert rescue.vote("suspend") == ["keep", "all", "1"]

        # A failed hot suspend must not release the existing lower current ticket.
        failed_restore = Daemon(Path(tmp) / "failed-restore")
        failed_restore.configure("")
        failed_restore.put("temp", "480")
        failed_restore.put("ichg", "user all 500")
        (failed_restore.work / "suspend").unlink()
        assert failed_restore.cli("restore").returncode == 1
        assert failed_restore.vote("ichg") == ["user", "all", "500"]

        # Offline reload publishes identity immediately even with 60s log throttling.
        idle_reload = Daemon(Path(tmp) / "idle-reload")
        idle_reload.put("usb_online", "0")
        idle_reload.put("status", "Discharging")
        idle_reload.configure("log_interval_ms=60000\n")
        daemon = idle_reload.start()
        try:
            wait_for(lambda: idle_reload.state().get("state") == "idle")
            idle_reload.configure(
                "log_interval_ms=60000\nmca_tag=updated\nhard_temp=46\n"
            )
            daemon.send_signal(signal.SIGHUP)
            wait_for(lambda: idle_reload.state().get("effective_mca_tag") == "updated")
            assert idle_reload.state()["effective_hard_temp_x10"] == "460"
            assert idle_reload.vote("ichg") == [] and idle_reload.vote("suspend") == []
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)

        # Only the observation window delays rising: after it expires, every
        # control sample changes power continuously, not once per 25s/0.8W probe.
        continuous = Daemon(Path(tmp) / "continuous")
        continuous.put("temp", "400")
        continuous.configure(LEGACY_CONFIG)
        daemon = continuous.start()
        try:
            wait_for(lambda: continuous.state().get("state") == "steady_hold")
            owner = (continuous.data / "daemon.pid").read_text()
            assert continuous.start().wait(timeout=5) == 0
            assert (continuous.data / "daemon.pid").read_text() == owner
            assert int(owner) == daemon.pid
            for _ in range(6):
                time.sleep(1)
                assert continuous.vote("ichg") == ["user", "all", "2000"]
            wait_for(
                lambda: continuous.state().get("state") == "steady_rise", timeout=10
            )
            votes = []
            for _ in range(6):
                time.sleep(0.3)
                votes.append(int(continuous.vote("ichg")[2]))
            assert len(set(votes)) >= 5, votes
            assert all(0 <= b - a < 80 for a, b in pairwise(votes)), votes
            assert math.isfinite(float(continuous.state()["temp_rate_c_min"]))
            assert float(continuous.state()["temp_pred_25s"]) == 40.0

            # Low-temperature recovery is allowed despite low draw, but voltage
            # changes must not extend its finite power budget.
            continuous.put("current", "-100000")
            time.sleep(0.5)
            before_limit = int(continuous.vote("ichg")[2])
            before_w = before_limit * 4.0 / 1000.0
            continuous.put("voltage", "3800000")
            time.sleep(0.8)
            after_limit = int(continuous.vote("ichg")[2])
            assert after_limit * 3.8 / 1000.0 <= before_w + 8.05
            continuous.put("voltage", "4000000")

            # Thermal trend reduction remains available despite system limiting.
            # The timestamp wait advances the fixture, rather than hard-coding dt.
            started = time.monotonic()
            peak_vote = int(continuous.vote("ichg")[2])
            while time.monotonic() - started < 10:
                elapsed = time.monotonic() - started
                continuous.put("temp", str(round(400 + 3 * elapsed)))
                peak_vote = max(peak_vote, int(continuous.vote("ichg")[2]))
                time.sleep(0.2)
            assert int(continuous.vote("ichg")[2]) < peak_vote
            assert continuous.state()["state"] == "steady_reduce"
            assert float(continuous.state()["temp_rate_c_min"]) > 0
            assert math.isfinite(float(continuous.state()["temp_pred_25s"]))
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert daemon.returncode == 0

        # Real I/O at a quantized 0.6 C/min trajectory, with current following
        # the already written vote. Far from target, rising must not freeze.
        rising = Daemon(Path(tmp) / "cold-rising")
        rising.put("temp", "310")
        rising.configure(LEGACY_CONFIG)
        daemon = rising.start()
        try:
            started = time.monotonic()
            sampled = []
            while time.monotonic() - started < 50:
                elapsed = time.monotonic() - started
                rising.put("temp", str(round(310 + elapsed * 0.1)))
                vote = rising.vote("ichg")
                if len(vote) == 3:
                    current_ma = int(vote[2])
                    rising.put("current", str(-current_ma * 1000))
                    if elapsed > 35:
                        sampled.append((elapsed, current_ma))
                time.sleep(0.2)
            assert len(sampled) >= 30
            delta_w = (sampled[-1][1] - sampled[0][1]) * 4 / 1000
            assert delta_w > 2.0, sampled
            assert rising.state()["state"] == "steady_rise"
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)

        tc = Daemon(Path(tmp))
        auto = LEGACY_CONFIG  # Including power_mode=0 must never restore classic.
        tc.configure(auto + "startup_grace_ms=3000\n")
        daemon = tc.start()
        try:
            wait_for(lambda: tc.state().get("state") == "grace")
            assert tc.vote("ichg") == ["user", "all", "2000"]
            tc.configure(
                auto + "pred_ambient=59\nstartup_grace_ms=3000\npower_max_w=1\n"
            )
            daemon.send_signal(signal.SIGHUP)
            wait_for(lambda: tc.vote("ichg") == ["user", "all", "250"])
            assert tc.state()["state"] == "grace"
            tc.configure(auto + "pred_ambient=59\nstartup_grace_ms=0\npower_max_w=8\n")
            daemon.send_signal(signal.SIGHUP)
            wait_for(lambda: tc.state().get("state") in {"steady_hold", "power_cap"})
            before = tc.vote("ichg")
            assert before == ["user", "all", "2000"]
            # Wait for the reload log followed by a control sample before comparing.
            logs = tc.data / "log/daemon.log"
            offset = logs.stat().st_size
            tc.configure(auto + "pred_ambient=5\npower_max_w=8\n")
            daemon.send_signal(signal.SIGHUP)

            def sampled_after_reload():
                chunk = logs.read_bytes()[offset:]
                _, found, after = chunk.partition(b"config reloaded:")
                return found and (
                    b"steady_hold soc=" in after or b"power_cap soc=" in after
                )

            wait_for(sampled_after_reload)
            assert_state_contract(tc.state())
            assert tc.vote("ichg") == before
            for key in RETIRED_CONFIG:
                assert tc.cli("set", key, "0").returncode == 3, key
                assert tc.cli("config-int", key).returncode == 2, key
            defaults = tc.cli("defaults")
            assert defaults.returncode == 0
            default_keys = {
                line.split("=", 1)[0] for line in defaults.stdout.splitlines()
            }
            assert not default_keys.intersection(RETIRED_CONFIG)

            # Removing or varying every legacy model key leaves the same output.
            offset = logs.stat().st_size
            tc.configure("power_max_w=8\n")
            daemon.send_signal(signal.SIGHUP)
            wait_for(sampled_after_reload)
            assert tc.vote("ichg") == before
            assert_state_contract(tc.state())

            tc.configure(auto + "power_max_w=8\nhold_below_soc=55\n")
            tc.put("capacity", "55")
            daemon.send_signal(signal.SIGHUP)
            wait_for(lambda: tc.state().get("state") == "soc_release")
            tc.put("voltage", "4400000")
            wait_for(lambda: tc.vote("ichg") == ["user", "all", "1818"])
            assert math.isnan(float(tc.state()["temp_pred_25s"]))
            (tc.work / "ichg").unlink()
            wait_for(lambda: tc.vote("suspend") == ["user", "all", "1"])
            wait_for(lambda: tc.state().get("state") == "ctl_fault")
            tc.put("ichg", "")
            wait_for(lambda: tc.vote("suspend") == ["user", "all", "0"])
            wait_for(lambda: tc.vote("ichg") == ["user", "all", "1818"])

            tc.put("temp", "480")
            wait_for(lambda: tc.vote("suspend") == ["user", "all", "1"])
            tc.configure(auto + "power_max_w=8\nhold_below_soc=55\nmca_tag=new\n")
            daemon.send_signal(signal.SIGHUP)
            wait_for(lambda: tc.state().get("state") == "hard_pause")
            assert tc.vote("suspend") == ["user", "all", "1"]
            tc.put("temp", "410")
            wait_for(lambda: tc.vote("suspend") == ["user", "all", "0"])
            wait_for(lambda: tc.vote("ichg") == ["new", "all", "1818"])

            tc.put("temp", "bad")
            wait_for(lambda: tc.state().get("state") == "sensor_fault")
            assert tc.vote("suspend") == ["new", "all", "1"]
            (tc.work / "ichg").unlink()
            tc.put("temp", "410")
            wait_for(lambda: tc.state().get("state") == "ctl_fault")
            assert tc.vote("suspend") == ["new", "all", "1"]
            tc.put("ichg", "")
            wait_for(lambda: tc.vote("suspend") == ["new", "all", "0"])
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert daemon.returncode == 0

        # Dry-run hard pause is not a real vote; enabling control must actually suspend.
        dry = Daemon(Path(tmp) / "dry")
        dry.put("temp", "480")
        dry.configure(auto + "dry_run=1\n")
        daemon = dry.start()
        try:
            wait_for(lambda: dry.state().get("state") == "hard_pause")
            assert dry.vote("suspend") == []
            dry.configure(auto)
            daemon.send_signal(signal.SIGHUP)
            wait_for(lambda: dry.vote("suspend") == ["user", "all", "1"])
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert daemon.returncode == 0

        # There is no startup vote when first observed unplugged. Hard protection
        # can cast one during grace; afterward a smaller manual ceiling still applies.
        grace = Daemon(Path(tmp) / "grace")
        grace.put("usb_online", "0")
        grace.put("status", "Discharging")
        extra = auto + "startup_grace_ms=15000\npause_on_hard=0\n"
        grace.configure(extra)
        daemon = grace.start()
        try:
            wait_for(lambda: grace.state().get("state") == "idle")
            grace.put("usb_online", "1")
            wait_for(lambda: grace.state().get("state") == "grace")
            assert grace.vote("ichg") == []
            grace.put("temp", "480")
            wait_for(lambda: grace.vote("ichg") == ["user", "all", "500"])
            grace.put("temp", "410")
            wait_for(lambda: grace.state().get("state") == "grace")
            grace.configure(extra + "power_max_w=1\n")
            daemon.send_signal(signal.SIGHUP)
            wait_for(lambda: grace.vote("ichg") == ["user", "all", "250"])
            assert grace.state()["state"] == "grace"
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert daemon.returncode == 0

        # Unplugging/idle reload/exit never write tickets, but must return takeover.
        unplug = Daemon(Path(tmp) / "unplug")
        unplug.configure("thermal_remove=1\n")
        daemon = unplug.start()
        try:
            wait_for(lambda: unplug.vote("thermal_remove") == ["1"])
            unplug.put("temp", "480")
            wait_for(lambda: unplug.vote("suspend") == ["user", "all", "1"])
            unplug.put("usb_online", "0")
            unplug.put("status", "Discharging")
            wait_for(lambda: unplug.state().get("state") == "idle")
            assert unplug.vote("thermal_remove") == ["0"]
            before = unplug.vote("ichg"), unplug.vote("suspend"), unplug.vote("ctl")
            unplug.configure("mca_tag=offline\nctl_mode=2\n")
            daemon.send_signal(signal.SIGHUP)
            wait_for(lambda: unplug.state().get("effective_ctl_mode") == "2")
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert (
            unplug.vote("ichg"),
            unplug.vote("suspend"),
            unplug.vote("ctl"),
        ) == before

        # Both cold-start and reload disable are intentional exits (supervisor rc=3).
        disabled = Daemon(Path(tmp) / "disabled")
        disabled.configure("enabled=0\n")
        assert disabled.start().wait(timeout=5) == 3
        assert disabled.vote("ichg") == [] and disabled.vote("suspend") == []
        disabled.configure("")
        daemon = disabled.start()
        try:
            wait_for(lambda: bool(disabled.state()))
            disabled.configure("enabled=0\n")
            daemon.send_signal(signal.SIGHUP)
            assert daemon.wait(timeout=5) == 3
        finally:
            if daemon.poll() is None:
                daemon.terminate()
                daemon.wait(timeout=5)
        assert disabled.vote("suspend") == ["user", "all", "0"]

        taken_exit = Daemon(Path(tmp) / "taken-exit")
        taken_exit.configure("thermal_remove=1\n")
        daemon = taken_exit.start()
        try:
            wait_for(lambda: bool(taken_exit.state().get("thermal_taken_path")))
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert taken_exit.vote("thermal_remove") == ["0"]
        assert taken_exit.state()["thermal_taken_path"] == ""

        # Keep the original takeover path after reload and retry a failed release.
        thermal = Daemon(Path(tmp) / "thermal")
        old_node = thermal.work / "thermal_old"
        new_node = thermal.work / "thermal_new"
        thermal.put(old_node.name, "0")
        thermal.put(new_node.name, "0")
        thermal.configure(auto + f"thermal_remove=1\np_thermal_remove={old_node}\n")
        daemon = thermal.start()
        try:
            wait_for(lambda: thermal.vote(old_node.name) == ["1"])
            wait_for(lambda: thermal.state().get("thermal_taken_path") == str(old_node))
            old_node.unlink()
            thermal.configure(
                auto + f"dry_run=1\nthermal_remove=1\np_thermal_remove={new_node}\n"
            )
            daemon.send_signal(signal.SIGHUP)
            thermal_log = thermal.data / "log/daemon.log"
            wait_for(lambda: "config reloaded:" in thermal_log.read_text())
            wait_for(lambda: thermal.state().get("effective_dry_run") == "1")
            assert thermal.state()["thermal_taken_path"] == str(old_node)
            thermal.put(old_node.name, "1")
            wait_for(lambda: thermal.vote(old_node.name) == ["0"])
            wait_for(lambda: thermal.state().get("thermal_taken_path") == "")
            assert thermal.vote(new_node.name) == ["0"]
            assert thermal.vote("ichg") == ["user", "all", "22000"]
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
        assert daemon.returncode == 0
        latched = Daemon(Path(tmp) / "latched")
        latched.configure(auto)
        marker = latched.data / "takeover.abort"
        daemon = latched.start()
        try:
            wait_for(lambda: bool(latched.state()))
            latched.put("suspend", "user all 1")
            marker.touch()
            assert daemon.wait(timeout=5) == 4
        finally:
            if daemon.poll() is None:
                daemon.terminate()
                daemon.wait(timeout=5)
        assert latched.vote("suspend") == ["user", "all", "1"]
        last_vote = latched.vote("ichg")
        assert latched.start().wait(timeout=5) == 4
        assert marker.exists()
        assert latched.vote("ichg") == last_vote
        assert latched.vote("suspend") == ["user", "all", "1"]

    print("trend daemon (startup, reload, protection and persistent latch): PASS")


if __name__ == "__main__":
    main()
