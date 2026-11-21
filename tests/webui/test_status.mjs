#!/usr/bin/env node
/* 从页面提取实际适配层；shell 身份探测只运行在临时伪 /proc，不碰设备节点。 */
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const htmlPath = path.join(root, "module/webroot/index.html");
const html = fs.readFileSync(htmlPath, "utf8");
const adapterStart = html.indexOf("function parseKV(");
const dataStart = html.indexOf("const Data = {", adapterStart);
const dataEnd = html.indexOf("\n};", dataStart) + 3;
assert.ok(adapterStart >= 0 && dataStart > adapterStart && dataEnd > dataStart);
const adapter = html.slice(adapterStart, dataEnd);
const definitions = html.slice(html.indexOf("const KEYS = {"), html.indexOf("const PATHS = {"));
const paths = {
  data:"/data/adb/thermocharge",
  bin:"/data/adb/modules/thermocharge/bin/thermocharge",
  mod:"/data/adb/modules/thermocharge",
};
const now = 1000;
class FixtureDate extends Date { static now(){ return now * 1000; } }
let count = 0;
async function test(name, fn){
  await fn();
  count++;
  console.log(`PASS ${name}`);
}
function loadAdapter(stdout = "", fixturePaths = paths){
  const commands = [];
  const sh = async command => {
    commands.push(command);
    return { errno:0, stdout, stderr:"" };
  };
  const result = new Function("sh", "PATHS", "Date",
    `const HAS_KSU = true;\n${definitions}\n${adapter}\nreturn { Data, daemonPidProbe, KEYS, SEGKEYS, GROUPS, Demo, DEMO_DEFAULTS };`)(sh, fixturePaths, FixtureDate);
  return { ...result, commands };
}
const live = [
  "charging=1", "temp=42.6", "voltage=4.2", "current=-3.25", "power=13.7", "soc=65",
  "limit_ma=4000", "target=43", "state=steady_hold", "controller=trend", "out=4000", "uptime=600",
  "temp_rate_c_min=0.1", "temp_pred_25s=42.64",
];
const config = [
  "target_temp=44", "hard_temp=46", "min_ma=500", "max_ma=20000", "ctl_mode=2",
  "dry_run=0", "enabled=1", "mca_tag=user # inline comment", "log_interval_ms=1000",
];
function fixture({ pid=42, heartbeat=999, mtime=999, state=live, cfg=config, device=[], latched=false } = {}){
  return [
    `@@ALIVE ${pid}`, `@@HEARTBEAT ${heartbeat}`, `@@STATE_MTIME ${mtime}`,
    ...(latched ? ["@@LATCHED"] : []), "@@STATE", ...state, "@@CFG", ...cfg, "@@DEVICE", ...device,
    "@@PROP", "v-test", "@@VER", "thermocharge test", "@@READBACK", "wired=4000000", "ichg=buck eff_client:user 4000|", "",
  ].join("\n");
}

await test("STATE/CFG/DEVICE 来源隔离且 trend 状态契约匹配", async () => {
  const collision = [
    "charging=0", "temp=99", "voltage=99", "current=99", "power=99", "soc=99", "limit_ma=99",
    "target=99", "state=hard_pause", "pid=99", "out=99", "uptime=99", "controller=wrong", "temp_rate_c_min=99", "temp_pred_25s=99", "model=wrong", "profile=wrong",
  ];
  const profile = [
    ...collision, "target_temp=99", "hard_temp=99", "min_ma=99", "max_ma=99",
    "ctl_mode=0", "dry_run=1", "enabled=0", "mca_tag=wrong", "model=fixture phone", "profile=fixture-profile",
  ];
  const { Data, commands } = loadAdapter(fixture({ cfg:[...config, ...collision], device:profile }));
  const got = await Data.status();
  assert.deepEqual(got, {
    alive:true, pid:42, latched:false, stale:false, heartbeat_age_s:1,
    version:"v-test / thermocharge test", charging:true, temp:42.6, voltage:4.2, current:3.25, power:13.7, soc:65,
    limit_ma:4000, target:43, hard:46, min_ma:500, max_ma:20000, state:"steady_hold", controller:"trend",
    out_ma:4000, uptime:600,
    temp_rate_c_min:0.1, temp_pred_25s:42.64, ctl_mode:2, wired_readback:"4000000",
    ichg_readback:"buck eff_client:user 4000|", dry_run:0, enabled:1, mca_tag:"user",
    device_model:"fixture phone", device_profile:"fixture-profile",
  });
  assert.equal(commands.length, 1);
  assert.ok(commands[0].startsWith(loadAdapter().daemonPidProbe()));
});

