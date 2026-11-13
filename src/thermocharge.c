/*
 * thermocharge - 恒温充电控制器 (Redmi K90 Ultra / warsaw)
 *
 * 原理：
 *   电池温度是被控量，充电电流上限是控制量。
 *   以 PI(D) 闭环把电池温度锁在 target，充电功率随温度偏差自动浮动。
 *
 * 调节手段（ctl_mode 选择，默认 2）：
 *   1) /sys/class/xm_power/charger/charge_interface/ichg_limit   (mA)（ctl_mode=1 单写）
 *      双写默认同时还会写 wired_chg_curr，以覆盖部分电荷泵阶段的执行差异。
 *      写入格式是三 token:  "<标签> <类型> <数值>"，如 "user all 5000"
 *      —— 解析失败会打印 mca_charge_if_sysfs_store:347 unable to parse input
 *      内核把它当作向 votable 的一次投票，聚合类型 Min：我们只能限得更小，
 *      永远不会比系统原有保护更激进。电荷泵阶段可能还需要 wired_chg_curr。
 *      单独 mca 与 wired_chg_curr 双写的 ctl_mode=2 是默认模式。
 *   0) /sys/class/xm_power/charger/charger_thermal/wired_chg_curr  (uA)
 *      —— mi_thermald 的 thermal_fcc_override，会被系统周期覆写，
 *         需要靠 fast_write_ms 高频对抗；ctl_mode=2 下与 MCA 通道共同写入。
 *   2) 两条都写。
 *
 * 安全：
 *   - 启动先写安全值 startup_ma，再靠 slew 限速爬到目标
 *   - 温度超过 hard_temp 强制降到 min_ma；持续超限可暂停充电
 *   - 默认不碰 wired_thermal_remove（不取消系统温控），靠 Min 聚合共存
 *   - 任何一次安全降流都不会被后面的分支推翻（见主循环 limit_ma 只降不升）
 *   - SIGTERM / 卸载 / 崩溃由 service.sh 看门狗兜底还原
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <ctype.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/types.h>
#include <stdarg.h>

#define TC_VERSION "1.2.5"
#define MAXPATH 256
#define MAXLINE 512

/* ---------------- 配置 ---------------- */

typedef struct {
    int  enabled;
    int  dry_run;

    int  target_temp_x10;   /* 目标温度，0.1℃ 单位，430 = 43.0℃ */
    int  hard_temp_x10;     /* 硬上限，超过则强制 min_ma */
    int  deadband_x10;      /* 死区，0.1℃ */

    int  max_ma;            /* 控制输出上限 (mA) */
    int  min_ma;            /* 控制输出下限 (mA) */
    int  startup_ma;        /* 启动安全值 */

    double kp;              /* 未使用（保留兼容），速度式由 ki 决定一切 */
    double ki;              /* mA/(℃·s)：误差每 1℃ 每秒调整的电流量 */
    double kd;              /* 阻尼时间常数（秒） */
    double tdot_tau_s;      /* 温度变化率低通时间常数（秒） */
    int  slew_ma_s;         /* 输出变化率上限 mA/s */

    int  sample_ms;         /* 控制周期 */
    int  fast_write_ms;     /* 快速回写周期（对抗系统覆写） */
    int  log_interval_ms;   /* CSV 日志周期 */

    int  hold_below_soc;    /* SOC 高于该值则不再限流，交还系统 */
    int  pause_on_hard;     /* 超硬上限且已在 min 时暂停充电 */

    int  restore_ma;        /* 退出还原值 */
    int  thermal_remove;    /* 1 = 接管系统 FCC 温控（默认 0，保留系统保护） */
    int  ctl_mode;          /* 0=wired_chg_curr  1=mca ichg_limit  2=两者都写（默认） */
    char mca_tag[32];       /* mca 投票者标签 */
    char mca_type[32];      /* mca 通道类型：all / buck / quick ... */
    int  startup_grace_ms;  /* 插电后多久开始接管（让 CP 先握手） */
    int  reassert_ms;       /* 同值重投间隔（系统可能把我们那票关掉/覆盖） */

    /* ---- 预测限幅 / 软着陆（默认全关；逐项开启，保证单变量可归因） ----
     * pred_alpha 必须先由开环阶跃辨识得到，否则启用会自动退回关闭（见 cfg_load 末尾）。 */
    int    pred_enable;     /* 1 = 启用预测上限 */
    double pred_alpha;      /* ℃/A²：稳态温升系数，T∞ = Tamb + α·I² */
    double pred_tau_s;      /* 热时间常数 τ（秒） */
    double pred_ambient;    /* 环境温度；<=0 表示自动估计 */
    double pred_margin;     /* 前瞻目标偏移（℃）：用 target+margin 做约束，换取瞬态余量 */
    double pred_horizon_s;  /* 前瞻时域 H（秒） */
    double pred_hit_s;      /* 到点时间阈值：t_hit 低于它就提前压流 */
    int    min_regulate_ma; /* 软着陆/调节下限（0 = 沿用 min_ma） */
    int    soft_landing;    /* 1 = 接近目标即压到 min_regulate，不归零 */
    double soft_margin;     /* 软着陆触发余量（℃） */
    double soft_band;       /* 软着陆保持带宽度（℃）：超出后放开下限交给硬保护 */

    char p_temp[MAXPATH];
    char p_voltage[MAXPATH];
    char p_current[MAXPATH];
    char p_status[MAXPATH];
    char p_usb_online[MAXPATH];
    char p_capacity[MAXPATH];
    char p_ctl[MAXPATH];
    char p_thermal_remove[MAXPATH];
    char p_stop_handle[MAXPATH];
    char p_ichg[MAXPATH];
    char p_suspend[MAXPATH];   /* mca input_suspend，硬停充用 */
} cfg_t;

static cfg_t C;
static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_reload = 0;
/* 运行数据目录。默认 /data/adb/thermocharge。
 * TC_DATA 可覆盖 —— 仿真与故障注入测试必须写到自己的目录里，
 * 否则会和真机守护进程抢同一个 log/csv/state/pid 文件，
 * 两边的记录互相污染，测试结论也就不可信了。 */
static char g_dir[MAXPATH] = "/data/adb/thermocharge";
static char g_cfgpath[MAXPATH] = "";
static char g_logpath[MAXPATH] = "";
static char g_csvpath[MAXPATH] = "";
static char g_pidpath[MAXPATH] = "";
static char g_lockpath[MAXPATH] = "";
static char g_statepath[MAXPATH] = "";

static void resolve_paths(void)
{
    const char *env = getenv("TC_DATA");
    if (env && env[0] == '/') {
        snprintf(g_dir, sizeof g_dir, "%s", env);
    }
    snprintf(g_cfgpath,   sizeof g_cfgpath,   "%s/config.conf",      g_dir);
    snprintf(g_logpath,   sizeof g_logpath,   "%s/log/daemon.log",   g_dir);
    snprintf(g_csvpath,   sizeof g_csvpath,   "%s/log/curve.csv",    g_dir);
    snprintf(g_pidpath,   sizeof g_pidpath,   "%s/daemon.pid",       g_dir);
    snprintf(g_lockpath,  sizeof g_lockpath,  "%s/daemon.lock",      g_dir);
    snprintf(g_statepath, sizeof g_statepath, "%s/state",            g_dir);
    /* 配置文件仍可用 TC_CONFIG 单独覆盖（兼容旧测试脚本） */
    const char *cfg = getenv("TC_CONFIG");
    if (cfg && cfg[0] == '/') snprintf(g_cfgpath, sizeof g_cfgpath, "%s", cfg);
}

static void on_term(int s) { (void)s; g_stop = 1; }
static void on_hup(int s)  { (void)s; g_reload = 1; }

static void cfg_defaults(cfg_t *c)
{
    memset(c, 0, sizeof(*c));
    c->enabled = 1;
    c->dry_run = 0;

    c->target_temp_x10 = 430;
    c->hard_temp_x10   = 450;
    c->deadband_x10    = 2;

    c->max_ma     = 20000;   /* K90U 原厂快充 17.6A，模块上限给 20.5A 以内 */
    c->min_ma     = 500;
    c->startup_ma = 2000;

    c->kp = 0.0;
    c->ki = 120.0;      /* 保守默认；环境斜坡下稳态偏差约 0.9C，满足 ±1C 目标 */
    c->kd = 40.0;       /* 阻尼时间常数 40s，对机型热参数不敏感 */
    c->tdot_tau_s = 6.0;
    c->slew_ma_s = 2500;

    c->sample_ms      = 500;
    c->fast_write_ms  = 100;
    c->log_interval_ms = 1000;

    c->hold_below_soc = 95;
    c->pause_on_hard  = 1;

    c->restore_ma     = 22000000;
    c->thermal_remove = 0;      /* 绝不以取消系统保护为代价；靠 Min 聚合共存 */
    c->ctl_mode       = 2;      /* 双写：兼顾 MCA 投票与电荷泵限流 */
    snprintf(c->mca_tag,  sizeof c->mca_tag,  "user");
    snprintf(c->mca_type, sizeof c->mca_type, "all");
    c->startup_grace_ms = 20000; /* 插电后 20s 内完全不写：让协议认证与电荷泵爬升先完成 */
    c->reassert_ms      = 5000;  /* 每 5s 重投一次同值票；不对回读做判等（见 enforce） */

    /* 预测层默认关闭：alpha 未辨识前启用没有意义，且会把"不可归因"带进真机实验 */
    c->pred_enable     = 0;
    c->pred_alpha      = 0.0;
    c->pred_tau_s      = 45.0;
    c->pred_ambient    = 0.0;    /* 0 = 自动估计（低电流时贴合实测温度） */
    c->pred_margin     = 0.5;    /* 前瞻目标 = target+0.5℃，留一点瞬态余量 */
    c->pred_horizon_s  = 60.0;
    c->pred_hit_s      = 60.0;
    c->min_regulate_ma = 0;      /* 0 = 关闭，PID 下限仍是 min_ma */
    c->soft_landing    = 0;
    c->soft_margin     = 0.8;
    c->soft_band       = 0.7;    /* 43.8–44.5℃ 停在 min_regulate；再高就放开下限 */

    snprintf(c->p_temp,     MAXPATH, "/sys/class/power_supply/battery/temp");
    snprintf(c->p_voltage,  MAXPATH, "/sys/class/power_supply/battery/voltage_now");
    snprintf(c->p_current,  MAXPATH, "/sys/class/power_supply/battery/current_now");
    snprintf(c->p_status,   MAXPATH, "/sys/class/power_supply/battery/status");
    snprintf(c->p_usb_online, MAXPATH, "/sys/class/power_supply/usb/online");
    snprintf(c->p_capacity, MAXPATH, "/sys/class/power_supply/battery/capacity");
    snprintf(c->p_ctl,      MAXPATH, "/sys/class/xm_power/charger/charger_thermal/wired_chg_curr");
    snprintf(c->p_thermal_remove, MAXPATH, "/sys/class/xm_power/charger/charger_thermal/wired_thermal_remove");
    snprintf(c->p_stop_handle,    MAXPATH, "/sys/class/xm_power/charger/charger_common/stop_handle_charge");
    snprintf(c->p_ichg,           MAXPATH, "/sys/class/xm_power/charger/charge_interface/ichg_limit");
    snprintf(c->p_suspend,        MAXPATH, "/sys/class/xm_power/charger/charge_interface/input_suspend");
}

