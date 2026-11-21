"""纯假节点短测；不加载项目模块、不构建/安装/启动真实守护进程。"""

import csv
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.dont_write_bytecode = True
SIM = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tc_sim_plant", SIM / "plant.py")
plant = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plant)


class PlantTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def make(self, **overrides):
        values = {
            "root": self.tmp.name,
            "ambient": 25.0,
            "alpha": 0.045,
            "tau": 20.0,
            "unit_eff": 1.0,
            "unit_lag": 0.0,
            "sys_cap": 20000.0,
            "capacity_ah": 5.0,
            "fixed_ma": 1000.0,
            "unplug_at": None,
            "duration": 3.0,
            "dt": 0.1,
            "ambient2": None,
            "ambient2_at": 0.0,
            "ambient3": None,
            "ambient3_at": 0.0,
            "t_start": 25.0,
            "soc0": 50.0,
        }
        values.update(overrides)
        p = plant.Plant(SimpleNamespace(**values))
        p.prime()
        return p

    def test_initial_temperature_is_not_elapsed_time(self):
        p = self.make(t_start=41.0, ambient2=60.0, ambient2_at=1.0)
        self.assertEqual((p.t, p.temp, p.amb), (0.0, 41.0, 25.0))
        p.step(0.5)
        self.assertEqual((p.t, p.amb), (0.5, 25.0))
        p.step(0.5)
        self.assertEqual((p.t, p.amb), (1.0, 60.0))

    def test_event_boundary_splits_thermal_integration(self):
        p = self.make(dt=1.0, fixed_ma=0, alpha=0, tau=1,
                      ambient2=45, ambient2_at=0.5,
                      ambient3=25, ambient3_at=1.5)
        p.step(1.0)
        self.assertAlmostEqual(p.temp, 35.0)
        p.step(1.0)
        self.assertAlmostEqual(p.temp, 32.5)
        self.assertEqual(p.t, 2.0)

    def test_unplug_stops_heating_and_soc_on_same_timeline(self):
        p = self.make(dt=1.0, unplug_at=0.5, tau=1, alpha=1)
        p.step(1.0)
        self.assertAlmostEqual(p.temp, 25.25)
        self.assertAlmostEqual(p.soc, 50 + 0.5 / 18000 * 100)
        self.assertEqual((p.i_ma, p.allowed, p.online), (0, 0, False))
        self.assertEqual(plant.read_text(p.path["usb"]), "0")
        self.assertEqual(plant.read_text(p.path["current"]), "0")
        old_soc = p.soc
        p.step(1)
        self.assertEqual(p.soc, old_soc)
        self.assertLess(p.temp, 25.25)

    def test_trace_units_voltage_votes_and_suspend(self):
        p = self.make(fixed_ma=None)
        plant.write_atomic(p.path["ichg"], "tc charger 2400\n")
        plant.write_atomic(p.path["ctl"], "1800000\n")
        p.step()
        p.sample()
        path = Path(self.tmp.name) / "trace.csv"
        p.write_trace(path)
        with path.open(newline="") as f:
            row = next(csv.DictReader(f))
        self.assertAlmostEqual(float(row["curr_a"]), 1.8)
        self.assertEqual(float(row["allowed_ma"]), 1800)
        self.assertEqual(int(row["ichg_vote_ma"]), 2400)
        self.assertEqual(int(row["ctl_vote_ua"]), 1800000)
        self.assertEqual(int(row["suspend"]), 0)
        self.assertAlmostEqual(float(row["voltage_v"]),
                               int(plant.read_text(p.path["voltage"])) / 1e6,
                               places=5)
        plant.write_atomic(p.path["suspend"], "tc charger 1\n")
        p.step()
        self.assertEqual((p.allowed, p.i_ma, p.suspend), (0, 0, 1))

    def test_invalid_votes_are_empty_not_zero_in_trace(self):
        p = self.make(fixed_ma=None)
        plant.write_atomic(p.path["ichg"], "broken\n")
        p.step()
        p.sample()
        self.assertIsNone(p.trace[-1][6])
        self.assertEqual(p.allowed, p.sys_cap)


