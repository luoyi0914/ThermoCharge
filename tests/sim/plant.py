"""ThermoCharge 无 root 闭环台架 —— 假 sysfs 电池 + 充电器模型

守护进程通过 config 里的 p_* 键指向这里的普通文件（需要 TC_ALLOW_FAKE_SYSFS=1，
见 src/thermocharge.c:366）。本脚本在每个时间步：

  1. 读走守护进程投的票（mca 三 token "tag type mA" / wired_chg_curr 的 µA）
  2. 按 votable 的 **Min** 语义，加上"系统自身的限制"，取最小值得到允许电流
  3. 用一阶热模型推进电池温度:  T∞ = Tamb + α·I²,   dT/dt = (T∞ - T)/τ
  4. 把温度 / 电压 / 电流 / SOC 写回假 sysfs

默认把 τ 缩到几十秒，2 分钟就能看到收敛。它验证的是**逻辑**：
控制代码在这些输入下会不会失控、抗风阻夹子 / 预测层 / 软着陆是否按预期生效。
它**不是** K90U 的热模型，不能用来宣称真机表现（HANDOFF §10）。

单独用来做开环阶跃辨识：
    python3 plant.py --root /tmp/fake --duration 60 --fixed-ma 12000
"""

import argparse
import csv
import math
import os
import signal
import sys
import time

# ---- 假 sysfs 里各个节点的相对路径（与 config.conf 的 p_* 一一对应） ----
REL = {
    "temp": "battery/temp",
    "voltage": "battery/voltage_now",
    "current": "battery/current_now",
    "status": "battery/status",
    "capacity": "battery/capacity",
    "usb": "usb/online",
    "ichg": "charger/charge_interface/ichg_limit",
    "ctl": "charger/charger_thermal/wired_chg_curr",
    "suspend": "charger/charge_interface/input_suspend",
    "threm": "charger/charger_thermal/wired_thermal_remove",
}


