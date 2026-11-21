# 假 sysfs 温度趋势闭环台架

台架运行「感知 → 电池温度趋势 → 投票 → 模拟电池温度变化」闭环，无需 root。守护进程用 `TC_DATA`／`TC_CONFIG` 隔离数据，并显式设置 `TC_ALLOW_FAKE_SYSFS=1`，所有 `p_*` 指向临时普通文件；生产服务不启用假节点开关。

> **可信度边界：** 本轮只修复台架并运行假程序短测，没有构建或运行当前核心 C，也没有安装、发布或操作真机。核心闭环结论必须绑定明确的二进制 SHA-256；已有旧 `out/thermocharge` 的结果不能冒充其他构建的验证。

## 明确选择测试二进制

构建获准并完成后，将 `TC_TEST_BINARY` 设为已经核对的最新产物绝对路径，再运行仓库中的脚本：

```sh
export TC_TEST_BINARY=/storage/emulated/0/ds/k90u-Charge/k90-thermocharge/out/thermocharge
sh /storage/emulated/0/ds/k90u-Charge/k90-thermocharge/tests/sim/run_sim.sh --duration 120
```

上面的路径只是产物位置，不能据此判断文件是否为最新构建。运行器强制要求非空、绝对路径的 `TC_TEST_BINARY`，不再回退到 `out/thermocharge`；复制到可执行临时目录后计算并记录实际执行副本的 SHA-256。请确认 `$TMPDIR` 有效可写且可执行；安卓上不要假设 `/tmp` 可用。

默认每次建立 `$TMPDIR/tc-sim.XXXXXX/` 独立目录，并打印实际位置。可设 `WORK=/绝对路径`，但目标必须不存在或为空，运行器不会清空旧产物。产物包括：

- `data/log/curve.csv`：守护进程采样；
- `plant.csv`：台架对象；
- `data/state`、`data/log/daemon.log`、`daemon.out`、`plant.out`：状态和诊断；
- `binary.sha256`、`binary-source.txt`：执行副本的哈希及来源路径；
- `exit_status.json`：子进程退出码和失败原因。

运行器对台架异常、守护进程提前退出（包括提前 exit 0）、不足 5 个台架样本、缺失/不完整守护曲线、正常退出失败及清理超时均返回非零。台架运行总等待上限为 `--duration + 15` 秒（不含后续有界清理），超时按失败进入清理；该新增超时路径已补测试，但尚未执行验证。进程使用独立进程组和 Linux/Android subreaper（不可用即失败），组长退出后也回收子孙；收尾直接发 TERM，最多等 3 秒，再对仍存活的整组发 KILL 并有界 wait 回收，强杀也判失败，不调用可能卡住的 `stop` 子命令。中断同样失败并清理。不要用 SIGKILL 杀监督器，SIGKILL 无法执行清理。

退出 0 只说明运行完成、取得基本样本且子进程正常回收，**不是控制效果断言通过**。仍需检查日志、曲线和专项测试。

## 场景

选定最新二进制后，给同一个运行器传入：

| 参数 | 目的 |
|---|---|
| `--duration 180` | 冷启动与连续调节，观察升功率是否受趋势与执行确认约束 |
| `--duration 110 --ambient 44 --t-start 40` | 模拟散热条件差；观察收紧及硬温路径，不保证一定低于硬线 |
| `--duration 260 --ambient 25 --ambient2 52 --ambient2-at 70 --ambient3 25 --ambient3-at 150` | 仅在假节点制造外部热扰动，观察挂起及恢复 |
| `--duration 180 --unit-eff 0.70` | 模拟实际电流低于上一票，检查不向上追票 |
| `--duration 150 --unplug-at 90` | 拔电状态切换；不写电流／挂起，实际接管温控须归还 |

`SIM_EXTRA_CONF` 可追加有效控制参数，例如自由功率上限，但禁止覆盖 `p_*`；运行器也禁止用 `--root` / `--trace` 覆盖隔离路径。`plant.py` 保留完整参数名，不接受参数缩写。已删除 `--ki` 控制器调参入口；环境模型、旧 PID 和软着陆参数不能恢复旧功能。

## 台架参数不是控制器输入