/* ---------------- 文件 I/O ---------------- */

static int read_file_str(const char *path, char *buf, size_t n)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t r = read(fd, buf, n - 1);
    close(fd);
    if (r < 0) return -1;
    buf[r] = 0;
    while (r > 0 && (buf[r-1] == '\n' || buf[r-1] == '\r' || buf[r-1] == ' '))
        buf[--r] = 0;
    return 0;
}

static long read_file_long(const char *path, long dflt)
{
    char b[64];
    if (read_file_str(path, b, sizeof b) < 0) return dflt;
    char *end = NULL;
    long v = strtol(b, &end, 10);
    if (end == b) return dflt;
    return v;
}

static int write_file_str(const char *path, const char *s)
{
    if (C.dry_run) return 0;
    /* O_TRUNC: real sysfs ignores it, but file-backed test harnesses
     * (and any regular-file sysfs stand-in) would otherwise keep the tail
     * of a longer previous value and read back garbage. */
    int fd = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t len = strlen(s);
    ssize_t w = write(fd, s, len);
    int e = errno;
    close(fd);
    if (w != (ssize_t)len) { errno = e ? e : EIO; return -1; }
    return 0;
}

static int write_file_long(const char *path, long v)
{
    char b[32];
    snprintf(b, sizeof b, "%ld", v);
    return write_file_str(path, b);
}

/* ---------------- 日志 ---------------- */

static FILE *g_log = NULL;
static long  g_log_bytes = 0;

static void log_open(void)
{
    g_log = fopen(g_logpath, "a");
    if (g_log) fchmod(fileno(g_log), 0600);
    if (g_log) {
        fseek(g_log, 0, SEEK_END);
        g_log_bytes = ftell(g_log);
    }
}

static void log_msg(const char *fmt, ...)
{
    char tbuf[32];
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    strftime(tbuf, sizeof tbuf, "%m-%d %H:%M:%S", &tm);

    char line[MAXLINE];
    va_list ap;
    __builtin_va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line, fmt, ap);
    __builtin_va_end(ap);
    if (n < 0) return;

    fprintf(stderr, "[%s] %s\n", tbuf, line);
    if (g_log) {
        fprintf(g_log, "[%s] %s\n", tbuf, line);
        fflush(g_log);
        /* 实际落盘长度 = "[MM-DD HH:MM:SS] " (21 字节) + 正文 + 换行 */
        g_log_bytes += n + 23;
        if (g_log_bytes > 512 * 1024) {
            fclose(g_log);
            char bak[MAXPATH];
            snprintf(bak, sizeof bak, "%s.1", g_logpath);
            rename(g_logpath, bak);
            log_open();
        }
    }
}

static FILE *g_csv = NULL;

static long g_csv_bytes = 0;

static void csv_open(void)
{
    /* 轮转：1Hz 采样约 5MB/天，不轮转一年就是 1.8GB。
     * 超过 8MB 就换名，最多保留 .1 .2 两份。 */
    struct stat st;
    if (stat(g_csvpath, &st) == 0 && st.st_size > 8 * 1024 * 1024) {
        char a[MAXPATH], b[MAXPATH];
        snprintf(a, sizeof a, "%s.2", g_csvpath);
        snprintf(b, sizeof b, "%s.1", g_csvpath);
        rename(b, a);
        rename(g_csvpath, b);
    }
    int fresh = (access(g_csvpath, F_OK) != 0);
    g_csv = fopen(g_csvpath, "a");
    if (g_csv) {
        g_csv_bytes = fresh ? 0 : (stat(g_csvpath, &st) == 0 ? st.st_size : 0);
        if (fresh)
            fprintf(g_csv, "epoch,temp_c,volt_v,curr_a,power_w,soc,limit_ma,target_c,state\n");
    }
}

/* ---------------- 配置加载 ---------------- */

static void trim(char *s)
{
    char *p = s;
    while (*p && isspace((unsigned char)*p)) p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
    size_t n = strlen(s);
    while (n > 0 && isspace((unsigned char)s[n-1])) s[--n] = 0;
}

/* 带校验的数值解析：非法值保持原样并返回 -1，由调用方决定是否告警。
 * 之前全部用 atoi/atof，`target_temp=abc` 会静默变成 0℃，再做钳制就变 25℃。 */
static int parse_int(const char *v, int *out)
{
    char *end = NULL;
    errno = 0;
    long r = strtol(v, &end, 10);
    if (end == v || *end || errno) return -1;
    *out = (int)r;
    return 0;
}

static int parse_dbl(const char *v, double *out)
{
    char *end = NULL;
    errno = 0;
    double r = strtod(v, &end);
    if (end == v || *end || errno || !isfinite(r)) return -1;
    *out = r;
    return 0;
}

/* 只接受 /sys 前缀的路径，挡住 `set p_ichg /tmp/x` 这种把 root 写入重定向到
 * 任意文件（O_WRONLY|O_TRUNC 会直接把文件截断）的攻击面。 */
static int path_ok(const char *v)
{
    if (strncmp(v, "/sys/", 5) == 0) return 1;
    /* 仿真/单测逃生口：只有显式设了这个环境变量，才允许把 p_* 指向普通文件。
     * 生产环境（service.sh 拉起）绝不会设它。 */
    if (getenv("TC_ALLOW_FAKE_SYSFS")) return strncmp(v, "/", 1) == 0;
    return 0;
}