await test("缺少实时 state 不允许 CFG/profile 补造新鲜状态", async () => {
  for (const state of [[], live.filter(line => !line.startsWith("state="))]){
    const got = await loadAdapter(fixture({ state, cfg:[...config, "state=regulate", "temp=66"],
      device:["state=regulate", "temp=77", "target_temp=99"] })).Data.status();
    assert.equal(got.stale, true);
    assert.equal(got.state, "—");
    assert.equal(got.charging, null);
    assert.ok(Number.isNaN(got.temp));
    assert.ok(Number.isNaN(got.limit_ma));
    assert.equal(got.target, 44);
  }
});

await test("心跳/采样过期、无守护进程、保护锁定均隐藏实时采样", async () => {
  for (const options of [{ heartbeat:980 }, { mtime:980 }, { pid:0 }, { latched:true }]){
    const got = await loadAdapter(fixture(options)).Data.status();
    assert.equal(got.stale, true);
    assert.equal(got.state, "—");
    assert.equal(got.charging, null);
    for (const key of ["temp", "voltage", "current", "power", "soc", "limit_ma", "out_ma", "uptime", "temp_rate_c_min", "temp_pred_25s"]){
      assert.ok(Number.isNaN(got[key]), `${key} 必须隐藏`);
    }
  }
});

await test("新鲜度日志间隔仅来自 CFG，profile 不可放宽窗口", async () => {
  const cfg = config.map(line => line.startsWith("log_interval_ms=") ? "log_interval_ms=60000" : line);
  assert.equal((await loadAdapter(fixture({ mtime:945, cfg })).Data.status()).stale, false);
  assert.equal((await loadAdapter(fixture({ mtime:945, device:["log_interval_ms=60000"] })).Data.status()).stale, true);
});

