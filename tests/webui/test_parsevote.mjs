#!/usr/bin/env node
/* WebUI 纯函数的夹具测试 —— 不需要浏览器，也不需要 KSU。
 *
 * 直接从 module/webroot/index.html 里把函数源码抠出来求值，测的是**页面上
 * 真正在跑的那份代码**，不是抄一份副本（抄副本的话页面改了测试也发现不了）。
 *
 * 覆盖：
 *   - 真机 ichg_limit 的回读格式 `<通道类型> eff_client:<tag> <mA>`
 *   - Min 聚合：多行时取最小值，不管行的先后
 *   - 旧的/写的格式 `<tag> <type> <mA>` 作为回退
 *   - 垃圾输入（null / 空串 / token 不足 / 值不是数字）返回 null
 *   - esc() 转义 & < > " '
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const html = fs.readFileSync(path.join(root, "module/webroot/index.html"), "utf8");

function extract(name) {
  const start = html.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`页面里找不到 function ${name}`);
  let i = html.indexOf("{", start);
  let depth = 0;
  for (; i < html.length; i++) {
    const c = html[i];
    if (c === "{") depth++;
    else if (c === "}" && --depth === 0) return html.slice(start, i + 1);
  }
  throw new Error(`${name} 的大括号不配对`);
}

const parseVote = new Function(`return (${extract("parseVote")})`)();
const esc = new Function(`return (${extract("esc")})`)();

let pass = 0, fail = 0;
const ok = (m) => { pass++; console.log(`  ✓ ${m}`); };
const bad = (m) => { fail++; console.log(`  ✗ ${m}`); };
function eq(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  g === w ? ok(name) : bad(`${name}（期望 ${w}，实际 ${g}）`);
}

// --- 真机回读格式：系统赢家 ---
eq("真机格式 · 系统赢家",
  parseVote("buck eff_client:volt_thermal_limit 2200"),
  { tag: "volt_thermal_limit", type: "buck", ma: 2200 });

// --- 真机回读格式：模块自己的票 ---
eq("真机格式 · 模块赢家",
  parseVote("buck eff_client:user 12000"),
  { tag: "user", type: "buck", ma: 12000 });

// --- Min 聚合：三行取最小，与次序无关 ---
eq("多行取最小",
  parseVote("buck eff_client:user 12000|buck eff_client:volt_thermal_limit 3000|buck eff_client:cp 8000|"),
  { tag: "volt_thermal_limit", type: "buck", ma: 3000 });
eq("顺序颠倒仍取最小",
  parseVote("buck eff_client:volt_thermal_limit 3000|buck eff_client:user 12000"),
  { tag: "volt_thermal_limit", type: "buck", ma: 3000 });

// --- 回退：写格式 `<tag> <type> <mA>` ---
eq("写格式回退",
  parseVote("user all 5000"),
  { tag: "user", type: "all", ma: 5000 });

// --- 非法输入 ---
eq("null", parseVote(null), null);
eq("非字符串", parseVote(12345), null);
eq("空串", parseVote(""), null);
eq("token 不足", parseVote("buck eff_client:user"), null);
eq("值不是数字", parseVote("buck eff_client:user abc"), null);

// --- HTML 转义 ---
eq("esc 转义", esc(`<b>&"'`), "&lt;b&gt;&amp;&quot;&#39;");
eq("esc 数字", esc(42), "42");

// --- 已移除的工具页和辨识代码不能只靠隐藏保留 ---
eq("工具 / 辨识实现与入口已删除",
  /page-tool|data-page="tool"|function (?:ident|tool)|const (?:Ident|Tool)\b|identify-thermal|tc\.tool/.test(html), false);
eq("没有固定功率档位或模式切换",
  /power_mode|power[_-]?presets?|data-(?:preset|watts)|选档|档位/.test(html), false);
eq("没有环境热模型或旧控制参数依赖",
  /\b(?:kp|ki|kd|deadband|tdot_tau_s|min_regulate_ma|pid_i|amb_est|pred_\w+|soft_\w+)\b|环境温度|热模型|积分项/.test(html), false);
eq("预览与发布 HTML 逐字节相同",
  fs.readFileSync(path.join(root, "webui/index.html")).equals(fs.readFileSync(path.join(root, "module/webroot/index.html"))), true);

const stateIsFresh = new Function(`return (${extract("stateIsFresh")})`)();
eq("状态 · 心跳和采样均新鲜", stateIsFresh(24694, 995, 994, 1000, 1000), true);
eq("状态 · PID 存在但心跳停止", stateIsFresh(24694, 960, 959, 1000, 1000), false);
eq("状态 · 心跳正常但采样没有更新", stateIsFresh(24694, 999, 960, 1000, 1000), false);
eq("状态 · 允许配置较长日志间隔", stateIsFresh(24694, 999, 945, 60000, 1000), true);
eq("状态 · 没有心跳", stateIsFresh(24694, 0, 999, 1000, 1000), false);
eq("状态 · 进程已退出", stateIsFresh(0, 999, 999, 1000, 1000), false);

console.log("== 结果 ==");
console.log(`  通过 ${pass} 项, 失败 ${fail} 项`);
process.exit(fail === 0 ? 0 : 1);