| 参数 | 默认 | 含义 |
|---|---|---|
| `--ambient` | 25 | **被控对象**的环境温度 ℃ |
| `--alpha` | 0.045 | **被控对象**的温升系数 ℃/A² |
| `--tau` | 20 | **被控对象**的热时间常数 s；是测试设定，不是真机实测 |
| `--unit-eff` | 1.0 | 模拟实际取流／允许上限比例 |
| `--unit-lag` | 3 | 模拟电流跟随延迟 s |
| `--sys-cap` | 20000 | 模拟系统电流上限 mA |
| `--soc0`／`--capacity-ah` | 50／5.0 | 模拟初始 SOC 与容量 |
| `--unplug-at` | — | 模拟拔电时刻 s |
| `--ambient2/2-at`、`--ambient3/3-at` | — | 被控对象的环境阶跃 |
| `--fixed-ma` | — | 台架固定输入调试；绕过票值，不能作为闭环测试 |

这些参数只传给 `plant.py`，控制器不读取它们。保留一个热响应测试对象不等于在运行模块中保留环境估计或热模型。主动开环辨识和 α／τ 配置流程已经移除，不再用台架指导真机标定。

## 时间轴与轨迹单位

`self.t` 从 0 开始，`--t-start` 只设置初温。CLI 以 prime 完成后的 `time.monotonic()` 经过时间推进热模型、SOC、环境阶跃和拔电；`--dt` 是最大积分步长，不再每轮固定加一次 dt 而让 I/O 延迟累积漂移。跨事件边界时拆步，事件时刻立即更新节点：拔电后的积分不再充电发热或增加 SOC。直接调用 `Plant.step()` 仍默认推进一个 dt，`step(seconds)` 可不睡眠推进指定时长。

`plant.csv` 首行数据为 t=0 初始状态，通常每 0.5 秒及结束时采样；不伪造遗漏样本。前四列顺序保留，**旧版 `curr_a` 错写 mA，本版修正为 A**，旧分析脚本不可再除以 1000。

| 列 | 含义/单位 |
|---|---|
| `t`, `temp_c`, `curr_a`, `soc` | 模拟经过秒、℃、充电正向 A、SOC % |
| `voltage_v`, `allowed_ma` | 模拟电池 V、聚合后的允许电流 mA（拔电为 0） |
| `ichg_vote_ma`, `ctl_vote_ua` | 同一采样时刻读取的 MCA 票 mA、wired 票 µA；缺失/坏票留空，不冒充零票 |
| `suspend`, `usb_online`, `ambient_c` | 挂起票、模拟插电状态 0/1、环境 ℃ |

票快照和实际电流之间可能有取流滞后，不能把当前允许值当作区间内恒定实测值。时间追赶也只能按当前票快照积分，无法重建 I/O 阻塞期间未观测的票变动；台架仍不是硬实时或真实电气模型。

## 独立短测与只读检查

```sh
python3 -I tests/sim/test_plant.py
sh -n tests/sim/run_sim.sh
shellcheck tests/sim/run_sim.sh
ruff check --no-cache tests/sim/plant.py tests/sim/test_plant.py
ruff format --check --no-cache tests/sim/plant.py tests/sim/test_plant.py
```

短测不需要 `TC_TEST_BINARY`，只在私有临时目录生成并执行假守护程序；包含确定性热模型/单位测试，以及异常退出、缺样本、隔离路径限制和 TERM 超时后的进程组清理。全部前台运行，新增总超时测试会额外等待约 15 秒，最终总耗时待复测；不运行核心 C，不触碰真实 sysfs，不安装、不发布。监督器还会留下实际退出状态，不能把短测通过写成当前核心闭环已通过。

## 能证明什么、不能证明什么

最新二进制的专项测试可检查连续输出、间隔缩放、噪声、系统限流不追票、无效电压不升流、功率上限和安全生命周期。`test_trend_daemon.py` 要求明确的 `TC_TEST_BINARY`，不应悄悄退回旧二进制。

假节点不能证明真机温控精度、MCA 聚合、快充握手、电荷泵或限流票是否真的约束电流。不要从台架功率和温度反推真机性能，也不要通过加热手机、遮挡散热或破坏真实节点重现危险场景。
