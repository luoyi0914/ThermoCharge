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
const identParse = new Function(`return (${extract("identParse")})`)();

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

// --- 辨识任务探测输出 ---
eq("辨识 · 运行中带 pid",
  identParse("@@RUN 4242\n@@TAIL\n--- 阶跃到 6000mA，持续 180s ---\n"),
  { running:true, pid:4242, json:null, tail:"--- 阶跃到 6000mA，持续 180s ---\n" });

eq("辨识 · 完成 JSON 多行可解析",
  identParse('@@IDLE\n@@JSON\n{"ok":true,"alpha":0.178,\n"tau":220,"recommend":{"pred_alpha":0.178}}\n@@TAIL\ndone\n'),
  { running:false, pid:0,
    json:{ ok:true, alpha:0.178, tau:220, recommend:{ pred_alpha:0.178 } },
    tail:"done\n" });

eq("辨识 · 空输出",
  identParse(""),
  { running:false, pid:0, json:null, tail:"" });

eq("辨识 · 坏 JSON 不抛",
  identParse("@@IDLE\n@@JSON\n{not json}\n"),
  { running:false, pid:0, json:null, tail:"" });

console.log("== 结果 ==");
console.log(`  通过 ${pass} 项, 失败 ${fail} 项`);
process.exit(fail === 0 ? 0 : 1);