# 只在私有临时目录执行此假程序；不调用项目 out/module 二进制。
FAKE_DAEMON = r'''
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

work = Path(os.environ["TC_DATA"]).parent
mode = os.environ.get("SIM_TEST_MODE", "normal")
(work / "fake.pid").write_text(str(os.getpid()))
if mode == "crash":
    sys.exit(7)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
if mode != "missing":
    (work / "data/log/curve.csv").write_text("t,temp\n0,25\n")
if mode == "hang":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable, "-I", "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"])
    (work / "child.pid").write_text(str(child.pid))
while True:
    time.sleep(0.05)
'''


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.binary = self.base / "fake-daemon"
        self.binary.write_text(f"#!{sys.executable}\n" + FAKE_DAEMON)
        self.binary.chmod(0o755)
        self.work = self.base / "work"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("TC_") and k not in ("SIM_EXTRA_CONF", "WORK")}
        self.env.update(TC_TEST_BINARY=str(self.binary), WORK=str(self.work))

    def run_sim(self, mode="normal", args=(), extra=None):
        self.env["SIM_TEST_MODE"] = mode
        if extra:
            self.env.update(extra)
        result = subprocess.run(
            ["sh", str(SIM / "run_sim.sh"), "--duration", "2.05", *args],
            check=False, env=self.env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=10,
        )
        for name in ("fake.pid", "child.pid"):
            path = self.work / name
            if path.exists():
                pid = int(path.read_text())
                self.assertFalse(Path(f"/proc/{pid}").exists(), result.stdout)
        return result

    def test_explicit_binary_required(self):
        del self.env["TC_TEST_BINARY"]
        result = self.run_sim()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.work.exists())

    def test_success_records_hash_status_and_samples(self):
        result = self.run_sim()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(
            (self.work / "binary.sha256").read_text().split()[0],
            hashlib.sha256((self.work / "bin/thermocharge").read_bytes()).hexdigest(),
        )
        status = json.loads((self.work / "exit_status.json").read_text())
        self.assertEqual(status, {"returncodes": {"plant": 0, "daemon": 0}, "errors": []})

    def test_daemon_failure_is_not_success(self):
        result = self.run_sim("crash")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("rc=7", result.stdout)

    def test_missing_curve_is_not_success(self):
        result = self.run_sim("missing")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("curve.csv", result.stdout)

    def test_plant_failure_is_not_success(self):
        result = self.run_sim(args=("--dt", "0"))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("plant", result.stdout)

    def test_missing_plant_samples_is_not_success(self):
        result = self.run_sim(args=("--duration", "0.1"))
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_cleanup_kills_stuck_process_group_and_fails(self):
        result = self.run_sim("hang", args=("--duration", "0.2"))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("TERM 清理超时", result.stdout)
        self.assertTrue((self.work / "child.pid").exists())

    def test_live_plant_cannot_wait_forever(self):
        # Copy only the runner into a private fixture, replacing the plant with
        # a process that finishes initialization but never completes its job.
        sim = self.base / "fixture/tests/sim"
        sim.mkdir(parents=True)
        shutil.copyfile(SIM / "run_sim.sh", sim / "run_sim.sh")
        (sim / "plant.py").write_text(
            "import argparse,os,signal,time\n"
            "from pathlib import Path\n"
            "p=argparse.ArgumentParser(); p.add_argument('--root'); "
            "a,_=p.parse_known_args()\n"
            "root=Path(a.root); ready=root/'charger/charger_thermal/wired_thermal_remove'\n"
            "ready.parent.mkdir(parents=True,exist_ok=True)\n"
            "(root.parent/'plant.pid').write_text(str(os.getpid()))\n"
            "signal.signal(signal.SIGTERM,lambda *_: exit(0))\n"
            "ready.write_text('0\\n')\n"
            "while True: time.sleep(0.05)\n"
        )
        result = subprocess.run(
            ["sh", str(sim / "run_sim.sh"), "--duration", "0.2"],
            check=False, env=self.env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=25,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("仿真总超时", result.stdout)
        status = json.loads((self.work / "exit_status.json").read_text())
        self.assertTrue(any("仿真总超时" in error for error in status["errors"]))
        for name in ("fake.pid", "plant.pid"):
            pid = int((self.work / name).read_text())
            self.assertFalse(Path(f"/proc/{pid}").exists(), result.stdout)

    def test_reject_real_node_overrides(self):
        result = self.run_sim(extra={"SIM_EXTRA_CONF": "p_temp=/sys/battery/temp"})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.work / "fake.pid").exists())

    def test_reject_plant_root_override(self):
        result = self.run_sim(args=("--root=/sys",))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.work / "fake.pid").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