def write_atomic(path, text):
    """写临时文件再 rename: 守护进程随时在读，不能让读到半截/空文件。"""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def read_text(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def parse_mca(path):
    """mca 写入协议是 "<tag> <type> <value>"，返回最后一个 token 的整数。

    返回 None 表示没写过 / 写坏了（例如守护进程正在 O_TRUNC 后被读）。
    """
    toks = read_text(path).split()
    if not toks:
        return None
    try:
        return int(toks[-1])
    except ValueError:
        return None


class Plant:
    def __init__(self, a):
        self.root = a.root
        self.amb = a.ambient
        self.alpha = a.alpha          # ℃/A²
        self.tau = a.tau              # s，热时间常数
        self.eff = a.unit_eff         # 实际取流 / 允许上限
        self.unit_lag = a.unit_lag    # s，取流的跟随延迟
        self.sys_cap = a.sys_cap      # mA，模拟系统自身的上限
        self.cap_ah = a.capacity_ah
        self.fixed_ma = a.fixed_ma
        self.unplug_at = a.unplug_at
        self.duration = a.duration
        self.dt = a.dt
        # 环境温度阶跃：模拟"突然把手机放进热环境"，是唯一能把温度顶过硬上限
        # 的扰动（闭环本身会把温度按在目标值上，不会自己冲过 hard_temp）
        self.amb2 = a.ambient2
        self.amb2_at = a.ambient2_at
        self.amb3 = a.ambient3
        self.amb3_at = a.ambient3_at

        # 唯一时间轴：从 prime 完成起经过的模拟秒数；初温不是时间。
        self.t = 0.0
        self.soc = a.soc0
        self.temp = a.t_start
        self.i_ma = 0.0

        self.path = {k: os.path.join(self.root, v) for k, v in REL.items()}
        for p in self.path.values():
            os.makedirs(os.path.dirname(p), exist_ok=True)

        self.trace = []
        self.ichg_ma = self.ctl_ua = self.suspend = None
        self.allowed = 0.0
        self.online = True
        self.voltage_v = 0.0

    # ---- 初始化假 sysfs：看起来像"系统正在正常充电" ----
    def prime(self):
        write_atomic(self.path["temp"], f"{int(self.temp * 10)}\n")
        write_atomic(self.path["capacity"], f"{int(self.soc)}\n")
        write_atomic(self.path["status"], "Charging\n")
        write_atomic(self.path["usb"], "1\n")
        # 这两个是守护进程的输入票：初值 = 系统默认上限，等价于"我们还没投票"
        write_atomic(self.path["ichg"], f"sys charger {self.sys_cap}\n")
        write_atomic(self.path["ctl"], f"{self.sys_cap * 1000}\n")
        write_atomic(self.path["suspend"], "sys charger 0\n")
        self._apply_events()
        self.allowed = self.allowed_ma() if self.online else 0.0
        self._write_electrical()
        # 最后创建；运行器以此判断全部假节点已就绪。
        write_atomic(self.path["threm"], "0\n")

    def _write_electrical(self):
        # 3.5V@0% -> 4.4V@100%，再叠一点内阻压降（太小会掩盖 CV 段，太大会失真）
        volt = 3.5 + 0.9 * (self.soc / 100.0) + self.i_ma / 1000.0 * 0.01
        self.voltage_v = min(volt, 4.60)
        write_atomic(self.path["voltage"], f"{int(self.voltage_v * 1e6)}\n")
        # Android 惯例：充电电流为负
        write_atomic(self.path["current"], f"{int(-self.i_ma * 1000)}\n")

    def taper_ma(self):
        """系统自己的 CV 收敛: 90% 以上线性压到 15%。"""
        if self.soc < 90:
            return self.sys_cap
        k = 1.0 - (self.soc - 90.0) / 10.0 * 0.85
        return max(self.sys_cap * k, 200.0)

    def allowed_ma(self):
        """votable 的 Min 聚合：我们的票 vs 系统自身限制，取最小。"""
        self.ichg_ma = parse_mca(self.path["ichg"])
        self.ctl_ua = parse_mca(self.path["ctl"])
        self.suspend = parse_mca(self.path["suspend"])
        votes = []
        if self.fixed_ma is not None:
            votes.append(float(self.fixed_ma))
        else:
            if self.ichg_ma is not None:
                votes.append(float(max(self.ichg_ma, 0)))
            if self.ctl_ua is not None:
                votes.append(max(self.ctl_ua, 0) / 1000.0)
        if self.suspend == 1:
            return 0.0
        votes.append(self.taper_ma())
        votes.append(float(self.sys_cap))
        return max(min(votes), 0.0)

    def _apply_events(self):
        if self.amb2 is not None and self.t >= self.amb2_at:
            self.amb = self.amb2
        if self.amb3 is not None and self.t >= self.amb3_at:
            self.amb = self.amb3
        self.online = self.unplug_at is None or self.t < self.unplug_at
        if not self.online:
            self.i_ma = 0.0
        write_atomic(self.path["usb"], "1\n" if self.online else "0\n")
        write_atomic(self.path["status"], "Charging\n" if self.online else "Discharging\n")

    def step(self, seconds=None):
        """推进经过秒数；dt 是最大积分步长，在阶跃/拔电边界拆步。

        CLI 传入 monotonic 实际经过时间，慢 I/O 不会使热积分落后于扰动。
        无参数调用仍推进一个 dt，便于不睡眠的确定性单测。
        """
        seconds = self.dt if seconds is None else seconds
        if not math.isfinite(seconds) or seconds < 0:
            raise ValueError("推进时间必须是非负有限数")
        end = self.t + seconds
        events = [
            at for value, at in ((self.amb2, self.amb2_at),
                                 (self.amb3, self.amb3_at),
                                 (self.unplug_at, self.unplug_at))
            if value is not None
        ]
        while self.t < end:
            self._apply_events()
            boundary = min([end, self.t + self.dt] + [e for e in events if e > self.t])
            dt = boundary - self.t
            self.allowed = self.allowed_ma() if self.online else 0.0
            target_ma = self.allowed * self.eff
            if self.online and self.unit_lag > 0:
                self.i_ma += (target_ma - self.i_ma) * min(1.0, dt / self.unit_lag)
            else:
                self.i_ma = target_ma
            i_a = self.i_ma / 1000.0
            t_inf = self.amb + self.alpha * i_a * i_a
            self.temp += (t_inf - self.temp) * min(1.0, dt / self.tau)
            self.soc += i_a * dt / (self.cap_ah * 3600.0) * 100.0
            self.soc = min(max(self.soc, 0.0), 100.0)
            self.t = boundary
        self._apply_events()
        # 同一时刻的票/挂起快照，拔电后允许与实际电流均为零。
        allowed = self.allowed_ma()
        self.allowed = allowed if self.online else 0.0
        write_atomic(self.path["temp"], f"{round(self.temp * 10)}\n")
        write_atomic(self.path["capacity"], f"{int(self.soc)}\n")
        self._write_electrical()

    def sample(self):
        self.trace.append((self.t, self.temp, self.i_ma / 1000.0, self.soc,
                           self.voltage_v, self.allowed, self.ichg_ma,
                           self.ctl_ua, self.suspend, int(self.online), self.amb))

    def summarize(self):
        if len(self.trace) < 5:
            print("台架: 样本太少", file=sys.stderr)
            return False
        tail = self.trace[-max(3, len(self.trace) // 5):]
        temps = [r[1] for r in tail]
        currents = [r[2] for r in tail]   # trace 的 curr_a 与摘要统一为 A
        print("---- 台架结果 (最后 20% 样本) ----")
        print(f"  时长      {self.trace[-1][0]:.0f}s, {len(self.trace)} 个样本")
        print(f"  温度      {min(temps):.2f} .. {max(temps):.2f} ℃ "
              f"(末值 {temps[-1]:.2f})")
        print(f"  电流      {min(currents):.2f} .. {max(currents):.2f} A "
              f"(末值 {currents[-1]:.2f})")
        print(f"  SOC       {self.soc:.1f}%   环境 {self.amb:.1f}℃   "
              f"α={self.alpha:g} τ={self.tau:g}s")
        return True

    def write_trace(self, path):
        with open(path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(("t", "temp_c", "curr_a", "soc", "voltage_v",
                             "allowed_ma", "ichg_vote_ma", "ctl_vote_ua",
                             "suspend", "usb_online", "ambient_c"))
            writer.writerows(self.trace)


def main():
    ap = argparse.ArgumentParser(description="ThermoCharge 假 sysfs 台架", allow_abbrev=False)
    ap.add_argument("--root", required=True, help="假 sysfs 根目录")
    ap.add_argument("--duration", type=float, default=120.0, help="模拟时长(秒)")
    ap.add_argument("--dt", type=float, default=0.05, help="积分步长(秒)")
    ap.add_argument("--ambient", type=float, default=25.0, help="环境温度 ℃")
    ap.add_argument("--alpha", type=float, default=0.045, help="温升系数 ℃/A²")
    ap.add_argument("--tau", type=float, default=20.0, help="热时间常数 s")
    ap.add_argument("--unit-eff", type=float, default=1.0,
                    help="实际取流 / 允许上限 (小于 1 模拟系统只肯给一部分)")
    ap.add_argument("--unit-lag", type=float, default=3.0, help="取流跟随延迟 s")
    ap.add_argument("--sys-cap", type=float, default=20000.0, help="系统自身上限 mA")
    ap.add_argument("--capacity-ah", type=float, default=5.0)
    ap.add_argument("--t-start", type=float, default=25.0, help="初始温度 ℃")
    ap.add_argument("--soc0", type=float, default=50.0)
    ap.add_argument("--unplug-at", type=float, default=None, help="第几秒拔电")
    ap.add_argument("--ambient2", type=float, default=None,
                    help="阶跃后的环境温度 ℃（配合 --ambient2-at）")
    ap.add_argument("--ambient2-at", type=float, default=0.0,
                    help="第几秒把环境温度跳到 --ambient2")
    ap.add_argument("--ambient3", type=float, default=None,
                    help="第二次阶跃的环境温度 ℃（用来验证降温后恢复）")
    ap.add_argument("--ambient3-at", type=float, default=0.0)
    ap.add_argument("--fixed-ma", type=float, default=None,
                    help="忽略投票, 固定电流 (开环阶跃用)")
    ap.add_argument("--trace", default=None, help="把台架时间序列写到这个 CSV")
    a = ap.parse_args()
    for name, value in vars(a).items():
        if isinstance(value, float) and not math.isfinite(value):
            ap.error(f"{name} 必须是有限数")
    if min(a.duration, a.dt, a.tau, a.capacity_ah) <= 0:
        ap.error("duration、dt、tau、capacity-ah 必须大于 0")
    if min(a.unit_eff, a.unit_lag, a.sys_cap, a.alpha) < 0:
        ap.error("unit-eff、unit-lag、sys-cap、alpha 不得为负")
    if a.fixed_ma is not None and a.fixed_ma < 0:
        ap.error("fixed-ma 不得为负")
    if any(v is not None and v < 0 for v in
           (a.unplug_at, a.ambient2_at, a.ambient3_at)):
        ap.error("事件时刻不得为负")

    p = Plant(a)
    p.prime()

    stop = {"flag": False}

    def on_term(sig, frame):
        stop["flag"] = True

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    t_start = time.monotonic()
    p.sample()  # t=0 对应初始温度，绝不预先积分一个 dt。
    next_trace = 0.5
    while not stop["flag"] and p.t < a.duration:
        time.sleep(min(a.dt, a.duration - p.t))
        elapsed = min(time.monotonic() - t_start, a.duration)
        p.step(max(0.0, elapsed - p.t))
        if p.t >= next_trace or p.t >= a.duration:
            p.sample()
            next_trace = (math.floor(p.t / 0.5) + 1) * 0.5

    enough = p.summarize()
    if a.trace:
        p.write_trace(a.trace)
        print(f"  轨迹      {a.trace}")
    if stop["flag"]:
        print("台架: 被中断，未完成", file=sys.stderr)
    return 0 if enough and not stop["flag"] else 1


if __name__ == "__main__":
    sys.exit(main())