await test("空输出安全回退，不伪造身份、配置或采样", async () => {
  const got = await loadAdapter().Data.status();
  assert.equal(got.alive, false);
  assert.equal(got.stale, true);
  assert.equal(got.enabled, 1);
  assert.equal(got.device_model, "");
  assert.ok(Number.isNaN(got.temp));
});

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tc-webui-status-"));
try {
  const fixturePaths = { data:path.join(tmp, "data"), bin:path.join(tmp, "bin/thermocharge"), mod:path.join(tmp, "module") };
  const proc = path.join(tmp, "proc");
  fs.mkdirSync(fixturePaths.data, { recursive:true });
  fs.mkdirSync(proc);
  function probe({ pid="42", argv=[fixturePaths.bin, "run"], exe=fixturePaths.bin, missing=false } = {}){
    fs.writeFileSync(path.join(fixturePaths.data, "daemon.pid"), pid);
    const processDir = path.join(proc, "42");
    fs.rmSync(processDir, { recursive:true, force:true });
    if (!missing){
      fs.mkdirSync(processDir);
      fs.writeFileSync(path.join(processDir, "cmdline"), argv.join("\0") + "\0");
      if (exe !== null) fs.symlinkSync(exe, path.join(processDir, "exe"));
    }
    const source = loadAdapter("", fixturePaths).daemonPidProbe().replaceAll("/proc/", `${proc}/`);
    assert.doesNotMatch(source, /\bkill\b/);
    const result = spawnSync("sh", ["-c", source + "printf '%s' \"$p\""], { encoding:"utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
  }
  await test("实际 shell 分段在输入文件没有末尾换行时仍隔离来源", async () => {
    assert.equal(probe(), "42");
    fs.mkdirSync(fixturePaths.mod, { recursive:true });
    for (const [name, text] of [
      ["state", live.join("\n")], ["config.conf", [...config, "temp=88", "state=hard_pause"].join("\n")],
      ["device.profile", "model=fixture phone\nprofile=fixture-profile\ntemp=99\nenabled=0"], ["heartbeat", ""],
    ]){
      const filename = path.join(fixturePaths.data, name);
      fs.writeFileSync(filename, text);
      fs.utimesSync(filename, 999, 999);
    }
    fs.writeFileSync(path.join(fixturePaths.mod, "module.prop"), "version=v-test");
    const { Data, commands } = loadAdapter("", fixturePaths);
    await Data.status();
    const command = commands[0].replaceAll("/proc/", `${proc}/`)
      .replaceAll("/sys/class/xm_power/", `${tmp}/readback/`);
    const result = spawnSync("sh", ["-c", command], { encoding:"utf8" });
    assert.equal(result.status, 0, result.stderr);
    const got = await loadAdapter(result.stdout, fixturePaths).Data.status();
    assert.equal(got.stale, false);
    assert.equal(got.state, "steady_hold");
    assert.equal(got.temp, 42.6);
    assert.equal(got.enabled, 1);
    assert.equal(got.device_model, "fixture phone");
    assert.equal(got.device_profile, "fixture-profile");
  });
  await test("伪 /proc 接受实际 thermocharge run 及更新前已删除可执行文件", () => {
    assert.equal(probe(), "42");
    assert.equal(probe({ argv:["thermocharge", "run"] }), "42");
    assert.equal(probe({ exe:`${fixturePaths.bin} (deleted)` }), "42");
  });
  await test("伪 /proc 拒绝 PID 复用、临时 CLI、脚本及子串冒充", () => {
    for (const options of [
      { argv:["sleep", "run"], exe:"/system/bin/sleep" },
      { argv:[fixturePaths.bin, "status"] }, { argv:[fixturePaths.bin] },
      { argv:[fixturePaths.bin, "runner"] }, { argv:[`${fixturePaths.bin}-fake`, "run"] },
      { argv:["/system/bin/sh", fixturePaths.bin, "run"] },
      { exe:"/other/bin/thermocharge" }, { exe:`${fixturePaths.bin}.old` }, { exe:null }, { argv:[] }, { missing:true },
    ]) assert.equal(probe(options), "0", JSON.stringify(options));
  });
  await test("pidfile 空/非法/多行/特殊 PID 不参与进程探测", () => {
    for (const pid of ["", "0", "1", "-42", "+42", "42xyz", "42 43", "42\n43", "../42", "99999999999999999999999999999"]){
      assert.equal(probe({ pid }), "0", JSON.stringify(pid));
    }
    assert.equal(probe({ pid:"42\n" }), "42");
  });
} finally {
  fs.rmSync(tmp, { recursive:true, force:true });
}

function sourceFunction(name){
  const start = html.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} 存在`);
  const end = html.indexOf("\n}", start) + 2;
  assert.ok(end > start);
  return html.slice(start, end);
}
const hintHost = { innerHTML:"" };
const renderHints = new Function("$", "renderStateList", "STATE_INFO", "hintHTML",
  `${sourceFunction("renderHints")}\nreturn renderHints;`)(
    id => { assert.equal(id, "sHint"); return hintHost; }, () => {}, {},
    (tone, title, body) => `${tone}|${title}|${body}`);
function hints(options){
  hintHost.innerHTML = "";
  renderHints({ state:"regulate", target:43, temp:42, limit_ma:4000, max_ma:20000, min_ma:500,
    current:12, power:50, enabled:1, alive:false, stale:true, latched:false, ...options });
  return hintHost.innerHTML;
}
await test("主动禁用且 stale 提示未启用及无实时状态；存活失联时不误称停用完成", () => {
  for (const alive of [false, true]){
    const text = hints({ enabled:0, alive });
    assert.match(text, /^warn\|模块未启用\|/);
    assert.match(text, /enabled=0/);
    assert.match(text, /无可用的实时状态/);
    assert.doesNotMatch(text, /守护进程未运行|状态数据已过期|实测取流|已主动停用/);
    if (alive){
      assert.match(text, /尚不能确认停用已完成/);
      assert.match(text, /停用尚未确认/);
      assert.match(text, /请先断开充电/);
    } else {
      assert.match(text, /未检测到运行中的守护进程/);
      assert.doesNotMatch(text, /danger\|/);
    }
  }
  assert.match(hints({ enabled:0, alive:true, heartbeat_age_s:20 }), /心跳已停止更新 20 秒/);
});
await test("禁用请求遇到新鲜旧快照时不继续实控诊断", () => {
  const text = hints({ enabled:0, alive:true, stale:false, charging:true });
  assert.match(text, /已请求停用/);
  assert.match(text, /快照可能来自停用前/);
  assert.doesNotMatch(text, /实测取流|不会写任何/);
});
await test("保护锁定优先于主动禁用；正常故障提示保留", () => {
  assert.match(hints({ enabled:0, latched:true }), /^danger\|接管失败保护已锁定\|/);
  assert.match(hints({}), /^danger\|守护进程未运行\|/);
  assert.match(hints({ alive:true }), /^danger\|状态数据已过期\|/);
  assert.match(hints({ alive:true, heartbeat_age_s:20 }), /心跳已停止更新 20 秒/);
});

await test("恢复前检查复用身份验证；无关进程/锁定不触发停止，停止失败不还原", async () => {
  const askRestore = sourceFunction("askRestore");
  const { daemonPidProbe } = loadAdapter();
  for (const [reply, stopErrno, expectedCommands, expectedActions] of [
    ["DEAD", 0, 1, 1], ["LATCHED", 0, 1, 0], ["ALIVE", 0, 2, 1], ["ALIVE", 1, 2, 0],
  ]){
    const commands = [], messages = [], actions = [];
    const restore = new Function("confirmSheet", "HAS_KSU", "sh", "PATHS", "daemonPidProbe", "toast", "Data", "refreshStatus",
      `${askRestore}\nreturn askRestore;`)(
        (title, text, callback) => callback(), true,
        async command => {
          commands.push(command);
          return { errno:commands.length === 1 ? 0 : stopErrno, stdout:`${reply}\n` };
        }, paths, daemonPidProbe, text => messages.push(text),
        { daemonAction:async action => { actions.push(action); return "restored"; } }, () => {});
    restore();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(commands.length, expectedCommands);
    assert.equal(actions.length, expectedActions);
    assert.ok(commands[0].includes(daemonPidProbe()));
    assert.doesNotMatch(commands[0], /\bkill\b/);
    assert.doesNotMatch(commands[0], /set enabled| stop/);
    if (expectedCommands === 2) assert.equal(commands[1], `${paths.bin} set enabled 0 && ${paths.bin} stop`);
    if (reply === "DEAD") assert.deepEqual(messages, ["restored"]);
    if (reply === "LATCHED") assert.match(messages[0], /保护已锁定/);
    if (stopErrno) assert.match(messages[0], /没有执行还原/);
  }
});

const removedKeys = [
  "power_mode", "kp", "ki", "kd", "deadband", "tdot_tau_s", "min_regulate_ma",
  "pred_enable", "pred_alpha", "pred_tau_s", "pred_ambient", "pred_margin", "pred_horizon_s", "pred_hit_s",
  "soft_landing", "soft_margin", "soft_band",
];
const removedState = ["active_power_mode", "pred_enable", "pred_cap_ma", "amb_est", "pid_i"];

await test("旧配置键全部过滤，缺省上限为 0，唯一功率配置为 power_max_w", async () => {
  const legacy = removedKeys.map(key => `${key}=1`).join("\n");
  const { Data, KEYS, SEGKEYS, GROUPS, commands } = loadAdapter(`target_temp=41.5\npower_max_w=37\n${legacy}`);
  const cfg = await Data.getConfig();
  assert.equal(cfg.target_temp, 41.5);
  assert.equal(cfg.power_max_w, 37);
  assert.equal((await loadAdapter(legacy).Data.getConfig()).power_max_w, 0);
  for (const key of removedKeys){
    assert.equal(Object.hasOwn(cfg, key), false, key);
    assert.equal(Object.hasOwn(KEYS, key) || Object.hasOwn(SEGKEYS, key), false, key);
    assert.ok(GROUPS.every(group => !group.keys.includes(key)), key);
  }
  assert.deepEqual(Object.keys(cfg).filter(key => key.startsWith("power")), ["power_max_w"]);
  assert.match(commands[0], /config-int power_max_w /);
  assert.doesNotMatch(commands[0], /power_mode|pred_|soft_/);
});

await test("配置缺失、非数值、越界及非法枚举回退安全默认值", async () => {
  const { Data, KEYS, SEGKEYS, DEMO_DEFAULTS } = loadAdapter([
    "power_max_w=oops", "target_temp=999", "max_ma=NaN", "min_ma=", "ctl_mode=99", "enabled=2", "dry_run=0oops",
  ].join("\n"));
  const cfg = await Data.getConfig();
  for (const key of [...Object.keys(KEYS), ...Object.keys(SEGKEYS)]){
    assert.equal(cfg[key], DEMO_DEFAULTS[key], key);
  }
  for (const value of ["-1", "121", "37.5", "37;echo injected"]){
    assert.equal((await loadAdapter(`power_max_w=${value}`).Data.getConfig()).power_max_w, 0);
  }
});

await test("白名单拒绝旧功能、未知键及命令注入，任意整数功率上限可保存", async () => {
  const { Data, commands } = loadAdapter();
  for (const key of [...removedKeys, "unknown", "__proto__", "constructor", "power_max_w; echo injected"]){
    assert.equal((await Data.setKey(key, 1)).ok, false, key);
  }
  for (const value of ["37", "37; echo injected", NaN, Infinity, -1, 121, 37.5, null]){
    assert.equal((await Data.setKey("power_max_w", value)).ok, false, String(value));
  }
  assert.equal((await Data.setKey("ctl_mode", 99)).ok, false);
  assert.equal(commands.length, 0, "拒绝项不能执行 shell");
  for (const value of [0, 1, 17, 37, 38, 39, 73, 119, 120]){
    assert.equal((await Data.setKey("power_max_w", value)).ok, true);
    assert.equal(commands.at(-1), `${paths.bin} set power_max_w ${value}`);
  }
  assert.equal((await Data.setKey("target_temp", 41.5)).ok, true);
  assert.equal((await Data.setKey("enabled", 0)).ok, true);
});

await test("仅新鲜 STATE 可声明 trend 控制器，旧字段永不镜像", async () => {
  const legacy = ["active_power_mode=1", "pred_enable=1", "pred_cap_ma=123", "amb_est=99", "pid=456"];
  for (const state of [live, [...live, ...legacy]]){
    const got = await loadAdapter(fixture({ state, cfg:[...config, ...legacy], device:legacy })).Data.status();
    assert.equal(got.controller, "trend");
    for (const key of removedState) assert.equal(Object.hasOwn(got, key), false, key);
    assert.equal(got.pid, 42, "进程 PID 不能被积分镜像覆盖");
    assert.equal(got.out_ma, 4000);
  }
  for (const options of [{ heartbeat:980 }, { latched:true }, {
    state:live.filter(line => !line.startsWith("controller=")), cfg:[...config, "controller=trend"], device:["controller=trend"],
  }]){
    assert.equal((await loadAdapter(fixture(options)).Data.status()).controller, "");
  }
});

// 轻量 DOM 夹具：执行整个页面脚本（包括 init），缺失元素会真实返回 null。
// KSU 命令仅记录并回传夹具输出，不执行；定时器仅记录，不访问真实设备。
function pageFixture({ native=false, stdout=fixture() } = {}){
  const nodes = new Map(), intervals = new Map(), timeouts = new Map();
  const commands = [], storageReads = [], requests = [], listeners = new Map();
  let sequence = 0;
  class Element {
    constructor(tag="div", attrs={}){
      this.tagName = tag.toUpperCase(); this.attrs = attrs; this.children = []; this.parentElement = null;
      this.dataset = {}; this.handlers = {}; this.className = attrs.class || "";
      this.value = attrs.value || ""; this._text = ""; this._html = ""; this.style = { setProperty(){} };
      for (const [key, val] of Object.entries(attrs)){
        if (key.startsWith("data-")) this.dataset[key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = val;
      }
      this.classList = {
        contains: name => this.className.split(/\s+/).includes(name),
        toggle: (name, force) => {
          const set = new Set(this.className.split(/\s+/).filter(Boolean));
          const on = force === undefined ? !set.has(name) : force;
          if (on) set.add(name); else set.delete(name);
          this.className = [...set].join(" "); return on;
        },
        add: name => this.classList.toggle(name, true), remove: name => this.classList.toggle(name, false),
      };
      if (attrs.id){ assert.ok(!nodes.has(attrs.id), `重复 ID ${attrs.id}`); nodes.set(attrs.id, this); }
    }
    get isConnected(){ return this === body || !!this.parentElement?.isConnected; }
    get textContent(){ return this._text + this.children.map(child => child.textContent).join(""); }
    set textContent(value){ this._text = String(value); this.children.forEach(child => child.parentElement = null); this.children = []; }
    get innerHTML(){ return this._html; }
    set innerHTML(value){ this.textContent = ""; this._html = ""; this.insertAdjacentHTML("beforeend", value); }
    appendChild(child){ child.parentElement = this; this.children.push(child); return child; }
    insertAdjacentHTML(where, value){ assert.equal(where, "beforeend"); this._html += value; parse(value, this); }
    matches(selector){
      const parts = selector.split(/\s+/);
      if (parts.length > 1){
        const last = parts.pop();
        let parent = this.parentElement;
        if (!this.matches(last)) return false;
        while (parent){ if (parent.matches(parts.join(" "))) return true; parent = parent.parentElement; }
        return false;
      }
      const tag = /^[\w-]+/.exec(selector)?.[0];
      if (tag && this.tagName !== tag.toUpperCase()) return false;
      for (const [, name] of selector.matchAll(/\.([\w-]+)/g)) if (!this.classList.contains(name)) return false;
      for (const [, name, value] of selector.matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)){
        const dataKey = name.startsWith("data-") ? name.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase()) : null;
        const actual = dataKey ? this.dataset[dataKey] : this.attrs[name];
        if (actual === undefined || (value !== undefined && actual !== value)) return false;
      }
      return true;
    }
    querySelectorAll(selector){
      return this.children.flatMap(child => [...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)]);
    }
    querySelector(selector){ return this.querySelectorAll(selector)[0] || null; }
    closest(selector){ return this.matches(selector) ? this : this.parentElement?.closest(selector) || null; }
    addEventListener(type, fn){ (this.handlers[type] ||= []).push(fn); }
    dispatch(type, options={}){ for (const fn of this.handlers[type] || []) fn({ preventDefault(){}, ...options }); }
    click(){ this.dispatch("click"); this.onclick?.(); }
    focus(){} select(){} blur(){ this.dispatch("blur"); } scrollIntoView(){}
    get clientWidth(){ return 360; }
    getContext(){
      return new Proxy({
        measureText:text => ({ width:String(text).length * 6 }),
        createLinearGradient:() => ({ addColorStop(){} }),
      }, { get:(target, key) => target[key] ?? (() => {}) });
    }
    remove(){ if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this); this.parentElement = null; }
    replaceWith(other){
      assert.ok(this.parentElement);
      const parent = this.parentElement, index = parent.children.indexOf(this);
      parent.children[index] = other; other.parentElement = parent; this.parentElement = null;
    }
  }
  function parse(markup, host){
    const stack = [host];
    for (const token of markup.matchAll(/<!--[\s\S]*?-->|<![^>]*>|<\/?[a-z][^>]*>|[^<]+/gi)){
      const text = token[0];
      if (text.startsWith("<!")) continue;
      if (text.startsWith("</")){ if (stack.length > 1) stack.pop(); continue; }
      if (!text.startsWith("<")){ stack.at(-1)._text += text; continue; }
      const tag = /^<([\w-]+)/.exec(text)[1], attrs = {};
      for (const [, key, quoted, single] of text.matchAll(/([\w-]+)=(?:"([^"]*)"|'([^']*)')/g)) attrs[key] = quoted ?? single;
      const node = stack.at(-1).appendChild(new Element(tag, attrs));
      if (!/^(?:input|meta|link|br|hr|img)$/i.test(tag)) stack.push(node);
    }
  }
  const body = new Element("body");
  parse(html.slice(html.indexOf("<body>") + 6, html.indexOf("<script>")), body);
  const document = {
    body, hidden:false, getElementById:id => nodes.get(id) || null,
    createElement:tag => new Element(tag), querySelectorAll:selector => body.querySelectorAll(selector),
    addEventListener:(type, fn) => listeners.set(type, fn),
  };
  const context = vm.createContext({
    document, console, navigator:{}, Date:FixtureDate,
    Math:Object.assign(Object.create(Math), { random:() => 0.5 }),
    setTimeout:(fn, ms) => { const id = ++sequence; timeouts.set(id, { fn, ms }); return id; },
    clearTimeout:id => timeouts.delete(id),
    setInterval:(fn, ms) => { const id = ++sequence; intervals.set(id, { fn, ms }); return id; },
    clearInterval:id => intervals.delete(id),
    localStorage:{ getItem:key => { storageReads.push(key); return '{"alpha":1,"tamb":60,"power":120}'; } },
    fetch:async url => { requests.push(url); return { ok:false, status:404 }; },
    scrollTo(){}, getComputedStyle:() => ({ getPropertyValue:() => "#888888" }),
  });
  context.window = context;
  if (native) context.ksu = { exec(command, options, callback){ commands.push(command); context[callback](0, stdout, ""); } };
  vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context, { timeout:5000 });
  const api = vm.runInContext("({ Data, Demo, KEYS, SEGKEYS, GROUPS, loadConfig, renderStatus, refreshStatus, switchPage, schedule, saveAll, restoreDefaults })", context);
  return { api, context, document, nodes, intervals, timeouts, commands, storageReads, requests, listeners };
}
const settle = async () => { await new Promise(resolve => setImmediate(resolve)); };

await test("完整启动和四页切换不访问旧工具存储、不查找缺失页面、不启动辨识轮询", async () => {
  for (const native of [false, true]){
    const page = pageFixture({ native });
    await settle();
    assert.equal(page.intervals.size, 1);
    assert.equal([...page.intervals.values()][0].ms, 2500);
    assert.equal(page.nodes.get("sController").textContent, "电池温度趋势");
    assert.match(page.nodes.get("sTrend").textContent, /℃\/分 · .* ℃/);
    assert.equal(page.nodes.has("page-tool"), false);
    assert.equal(page.nodes.has("sAmb"), false);
    assert.equal(page.nodes.has("sPid"), false);
    page.api.switchPage("config"); await settle();
    assert.equal(page.intervals.size, 0);
    assert.equal(page.nodes.get("page-config").classList.contains("hidden"), false);
    const groups = page.nodes.get("cfgGroups");
    assert.match(groups.innerHTML, /默认 0 = 自动不限，不是固定功率目标/);
    assert.equal(groups.querySelectorAll('.item[data-key="power_max_w"]').length, 1);
    assert.equal(groups.querySelectorAll('input[data-rk="power_max_w"]').length, 1);
    assert.equal(groups.querySelectorAll('[data-seg="power_max_w"]').length, 0);
    for (const key of removedKeys) assert.equal(groups.querySelector(`[data-key="${key}"]`), null);
    page.api.switchPage("log"); await settle();
    assert.equal([...page.intervals.values()][0].ms, 5000);
    page.api.switchPage("charge"); await settle();
    assert.equal([...page.intervals.values()][0].ms, 30000);
    assert.equal(page.nodes.get("page-charge").classList.contains("hidden"), false);
    assert.ok(page.nodes.get("curveCount").textContent);
    page.api.switchPage("status"); await settle();
    for (const retired of ["tool", "identify", "unknown"]){
      const before = page.commands.length;
      page.api.switchPage(retired); await settle();
      assert.equal(page.commands.length, before);
      assert.equal(page.nodes.get("page-status").classList.contains("hidden"), false);
      assert.equal([...page.intervals.values()][0].ms, 2500);
    }
    page.document.hidden = true; page.listeners.get("visibilitychange")();
    assert.equal(page.intervals.size, 0);
    page.document.hidden = false; page.listeners.get("visibilitychange")();
    assert.equal(page.intervals.size, 1);
    assert.deepEqual(page.storageReads, []);
    assert.doesNotMatch(page.commands.join("\n"), /identify|pred_|soft_|power_mode|\bsu\b/);
    assert.equal(page.timeouts.size, 0, "启动不能遗留辨识或超时轮询");
  }
});

await test("功率上限滑块、数字输入和保存走同一白名单，无预设档位", async () => {
  const page = pageFixture(); await settle();
  page.api.switchPage("config"); await settle();
  let groups = page.nodes.get("cfgGroups");
  const slider = groups.querySelector('input[data-rk="power_max_w"]');
  for (const value of [17, 37, 38, 39, 73, 0, 120]){
    slider.value = String(value); slider.dispatch("input");
    assert.equal(groups.querySelector('[data-vk="power_max_w"]').textContent, String(value));
    assert.equal(page.nodes.get("saveBar").classList.contains("hidden"), value === 0);
  }
  await page.api.saveAll();
  assert.equal(page.api.Demo.cfg.power_max_w, 120);
  groups.querySelector('[data-vk="power_max_w"]').click();
  let input = groups.querySelector(".valin");
  assert.ok(input); input.value = "37"; input.blur();
  await page.api.saveAll();
  assert.equal(page.api.Demo.cfg.power_max_w, 37);
  groups = page.nodes.get("cfgGroups");
  groups.querySelector('[data-vk="power_max_w"]').click();
  input = groups.querySelector(".valin"); input.value = "121"; input.blur();
  assert.equal(groups.querySelector('[data-vk="power_max_w"]').textContent, "37");
  groups.querySelector('[data-vk="power_max_w"]').click();
  input = groups.querySelector(".valin"); input.value = "75"; input.dispatch("keydown", { key:"Escape" });
  assert.equal(groups.querySelector('[data-vk="power_max_w"]').textContent, "37");
  await page.api.saveAll();
  assert.equal(page.api.Demo.cfg.power_max_w, 37);
});

await test("Demo 只使用 trend，旧配置不能复活模型；上限不作为固定追踪目标", async () => {
  const page = pageFixture(); await settle();
  const { Demo, Data } = page.api;
  for (const key of removedKeys) Demo.cfg[key] = 1;
  const cfg = await Data.getConfig();
  for (const key of removedKeys){
    assert.equal(Object.hasOwn(cfg, key), false);
    assert.equal((await Data.setKey(key, 1)).ok, false);
  }
  Object.assign(Demo.live, { temp:43, limit_ma:12345, temp_rate_c_min:0 });
  Demo.cfg.power_max_w = 0; Demo.tick();
  assert.equal(Demo.live.limit_ma, 12345);
  assert.equal(Demo.live.state, "steady_hold");
  Demo.cfg.power_max_w = 120; Demo.tick();
  assert.equal(Demo.live.limit_ma, 12345, "放宽上限不会追涨到设定瓦数");
  const limits = [];
  for (let watts=31; watts<=40; watts++){
    Object.assign(Demo.live, { temp:43, limit_ma:20000, temp_rate_c_min:0 });
    Demo.cfg.power_max_w = watts; Demo.tick();
    limits.push(Demo.live.limit_ma);
    assert.ok(Math.abs(Demo.live.limit_ma * Demo.live.voltage / 1000 - watts) < 1e-10);
    assert.equal(Demo.live.state, "power_cap");
    assert.ok(Demo.live.power <= watts);
  }
  assert.equal(new Set(limits).size, 10, "相邻功率上限不会吸附到固定档位");
  Demo.cfg.power_max_w = 0;
  Object.assign(Demo.live, { temp:41, limit_ma:12000, temp_rate_c_min:0 }); Demo.tick();
  assert.ok(Demo.live.limit_ma > 12000); assert.equal(Demo.live.state, "steady_rise");
  Object.assign(Demo.live, { temp:44, limit_ma:12000, temp_rate_c_min:0 }); Demo.tick();
  assert.ok(Demo.live.limit_ma < 12000); assert.equal(Demo.live.state, "steady_reduce");
  const status = await Data.status();
  assert.equal(status.controller, "trend");
  assert.ok(Number.isFinite(status.temp_rate_c_min) && Number.isFinite(status.temp_pred_25s));
  for (const key of removedState) assert.equal(Object.hasOwn(status, key), false);
  await Data.defaults();
  assert.equal(Demo.cfg.power_max_w, 0);
  for (const key of removedKeys) assert.equal(Object.hasOwn(Demo.cfg, key), false);
});

await test("状态渲染保留趋势与输出，过期/缺失字段显示占位而非旧模型", async () => {
  const page = pageFixture(); await settle();
  const { Data } = loadAdapter(fixture());
  const status = await Data.status();
  page.api.renderStatus(status);
  assert.equal(page.nodes.get("sOut").textContent, "4000 mA");
  assert.match(page.nodes.get("sTrend").textContent, /\+0\.10 ℃\/分 · 42\.6 ℃/);
  page.api.renderStatus(await loadAdapter(fixture({ heartbeat:980 })).Data.status());
  for (const id of ["sTemp", "sPower", "sTrend", "sController", "sOut"]){
    assert.equal(page.nodes.get(id).textContent, "—", id);
  }
  assert.match(page.nodes.get("sDaemon").innerHTML, /状态过期/);
  page.api.renderStatus({ ...status, temp_rate_c_min:NaN, temp_pred_25s:NaN });
  assert.equal(page.nodes.get("sTrend").textContent, "—");
});

console.log(`WebUI status: ${count} 组回归通过`);
