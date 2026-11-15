# 假 sysfs 闭环台架

在没有 root 的机器上跑完整的「感知 → PID → 投票 → 电池温度变化」闭环。

守护进程本身不知道自己在写真 sysfs 还是普通文件 —— 它只调 `open/write/read`。
`src/thermocharge.c:366` 的 `path_ok()` 默认只放行 `/sys/` 前缀，但显式设了
`TC_ALLOW_FAKE_SYSFS=1` 就允许把 `p_*` 指向普通文件。生产环境的 `service.sh`
从不设这个变量。

## 跑一次

```sh
sh build.sh                 # 先有 out/thermocharge
sh tests/sim/run_sim.sh                       # 120s，环境 25℃
sh tests/sim/run_sim.sh --duration 200        # 更长时间看收敛
```

产物在 `$TMPDIR/tc-sim/`：`data/log/curve.csv`（守护进程视角）、`plant.csv`（台架视角）。

看状态迁移：

```sh
awk -F, 'NR>1 && $9!=prev {print $1"  T="$2"  I="$4"  lim="$7"  => "$9; prev=$9}' \
  "$TMPDIR/tc-sim/data/log/curve.csv"
```

## 常用场景

```sh
# 冷电池 → 满流 → 压回目标
sh tests/sim/run_sim.sh --duration 180

# 环境恒温高于目标：应当压在 min_ma，不越硬上限
sh tests/sim/run_sim.sh --duration 110 --ambient 44 --t-start 40

# 环境阶跃：撞硬上限 → hard_pause → 降温后恢复
sh tests/sim/run_sim.sh --duration 260 --ambient 25 \
    --ambient2 52 --ambient2-at 70 --ambient3 25 --ambient3-at 150

# 系统只肯给 85%：验证低温段放行到 max，不会因为"实测 < 上限"就把上限越压越低
sh tests/sim/run_sim.sh --duration 180 --unit-eff 0.85

# 中途拔电：验证还原路径
sh tests/sim/run_sim.sh --duration 150 --unplug-at 90
```

## 台架参数

| 参数 | 默认 | 含义 |
|---|---|---|
| `--ambient` | 25 | 环境温度 ℃ |
| `--alpha` | 0.045 | 温升系数 ℃/A²，稳态 `T∞ = Tamb + α·I²` |
| `--tau` | 20 | 热时间常数 s（真机约 300s，这里缩小以便快速收敛） |
| `--unit-eff` | 1.0 | 实际取流 / 允许上限，小于 1 模拟系统只肯给一部分 |
| `--unit-lag` | 3 | 取流跟随延迟 s |
| `--sys-cap` | 20000 | 模拟系统自身上限 mA |
| `--soc0` / `--capacity-ah` | 50 / 5.0 | 初始 SOC 与容量 |
| `--unplug-at` | — | 第几秒拔电 |
| `--ambient2/2-at`、`--ambient3/3-at` | — | 环境温度两次阶跃 |
| `--fixed-ma` | — | 忽略投票、固定电流（开环阶跃辨识用） |
| `--ki` | 40 | 台架的积分增益，见下 |

## 这个台架能证明什么、不能证明什么

**能**：控制律在这些输入下会不会失控；抗风阻夹子、硬上限挂起/恢复、状态机、
`curve.csv` 字段与日志格式是否符合预期。改动 `src/thermocharge.c` 后跑一遍，
能挡住"越限冲顶"这类回归。

**不能**：`--ki` 是**按台架对象单独标定**的，默认 40。真机默认 `ki=600` 在
本台架上会跑成极限环 —— 那是台架对象（一阶、直流增益 0.0017 ℃/mA）比真机
灵敏得多造成的假象，**不是控制律的 bug**。所以：

- 不要从台架的 `ki` 反推真机参数；
- 不要用台架的功率/温度数字宣称真机表现；
- mca votable 的 Min 聚合、快充握手、电荷泵行为，台架全部不覆盖 —— 只能真机验。

真机的 `ichg_limit` 读出来是 `buck eff_client:volt_thermal_limit 3000` 这种
三 token 串，台架按同样的格式造票（`tag type mA`），但聚合是台架自己实现的。

## 开环阶跃辨识

闭环数据回归 `T = a + b·I²` 会退化（电流随温度自适应，参数不可辨识）。
要辨识 `pred_alpha` 必须开环：

```sh
python3 tests/sim/plant.py --root $TMPDIR/step --duration 120 --fixed-ma 12000 \
    --trace $TMPDIR/step.csv
```

台架里这么做只能验证**辨识流程**本身，得到的 α 就是你设进去的那个值 —— 真机的
α 只能上真机做开环阶跃，且要人盯着温度。