static void cfg_load(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        /* 打开失败不再静默：带着默认值跑但必须留痕 */
        log_msg("WARN: cannot open config %s (%s), using defaults", path, strerror(errno));
        return;
    }

    char line[MAXLINE];
    while (fgets(line, sizeof line, f)) {
        char *hash = strchr(line, '#');   /* 行内注释：config.conf 里没有含 # 的合法值 */
        if (hash) *hash = 0;
        trim(line);
        if (!*line) continue;

        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char *k = line, *v = eq + 1;
        trim(k); trim(v);
        if (!*k) continue;

        int iv = 0; double dv = 0.0;
        if      (!strcmp(k, "enabled"))            { if (!parse_int(v,&iv)) C.enabled = iv; }
        else if (!strcmp(k, "dry_run"))            { if (!parse_int(v,&iv)) C.dry_run = iv; }
        else if (!strcmp(k, "target_temp"))        { if (!parse_dbl(v,&dv)) C.target_temp_x10 = (int)(dv * 10.0 + 0.5); }
        else if (!strcmp(k, "hard_temp"))          { if (!parse_dbl(v,&dv)) C.hard_temp_x10 = (int)(dv * 10.0 + 0.5); }
        else if (!strcmp(k, "deadband"))           { if (!parse_dbl(v,&dv)) C.deadband_x10 = (int)(dv * 10.0 + 0.5); }
        else if (!strcmp(k, "max_ma"))             { if (!parse_int(v,&iv)) C.max_ma = iv; }
        else if (!strcmp(k, "min_ma"))             { if (!parse_int(v,&iv)) C.min_ma = iv; }
        else if (!strcmp(k, "startup_ma"))         { if (!parse_int(v,&iv)) C.startup_ma = iv; }
        else if (!strcmp(k, "kp"))                 { if (!parse_dbl(v,&dv)) C.kp = dv; }
        else if (!strcmp(k, "ki"))                 { if (!parse_dbl(v,&dv)) C.ki = dv; }
        else if (!strcmp(k, "kd"))                 { if (!parse_dbl(v,&dv)) C.kd = dv; }
        else if (!strcmp(k, "tdot_tau_s"))         { if (!parse_dbl(v,&dv)) C.tdot_tau_s = dv; }
        else if (!strcmp(k, "slew_ma_s"))          { if (!parse_int(v,&iv)) C.slew_ma_s = iv; }
        else if (!strcmp(k, "sample_ms"))          { if (!parse_int(v,&iv)) C.sample_ms = iv; }
        else if (!strcmp(k, "fast_write_ms"))      { if (!parse_int(v,&iv)) C.fast_write_ms = iv; }
        else if (!strcmp(k, "log_interval_ms"))    { if (!parse_int(v,&iv)) C.log_interval_ms = iv; }
        else if (!strcmp(k, "hold_below_soc"))     { if (!parse_int(v,&iv)) C.hold_below_soc = iv; }
        else if (!strcmp(k, "pause_on_hard"))      { if (!parse_int(v,&iv)) C.pause_on_hard = iv; }
        else if (!strcmp(k, "restore_ma"))         { if (!parse_int(v,&iv)) C.restore_ma = iv; }
        else if (!strcmp(k, "thermal_remove"))     { if (!parse_int(v,&iv)) C.thermal_remove = iv; }
        else if (!strcmp(k, "startup_grace_ms"))   { if (!parse_int(v,&iv)) C.startup_grace_ms = iv; }
        else if (!strcmp(k, "reassert_ms"))        { if (!parse_int(v,&iv)) C.reassert_ms = iv; }
        else if (!strcmp(k, "pred_enable"))        { if (!parse_int(v,&iv)) C.pred_enable = iv; }
        else if (!strcmp(k, "pred_alpha"))         { if (!parse_dbl(v,&dv)) C.pred_alpha = dv; }
        else if (!strcmp(k, "pred_tau_s"))         { if (!parse_dbl(v,&dv)) C.pred_tau_s = dv; }
        else if (!strcmp(k, "pred_ambient"))       { if (!parse_dbl(v,&dv)) C.pred_ambient = dv; }
        else if (!strcmp(k, "pred_margin"))        { if (!parse_dbl(v,&dv)) C.pred_margin = dv; }
        else if (!strcmp(k, "pred_horizon_s"))     { if (!parse_dbl(v,&dv)) C.pred_horizon_s = dv; }
        else if (!strcmp(k, "pred_hit_s"))         { if (!parse_dbl(v,&dv)) C.pred_hit_s = dv; }
        else if (!strcmp(k, "min_regulate_ma"))    { if (!parse_int(v,&iv)) C.min_regulate_ma = iv; }
        else if (!strcmp(k, "soft_landing"))       { if (!parse_int(v,&iv)) C.soft_landing = iv; }
        else if (!strcmp(k, "soft_margin"))        { if (!parse_dbl(v,&dv)) C.soft_margin = dv; }
        else if (!strcmp(k, "soft_band"))          { if (!parse_dbl(v,&dv)) C.soft_band = dv; }
        else if (!strcmp(k, "p_temp"))             { if (path_ok(v)) snprintf(C.p_temp, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_voltage"))          { if (path_ok(v)) snprintf(C.p_voltage, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_current"))          { if (path_ok(v)) snprintf(C.p_current, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_status"))           { if (path_ok(v)) snprintf(C.p_status, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_usb_online"))       { if (path_ok(v)) snprintf(C.p_usb_online, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_capacity"))         { if (path_ok(v)) snprintf(C.p_capacity, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_ctl"))              { if (path_ok(v)) snprintf(C.p_ctl, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_thermal_remove"))   { if (path_ok(v)) snprintf(C.p_thermal_remove, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_stop_handle"))      { if (path_ok(v)) snprintf(C.p_stop_handle, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_ichg"))             { if (path_ok(v)) snprintf(C.p_ichg, MAXPATH, "%s", v); }
        else if (!strcmp(k, "p_suspend"))          { if (path_ok(v)) snprintf(C.p_suspend, MAXPATH, "%s", v); }
        else if (!strcmp(k, "ctl_mode"))           { if (!parse_int(v,&iv)) C.ctl_mode = iv; }
        else if (!strcmp(k, "mca_tag"))            snprintf(C.mca_tag, sizeof C.mca_tag, "%s", v);
        else if (!strcmp(k, "mca_type"))           snprintf(C.mca_type, sizeof C.mca_type, "%s", v);
    }
    fclose(f);

    /* 合理性钳制，避免手改配置把机器写坏 */
    if (C.sample_ms < 100)             C.sample_ms = 100;
    if (C.fast_write_ms < 50)          C.fast_write_ms = 50;
    if (C.min_ma < 100)                C.min_ma = 100;
    if (C.max_ma > 20500)              C.max_ma = 20500;   /* 原厂快充 17.6A，20.5A 已是余量上限 */
    /* 两道钳制必须互相回夹，否则 min=30000/max=20500 这种组合会让 30A 被放行 */
    if (C.min_ma > C.max_ma - 100)     C.min_ma = C.max_ma - 100;
    if (C.min_ma < 100)                C.min_ma = 100;
    if (C.max_ma <= C.min_ma)          C.max_ma = C.min_ma + 100;
    /* restore_ma 内部一律按 uA 处理：用户若按 mA 填（<1000）自动升位，再夹到合法区间 */
    if (C.restore_ma > 0 && C.restore_ma < 1000) C.restore_ma *= 1000;
    if (C.restore_ma < 1000000)        C.restore_ma = 22000000;
    if (C.restore_ma > 22000000)       C.restore_ma = 22000000;
    if (C.startup_ma < C.min_ma)       C.startup_ma = C.min_ma;
    if (C.startup_ma > C.max_ma)       C.startup_ma = C.max_ma;
    if (C.target_temp_x10 < 250)       C.target_temp_x10 = 250;
    if (C.target_temp_x10 > 500)       C.target_temp_x10 = 500;
    if (C.hard_temp_x10 < C.target_temp_x10 + 10)
        C.hard_temp_x10 = C.target_temp_x10 + 10;
    /* 上限必须有：hard_temp=99 会让全部过温保护静默失效 */
    if (C.hard_temp_x10 > 550)         C.hard_temp_x10 = 550;
    if (C.deadband_x10 < 0)            C.deadband_x10 = 0;
    if (C.slew_ma_s <= 0)              C.slew_ma_s = 1000;
    if (C.log_interval_ms < 200)       C.log_interval_ms = 200;
    if (C.hold_below_soc < 0 || C.hold_below_soc > 100) C.hold_below_soc = 95;
    /* 越界值回落到与 cfg_defaults 一致的默认 2（双通道），不静默切到单通道 mca */
    if (C.ctl_mode < 0 || C.ctl_mode > 2) {
        log_msg("WARN: ctl_mode=%d out of range 0..2 -> using default 2", C.ctl_mode);
        C.ctl_mode = 2;
    }
    if (C.ki < 1.0)    C.ki = 1.0;
    if (C.kd < 0.0)    C.kd = 0.0;
    if (C.tdot_tau_s < 1.0) C.tdot_tau_s = 1.0;
    if (C.reassert_ms < 500)  C.reassert_ms = 500;
    if (C.reassert_ms > 60000) C.reassert_ms = 60000;

    /* 预测层钳制：参数不合理就退回"不启用"，绝不让错误参数直接参与限流 */
    if (C.pred_alpha < 0.0)     C.pred_alpha = 0.0;
    if (C.pred_alpha > 1.0)     C.pred_alpha = 1.0;
    if (C.pred_tau_s < 5.0)     C.pred_tau_s = 5.0;
    if (C.pred_tau_s > 1800.0)  C.pred_tau_s = 1800.0;
    if (C.pred_horizon_s < 5.0) C.pred_horizon_s = 5.0;
    if (C.pred_horizon_s > 1800.0) C.pred_horizon_s = 1800.0;
    if (C.pred_hit_s < 5.0)     C.pred_hit_s = 5.0;
    if (C.pred_hit_s > 600.0)   C.pred_hit_s = 600.0;
    if (C.pred_ambient < 0.0)   C.pred_ambient = 0.0;
    if (C.pred_ambient > 60.0)  C.pred_ambient = 60.0;
    if (C.pred_margin < -1.0)   C.pred_margin = -1.0;
    if (C.pred_margin > 2.0)    C.pred_margin = 2.0;
    if (C.soft_margin < 0.0)    C.soft_margin = 0.0;
    if (C.soft_margin > 3.0)    C.soft_margin = 3.0;
    if (C.soft_band < 0.2)      C.soft_band = 0.2;
    if (C.soft_band > 3.0)      C.soft_band = 3.0;
    if (C.min_regulate_ma > 0) {
        if (C.min_regulate_ma < C.min_ma) C.min_regulate_ma = C.min_ma;
        if (C.min_regulate_ma > C.max_ma) C.min_regulate_ma = C.max_ma;
    }
    if (C.pred_enable && C.pred_alpha <= 0.0) {
        /* alpha 未辨识（或填 0）时启用预测没有数学意义，会自动失效并留痕 */
        log_msg("WARN: pred_enable=1 but pred_alpha=%.4f (not identified) -> predictive cap OFF",
                C.pred_alpha);
        C.pred_enable = 0;
    }
    if (C.pred_enable && C.pred_ambient <= 0.0) {
        /* 允许自动估计，但它依赖 α 准确，精度必然不如实测值 */
        log_msg("WARN: pred_ambient=0 -> ambient estimated from residual (identify it for accuracy)");
    }
    if (C.soft_landing && C.min_regulate_ma <= 0) {
        /* 软着陆的落点就是 min_regulate：没设落点等于没开，别让它静默失效 */
        log_msg("WARN: soft_landing=1 but min_regulate_ma=0 -> soft landing OFF");
        C.soft_landing = 0;
    }
    if (C.mca_tag[0] == 0)  snprintf(C.mca_tag, sizeof C.mca_tag, "user");
    if (C.mca_type[0] == 0) snprintf(C.mca_type, sizeof C.mca_type, "all");
    /* 标签/类型里出现空白会拆散 3-token 协议，必须挡掉 */
    for (char *q = C.mca_tag;  *q; ++q) if (*q == ' ' || *q == '\t') *q = '_';
    for (char *q = C.mca_type; *q; ++q) if (*q == ' ' || *q == '\t') *q = '_';
}

/* ---------------- 控制器 ---------------- */

typedef struct {
    double integral;    /* 仅日志镜像当前输出 */
    double tdot;        /* 温度变化率估计 K/s */
    double out_ma;      /* 当前输出 */
    int    saturated;
    double last_temp;
    int    hold_count;
} pid_t_;

static pid_t_ P;

static void pid_reset(double start_ma)
{
    memset(&P, 0, sizeof P);
    P.out_ma = start_ma;
    P.last_temp = NAN;
}

/* 速度式（incremental）温控律 —— 温度回落/上升通过"改变限流"实现
 *
 * 被控对象是一个积分器：限流越大，温升速度越快
 *     dT/dt = g * I - (T - Tamb) / tau
 * 对它做纯积分控制会得到双积分环节，必然振荡；必须用温度变化率提供阻尼。
 *
 *     drive = -err - kd_sec * Tdot          (err = T - target，过热为正)
 *     dI/dt =  ki * drive
 *
 * 其中 kd_sec 是"阻尼时间常数"（秒），不是传统 PID 的 Kd：
 * 环路自然频率 wn = sqrt(g * ki)，阻尼比 zeta = kd_sec * wn / 2。
 * 因为 kd_sec 是绝对时间，即使 g（机型热参数）差一个数量级，
 * zeta 只按 sqrt 变化 —— 这是它比固定 Kd 更耐换机型的原因。
 *
 * Tdot 用一阶低通估计（温度分辨率只有 0.1℃，原始差分噪声极大）。
 * 整定顺序：先调 ki 定响应速度，再调 kd_sec 压超调。
 */
static double pid_step(double temp_c, double dt)
{
    double target = C.target_temp_x10 / 10.0;
    double err = temp_c - target;          /* >0 过热 */
    double dead = C.deadband_x10 / 10.0;

    if (dt <= 0.0) return P.out_ma;
    if (dt > 5.0) dt = 5.0;

    /* ---- 温度变化率估计（一阶低通，时间常数 tau_sec） ---- */
    if (isnan(P.last_temp)) {
        P.last_temp = temp_c;
        P.tdot = 0.0;
    } else {
        double raw = (temp_c - P.last_temp) / dt;
        double tau = C.tdot_tau_s > 0.5 ? C.tdot_tau_s : 4.0;
        double a = dt / (tau + dt);        /* 低通系数 */
        if (a > 1.0) a = 1.0;
        P.tdot += a * (raw - P.tdot);
        P.last_temp = temp_c;
    }

    /* ---- 死区只作用于温度误差，阻尼项永远生效 ---- */
    double e = 0.0;
    if (err > dead)       e = err - dead;
    else if (err < -dead) e = err + dead;

    double drive = -e - C.kd * P.tdot;     /* kd 在速度式里是"秒" */

    double u = P.out_ma + C.ki * drive * dt;

    /* 输出限幅 */
    P.saturated = 0;
    if (u > C.max_ma) { u = C.max_ma; P.saturated = 1; }
    if (u < C.min_ma) { u = C.min_ma; P.saturated = -1; }

    /* 变化率限制（保护充电器，避免阶跃） */
    double slew = C.slew_ma_s * dt;
    if (slew < 1.0) slew = 1.0;
    if (u > P.out_ma + slew) u = P.out_ma + slew;
    if (u < P.out_ma - slew) u = P.out_ma - slew;
    /* slew 是在钳制之后做的，可能越出 [min,max]，必须再夹一次 */
    if (u > C.max_ma) u = C.max_ma;
    if (u < C.min_ma) u = C.min_ma;

    P.out_ma = u;
    P.integral = u;      /* 仅用于日志：当前输出即可，无独立积分态 */
    return u;
}

/* ---------------- 预测限幅（约束管理：MRG / 离散 CBF 的标量形式） ----------------
 *
 * 一阶集总热模型：C·dT/dt = I²R − (T−Tamb)/Rth   →  T∞ = Tamb + α·I²  (α = R·Rth)
 * 给定前瞻 H 与目标 T*，先反解"此刻允许的稳态温度"，再反解电流：
 *     T∞*  = (T* − T·e^(−H/τ)) / (1 − e^(−H/τ))
 *     Imax = sqrt((T∞* − Tamb)/α)
 * 单状态、单输入、单约束时，MRG / CBF 的 QP 退化成这个标量夹紧，不需要求解器。
 * 该层只压不抬；返回 <0 表示未启用或不可用，调用方原样放过。
 */
static double g_amb_est = NAN;      /* 环境温度自动估计 */
static double g_pred_cap = -1.0;    /* 最近一次预测上限（-1 = 未启用），供 state 观测 */

/* 抗风阻夹的"压制区"边界（℃ 低于目标）：进入/退出带回差，避免在边界反复切换。
 * 2026-11-12 真机：夹子在低温段也生效会形成自锁（见控制周期里的注释）。 */
#define BRAKE_ENTER_C 0.3
#define BRAKE_EXIT_C  1.0
static int g_braking = 0;           /* 1 = 处于压制区，抗风阻夹生效 */

static double ambient_est_c(double temp_c, double curr_a, double dt)
{
    if (C.pred_ambient > 0.0) return C.pred_ambient;
    /* 温度读数离谱时不要让它污染估计（0.1℃ 的坏值会把估计拖到 -2） */
    if (!isfinite(temp_c) || temp_c < 5.0 || temp_c > 60.0)
        return isnan(g_amb_est) ? 25.0 : g_amb_est;
    if (isnan(g_amb_est)) {
        g_amb_est = temp_c - 2.0;
        return g_amb_est;
    }
    if (C.pred_alpha > 0.0) {
        /* 残差式：T − α·I² 在稳态就等于环境温度，可升可降（τ=300s）。
         * 旧写法只允许 0.0002K/s 上浮并钉死在 T−1.5，等于"环境=当前温度"，
         * 闭环仿真会把稳态拉到 40.8℃ 而不是 43.5℃。 */
        double resid = temp_c - C.pred_alpha * curr_a * curr_a;
        double a = dt / (300.0 + dt);
        if (a > 1.0) a = 1.0;
        g_amb_est += a * (resid - g_amb_est);
    } else if (fabs(curr_a) < 0.5) {
        /* α 还没辨识：只有近零电流时温度才近似环境，慢速贴合（τ=600s） */
        double a = dt / (600.0 + dt);
        if (a > 1.0) a = 1.0;
        g_amb_est += a * (temp_c - g_amb_est);
    }
    if (g_amb_est > temp_c - 0.3) g_amb_est = temp_c - 0.3;
    if (g_amb_est < -20.0)        g_amb_est = -20.0;
    return g_amb_est;
}

static double pred_cap_ma(double temp_c, double curr_a, double dt, double *out_hit_s)
{
    if (out_hit_s) *out_hit_s = -1.0;
    if (!C.pred_enable || C.pred_alpha <= 0.0) { g_pred_cap = -1.0; return -1.0; }

    double target = C.target_temp_x10 / 10.0 + C.pred_margin;
    double amb = ambient_est_c(temp_c, curr_a, dt);
    double h = C.pred_horizon_s;
    double tau = C.pred_tau_s;
    double e = exp(-h / tau);
    double cap = -1.0;

    if (e > 0.0 && e < 1.0) {
        double tinf = (target - temp_c * e) / (1.0 - e);   /* 允许的稳态温度 */
        if (tinf <= amb) cap = (double)C.min_ma;           /* 已压不住：退回安全下限，绝不给 0 */
        else cap = 1000.0 * sqrt((tinf - amb) / C.pred_alpha);
        /* 预测层永不下探到 0：归零只能由硬保护（input_suspend）决定 */
        if (cap < (double)C.min_ma) cap = (double)C.min_ma;
    }

    /* 到点时间：按当前斜率估计还有多久撞线（斜率 <0.002K/s 视为不升温） */
    if (out_hit_s && P.tdot > 0.002) {
        double t_hit = (target - temp_c) / P.tdot;
        *out_hit_s = (t_hit > 0.0) ? t_hit : 0.0;
    } else if (out_hit_s) {
        *out_hit_s = 1e6;
    }
    /* 出口再兜一次：α 极小会让 sqrt 溢出成 inf，(long)inf 未定义 */
    if (!isfinite(cap))            cap = (double)C.min_ma;
    if (cap > (double)C.max_ma)    cap = (double)C.max_ma;
    g_pred_cap = cap;
    return cap;
}

/* ---------------- 系统状态 ---------------- */

static int is_charging(void)
{
    char b[64] = {0};
    if (read_file_str(C.p_usb_online, b, sizeof b) == 0)
        if (atoi(b) > 0) return 1;
    if (read_file_str(C.p_status, b, sizeof b) == 0) {
        if (strstr(b, "Charging") || strstr(b, "Full")) return 1;
    }
    return 0;
}

/* ---- mca charge_interface 写入协议 ----
 * 内核 mca_charge_if_sysfs_store 用 sscanf(buf,"%s %s %s") 解析，必须恰好 3 个
 * token，否则打印 "unable to parse input" 并返回 -EINVAL：
 *     <投票者标签> <通道类型> <毫安数>
 * 数值单位是 mA 且不做换算；通道类型必须命中内核的 19 项表
 * （micharger/charger/buck/main_buck/aux_buck/quick/quick_main/quick_aux/
 *   div1/div2/div4/wl_* /all）。写入本质是向 votable 投票，聚合器
 * （默认 Min）会取所有投票者的最小值 —— 所以我们永远不可能比系统保护更激进。
 */
static int mca_write(const char *path, const char *tag, const char *type, long ma)
{
    if (C.dry_run) return 0;
    if (ma < 0) ma = 0;
    char b[128];
    int n = snprintf(b, sizeof b, "%s %s %ld", tag, type, ma);
    if (n <= 0 || n >= (int)sizeof b) return -1;
    return write_file_str(path, b);
}

/* 回写并校验；返回 1 表示需要重写（被系统覆写或写入失败）
 * 注意两种通道的单位不同：wired_chg_curr 是 uA，mca ichg_limit 是 mA。 */
/* 读取 mca 节点的 effective 值（回读格式 "<type> eff_client:<tag> <值>"）。
 * 成功返回 0 并填 *out，失败返回 -1。 */
/* 当前没有说话人了 —— 保留给 status/诊断用（-Wunused 由 __attribute__ 抑制） */
static int mca_readback(const char *path, long *out) __attribute__((unused));
static int mca_readback(const char *path, long *out)
{
    char b[128];
    if (read_file_str(path, b, sizeof b) < 0) return -1;
    /* 取最后一个空白分隔的 token */
    char *last = NULL, *save = NULL, *tok = strtok_r(b, " \t\r\n", &save);
    while (tok) { last = tok; tok = strtok_r(NULL, " \t\r\n", &save); }
    if (!last) return -1;
    char *end = NULL;
    long v = strtol(last, &end, 10);
    if (end == last) return -1;
    *out = v;
    return 0;
}

/* 返回值约定：
 *    0  正常（写入成功，或值没变且未到重投时刻）
 *    1  值被系统改写（下次采样会重投）
 *   -1  写入真的失败了（路径不存在 / 权限 / 格式被拒）—— 这是必须报警的失效模式
 *
 * 关于"是否要重投"：不能拿回读值做精确判等。真机上 votable 的回读显示的是
 * **聚合后的 effective 值**，别人的票更低时我们永远读不到自己的值，判等会
 * 导致每 100ms 写一次（实测 19.3 次/秒）。所以改成按 reassert_ms 定时重投：
 * 值变了立刻重投，值没变也每 reassert_ms 补一次，防止系统把我们的票关掉。 */
static int  thermal_taken = 0;   /* 是否曾经把 wired_thermal_remove 置 1（用于还原，与当前配置无关） */
static long last_reassert_ms = 0;
static long last_enforced_ma   = -1;

static int enforce(long ma)
{
    int rc = 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    long now = (long)(ts.tv_sec * 1000L + ts.tv_nsec / 1000000L);
    int due = (now - last_reassert_ms >= C.reassert_ms) || (ma != last_enforced_ma);

    if (C.ctl_mode == 0 || C.ctl_mode == 2) {
        /* 与 mca 通道共用同一个 due 节流：值变了或到达 reassert_ms 才重投，
         * 否则默认 ctl_mode=2 每 100ms 都读写一次 wired_chg_curr。 */
        if (due) {
            long want_ua = ma * 1000L;
            if (write_file_long(C.p_ctl, want_ua) < 0) rc = -1;
            else {
                long rb = read_file_long(C.p_ctl, -1);
                /* wired_chg_curr 读回到 mA，容忍 500mA 的取整/竞争误差 */
                if (rb < 0) rc = -1;
                else if (labs(rb - ma) > 500L) rc = (rc == -1) ? -1 : 1;
            }
        }
    }

    if (C.ctl_mode == 1 || C.ctl_mode == 2) {
        if (due) {
            if (mca_write(C.p_ichg, C.mca_tag, C.mca_type, ma) < 0)
                rc = -1;
            else {
                last_reassert_ms = now;
                last_enforced_ma = ma;
            }
        }
    }
    /* 一次都没真正写（未到重投时刻）时不计为"被覆写"；
     * rc==1 只可能来自上面 due 分支里的回读失配 */
    return rc;
}

/* ---- 硬停充：mca input_suspend ----
 * 比 stop_handle_charge（小米私有标志）更直接，是硬件层的输入挂起。
 * 同样走 3-token 协议；纯数字写法在 MCA 上会 EINVAL。 */
static int set_suspend(int on)
{
    if (C.dry_run) return 0;
    /* 失败必须能被上层看到：硬停充没写进去却报成功是最危险的假象 */
    return (mca_write(C.p_suspend, C.mca_tag, C.mca_type, on ? 1 : 0) < 0) ? -1 : 0;
}

/* ---- 接管系统 FCC 温控 ----
 * 置位前先写 0、停 300ms 再写 1：清掉驱动内部状态，比直接写 1 可靠得多。
 * 本模块默认 thermal_remove=0（靠 Min 聚合与系统保护共存），仅在用户显式开启时用到。 */
static int take_thermal_override(int on)
{
    if (C.dry_run) return 0;
    if (!on) return write_file_long(C.p_thermal_remove, 0);
    write_file_long(C.p_thermal_remove, 0);
    usleep(300000);
    return write_file_long(C.p_thermal_remove, 1);
}

/* 退出时把两条通道都交还系统：mca 侧投一个"无限制"票并关闭我们的投票，
 * wired_chg_curr 恢复原始上限，并且无论如何都不动系统温控开关。 */
static void do_restore(void)
{
    if (C.ctl_mode == 0 || C.ctl_mode == 2) {
        write_file_long(C.p_ctl, C.restore_ma);
    }
    if (C.ctl_mode == 1 || C.ctl_mode == 2) {
        /* 拉到内核上限即等于放弃约束（Min 聚合下不会压住系统保护） */
        mca_write(C.p_ichg, C.mca_tag, C.mca_type, C.restore_ma / 1000L);
    }
    set_suspend(0);
    /* stop_handle_charge 本进程从不写 1，也就绝不能写 0 —— 那个 1 属于
     * 系统温控/HAL/别的模块，清零它等于替别人解除刹车。 */
    /* 只有在真的置位过温控接管时才还原（见 thermal_taken） */
    if (thermal_taken) write_file_long(C.p_thermal_remove, 0);
}

/* ---------------- 状态文件（给 status 子命令 / WebUI 读） ---------------- */

static void write_state(int charging, double temp, double volt, double curr,
                        double power, int soc, long limit_ma, const char *st)
{
    char tmp[MAXPATH], fin[MAXPATH];
    snprintf(fin, MAXPATH, "%s", g_statepath);
    snprintf(tmp, MAXPATH, "%s.tmp", fin);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fchmod(fileno(f), 0600);
    fprintf(f, "charging=%d\n", charging);
    fprintf(f, "temp=%.1f\n", temp);
    fprintf(f, "voltage=%.3f\n", volt);
    fprintf(f, "current=%.3f\n", curr);
    fprintf(f, "power=%.1f\n", power);
    fprintf(f, "soc=%d\n", soc);
    fprintf(f, "limit_ma=%ld\n", limit_ma);
    fprintf(f, "target=%.1f\n", C.target_temp_x10 / 10.0);
    fprintf(f, "state=%s\n", st);
    fprintf(f, "pid=%.3f\n", P.integral);
    fprintf(f, "out=%.0f\n", P.out_ma);
    fprintf(f, "uptime=%ld\n", (long)time(NULL));
    fprintf(f, "pred_enable=%d\n", C.pred_enable);
    fprintf(f, "pred_cap_ma=%.0f\n", g_pred_cap);
    fprintf(f, "amb_est=%.1f\n",
            C.pred_ambient > 0.0 ? C.pred_ambient : (isnan(g_amb_est) ? 0.0 : g_amb_est));
    fclose(f);
    rename(tmp, fin);
}

/* ---------------- 主循环 ---------------- */

static void msleep(int ms)
{
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {
        if (g_stop) return;
    }
}

static int cmd_run(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sa.sa_flags = SA_RESTART;     /* 少了它，usleep(300ms) 会被 SIGHUP 打断 */
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sa.sa_handler = on_hup;
    sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    /* 数据目录不存在就建（post-fs-data.sh 也会建，这里是双保险） */
    mkdir(g_dir, 0700);
    {
        char ldir[MAXPATH];
        snprintf(ldir, sizeof ldir, "%s/log", g_dir);
        mkdir(ldir, 0700);
    }

    /* ---- 单实例锁 ----
     * 之前没有任何互斥：实测两个实例会同时跑，后来者覆盖 pidfile，
     * 先来者退出时 unlink 掉，仍在运行的那个就彻底失联（set 发不到 SIGHUP）。
     * 拿不到锁就静默退出，让看门狗以为"已有实例在跑"。 */
    int lockfd = open(g_lockpath,
                      O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (lockfd < 0) {
        fprintf(stderr, "cannot open lock file: %s\n", strerror(errno));
        return 1;
    }
    if (flock(lockfd, LOCK_EX | LOCK_NB) != 0) {
        fprintf(stderr, "another instance is already running, exit\n");
        close(lockfd);
        return 0;
    }

    log_open();          /* 先开日志，后面 cfg_load 的 WARN 才能落盘 */
    cfg_defaults(&C);
    cfg_load(g_cfgpath);

    if (!C.enabled) {
        log_msg("disabled in config, exit");
        return 0;
    }

    /* 写 pid 文件：set 子命令靠它发 SIGHUP，uninstall/看门狗靠它精确结束进程。
     * 放在拿到锁之后，避免第二个实例把第一个的 pidfile 覆盖掉。 */
    FILE *pf = fopen(g_pidpath, "w");
    if (pf) { fchmod(fileno(pf), 0600); fprintf(pf, "%d\n", (int)getpid()); fclose(pf); }
    
    csv_open();
    log_msg("=== thermocharge %s start (pid %d) ===", TC_VERSION, getpid());
    log_msg("target=%.1fC hard=%.1fC range=%d..%dmA kp=%.0f ki=%.0f kd=%.0f slew=%dmA/s dry_run=%d",
            C.target_temp_x10/10.0, C.hard_temp_x10/10.0, C.min_ma, C.max_ma,
            C.kp, C.ki, C.kd, C.slew_ma_s, C.dry_run);

    /* 接管系统 FCC 温控 */
    if (C.thermal_remove) {
        if (write_file_long(C.p_thermal_remove, 1) < 0)
            log_msg("WARN: cannot set thermal_remove=1 (%s)", strerror(errno));
        else {
            thermal_taken = 1;
            log_msg("thermal FCC override taken (wired_thermal_remove=1)");
        }
    }

    /* 启动安全值：进程起来时如果已经在充电，先给个保守值；
     * 若此刻没在充电就什么都不写（插电瞬间由宽限期接管）。 */
    pid_reset(C.startup_ma);
    if (is_charging()) enforce((long)C.startup_ma);
    else log_msg("not charging at startup, leaving sysfs untouched");

    long  limit_ma   = C.startup_ma;
    int   was_charging = -1;
    int   grace_done = 1;       /* 宽限期是否已过；过的时候用实测电流接管 */
    int   paused = 0;           /* 是否处于 input_suspend=1 的挂起状态 */
    /* 挂起原因：0 无 / 1 过温 / 2 控制通道坏掉
     * 必须分开记。之前只有 paused 一个标志，通道故障挂起后下一拍
     * 温度一降到 target+0.3 以下就被「降温了可以起充」的逻辑解挂，
     * 而通道依然是坏的 —— 等于解除了唯一剩下的刹车。 */
    int   pause_reason = 0;
    long  charge_since = 0;
    long  overwrite_cnt = 0;
    long  hard_cnt = 0;
    long  sensor_fail = 0;      /* 温度连续读失败拍数 */
    long  ctl_fail = 0;         /* 控制通道连续写失败拍数 */
    long  last_ctrl_ms = 0, last_log_ms = 0;
    double prev_temp = NAN;
    long  now_ms = 0;

    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    for (;;) {
        if (g_stop) break;

        if (g_reload) {
            g_reload = 0;
            cfg_defaults(&C);
            cfg_load(g_cfgpath);
            if (!C.enabled) {
                log_msg("disabled by config reload, restoring and exit");
                break;
            }
            /* 重载必须重置控制状态：否则把 max_ma 从 20000 降到 8000 时，
             * 下一拍还会 enforce(20000) 突破新上限；改 ctl_mode 更糟，
             * 新通道从没写过、旧通道还残留着我们的限流票。 */
            if (limit_ma < C.min_ma) limit_ma = C.min_ma;
            if (limit_ma > C.max_ma) limit_ma = C.max_ma;
            pid_reset(limit_ma);
            last_enforced_ma = -1;   /* 强制下一拍重投 */
            last_reassert_ms = 0;
            hard_cnt = 0;
            prev_temp = NAN;
            /* 预测层的估计量也随配置作废：否则 state 里会留着上一套参数的 cap，
             * 自动环境温度还可能带着一小时只爬 0.72K 的陈旧值 */
            g_amb_est = NAN;
            g_pred_cap = -1.0;
            log_msg("config reloaded: target=%.1fC hard=%.1fC ki=%.0f kd=%.0f "
                    "range=%d..%dmA ctl_mode=%d reassert=%dms",
                    C.target_temp_x10/10.0, C.hard_temp_x10/10.0, C.ki, C.kd,
                    C.min_ma, C.max_ma, C.ctl_mode, C.reassert_ms);
        }

        struct timespec tn;
        clock_gettime(CLOCK_MONOTONIC, &tn);
        now_ms = (tn.tv_sec - t0.tv_sec) * 1000L + (tn.tv_nsec - t0.tv_nsec) / 1000000L;

        int charging = is_charging();
        long soc     = read_file_long(C.p_capacity, -1);
        long tv      = read_file_long(C.p_temp, -1);       /* 0.1℃ */
        long vv      = read_file_long(C.p_voltage, -1);    /* uV */
        long iv      = read_file_long(C.p_current, 0);     /* uA，充电时通常为负 */
        double temp_c = tv / 10.0;
        double volt   = vv / 1e6;
        double curr   = fabs((double)iv) / 1e6;
        double power  = volt * curr;
        const char *st = "idle";

        /* ---- 插拔电状态切换 ---- */
        if (charging != was_charging) {
            if (was_charging != -1)
                log_msg("charger %s (soc=%ld temp=%.1f)",
                        charging ? "PLUGGED" : "UNPLUGGED", soc, temp_c);
            int first = (was_charging == -1);
            was_charging = charging;
            charge_since = now_ms;
            pid_reset(charging ? C.startup_ma : C.restore_ma / 1000L);
            hard_cnt = 0;
            grace_done = !charging;
            if (first && !charging) {
                /* 首次循环就判定未充电：不要写任何节点。
                 * 旧版本会 enforce(restore_ma/1000)，等于用我们更高的一票覆盖
                 * 系统更严格的 volt_thermal_limit（实测 3000mA 被顶成 22000mA）。 */
                msleep(C.fast_write_ms);
                continue;
            }
            if (!charging) {
                /* 拔电：交还系统 */
                if (thermal_taken) { write_file_long(C.p_thermal_remove, 0); thermal_taken = 0; }
                set_suspend(0);
                paused = 0;
                pause_reason = 0;
                ctl_fail = 0;
                enforce(C.restore_ma / 1000L);
            } else {
                if (C.thermal_remove) {
                    if (take_thermal_override(1) == 0) thermal_taken = 1;
                }
                log_msg("control channel: %s (mca tag=%s type=%s) grace=%dms",
                        C.ctl_mode == 0 ? "wired_chg_curr" :
                        C.ctl_mode == 1 ? "mca ichg_limit" : "both",
                        C.mca_tag, C.mca_type, C.startup_grace_ms);
                /* 插电瞬间一个字节都不写：让快充协议认证与电荷泵爬升先跑完。
                 * 这时候写限流反而会打断 CP 起泵，甚至让握手回退到慢充。 */
            }
        }

        if (!charging) {
            st = "idle";
            limit_ma = C.restore_ma / 1000L;   /* restore_ma 是 uA，统一成 mA 上报 */
            if (now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                write_state(0, temp_c, volt, curr, power, (int)soc, limit_ma, st);
            }
            msleep(C.fast_write_ms);
            continue;
        }

        /* ---- 温度读失败：连续 3 拍就降级保护，绝不静默冻结 ---- */
        if (tv <= 0) {
            sensor_fail++;
            if (sensor_fail >= 3) {
                /* 没有任何温度反馈还继续大电流，是纯粹的盲目充电 */
                st = "sensor_fault";
                limit_ma = C.min_ma;
                P.out_ma = C.min_ma;
                set_suspend(1);
                enforce(C.min_ma);
                if (now_ms - last_log_ms >= C.log_interval_ms) {
                    last_log_ms = now_ms;
                    log_msg("ERROR: temp unreadable %ld ticks (%s) -> limit %dmA + input suspended",
                            sensor_fail, C.p_temp, C.min_ma);
                    write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
                }
                msleep(C.fast_write_ms);
                continue;
            }
            enforce(limit_ma);
            msleep(C.fast_write_ms);
            continue;
        }
        sensor_fail = 0;

        /* ---- 安全判定放在最前面：任何分支都不能绕过它 ----
         * 之前的版本把宽限期和 SOC 释放分支放在硬限判断之前，结果
         * 「开机就 48℃」会按 startup_ma 跑满宽限期、「电量越满温度越高
         * 反而解除限流」。现在超限是第一优先级，且超限分支直接 continue。 */
        if (temp_c >= C.hard_temp_x10 / 10.0) {
            hard_cnt++;
            limit_ma = C.min_ma;
            P.out_ma = C.min_ma;
            st = "hard_safety";
            if (paused) {
                st = "hard_pause";
            } else if (C.pause_on_hard && hard_cnt >= 4) {
                /* 限流压到 min 仍超限 → 硬件层挂起输入彻底停充 */
                if (set_suspend(1) == 0) {
                    paused = 1;
                    pause_reason = 1;
                    st = "hard_pause";
                    log_msg("HARD PAUSE: input suspended (T=%.1fC > %.1fC)", temp_c,
                            C.hard_temp_x10 / 10.0);
                } else {
                    log_msg("WARN: input_suspend write FAILED (T=%.1fC), will retry", temp_c);
                }
            }
            enforce(limit_ma);
            prev_temp = temp_c;
            if (now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                log_msg("%s soc=%ld T=%.1f V=%.2f I=%.2f P=%.1fW limit=%dmA",
                        st, soc, temp_c, volt, curr, power, limit_ma);
                if (g_csv) {
                    fprintf(g_csv, "%ld,%.1f,%.3f,%.3f,%.1f,%ld,%ld,%.1f,%s\n",
                            (long)time(NULL), temp_c, volt, curr, power,
                            soc, limit_ma, C.target_temp_x10/10.0, st);
                    fflush(g_csv);
                }
                write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
            }
            msleep(C.fast_write_ms);
            continue;
        }

        /* ---- 挂起状态下的恢复 ----
         * 过温挂起（reason 1）：必须回到 target+0.3℃ 以下才重新起充。
         * 通道故障挂起（reason 2）：温度高低无关，只能靠"控制通道真的能写进去"
         * 来解除 —— 否则会在失控状态下解挂，等于没有刹车。 */
        if (paused && pause_reason == 2) {
            /* 试探性写一次：成功了才解挂 */
            if (mca_write(C.p_ichg, C.mca_tag, C.mca_type, limit_ma) < 0) {
                st = "ctl_fault";
                limit_ma = C.min_ma;
                P.out_ma = C.min_ma;
                if (now_ms - last_log_ms >= C.log_interval_ms) {
                    last_log_ms = now_ms;
                    log_msg("%s control channel still broken (%s), staying suspended",
                            st, C.p_ichg);
                    write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
                }
                msleep(C.fast_write_ms);
                continue;
            }
            /* 通道恢复：保持挂起直到温度也允许（双条件都满足才起充） */
            if (temp_c > (C.target_temp_x10 / 10.0) + 0.3) {
                st = "ctl_fault";
                limit_ma = C.min_ma;
                P.out_ma = C.min_ma;
                msleep(C.fast_write_ms);
                continue;
            }
            ctl_fail = 0;
            if (set_suspend(0) < 0) {
                log_msg("WARN: cannot clear input_suspend, keep paused");
                msleep(C.fast_write_ms);
                continue;
            }
            paused = 0;
            pause_reason = 0;
            hard_cnt = 0;
            last_enforced_ma = -1;
            last_reassert_ms = 0;
            pid_reset(C.startup_ma);
            log_msg("CTL FAULT cleared: control channel writable again at T=%.1fC, resume from %dmA",
                    temp_c, C.startup_ma);
            msleep(C.fast_write_ms);
            continue;
        }

        if (paused) {
            if (temp_c > (C.target_temp_x10 / 10.0) + 0.3) {
                limit_ma = C.min_ma;
                P.out_ma = C.min_ma;
                st = "hard_pause";
                enforce(limit_ma);
                prev_temp = temp_c;
                if (now_ms - last_log_ms >= C.log_interval_ms) {
                    last_log_ms = now_ms;
                    log_msg("%s soc=%ld T=%.1f waiting cool->%.1fC", st, soc, temp_c,
                            C.target_temp_x10 / 10.0 + 0.3);
                    write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
                }
                msleep(C.fast_write_ms);
                continue;
            }
            if (set_suspend(0) < 0) {
                log_msg("WARN: cannot clear input_suspend, keep paused");
                msleep(C.fast_write_ms);
                continue;
            }
            paused = 0;
            pause_reason = 0;
            hard_cnt = 0;
            last_enforced_ma = -1;
            last_reassert_ms = 0;
            pid_reset(C.startup_ma);
            log_msg("HARD PAUSE released at T=%.1fC, resume from %dmA", temp_c, C.startup_ma);
        }

        /* ---- 刚插电的握手宽限期：先不动 ---- */
        if (now_ms - charge_since < C.startup_grace_ms) {
            st = "grace";
            if (now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
            }
            msleep(C.fast_write_ms);
            continue;
        }

        /* ---- 宽限期结束：用实测电流当 PID 初值，而不是硬编码值 ---- */
        if (!grace_done) {
            grace_done = 1;
            double meas = curr * 1000.0;         /* A -> mA */
            if (meas < C.min_ma) meas = C.min_ma;
            if (meas > C.max_ma) meas = C.max_ma;
            pid_reset(meas);
            limit_ma = (long)meas;
            log_msg("grace over: adopt measured %.0fmA as initial output (T=%.1fC)", meas, temp_c);
        }

        /* ---- SOC 保护：快满了交还系统（但它已经在硬限判断之后，安全） ---- */
        if (C.hold_below_soc > 0 && soc >= C.hold_below_soc) {
            st = "soc_release";
            if (P.out_ma != C.max_ma) { P.out_ma = C.max_ma; limit_ma = C.max_ma; }
            enforce(C.max_ma);
            if (now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                write_state(1, temp_c, volt, curr, power, (int)soc, C.max_ma, st);
            }
            msleep(C.fast_write_ms);
            continue;
        }

        /* ---- 控制周期 ---- */
        if (now_ms - last_ctrl_ms >= C.sample_ms) {
            double dt = (now_ms - last_ctrl_ms) / 1000.0;
            last_ctrl_ms = now_ms;
            if (dt <= 0) dt = C.sample_ms / 1000.0;
            if (dt > 10.0) dt = 10.0;

            hard_cnt = 0;
            st = "regulate";
            limit_ma = (long)pid_step(temp_c, dt);
            if (P.saturated > 0)  st = "regulate_max";
            if (P.saturated < 0)  st = "regulate_min";

            /* 尖峰守卫：只允许"更保守"，绝不允许把已经降下来的流打回去。
             * 之前这里直接赋值 limit_ma = P.out_ma，会在越限那一拍把 min_ma 推翻。 */
            if (!isnan(prev_temp) && fabs(temp_c - prev_temp) > 1.5) {
                if (limit_ma > (long)P.out_ma) limit_ma = (long)P.out_ma;
            }
            /* ---- 抗积分风阻：限流是天花板，不是指令 ----
             * 实测电流明显低于我们给的上限时，再往上抬没有物理效果，只会把
             * "风阻"积到 max_ma；等温度超调后再按 ki 往回退要好几分钟，
             * 真机 20:54–21:02 那段 44–45℃ 就是这么来的（limit 20000，实际 11.6A）。
             * 所以上限最多只比实测高 15%（+500mA 余量；实测 <1A 时是握手/断流态，不启用）。
             *
             * 2026-11-12 真机补充：这个夹子只能"压制"，绝不能在低温段生效。
             * 它曾经形成自锁：上限 = 1.15×实测+500，而系统只肯取上限的一部分
             * （CP 段尤其明显），于是"上限低 → 电流低 → 上限更低"滚成死循环，
             * 温度明明只有 39℃、离目标 4℃，功率却卡在 10–20W 上不去。
             * 对照实验（SIGSTOP 冻结守护进程 + 手写 wired_chg_curr=6A）证明：
             * 只要放行，系统 4 秒内从 1.0A 拉到 5.1A（输入 27W）——限制来自夹子本身。
             * 修法：只在"压制区"（温度进入目标下方 1℃ 以内）才启用，
             * 退出要回落到目标下方 2.5℃（回差）。低温段放行到 max_ma，
             * 由 PID 的 slew 限速，热风阻不再有机会累积。 */
            {
                double tgt_c = C.target_temp_x10 / 10.0;
                if (temp_c >= tgt_c - BRAKE_ENTER_C)      g_braking = 1;
                else if (temp_c <= tgt_c - BRAKE_EXIT_C)  g_braking = 0;
            }
            if (g_braking && !isnan(curr)) {
                double meas_ma = fabs(curr) * 1000.0;
                if (meas_ma > 1000.0) {
                    long cap = (long)(meas_ma * 1.15) + 500;
                    /* 下降也走斜率：从 20A 一步砸到 6A 会造成功率断崖（2026-11-12 真机
                     * 42.3℃ 时上限 20000→4662→1370，功率 22W 掉到 6W）。让致动器跟得上，
                     * 也避免"上限砸低→系统取流更低→上限再砸低"的二次自锁。 */
                    long floor_ma = limit_ma - (long)(C.slew_ma_s * dt);
                    if (cap < floor_ma) cap = floor_ma;
                    if (limit_ma > cap) {
                        limit_ma = cap;
                        P.out_ma = cap;
                        P.saturated = 0;
                        st = "windup";
                    }
                }
            }

            /* ---- 预测限幅 + 软着陆（默认关闭；开启后只压不抬） ----
             * 三层按"越靠近目标越保守"排列：预测上限 -> 到点时间 -> 软着陆下限。
             * 任何一层都不会把电流打到 0：归零只由硬保护（input_suspend）负责。 */
            {
                double tgt = C.target_temp_x10 / 10.0;
                long reg_min = (C.min_regulate_ma > 0) ? C.min_regulate_ma : C.min_ma;
                double hit_s = -1.0;
                double cap = pred_cap_ma(temp_c, curr, dt, &hit_s);

                if (cap >= 0.0 && (long)cap < limit_ma) {
                    limit_ma = (long)cap;
                    P.out_ma = limit_ma;
                    P.saturated = 0;
                    st = "predict";
                }

                /* 还没到目标，但按当前斜率马上就撞线：提前压到调节下限（不归零） */
                if (C.pred_enable && C.min_regulate_ma > 0 &&
                    hit_s >= 0.0 && hit_s < C.pred_hit_s &&
                    temp_c > tgt - 1.5 && limit_ma > reg_min) {
                    limit_ma = reg_min;
                    P.out_ma = reg_min;
                    P.saturated = 0;
                    st = "predict_hit";
                }

                /* 软着陆：越过余量后把上限封在 min_regulate 等降温，而不是等硬停。
                 * 守卫必须是"高于"而不是"不等于"：抗风阻/预测可能已经压得比
                 * reg_min 更低，那些更保守的票不许被这一步抬回去。
                 * 超过 soft_band 后放开下限（PID 可以降得更低），给硬保护留出缓冲。 */
                if (C.soft_landing && C.min_regulate_ma > 0 &&
                    temp_c >= tgt + C.soft_margin &&
                    temp_c < tgt + C.soft_margin + C.soft_band) {
                    if (limit_ma > reg_min) {
                        limit_ma = reg_min;
                        P.out_ma = reg_min;
                        P.saturated = 0;
                    }
                    st = "soft_land";
                }
            }
            prev_temp = temp_c;

            int erc = enforce(limit_ma);
            if (erc < 0) {
                ctl_fail++;
                if (ctl_fail >= 3 && !paused) {
                    /* 控制通道彻底写不进去 = 完全失控。唯一还剩的刹车是 input_suspend。 */
                    log_msg("ERROR: control channel write failed %ld times (%s) -> suspend input",
                            ctl_fail, C.p_ichg);
                    if (set_suspend(1) == 0) {
                        paused = 1;
                        pause_reason = 2;
                        st = "ctl_fault";
                        log_msg("ERROR: input suspended because control channel is dead, "
                                "will stay suspended until it becomes writable again");
                    }
                }
            } else {
                ctl_fail = 0;
                if (erc > 0) overwrite_cnt++;
            }

            if (now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                log_msg("%s soc=%ld T=%.1f V=%.2f I=%.2f P=%.1fW limit=%ldmA pid=%.2f ow=%ld",
                        st, soc, temp_c, volt, curr, power, limit_ma, P.integral, overwrite_cnt);
                if (g_csv) {
                    fprintf(g_csv, "%ld,%.1f,%.3f,%.3f,%.1f,%ld,%ld,%.1f,%s\n",
                            (long)time(NULL), temp_c, volt, curr, power,
                            soc, limit_ma, C.target_temp_x10/10.0, st);
                    fflush(g_csv);
                }
                write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
            }
        } else {
            /* ---- 快速回写：只对抗覆写，不动控制量 ---- */
            int erc = enforce(limit_ma);
            if (erc < 0) ctl_fail++; else { ctl_fail = 0; if (erc > 0) overwrite_cnt++; }
            st = "hold";
        }

        msleep(C.fast_write_ms);
    }

    log_msg("=== stop, restoring (ow=%ld) ===", overwrite_cnt);
    do_restore();
    unlink(g_pidpath);
    if (g_log) fclose(g_log);
    if (g_csv) fclose(g_csv);
    return 0;
}

/* ---------------- 子命令 ---------------- */

/* 前向声明：cmd_status/cmd_set 在定义之前就要用它们 */
static int pid_is_daemon(int pid);
static int daemon_alive(int *pidout);

static int cmd_status(void)
{
    cfg_defaults(&C);
    cfg_load(g_cfgpath);

    char b[MAXLINE] = "";
    long tv  = read_file_long(C.p_temp, -1);
    long vv  = read_file_long(C.p_voltage, -1);
    long iv  = read_file_long(C.p_current, 0);
    long soc = read_file_long(C.p_capacity, -1);
    read_file_str(C.p_status, b, sizeof b);

    /* 存活校验：进程没了还报 regulate 会让人误以为在控温 */
    int alive = 0, dpid = 0;
    if (daemon_alive(&dpid)) alive = 1;

    /* 当前真正生效的控制通道 */
    char chdesc[MAXLINE] = "";
    if (C.ctl_mode == 0 || C.ctl_mode == 2) {
        long w = read_file_long(C.p_ctl, -1);
        snprintf(chdesc + strlen(chdesc), sizeof chdesc - strlen(chdesc),
                 "wired_chg_curr=%lduA(%ldmA) ", w, w / 1000);
    }
    if (C.ctl_mode == 1 || C.ctl_mode == 2) {
        long rb = -1;
        if (mca_readback(C.p_ichg, &rb) == 0) {
            char raw[MAXLINE] = "";
            read_file_str(C.p_ichg, raw, sizeof raw);
            for (char *q = raw; *q; ++q) if (*q == '\n') *q = ' ';
            snprintf(chdesc + strlen(chdesc), sizeof chdesc - strlen(chdesc),
                     "ichg_limit=[%s]", raw[0] ? raw : "?");
        } else {
            snprintf(chdesc + strlen(chdesc), sizeof chdesc - strlen(chdesc),
                     "ichg_limit=unreadable");
        }
    }

    printf("daemon   : %s (pid %d)\n", alive ? "RUNNING" : "NOT RUNNING", dpid);
    printf("version  : %s\n", TC_VERSION);
    printf("charging : %s (%s)\n", is_charging() ? "yes" : "no", b);
    printf("temp     : %.1f C  (target %.1f / hard %.1f)\n",
           tv / 10.0, C.target_temp_x10/10.0, C.hard_temp_x10/10.0);
    printf("battery  : %.3f V  %.3f A  %.1f W  soc %ld%%\n",
           vv / 1e6, fabs((double)iv) / 1e6, (vv / 1e6) * (fabs((double)iv) / 1e6), soc);
    printf("ctl_mode : %d  %s\n", C.ctl_mode, chdesc);
    printf("range    : %d..%d mA\n", C.min_ma, C.max_ma);

    /* state 文件只在守护进程活着时可信 */
    FILE *st = fopen(g_statepath, "r");
    if (st) {
        char line[MAXLINE];
        printf("--- last state (%s) ---\n", alive ? "live" : "STALE, daemon down");
        while (fgets(line, sizeof line, st)) fputs(line, stdout);
        fclose(st);
    }

    /* 二进制/清单一致性自检：安装态漂移过（装的是 v1.0.0，module.prop 写 v1.1.0） */
    char pv[MAXLINE] = "";
    if (read_file_str("/data/adb/modules/thermocharge/module.prop", pv, sizeof pv) >= 0) {
        char *v = strstr(pv, "version=");
        if (v) {
            char *e = strchr(v, '\n');
            if (e) *e = 0;
            printf("--- module ---\n%s\n", v);
        }
    }
    return 0;
}

/* ---- 配置键表：set 只允许改这些，且带类型与范围校验 ----
 * 之前的 set 完全不校验：`set targt_temp 42` 会写进一个永不生效的键，
 * `set target_temp abc` 也 rc=0，用户以为改了其实没改。 */
typedef struct {
    const char *name;
    int   is_double;
    double dmin, dmax;      /* is_double = 1 时生效 */
    long  imin, imax;       /* is_double = 0 时生效 */
} keydef_t;

static const keydef_t g_keys[] = {
    { "target_temp",     1, 25.0, 50.0, 0, 0 },
    { "hard_temp",       1, 30.0, 55.0, 0, 0 },
    { "deadband",        1,  0.0,  2.0, 0, 0 },
    { "ki",              1,  1.0, 2000.0, 0, 0 },
    { "kd",              1,  0.0,  600.0, 0, 0 },
    { "tdot_tau_s",      1,  1.0,   60.0, 0, 0 },
    { "kp",              1,  0.0, 1000.0, 0, 0 },
    { "max_ma",          0, 0, 0, 1000,  20500 },
    { "min_ma",          0, 0, 0,  100,   5000 },
    { "startup_ma",      0, 0, 0,  100,  20500 },
    { "restore_ma",      0, 0, 0, 1000, 22000000 },
    { "slew_ma_s",       0, 0, 0,  100,  20000 },
    { "sample_ms",       0, 0, 0,  100,  10000 },
    { "fast_write_ms",   0, 0, 0,   50,   5000 },
    { "log_interval_ms", 0, 0, 0,  200,  60000 },
    { "hold_below_soc",  0, 0, 0,    0,    100 },
    { "pause_on_hard",   0, 0, 0,    0,      1 },
    { "thermal_remove",  0, 0, 0,    0,      1 },
    { "startup_grace_ms",0, 0, 0,    0, 120000 },
    { "reassert_ms",     0, 0, 0,  500,  60000 },
    { "ctl_mode",        0, 0, 0,    0,      2 },
    { "pred_enable",     0, 0, 0,    0,      1 },
    { "pred_alpha",      1,  0.0, 1.0, 0, 0 },
    { "pred_tau_s",      1,  5.0, 1800.0, 0, 0 },
    { "pred_ambient",    1,  0.0, 60.0, 0, 0 },
    { "pred_margin",     1, -1.0, 2.0, 0, 0 },
    { "pred_horizon_s",  1,  5.0, 1800.0, 0, 0 },
    { "pred_hit_s",      1,  5.0, 600.0, 0, 0 },
    { "min_regulate_ma", 0, 0, 0,    0,  20500 },
    { "soft_landing",    0, 0, 0,    0,      1 },
    { "soft_margin",     1,  0.0, 3.0, 0, 0 },
    { "soft_band",       1,  0.2, 3.0, 0, 0 },
    { "enabled",         0, 0, 0,    0,      1 },
    { "dry_run",         0, 0, 0,    0,      1 },
};

/* 写入临时文件再 rename：原子、不截断、不会因为 256 行上限丢掉尾部 */
static int cfg_set_atomic(const char *path, const char *key, const char *val)
{
    char tmp[MAXPATH];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);

    FILE *in = fopen(path, "r");
    FILE *out = fopen(tmp, "w");
    if (!out) { if (in) fclose(in); return -1; }

    int found = 0;
    char line[MAXLINE];
    if (in) {
        while (fgets(line, sizeof line, in)) {
            char probe[MAXLINE];
            snprintf(probe, sizeof probe, "%s", line);
            char *hash = strchr(probe, '#');
            if (hash) *hash = 0;
            trim(probe);
            char *eq = strchr(probe, '=');
            if (eq) {
                *eq = 0;
                trim(probe);
                if (!strcmp(probe, key)) {
                    fprintf(out, "%s=%s\n", key, val);
                    found = 1;
                    continue;
                }
            }
            fputs(line, out);
            size_t L = strlen(line);
            if (L == 0 || line[L-1] != '\n') fputc('\n', out);
        }
        fclose(in);
    }
    if (!found) fprintf(out, "%s=%s\n", key, val);
    if (fflush(out) != 0) { fclose(out); unlink(tmp); return -1; }
    fsync(fileno(out));
    fclose(out);
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

static int cmd_set(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: set <key> <value>\n"); return 2; }
    const char *key = argv[1], *val = argv[2];

    /* 值里绝不能出现换行或等号：否则可以往配置里注入一整行新键
     * （实测 `set mca_type "all\np_ichg=/tmp/EVIL"` 能把控制通道改向） */
    if (strpbrk(val, "\n\r=") || strpbrk(key, "\n\r=")) {
        fprintf(stderr, "rejected: key/value must not contain newline or '='\n");
        return 3;
    }

    const keydef_t *kd = NULL;
    for (size_t i = 0; i < sizeof g_keys / sizeof g_keys[0]; i++)
        if (!strcmp(g_keys[i].name, key)) { kd = &g_keys[i]; break; }
    if (!kd) {
        fprintf(stderr, "unknown key '%s' (try: thermocharge help)\n", key);
        return 3;
    }
    char *end = NULL;
    errno = 0;
    if (kd->is_double) {
        double d = strtod(val, &end);
        if (end == val || *end || errno || !isfinite(d)) { fprintf(stderr, "not a finite number: %s\n", val); return 4; }
        if (d < kd->dmin || d > kd->dmax) {
            fprintf(stderr, "out of range: %s must be %.1f..%.1f\n", key, kd->dmin, kd->dmax);
            return 4;
        }
    } else {
        long v = strtol(val, &end, 10);
        if (end == val || *end || errno) { fprintf(stderr, "not an integer: %s\n", val); return 4; }
        if (v < kd->imin || v > kd->imax) {
            fprintf(stderr, "out of range: %s must be %ld..%ld\n", key, kd->imin, kd->imax);
            return 4;
        }
    }

    if (cfg_set_atomic(g_cfgpath, key, val) != 0) {
        fprintf(stderr, "cannot write %s: %s\n", g_cfgpath, strerror(errno));
        return 1;
    }
    printf("%s=%s\n", key, val);

    /* 通知守护进程重载：先确认这个 pid 真的是我们的进程，避免陈旧 pidfile 误杀 */
    FILE *pf = fopen(g_pidpath, "r");
    if (pf) {
        int pid = 0;
        if (fscanf(pf, "%d", &pid) == 1 && pid > 1) {
            if (pid_is_daemon(pid)) {
                kill(pid, SIGHUP);
                printf("signalled daemon (pid %d)\n", pid);
            } else {
                printf("stale pid %d, not our process — not signalled\n", pid);
            }
        }
        fclose(pf);
    }
    return 0;
}

/* 守护进程是否在跑（用于 restore/stop 的存活判断） */
/* 取 cmdline 里的 argv[0] 与 argv[1]。
 * cmdline 是 NUL 分隔的，所以不能用 strstr 找 "thermocharge run" 之类的子串；
 * 而且二进制可能被改名（测试/调试），比对 basename 才可靠。
 * 返回 0 成功并填两份缓冲，-1 失败。 */
static int read_cmdline_argv(const char *path, char *a0, size_t n0, char *a1, size_t n1)
{
    char raw[1024];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t r = read(fd, raw, sizeof raw - 1);
    close(fd);
    if (r <= 0) return -1;
    raw[r] = 0;

    /* argv[0] 到第一个 NUL 为止 */
    size_t l0 = strnlen(raw, (size_t)r);
    if (l0 >= n0) l0 = n0 - 1;
    memcpy(a0, raw, l0);
    a0[l0] = 0;

    /* argv[1]：第一个 NUL 之后 */
    a1[0] = 0;
    if (l0 + 1 < (size_t)r) {
        const char *p = raw + l0 + 1;
        size_t rem = (size_t)r - (l0 + 1);
        size_t l1 = strnlen(p, rem);
        if (l1 >= n1) l1 = n1 - 1;
        memcpy(a1, p, l1);
        a1[l1] = 0;
    }
    return 0;
}

static const char *base_name(const char *p)
{
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

/* pid 是不是我们自己的守护进程：basename(argv[0]) 与自身相同，且 argv[1] == "run"。
 * 这样二进制改名后依然能认出来，陈旧 pidfile 也不会被误信。 */
static int pid_is_daemon(int pid)
{
    char cb[MAXPATH];
    char their0[MAXPATH], their1[64];
    char my0[MAXPATH], my1[64];

    snprintf(cb, sizeof cb, "/proc/%d/cmdline", pid);
    if (read_cmdline_argv(cb, their0, sizeof their0, their1, sizeof their1) < 0) return 0;
    if (read_cmdline_argv("/proc/self/cmdline", my0, sizeof my0, my1, sizeof my1) < 0) return 0;

    if (!their0[0]) return 0;
    if (strcmp(base_name(their0), base_name(my0)) != 0) return 0;
    /* 只认 `run` 子命令；手动 `set`/`status` 的临时进程不算 */
    if (strcmp(their1, "run") != 0) return 0;
    return (kill(pid, 0) == 0);
}

static int daemon_alive(int *pidout)
{
    int pid = 0;
    FILE *pf = fopen(g_pidpath, "r");
    if (pf) { if (fscanf(pf, "%d", &pid) != 1) pid = 0; fclose(pf); }
    if (pidout) *pidout = pid;
    if (pid <= 1) return 0;
    return pid_is_daemon(pid);
}

static int cmd_restore(int force)
{
    cfg_defaults(&C);
    cfg_load(g_cfgpath);

    int pid = 0;
    if (daemon_alive(&pid) && !force) {
        fprintf(stderr,
                "daemon is running (pid %d) and will overwrite this within 100ms.\n"
                "run 'thermocharge stop' first, or 'restore --force'.\n", pid);
        return 5;
    }

    /* dry_run 只应该影响守护进程的写行为；restore 是救援手段，
     * 必须真写，否则 uninstall.sh 里的 restore 变成空操作。 */
    int saved = C.dry_run;
    C.dry_run = 0;
    do_restore();
    C.dry_run = saved;

    printf("restored: wired_chg_curr=%d ichg_limit=%ldmA input_suspend=0 thermal_remove=0\n",
           C.restore_ma, C.restore_ma / 1000L);
    return 0;
}

static int cmd_stop(void)
{
    int pid = 0;
    if (!daemon_alive(&pid)) {
        printf("daemon not running\n");
        return 0;
    }
    if (kill(pid, SIGTERM) != 0) {
        fprintf(stderr, "cannot signal pid %d: %s\n", pid, strerror(errno));
        return 1;
    }
    for (int i = 0; i < 40; i++) {          /* 最多等 4 秒 */
        usleep(100000);
        if (!daemon_alive(&pid)) { printf("stopped (pid %d)\n", pid); return 0; }
    }
    fprintf(stderr, "pid %d did not exit within 4s\n", pid);
    return 1;
}

static void usage(void)
{
    printf("thermocharge %s\n", TC_VERSION);
    printf("  run      启动恒温充电守护进程\n");
    printf("  status   显示当前状态\n");
    printf("  set k v  修改配置并通知重载 (如 set target_temp 42)\n");
    printf("  stop     结束守护进程（它会自己还原 sysfs）\n");
    printf("  restore [--force]  还原系统默认限流（守护进程在跑时会拒绝）\n");
    printf("  help     显示本帮助\n");
    printf("  --version  显示版本\n");
    printf("\n");
    printf("主要配置项 (config.conf 或 set):\n");
    printf("  target_temp  43.0  目标电池温度 ℃\n");
    printf("  hard_temp    45.0  硬上限 ℃，超过立即降流并可能暂停充电\n");
    printf("  ki          600    误差每 1℃ 每秒调整的电流量 mA/(℃·s)\n");
    printf("  kd           40    阻尼时间常数（秒），大则更稳、更迟钝\n");
    printf("  ctl_mode      1    0=wired_chg_curr 1=mca ichg_limit 2=两者\n");
    printf("  max_ma    20000    限流上限 mA（原厂快充 17600，硬上限 20500）\n");
    printf("  reassert_ms 5000   同值重投间隔 ms（防系统把我们的票关掉）\n");
    printf("  min_ma      500    限流下限 mA\n");
    printf("  startup_grace_ms 20000  插电后多少毫秒开始接管（让快充握手先完成）\n");
    printf("  dry_run       0    1=只算不写（调试用）\n");
}

int main(int argc, char **argv)
{
    resolve_paths();

    const char *cmd = argc > 1 ? argv[1] : "status";
    if (!strcmp(cmd, "run"))       return cmd_run();
    if (!strcmp(cmd, "status"))    return cmd_status();
    if (!strcmp(cmd, "set"))       return cmd_set(argc - 1, argv + 1);
    if (!strcmp(cmd, "restore"))   return cmd_restore(argc > 2 && !strcmp(argv[2], "--force"));
    if (!strcmp(cmd, "stop"))      return cmd_stop();
    if (!strcmp(cmd, "help") || !strcmp(cmd, "-h") || !strcmp(cmd, "--help")) {
        usage();
        return 0;
    }
    if (!strcmp(cmd, "--version") || !strcmp(cmd, "-V")) {
        printf("%s\n", TC_VERSION);
        return 0;
    }
    fprintf(stderr, "unknown command '%s'\n\n", cmd);
    usage();
    return 2;
}
