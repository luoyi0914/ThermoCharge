/*
 * thermocharge - 恒温充电控制器 (Redmi K90 Ultra / warsaw)
 *
 * 原理：
 *   电池温度是被控量，充电电流上限是控制量。
 *   仅按电池温度与温变趋势连续调节功率，手动瓦数只作上限，不作追踪设定值。
 *
 * 调节手段（ctl_mode 选择，默认 2）：
 *   1) /sys/class/xm_power/charger/charge_interface/ichg_limit   (mA)（ctl_mode=1 单写）
 *      双写默认同时还会写 wired_chg_curr，以覆盖部分电荷泵阶段的执行差异。
 *      写入格式是三 token:  "<标签> <类型> <数值>"，如 "user all 5000"
 *      —— 解析失败会打印 mca_charge_if_sysfs_store:347 unable to parse input
 *      内核把它当作向 votable 的一次投票；特定 Min 聚合路径会取有效票的最小值，
 *      但这不证明所有执行通道或温控接管设置都只会更保守。电荷泵阶段可能还需要 wired_chg_curr。
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
#include <limits.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/types.h>
#include <stdarg.h>
#include <stddef.h>   /* offsetof：配置键表按字段偏移读默认值 */

#define TC_VERSION "1.5.0"
#define MAXPATH 256
#define MAXLINE 512

/* ---------------- 配置 ---------------- */

typedef struct {
    int  enabled;
    int  dry_run;

    int  target_temp_x10;   /* 目标温度，0.1℃ 单位，430 = 43.0℃ */
    int  hard_temp_x10;     /* 硬上限，超过则强制 min_ma */

    int  max_ma;            /* 控制输出上限 (mA) */
    int  min_ma;            /* 控制输出下限 (mA) */
    int  startup_ma;        /* 启动安全值 */
    int  power_max_w;       /* 0 = 不设手动功率上限；不是追踪设定值 */

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
static char g_abortpath[MAXPATH] = "";
static char g_hbpath[MAXPATH] = "";      /* 看门狗心跳（主控还活着） */
static char g_wdlimit[MAXPATH] = "";     /* 当前票值 mA（看门狗据此判断票是否生效） */

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
    snprintf(g_abortpath, sizeof g_abortpath, "%s/takeover.abort",   g_dir);
    snprintf(g_hbpath,    sizeof g_hbpath,    "%s/heartbeat",        g_dir);
    snprintf(g_wdlimit,   sizeof g_wdlimit,   "%s/watchdog.limit",   g_dir);
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

    c->max_ma     = 20000;   /* K90U 原厂快充 17.6A，模块上限给 20.5A 以内 */
    c->min_ma     = 500;
    c->startup_ma = 2000;

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
    c->startup_grace_ms = 1500;  /* 正常插电等待 1.5s；过温/故障保护不豁免。 */
    c->reassert_ms      = 5000;  /* 每 5s 重投一次同值票；不对回读做判等（见 enforce） */

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
    errno = 0;
    long v = strtol(b, &end, 10);
    if (end == b || errno) return dflt;
    while (isspace((unsigned char)*end)) end++;
    if (*end) return dflt;
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

    /* stderr 只在真终端上输出。service.sh 把 run 的 stderr 重定向到
     * daemon.out，这里若无条件写，每条日志会落两份盘——实测 daemon.log 与
     * daemon.out 的内容逐行相同，白占约 2 MB 磁盘和双倍写入。
     * 前台手工跑 `thermocharge run` 时 stderr 是 tty，照常看得到。 */
    if (isatty(STDERR_FILENO))
        fprintf(stderr, "[%s] [v" TC_VERSION "] %s\n", tbuf, line);
    if (g_log) {
        int written = fprintf(g_log, "[%s] [v" TC_VERSION "] %s\n", tbuf, line);
        fflush(g_log);
        if (written > 0) g_log_bytes += written;
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
    /* 不检查范围的话，(int) 截断会把 4294967297 变成 1、
     * 4294967296+9000 变成 9000 —— 手改配置就能绕过 cmd_set 的范围校验 */
    if (r < INT_MIN || r > INT_MAX) return -1;
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

/* 将温度的 double 安全转换为 0.1℃ 整数，先挡住超出 int 范围的
 * 有限输入，避免 C 对越界浮点转整数的未定义行为。 */
static int parse_x10(const char *v, int *out)
{
    double d, scaled;
    if (parse_dbl(v, &d) < 0) return -1;
    scaled = d * 10.0 + 0.5;
    if (scaled < (double)INT_MIN || scaled > (double)INT_MAX) return -1;
    *out = (int)scaled;
    return 0;
}

/* 只接受 /sys 前缀的路径，挡住 `set p_ichg /tmp/x` 这种把 root 写入重定向到
 * 任意文件（O_WRONLY|O_TRUNC 会直接把文件截断）的攻击面。 */
static int path_ok(const char *v)
{
    size_t n = strlen(v);
    /* 不允许截断成另一路径，也不允许通过 .. 越出受限根目录。 */
    if (n >= MAXPATH || strstr(v, "/../") ||
        (n >= 3 && !strcmp(v + n - 3, "/.."))) return 0;
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

    char *line = NULL;
    size_t size = 0;
    /* 长注释的续块不能被误当成另一条有效配置。 */
    while (getline(&line, &size, f) >= 0) {
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

        int iv = 0;
        if      (!strcmp(k, "enabled"))            { if (!parse_int(v,&iv)) C.enabled = iv; }
        else if (!strcmp(k, "dry_run"))            { if (!parse_int(v,&iv)) C.dry_run = iv; }
        else if (!strcmp(k, "target_temp"))        { if (!parse_x10(v,&iv)) C.target_temp_x10 = iv; }
        else if (!strcmp(k, "hard_temp"))          { if (!parse_x10(v,&iv)) C.hard_temp_x10 = iv; }
        else if (!strcmp(k, "max_ma"))             { if (!parse_int(v,&iv)) C.max_ma = iv; }
        else if (!strcmp(k, "power_max_w"))        { if (!parse_int(v,&iv) && iv >= 0 && iv <= 120) C.power_max_w = iv; }
        else if (!strcmp(k, "min_ma"))             { if (!parse_int(v,&iv)) C.min_ma = iv; }
        else if (!strcmp(k, "startup_ma"))         { if (!parse_int(v,&iv)) C.startup_ma = iv; }
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
    free(line);
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
    if (C.slew_ma_s <= 0)              C.slew_ma_s = 1000;
    if (C.log_interval_ms < 200)       C.log_interval_ms = 200;
    if (C.hold_below_soc < 0 || C.hold_below_soc > 100) C.hold_below_soc = 95;
    /* 越界值回落到与 cfg_defaults 一致的默认 2（双通道），不静默切到单通道 mca */
    if (C.ctl_mode < 0 || C.ctl_mode > 2) {
        log_msg("WARN: ctl_mode=%d out of range 0..2 -> using default 2", C.ctl_mode);
        C.ctl_mode = 2;
    }
    if (C.reassert_ms < 500)  C.reassert_ms = 500;
    if (C.reassert_ms > 60000) C.reassert_ms = 60000;

    if (C.mca_tag[0] == 0)  snprintf(C.mca_tag, sizeof C.mca_tag, "user");
    if (C.mca_type[0] == 0) snprintf(C.mca_type, sizeof C.mca_type, "all");
    /* 标签/类型里出现空白会拆散 3-token 协议，必须挡掉 */
    for (char *q = C.mca_tag;  *q; ++q) if (*q == ' ' || *q == '\t') *q = '_';
    for (char *q = C.mca_type; *q; ++q) if (*q == ' ' || *q == '\t') *q = '_';
}

/* ---------------- 控制器 ---------------- */

/* 输出与电池趋势状态；没有 PID 积分态，也不估计环境或热模型参数。 */
static struct {
    double out_ma;
    double watts;
    double last_temp;
    double filtered_temp;
    double tdot;
    double projected_temp;
    double observed_s;
    double last_volt;
    double recovery_limit_w;
} S;

#define TREND_LOOKAHEAD_S 25.0
#define TREND_OBSERVE_S   12.0
#define TREND_FILTER_S    10.0
#define SYS_LIMIT_RATIO   0.85
#define SYS_LIMIT_S       60.0
#define RECOVERY_BUDGET_W 25.0
static double g_sys_low_s = 0.0;

static void trend_reset_observation(void)
{
    S.last_temp = NAN;
    S.filtered_temp = NAN;
    S.tdot = 0.0;
    S.projected_temp = NAN;
    S.observed_s = 0.0;
    S.last_volt = NAN;
}

static void trend_reset(double start_ma)
{
    memset(&S, 0, sizeof S);
    S.out_ma = start_ma;
    trend_reset_observation();
}

/* Compare a sample with the vote that was already in effect when it was taken. */
static int below_vote(double curr_a, long vote_ma)
{
    return vote_ma > 0 && isfinite(curr_a) && curr_a >= 0.0 &&
           curr_a * 1000.0 < SYS_LIMIT_RATIO * vote_ma;
}

static int sys_limit_step(double curr_a, long prev_vote, long next_vote, double dt)
{
    if (isfinite(dt) && dt > 0.0 &&
        below_vote(curr_a, prev_vote) && below_vote(curr_a, next_vote))
        g_sys_low_s = fmin(SYS_LIMIT_S, g_sys_low_s + dt);
    else
        g_sys_low_s = 0.0;
    return g_sys_low_s >= SYS_LIMIT_S;
}

/* 电压异常时不升功率。手动上限按至少 5.5V 换算，
 * 如果读数比 5.5V 更高，宁可采用更低的电流上限。 */
static int battery_volt_ok(double volt)
{
    return isfinite(volt) && volt >= 2.5 && volt <= 5.5;
}

static long power_ceiling_ma(double volt)
{
    if (C.power_max_w == 0) return C.max_ma;
    if (!battery_volt_ok(volt)) volt = isfinite(volt) ? fmax(5.5, volt) : 5.5;
    return (long)fmin(C.max_ma, 1000.0 * C.power_max_w / volt);
}

/* 远离目标时加快爬升；接近目标时保持原有缓收特性，不用固定温升率一票否决。 */
static double trend_rise_rate(double headroom, double tdot)
{
    double trend_limit = 0.010 + 0.0015 * headroom;
    double calm = fmax(0.0, 1.0 - fmax(tdot, 0.0) / trend_limit);
    double base = 0.30 + 0.40 * headroom * headroom / (headroom * headroom + 9.0);
    return base * headroom / (1.0 + headroom) * calm;
}

/* 连续调节：只使用电池温度和温变率，W/s 随热余量/预测越线量连续变化。
 * 25s 仅是短期线性前瞻，不是试探定时器；没有固定瓦数档位或固定步长。
 * 温度先滤波再对斜率滤波，隔离 0.1℃ 量化噪声；观察期只禁止升功率。
 * 电流只确认已有票是否被执行，不作为功率追踪目标，系统限流时不向上追票。 */
static long trend_power_step(double temp, double volt, double curr, double dt,
                             long prev_vote, long ceiling, const char **state)
{
    int volt_ok = battery_volt_ok(volt);
    double v = volt_ok ? volt : 5.5;
    double min_w = fmin(C.min_ma, ceiling) * v / 1000.0;
    double max_w = ceiling * v / 1000.0;
    double target = C.target_temp_x10 / 10.0;
    *state = "steady_hold";
    if (!isfinite(dt) || dt <= 0.0 || !isfinite(temp)) {
        S.out_ma = fmin(S.out_ma, ceiling);
        return (long)floor(S.out_ma + 1e-8);
    }
    if (dt > 10.0) dt = 10.0;
    if (volt_ok) {
        if (S.watts <= 0.0) S.watts = fmin(S.out_ma, ceiling) * v / 1000.0;
        S.watts = fmax(min_w, fmin(S.watts, max_w));
    }

    if (isnan(S.last_temp) || fabs(temp - S.last_temp) > 1.5) {
        trend_reset_observation();
        S.filtered_temp = temp;
    } else {
        double a = dt / (TREND_FILTER_S + dt);
        double filtered = S.filtered_temp + a * (temp - S.filtered_temp);
        double rate = (filtered - S.filtered_temp) / dt;
        S.filtered_temp = filtered;
        S.tdot += a * (rate - S.tdot);
        S.observed_s = fmin(TREND_OBSERVE_S, S.observed_s + dt);
    }
    S.last_temp = temp;
    /* 由平滑温度外推，并补偿温度滤波的一阶延迟，避免原始量化噪声直接撞线。 */
    S.projected_temp = S.observed_s >= TREND_OBSERVE_S
                     ? S.filtered_temp + (TREND_FILTER_S + TREND_LOOKAHEAD_S) * S.tdot
                     : NAN;

    double excess = fmax(0.0, temp - target - 0.15);
    /* 前瞻线留 0.3℃ 容差，避免把 0.1℃ 量化抖动外推成持续越线。 */
    double projected_excess = isfinite(S.projected_temp)
                            ? fmax(0.0, S.projected_temp - target - 0.30) : 0.0;
    double reduce_w_s = fmin(2.0, 0.9 * excess + 0.55 * projected_excess);
    double previous_volt = S.last_volt;
    S.last_volt = volt_ok ? volt : NAN;
    double rise_w_s = 0.0;
    /* Normal ramp requires a responsive current path; only flat low-temperature
     * recovery gets a small finite budget so a partially obeyed vote cannot latch
     * the controller forever. This is permission to probe, never a power target. */
    int can_normal_rise = volt_ok && isfinite(S.projected_temp) &&
                          isfinite(curr) && curr >= 0.1 && !C.dry_run &&
                          prev_vote > 0 && curr * 1000.0 >= SYS_LIMIT_RATIO * prev_vote;
    int voltage_stable = volt_ok && isfinite(previous_volt) && fabs(volt - previous_volt) < 0.15;
    int can_recover = volt_ok && voltage_stable && isfinite(S.projected_temp) && isfinite(curr) &&
                      curr >= 0.1 && !C.dry_run && prev_vote > 0 &&
                      temp < target - 1.0 && S.projected_temp < target - 1.0 &&
                      S.tdot < 0.030; /* low-temperature rise is safe below 1.8 C/min */
    if (can_normal_rise) S.recovery_limit_w = 0.0;
    else if (can_recover && S.recovery_limit_w <= 0.0)
        S.recovery_limit_w = fmin(max_w, S.watts + RECOVERY_BUDGET_W);
    if (reduce_w_s == 0.0 && (can_normal_rise || can_recover)) {
        double headroom = fmax(0.0, target - fmax(temp, S.projected_temp) - 0.6);
        rise_w_s = trend_rise_rate(headroom, S.tdot);
        if (!can_normal_rise) {
            double recovery_left = S.recovery_limit_w - S.watts;
            rise_w_s = fmin(rise_w_s, fmax(0.0, recovery_left) / dt);
        }
    }
    double change = (rise_w_s - reduce_w_s) * dt;
    double slew = C.slew_ma_s * dt;
    if (!volt_ok) {
        /* 无法换算时维持电流票；过热或手动上限仍可收紧。 */
        double base = prev_vote > 0 ? prev_vote : S.out_ma;
        double reduction = fmin(slew, -change * 1000.0 / v);
        double out = fmin(ceiling, fmax(fmin(C.min_ma, base), base - reduction));
        if (out < base && change < 0.0) {
            if (S.watts > 0.0) S.watts = fmax(0.0, S.watts - (base - out) * v / 1000.0);
            *state = "steady_reduce";
        }
        S.out_ma = out;
        return (long)floor(out + 1e-8);
    }
    double next = fmax(min_w, fmin(max_w, S.watts + change));
    double requested_ma = next * 1000.0 / v;
    double base = prev_vote > 0 ? prev_vote : S.out_ma;
    /* 降功率或系统未取足上一票时，电压变化也不能被换算成升流。
     * 没有已确认的票也按内部输出限速，不能因电压变化突破变化率约束。 */
    double rise = change < 0.0 || !(can_normal_rise || can_recover) ? 0.0 : slew;
    double out = fmax(base - slew, fmin(base + rise, requested_ma));
    out = fmin(ceiling, out);     /* 用户上限可以立即收紧，包括低于 min_ma。 */
    if (next > S.watts && out > prev_vote) *state = "steady_rise";
    else if (reduce_w_s > 0.0 && next < S.watts) *state = "steady_reduce";
    S.watts = out != requested_ma ? out * v / 1000.0 : next;
    S.out_ma = out;
    return (long)floor(out + 1e-8);
}

static void reset_current_observation(void)
{
    g_sys_low_s = 0.0;
    trend_reset_observation();
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
 * （默认 Min）会取有效投票者的最小值；这只描述该聚合路径，不代表所有执行通道都更保守。
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
static char thermal_taken_path[MAXPATH];  /* 只归还本进程实际接管过的节点 */
static int safety_state_dirty = 1;        /* 路径/身份变更不等待日志节流 */
static long last_reassert_ms = 0;
static long last_enforced_ma   = -1;

/* 看门狗比对的"当前票值"：记我们投出去的 mA，不是实测电流。
 * 实测明显高于票值就说明票没落到电流上，接管态下这是危险信号。
 * 跟着 enforce() 走 —— 只有真正投票时才更新，空闲时保持上一票不变。 */
static void write_wd_limit(long ma)
{
    char tmp[MAXPATH];
    snprintf(tmp, MAXPATH, "%s.tmp", g_wdlimit);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fchmod(fileno(f), 0600);
    fprintf(f, "%ld\n", ma);
    fclose(f);
    rename(tmp, g_wdlimit);
}

static int enforce(long ma)
{
    int rc = 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    long now = (long)(ts.tv_sec * 1000L + ts.tv_nsec / 1000000L);
    int due = (now - last_reassert_ms >= C.reassert_ms) || (ma != last_enforced_ma);
    if (due) write_wd_limit(ma);

    int wrote = 0, failed = 0;
    if (due) {
        if (C.ctl_mode == 0 || C.ctl_mode == 2) {
            long want_ua = ma * 1000L;
            if (write_file_long(C.p_ctl, want_ua) < 0) failed = 1;
            else {
                wrote = 1;
                long rb = read_file_long(C.p_ctl, -1);
                /* 回读单位也是 uA。之前拿 mA 直接和 uA 比，差值恒为上百万，
                 * 每次真正写入都被判成"被覆写"：ow 计数虚增，而且 ctl_mode=0
                 * 时下面的时间戳永远不更新，wired 节点会按 fast_write_ms
                 * （默认 100ms）无限读写，reassert_ms 完全失效。
                 * 读不到（-1）只说明节点暂时不可读，不算系统覆盖。 */
                if (rb >= 0 && labs(rb - want_ua) > 500000L) rc = 1;
            }
        }
        if (C.ctl_mode == 1 || C.ctl_mode == 2) {
            if (mca_write(C.p_ichg, C.mca_tag, C.mca_type, ma) < 0) failed = 1;
            else wrote = 1;
        }
        if (failed) rc = -1;
        else if (wrote) {
            /* 只要本次真的写出去了就推进时间戳：ctl_mode=0 也要推进，
             * 否则重投节流对 wired 通道不存在 */
            last_reassert_ms = now;
            last_enforced_ma = ma;
        }
    }
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
static void take_thermal_override(void)
{
    if (C.dry_run || thermal_taken_path[0]) return;
    write_file_long(C.p_thermal_remove, 0);
    usleep(300000);
    if (write_file_long(C.p_thermal_remove, 1) == 0) {
        snprintf(thermal_taken_path, sizeof thermal_taken_path, "%s", C.p_thermal_remove);
        safety_state_dirty = 1;
    } else
        log_msg("WARN: cannot set thermal_remove=1 (%s)", strerror(errno));
}

static int release_thermal_override(void)
{
    if (!thermal_taken_path[0]) return 0;
    /* 归还是撤销之前的实写，不应被当前演练配置挡住。 */
    int saved = C.dry_run;
    C.dry_run = 0;
    int rc = write_file_long(thermal_taken_path, 0);
    C.dry_run = saved;
    if (rc < 0) return rc;
    thermal_taken_path[0] = '\0';
    safety_state_dirty = 1;
    log_msg("system thermal override released");
    return 0;
}

/* 退出时把两条通道都交还系统：mca 侧投一个"无限制"票并关闭我们的投票，
 * wired_chg_curr 恢复原始上限，并且无论如何都不动系统温控开关。 */
/* 两条通道都释放。
 * mca 的票是按 tag 常驻的，不随进程退出撤销：用户把 ctl_mode 从 2 改成 0
 * 之后，旧 ichg_limit 票（可能只有 500mA）仍在 Min 聚合里，而只按“当前模式”
 * 还原会漏掉它，充电一直被压在旧值，直到重启或卸载。
 * 拉到内核上限即等于放弃约束（Min 聚合下不会压住系统保护）。 */
static int release_channels(void)
{
    int wired = write_file_long(C.p_ctl, C.restore_ma);
    int mca = mca_write(C.p_ichg, C.mca_tag, C.mca_type, C.restore_ma / 1000L);
    return wired < 0 || mca < 0 ? -1 : 0;
}

static int restore_charging_channels(void)
{
    long tv = read_file_long(C.p_temp, -1);
    /* 热态或失去温度反馈时先保留/加上刹车，再归还限流通道。
     * 挂起写失败则保留已有的低电流票，不能先释放最后一道限制。 */
    int hot = tv <= 0 || tv >= C.hard_temp_x10;
    if (hot && set_suspend(1) < 0) return -1;
    int rc = release_channels();
    if (!hot && set_suspend(0) < 0) return -1;
    return rc < 0 ? -1 : hot;
}

static void do_restore(void)
{
    if (is_charging() && restore_charging_channels() < 0)
        log_msg("WARN: cannot fully restore charging channels (%s)", strerror(errno));
    /* stop_handle_charge 本进程从不写 1，也就绝不能写 0 —— 那个 1 属于
     * 系统温控/HAL/别的模块，清零它等于替别人解除刹车。 */
    if (release_thermal_override() < 0)
        log_msg("WARN: cannot restore system thermal override (%s)", strerror(errno));
}

/* ---------------- 状态文件（给 status 子命令 / WebUI 读） ---------------- */

/* ---- 看门狗心跳 ----
 * 进程外看门狗只靠这个文件的 mtime 判断"主控还活着"，不读我们的日志。
 * 必须由主循环每轮刷新，**不能挂在 write_state 里**：空闲时 write_state 受
 * log_interval_ms 节流（可配到 60s），超过看门狗的 30s 阈值就会误判成卡死。 */
static void touch_heartbeat(void)
{
    int hb = open(g_hbpath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (hb >= 0) {
        ssize_t w = write(hb, "1", 1);
        (void)w;
        close(hb);
    }
}

/* 守护进程已运行秒数，单调时钟计时，不受系统时间跳变/NTP 校时影响。
 * 以前这里写的是 time(NULL)（"当前时刻"），WebUI 拿到之后再减一次当前时间，
 * 差值恒为 0 —— 所以「本次运行」永远显示 0 分 0 秒。 */
static struct timespec g_t_start;

static long daemon_uptime_s(void)
{
    struct timespec tn;
    clock_gettime(CLOCK_MONOTONIC, &tn);
    if (g_t_start.tv_sec == 0) g_t_start = tn;   /* 兜底：首次调用即起点 */
    long up = (long)(tn.tv_sec - g_t_start.tv_sec);
    return up < 0 ? 0 : up;
}

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
    fprintf(f, "effective_mca_tag=%s\neffective_mca_type=%s\n", C.mca_tag, C.mca_type);
    fprintf(f, "effective_p_suspend=%s\neffective_p_thermal_remove=%s\n", C.p_suspend, C.p_thermal_remove);
    fprintf(f, "effective_p_temp=%s\neffective_p_current=%s\n", C.p_temp, C.p_current);
    fprintf(f, "effective_p_usb_online=%s\neffective_p_status=%s\n", C.p_usb_online, C.p_status);
    fprintf(f, "effective_p_ctl=%s\neffective_p_ichg=%s\n", C.p_ctl, C.p_ichg);
    fprintf(f, "effective_ctl_mode=%d\neffective_dry_run=%d\neffective_thermal_remove=%d\n",
            C.ctl_mode, C.dry_run, C.thermal_remove);
    fprintf(f, "effective_hard_temp_x10=%d\n", C.hard_temp_x10);
    fprintf(f, "thermal_taken_path=%s\n", thermal_taken_path);
    fprintf(f, "out=%.0f\n", S.out_ma);
    fprintf(f, "uptime=%ld\n", daemon_uptime_s());
    fprintf(f, "controller=trend\n");
    fprintf(f, "temp_pred_25s=%.2f\n", S.projected_temp);
    fprintf(f, "temp_rate_c_min=%.2f\n", isfinite(S.projected_temp) ? S.tdot * 60.0 : NAN);
    int failed = ferror(f);
    if (fclose(f) != 0) failed = 1;
    if (!failed && rename(tmp, fin) == 0) safety_state_dirty = 0;
    else unlink(tmp);
}

/* 普通调节、快回写和 SOC 阶段共用故障判定。 */
static int control_write_result(int rc, long *failures)
{
    if (rc >= 0) {
        *failures = 0;
        return 0;
    }
    reset_current_observation();
    if (++*failures < 3) return 0;
    if (*failures == 3) log_msg("ERROR: repeated control channel failures -> suspend input");
    if (set_suspend(1) < 0) return 0;
    log_msg("ERROR: input suspended until the control channel becomes writable again");
    return 1;
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

    if (access(g_abortpath, F_OK) == 0) {
        fprintf(stderr, "takeover protection latched; refusing to start\n");
        close(lockfd);
        return 4;
    }

    log_open();          /* 先开日志，后面 cfg_load 的 WARN 才能落盘 */
    cfg_defaults(&C);
    cfg_load(g_cfgpath);

    if (!C.enabled) {
        /* 退出码 3 专供 supervisor 识别："这是按配置主动停用，不是崩溃"。
         * 之前这里返回 0，而 service.sh 把任何退出都记一次崩溃，于是
         * 用户把 enabled 改成 0 再改回 1，5 分钟内就能把熔断器打满，
         * 之后 supervisor 永久停手（真机 11-14 23:32 就这么失联的）。 */
        log_msg("disabled in config, exit");
        return 3;
    }

    /* 取得独占锁后丢弃旧快照，避免新 PID 搭配上一进程的状态。 */
    unlink(g_statepath);
    unlink(g_hbpath);

    /* 写 pid 文件：set 子命令靠它发 SIGHUP，uninstall/看门狗靠它精确结束进程。
     * 放在拿到锁之后，避免第二个实例把第一个的 pidfile 覆盖掉。 */
    FILE *pf = fopen(g_pidpath, "w");
    if (pf) { fchmod(fileno(pf), 0600); fprintf(pf, "%d\n", (int)getpid()); fclose(pf); }
    
    csv_open();
    log_msg("=== thermocharge %s start (pid %d) ===", TC_VERSION, getpid());
    log_msg("controller=trend target=%.1fC hard=%.1fC range=%d..%dmA slew=%dmA/s dry_run=%d",
            C.target_temp_x10/10.0, C.hard_temp_x10/10.0, C.min_ma, C.max_ma,
            C.slew_ma_s, C.dry_run);

    /* 启动安全值：进程起来时如果已经在充电，先给个保守值；
     * 若此刻没在充电就什么都不写（插电瞬间由宽限期接管）。 */
    long limit_ma = C.startup_ma;
    if (is_charging()) {
        long cap = power_ceiling_ma(read_file_long(C.p_voltage, -1) / 1e6);
        long tv = read_file_long(C.p_temp, -1);
        if (tv <= 0 || tv >= C.hard_temp_x10) limit_ma = C.min_ma;
        if (limit_ma > cap) limit_ma = cap;
        enforce(limit_ma);
    }
    else log_msg("not charging at startup, leaving sysfs untouched");
    trend_reset(limit_ma);

    int   was_charging = -1;
    int   grace_done = 1;       /* 宽限期是否已过 */
    int   grace_has_vote = 0;   /* 当前充电会话已有票，宽限期内可以收紧 */
    int   paused = 0;           /* 是否处于 input_suspend=1 的挂起状态 */
    /* 挂起原因：0 无 / 1 过温 / 2 控制通道坏掉
     * 必须分开记。之前只有 paused 一个标志，通道故障挂起后下一拍
     * 温度一降到 target+0.3 以下就被「降温了可以起充」的逻辑解挂，
     * 而通道依然是坏的 —— 等于解除了唯一剩下的刹车。 */
    int   pause_reason = 0;
    int   reload_after_pause = 0;
    long  charge_since = 0;
    long  overwrite_cnt = 0;
    long  hard_cnt = 0;
    long  sensor_fail = 0;      /* 温度连续读失败拍数 */
    long  ctl_fail = 0;         /* 控制通道连续写失败拍数 */
    long  last_ctrl_ms = 0, last_log_ms = 0;
    long  now_ms = 0;
    int   exit_code = 0;        /* 0 正常退出；3 = 配置停用（supervisor 不计崩溃） */

    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    g_t_start = t0;      /* 「本次运行」的计时起点 */

    for (;;) {
        if (access(g_abortpath, F_OK) == 0) {
            exit_code = 4;
            break;
        }
        if (g_stop) break;
        touch_heartbeat();
        long prior_vote = last_enforced_ma;

        if (g_reload || (reload_after_pause && !paused)) {
            g_reload = 0;
            reload_after_pause = 0;
            cfg_t old = C;      /* 旧配置留着：切通道/换标签时要先释放旧票 */
            cfg_defaults(&C);
            cfg_load(g_cfgpath);
            safety_state_dirty = 1;
            /* 挂起票可能需要延期清理，但请求演练时先交还系统温控。 */
            if (C.dry_run) C.thermal_remove = 0;
            if (old.dry_run && !C.dry_run) {
                /* 模拟挂起没有真实的票需要保留。 */
                paused = 0;
                pause_reason = 0;
                ctl_fail = 0;
            }
            if (paused && C.enabled && (old.dry_run != C.dry_run ||
                strcmp(old.p_suspend, C.p_suspend) || strcmp(old.mca_tag, C.mca_tag) ||
                strcmp(old.mca_type, C.mca_type))) {
                /* 只延后切换挂起票身份；修复限流通道的路径等配置仍可即时生效。 */
                C.dry_run = old.dry_run;
                memcpy(C.p_suspend, old.p_suspend, sizeof C.p_suspend);
                memcpy(C.mca_tag, old.mca_tag, sizeof C.mca_tag);
                memcpy(C.mca_type, old.mca_type, sizeof C.mca_type);
                reload_after_pause = 1;
                log_msg("suspend vote changed by reload -> deferred until charging can resume");
            }
            if (!C.enabled) {
                C = old;   /* 退出还原必须收回当前进程实际投出的票 */
                /* 必须和冷启动一样返回 3：返回 0 会被 supervisor 当成
                 * "跑不到 60 秒就崩了"，5 分钟内开关几次 enabled 就把熔断器打满 */
                log_msg("disabled by config reload, restoring and exit");
                exit_code = 3;
                break;
            }
            if (old.ctl_mode != C.ctl_mode ||
                strcmp(old.mca_tag, C.mca_tag) || strcmp(old.mca_type, C.mca_type) ||
                strcmp(old.p_ctl, C.p_ctl) || strcmp(old.p_ichg, C.p_ichg) ||
                (!old.dry_run && C.dry_run)) {
                cfg_t nw = C;
                C = old;
                if (is_charging()) release_channels();
                C = nw;
                log_msg("control channel changed by reload -> released old channel votes");
            }
            /* 重载必须重置控制状态：否则把 max_ma 从 20000 降到 8000 时，
             * 下一拍还会 enforce(20000) 突破新上限；改 ctl_mode 更糟，
             * 新通道从没写过、旧通道还残留着我们的限流票。 */
            if (limit_ma < C.min_ma && !(grace_has_vote && !grace_done)) limit_ma = C.min_ma;
            if (limit_ma > C.max_ma) limit_ma = C.max_ma;
            trend_reset(limit_ma);
            last_enforced_ma = -1;   /* 强制下一拍重投 */
            last_reassert_ms = 0;
            hard_cnt = 0;
            reset_current_observation();
            log_msg("config reloaded: controller=trend target=%.1fC hard=%.1fC "
                    "range=%d..%dmA ctl_mode=%d reassert=%dms",
                    C.target_temp_x10/10.0, C.hard_temp_x10/10.0,
                    C.min_ma, C.max_ma, C.ctl_mode, C.reassert_ms);
        }

        struct timespec tn;
        clock_gettime(CLOCK_MONOTONIC, &tn);
        now_ms = (tn.tv_sec - t0.tv_sec) * 1000L + (tn.tv_nsec - t0.tv_nsec) / 1000000L;

        int charging = is_charging();
        /* 归还失败时保留原路径，下一拍继续重试。 */
        if (thermal_taken_path[0] && (!charging || !C.thermal_remove || C.dry_run ||
            strcmp(thermal_taken_path, C.p_thermal_remove)))
            release_thermal_override();
        long soc     = read_file_long(C.p_capacity, -1);
        long tv      = read_file_long(C.p_temp, -1);       /* 0.1℃ */
        long vv      = read_file_long(C.p_voltage, -1);    /* uV */
        long iv      = read_file_long(C.p_current, LONG_MIN); /* uA，充电时通常为负 */
        double temp_c = tv / 10.0;
        double volt   = vv / 1e6;
        double curr   = iv == LONG_MIN ? NAN : fabs((double)iv) / 1e6;
        double power  = volt * curr;
        const char *st = "idle";
        long ceiling   = power_ceiling_ma(volt);

        /* ---- 插拔电状态切换 ---- */
        if (charging != was_charging) {
            if (was_charging != -1)
                log_msg("charger %s (soc=%ld temp=%.1f)",
                        charging ? "PLUGGED" : "UNPLUGGED", soc, temp_c);
            int first = (was_charging == -1);
            was_charging = charging;
            charge_since = now_ms;
            reset_current_observation();
            trend_reset(charging ? C.startup_ma : C.restore_ma / 1000L);
            hard_cnt = 0;
            sensor_fail = 0;
            grace_done = !charging;
            grace_has_vote = first && charging && prior_vote > 0 && !C.dry_run;
            if (first && !charging) {
                /* 首次循环就判定未充电：不要写任何节点。
                 * 旧版本会 enforce(restore_ma/1000)，等于用我们更高的一票覆盖
                 * 系统更严格的 volt_thermal_limit（实测 3000mA 被顶成 22000mA）。 */
                if (safety_state_dirty)
                    write_state(0, temp_c, volt, curr, power, (int)soc,
                                C.restore_ma / 1000L, "idle");
                msleep(C.fast_write_ms);
                continue;
            }
            if (!charging) {
                /* 未插电时不写票；重新插电后保留挂起状态并按安全条件恢复。 */
                ctl_fail = 0;
            } else {
                /* 拔电时的归还票不属于这次会话。 */
                if (!first) last_enforced_ma = -1;
                limit_ma = grace_has_vote ? prior_vote : C.startup_ma;
                if (C.thermal_remove) take_thermal_override();
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
            if (safety_state_dirty || now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                write_state(0, temp_c, volt, curr, power, (int)soc, limit_ma, st);
            }
            msleep(C.fast_write_ms);
            continue;
        }

        /* ---- 温度读失败：连续 3 拍就降级保护，绝不静默冻结 ---- */
        int in_grace = now_ms - charge_since < C.startup_grace_ms;
        long safe_ma = C.min_ma < ceiling ? C.min_ma : ceiling;
        if (limit_ma > ceiling) limit_ma = ceiling;
        if (tv <= 0) {
            hard_cnt = 0;
            reset_current_observation();
            sensor_fail++;
            if (sensor_fail >= 3) {
                /* 没有任何温度反馈还继续大电流，是纯粹的盲目充电 */
                st = "sensor_fault";
                limit_ma = safe_ma;
                trend_reset(limit_ma);
                if (set_suspend(1) == 0 && !paused) {
                    paused = 1;
                    pause_reason = 1;
                }
                enforce(limit_ma);
                if (!C.dry_run) grace_has_vote = 1;
                if (safety_state_dirty || now_ms - last_log_ms >= C.log_interval_ms) {
                    last_log_ms = now_ms;
                    log_msg("ERROR: temp unreadable %ld ticks (%s) -> limit %ldmA + suspend requested",
                            sensor_fail, C.p_temp, limit_ma);
                    write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
                }
                msleep(C.fast_write_ms);
                continue;
            }
            if (!in_grace || grace_has_vote) enforce(limit_ma);
            if (safety_state_dirty)
                write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, "sensor_wait");
            msleep(C.fast_write_ms);
            continue;
        }
        sensor_fail = 0;

        /* ---- 安全判定放在最前面：任何分支都不能绕过它 ----
         * 之前的版本把宽限期和 SOC 释放分支放在硬限判断之前，结果
         * 「开机就 48℃」会按 startup_ma 跑满宽限期、「电量越满温度越高
         * 反而解除限流」。现在超限是第一优先级，且超限分支直接 continue。 */
        if (temp_c >= C.hard_temp_x10 / 10.0) {
            reset_current_observation();
            hard_cnt++;
            limit_ma = safe_ma;
            trend_reset(limit_ma);
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
            if (!C.dry_run) grace_has_vote = 1;
            if (safety_state_dirty || now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                log_msg("%s soc=%ld T=%.1f V=%.2f I=%.2f P=%.1fW limit=%ldmA",
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

        hard_cnt = 0;  /* 每个有效的低温样本都中断连续越线计数。 */
        /* ---- 挂起恢复：降到回差线以下，且真能写入安全票，才解挂。 ---- */
        if (paused) {
            double resume_temp = C.target_temp_x10 / 10.0 + 0.3;
            int cool = temp_c <= resume_temp;
            limit_ma = safe_ma;
            trend_reset(limit_ma);
            if (cool) last_enforced_ma = -1;  /* 绕过同值重投节流，实际探测通道。 */
            int rc = enforce(limit_ma);
            if (rc < 0) pause_reason = 2;
            if (rc >= 0 && !C.dry_run) grace_has_vote = 1;
            if (!cool || rc < 0 || set_suspend(0) < 0) {
                st = pause_reason == 2 ? "ctl_fault" : "hard_pause";
                if (safety_state_dirty || now_ms - last_log_ms >= C.log_interval_ms) {
                    last_log_ms = now_ms;
                    log_msg("%s soc=%ld T=%.1f: %s", st, soc, temp_c,
                            rc < 0 ? "control channel still broken" :
                            !cool ? "waiting to cool" : "cannot clear input_suspend");
                    write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
                }
                msleep(C.fast_write_ms);
                continue;
            }
            paused = 0;
            pause_reason = 0;
            ctl_fail = 0;
            log_msg("input resumed at T=%.1fC with safe vote %ldmA", temp_c, limit_ma);
            if (safety_state_dirty)
                write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, "resuming");
            msleep(C.fast_write_ms);
            continue;   /* 下轮先应用延后配置，再走宽限期或调节。 */
        }

        /* ---- 刚插电的握手宽限期：先不动 ---- */
        if (in_grace) {
            st = "grace";
            /* 只收紧已有的启动或保护票，不在正常握手期间投新票。 */
            if (grace_has_vote && C.power_max_w &&
                (last_enforced_ma < 0 || ceiling < last_enforced_ma)) {
                if (prior_vote > 0 && limit_ma > prior_vote) limit_ma = prior_vote;
                if (control_write_result(enforce(limit_ma), &ctl_fail)) {
                    paused = 1;
                    pause_reason = 2;
                    st = "ctl_fault";
                }
            }
            if (safety_state_dirty || now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
            }
            msleep(C.fast_write_ms);
            continue;
        }

        /* ---- 宽限期结束：从启动安全值开始，不追踪系统当前取流。 ---- */
        if (!grace_done) {
            grace_done = 1;
            double meas = C.startup_ma;
            if (meas < C.min_ma) meas = C.min_ma;
            if (meas > ceiling) meas = ceiling;
            trend_reset(meas);
            limit_ma = (long)meas;
            log_msg("grace over: trend initial output %.0fmA (T=%.1fC)", meas, temp_c);
        }

        /* ---- SOC 保护：快满了交还系统（但它已经在硬限判断之后，安全） ---- */
        if (C.hold_below_soc > 0 && soc >= C.hold_below_soc) {
            reset_current_observation();
            st = "soc_release";
            trend_reset(ceiling);
            limit_ma = ceiling;
            int rc = enforce(limit_ma);
            if (control_write_result(rc, &ctl_fail)) {
                paused = 1;
                pause_reason = 2;
                st = "ctl_fault";
            }
            if (safety_state_dirty || now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                write_state(1, temp_c, volt, curr, power, (int)soc, limit_ma, st);
            }
            msleep(C.fast_write_ms);
            continue;
        }

        /* ---- 控制周期 ---- */
        if (safety_state_dirty || now_ms - last_ctrl_ms >= C.sample_ms) {
            double dt = (now_ms - last_ctrl_ms) / 1000.0;
            last_ctrl_ms = now_ms;
            if (dt <= 0) dt = C.sample_ms / 1000.0;
            if (dt > 10.0) dt = 10.0;

            long prev_vote = last_enforced_ma;
            if (prev_vote > C.max_ma || C.dry_run || ctl_fail) prev_vote = -1;
            limit_ma = trend_power_step(temp_c, volt, curr, dt, prev_vote, ceiling, &st);

            if (limit_ma > ceiling) {
                limit_ma = ceiling;
                S.out_ma = limit_ma;
                st = "power_cap";
            } else if (ceiling < C.max_ma && limit_ma == ceiling && !strcmp(st, "steady_hold")) {
                st = "power_cap";
            }
            int erc = enforce(limit_ma);
            if (control_write_result(erc, &ctl_fail)) {
                paused = 1;
                pause_reason = 2;
                st = "ctl_fault";
            } else if (erc >= 0) {
                if (erc > 0) overwrite_cnt++;
                /* 若本拍把票收到了实测附近，不能继续显示为外部限流。 */
                if (sys_limit_step(curr, prev_vote, limit_ma, dt) &&
                    (!strcmp(st, "steady_hold") || !strcmp(st, "power_cap")))
                    st = "sys_limit";
            }

            if (safety_state_dirty || now_ms - last_log_ms >= C.log_interval_ms) {
                last_log_ms = now_ms;
                log_msg("%s soc=%ld T=%.1f V=%.2f I=%.2f P=%.1fW limit=%ldmA out=%.2f ow=%ld",
                        st, soc, temp_c, volt, curr, power, limit_ma, S.out_ma, overwrite_cnt);
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
            if (control_write_result(erc, &ctl_fail)) {
                paused = 1;
                pause_reason = 2;
            } else if (erc > 0) overwrite_cnt++;
        }

        msleep(C.fast_write_ms);
    }

    if (access(g_abortpath, F_OK) == 0) {
        exit_code = 4;
        log_msg("=== takeover protection latched; preserving suspend vote ===");
        if (release_thermal_override() < 0)
            log_msg("WARN: cannot restore system thermal override (%s)", strerror(errno));
    } else {
        log_msg("=== stop, restoring (ow=%ld) ===", overwrite_cnt);
        do_restore();
    }
    if (safety_state_dirty) {
        long tv = read_file_long(C.p_temp, -1);
        write_state(is_charging(), tv / 10.0,
                    read_file_long(C.p_voltage, -1) / 1e6,
                    NAN, NAN, (int)read_file_long(C.p_capacity, -1), limit_ma,
                    exit_code == 4 ? "latched" : "stopped");
    }
    unlink(g_pidpath);
    if (g_log) fclose(g_log);
    if (g_csv) fclose(g_csv);
    return exit_code;
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

    int latched = access(g_abortpath, F_OK) == 0;
    struct stat hb_stat;
    time_t now = time(NULL);
    long hb_age = -1;
    if (stat(g_hbpath, &hb_stat) == 0 && hb_stat.st_mtime <= now + 1)
        hb_age = now > hb_stat.st_mtime ? (long)(now - hb_stat.st_mtime) : 0;
    int heartbeat_ok = alive && hb_age >= 0 && hb_age <= 8;
    printf("daemon   : %s (pid %d)\n", latched ? "PROTECTION LATCHED" :
           !alive ? "NOT RUNNING" : heartbeat_ok ? "RUNNING" : "HEARTBEAT STALE", dpid);
    printf("version  : %s\n", TC_VERSION);
    printf("charging : %s (%s)\n", is_charging() ? "yes" : "no", b);
    printf("temp     : %.1f C  (target %.1f / hard %.1f)\n",
           tv / 10.0, C.target_temp_x10/10.0, C.hard_temp_x10/10.0);
    printf("battery  : %.3f V  %.3f A  %.1f W  soc %ld%%\n",
           vv / 1e6, fabs((double)iv) / 1e6, (vv / 1e6) * (fabs((double)iv) / 1e6), soc);
    printf("ctl_mode : %d  %s\n", C.ctl_mode, chdesc);
    printf("range    : %d..%d mA\n", C.min_ma, C.max_ma);

    FILE *st = fopen(g_statepath, "r");
    if (st) {
        struct stat state_stat;
        double state_window = fmax(10.0, C.log_interval_ms / 1000.0 + 8.0);
        int fresh = !latched && heartbeat_ok && fstat(fileno(st), &state_stat) == 0 &&
                    state_stat.st_mtime <= now + 1 && difftime(now, state_stat.st_mtime) <= state_window;
        printf("--- last state (%s, heartbeat %lds ago) ---\n", fresh ? "live" : "STALE", hb_age);
        if (fresh) {
            char line[MAXLINE];
            while (fgets(line, sizeof line, st)) fputs(line, stdout);
        }
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
/* kind: 0=int, 2=以 0.1 为单位存的温度(double 范围、int 存储), 3=字符串
 * off  : cfg_t 里的字段偏移。
 *
 * 这张表现在有两个用途，所以名字和字段必须和 cfg_t 严格对齐：
 *   1) set 子命令的范围校验（只认 kind 0/2）
 *   2) defaults 子命令按偏移直接从 cfg_defaults() 的结果读值
 * 好处是默认值只有 cfg_defaults() 一个来源，这里不再抄一份数字。
 * kind=3 的两项故意不开放 set：它们是写进 sysfs 的通道名，
 * 改错了控制器就拿不到限流点，且没有范围可校验。 */
typedef struct {
    const char *name;
    int   kind;
    double dmin, dmax;      /* kind 2 时生效 */
    long  imin, imax;       /* kind 0 时生效 */
    size_t off;
} keydef_t;

#define K_INT(n, f, lo, hi)   { n, 0, 0, 0, lo, hi, offsetof(cfg_t, f) }
#define K_X10(n, f, lo, hi)   { n, 2, lo, hi, 0, 0, offsetof(cfg_t, f) }
#define K_STR(n, f)           { n, 3, 0, 0, 0, 0, offsetof(cfg_t, f) }

static const keydef_t g_keys[] = {
    K_X10("target_temp", target_temp_x10, 25.0, 50.0),
    K_X10("hard_temp",   hard_temp_x10,   30.0, 55.0),
    K_INT("power_max_w", power_max_w, 0, 120),
    K_INT("max_ma",          max_ma,          1000, 20500),
    K_INT("min_ma",          min_ma,           100,  5000),
    K_INT("startup_ma",      startup_ma,       100, 20500),
    K_INT("restore_ma",      restore_ma,      1000, 22000000),
    K_INT("slew_ma_s",       slew_ma_s,        100, 20000),
    K_INT("sample_ms",       sample_ms,        100, 10000),
    K_INT("fast_write_ms",   fast_write_ms,     50,  5000),
    K_INT("log_interval_ms", log_interval_ms,  200, 60000),
    K_INT("hold_below_soc",  hold_below_soc,     0,   100),
    K_INT("pause_on_hard",   pause_on_hard,      0,     1),
    K_INT("thermal_remove",  thermal_remove,     0,     1),
    K_INT("startup_grace_ms",startup_grace_ms,   0, 120000),
    K_INT("reassert_ms",     reassert_ms,      500, 60000),
    K_INT("ctl_mode",        ctl_mode,           0,     2),
    K_STR("mca_tag",         mca_tag),
    K_STR("mca_type",        mca_type),
    K_INT("enabled",         enabled,            0,     1),
    K_INT("dry_run",         dry_run,            0,     1),
};

#define NKEYS (sizeof g_keys / sizeof g_keys[0])

/* 把一个键从配置结构里取出来，按 config.conf 的写法格式化 */
static void key_to_str(const cfg_t *c, const keydef_t *k, char *out, size_t n)
{
    switch (k->kind) {
    case 0: snprintf(out, n, "%ld", (long)*(const int *)((const char *)c + k->off)); break;
    case 2: snprintf(out, n, "%.1f", *(const int *)((const char *)c + k->off) / 10.0); break;
    default: snprintf(out, n, "%s", (const char *)c + k->off); break;
    }
}

/* 写入临时文件再 rename：原子、不截断、不会因为 256 行上限丢掉尾部 */
static int cfg_set_atomic(const char *path, const char *key, const char *val)
{
    char tmp[MAXPATH];
    /* 临时名带 pid：升级安装（customize.sh）与「恢复默认配置」可能同时写配置，
     * 共用 "#path.tmp" 会互相截断，最后 rename 出去的是混合快照。 */
    snprintf(tmp, sizeof tmp, "%s.tmp.%d", path, (int)getpid());

    /* 先记下原文件的权限：rename 换的是 inode，新建的 tmp 会按 umask 变成
     * 0644，把 install 时设的 0600 丢掉（配置里有 sysfs 路径，不该世界可读） */
    struct stat st;
    int have_st = (stat(path, &st) == 0);
    if (!have_st && errno != ENOENT) return -1;

    FILE *in = fopen(path, "r");
    /* 原文件存在却读不出来（EMFILE/ENOMEM/瞬时 I/O 错）时绝不能继续：
     * 后面会把"只含当前 key"的空文件 rename 上去，整个配置就剩一行。 */
    if (!in && (have_st || errno != ENOENT)) return -1;
    FILE *out = fopen(tmp, "w");
    if (!out) { if (in) fclose(in); return -1; }
    if (fchmod(fileno(out), have_st ? st.st_mode & 07777 : 0600) != 0) {
        if (in) fclose(in);
        fclose(out);
        unlink(tmp);
        return -1;
    }

    int found = 0, read_bad = 0, needs_newline = 0;
    char *line = NULL;
    size_t size = 0;
    ssize_t n;
    if (in) {
        /* 整行读取，不能每 MAXLINE 字节给用户注释或未知配置插入换行。 */
        while ((n = getline(&line, &size, in)) >= 0) {
            char *probe = strdup(line);
            if (!probe) { read_bad = 1; break; }
            char *hash = strchr(probe, '#');
            if (hash) *hash = 0;
            trim(probe);
            char *eq = strchr(probe, '=');
            int same = 0;
            if (eq) {
                *eq = 0;
                trim(probe);
                same = !strcmp(probe, key);
            }
            free(probe);
            if (same) {
                fprintf(out, "%s=%s\n", key, val);
                found = 1;
                needs_newline = 0;
            } else {
                if (fwrite(line, 1, (size_t)n, out) != (size_t)n) { read_bad = 1; break; }
                needs_newline = n > 0 && line[n-1] != '\n';
            }
        }
        if (ferror(in) || !feof(in)) read_bad = 1;
        if (fclose(in) != 0) read_bad = 1;
    }
    free(line);
    if (read_bad) { fclose(out); unlink(tmp); return -1; }
    if (!found) {
        if (needs_newline) fputc('\n', out);
        fprintf(out, "%s=%s\n", key, val);
    }
    if (ferror(out) || fflush(out) != 0) { fclose(out); unlink(tmp); return -1; }
    /* fsync/fclose 失败意味着数据没真正落盘，此时 rename 会把旧配置换成一个
     * 内容可能不完整的文件；宁可报错让调用方知道没写成。
     * 两步分开写：`a || b` 短路时 fsync 失败就不会执行 fclose，fd 和 FILE 都漏掉。 */
    int sync_bad = (fsync(fileno(out)) != 0);
    if (fclose(out) != 0) sync_bad = 1;
    if (sync_bad) { unlink(tmp); return -1; }
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

/* 定义在 pid_is_daemon 之后，set / defaults 共用 */
static void notify_daemon_reload(void);

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

    const keydef_t *keydef = NULL;
    for (size_t i = 0; i < NKEYS; i++)
        if (!strcmp(g_keys[i].name, key)) { keydef = &g_keys[i]; break; }
    /* kind=3 的字符串键不开放命令行修改（见键表注释） */
    if (!keydef || keydef->kind == 3) {
        fprintf(stderr, "unknown key '%s' (try: thermocharge help)\n", key);
        return 3;
    }
    char *end = NULL;
    errno = 0;
    if (keydef->kind != 0) {
        double d = strtod(val, &end);
        if (end == val || *end || errno || !isfinite(d)) { fprintf(stderr, "not a finite number: %s\n", val); return 4; }
        if (d < keydef->dmin || d > keydef->dmax) {
            fprintf(stderr, "out of range: %s must be %.1f..%.1f\n", key, keydef->dmin, keydef->dmax);
            return 4;
        }
    } else {
        long v = strtol(val, &end, 10);
        if (end == val || *end || errno) { fprintf(stderr, "not an integer: %s\n", val); return 4; }
        if (v < keydef->imin || v > keydef->imax) {
            fprintf(stderr, "out of range: %s must be %ld..%ld\n", key, keydef->imin, keydef->imax);
            return 4;
        }
    }

    if (cfg_set_atomic(g_cfgpath, key, val) != 0) {
        fprintf(stderr, "cannot write %s: %s\n", g_cfgpath, strerror(errno));
        return 1;
    }
    printf("%s=%s\n", key, val);
    notify_daemon_reload();
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

/* 通知守护进程重载配置：先确认这个 pid 真的是我们的进程，避免陈旧 pidfile 误杀 */
static void notify_daemon_reload(void)
{
    FILE *pf = fopen(g_pidpath, "r");
    if (!pf) return;
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

/* defaults [--apply]
 *   不带参数：把出厂默认值打成 key=value 打印出来（WebUI 用它填表单）
 *   带 --apply：逐项写进配置文件并通知重载（WebUI 的「恢复默认」按钮）
 * 默认值只有一个来源 —— cfg_defaults()，这里按字段偏移去读，不重复写数字。 */
/* 拷贝文件（用于"恢复默认"的整文件原子替换）。失败时不留半成品。 */
/* 仅恢复默认配置时清除退役键；set 仍只修改指定的有效键。 */
static int retired_key(const char *key)
{
    const char *const retired[] = {"power_mode", "kp", "ki", "kd", "deadband",
        "tdot_tau_s", "min_regulate_ma"};
    if (!strncmp(key, "pred_", 5) || !strncmp(key, "soft_", 5)) return 1;
    for (size_t i = 0; i < sizeof retired / sizeof retired[0]; i++)
        if (!strcmp(key, retired[i])) return 1;
    return 0;
}

static int copy_defaults_config(const char *src, const char *dst)
{
    FILE *in = fopen(src, "r");
    if (!in) return -1;
    FILE *out = fopen(dst, "w");
    if (!out) { fclose(in); return -1; }
    if (fchmod(fileno(out), 0600) != 0) {
        fclose(in);
        fclose(out);
        unlink(dst);
        return -1;
    }
    char *line = NULL;
    size_t size = 0;
    ssize_t n;
    int ok = 1;
    while ((n = getline(&line, &size, in)) >= 0) {
        char *probe = strdup(line);
        if (!probe) { ok = 0; break; }
        char *comment = strchr(probe, '#');
        if (comment) *comment = 0;
        char *eq = strchr(probe, '=');
        int retired = 0;
        if (eq) {
            *eq = 0;
            trim(probe);
            retired = retired_key(probe);
        }
        free(probe);
        /* 未知自定义键/cfg_version/整行注释逐字保留；退役键的行内注释也保留。 */
        if (!retired) {
            if (fwrite(line, 1, (size_t)n, out) != (size_t)n) { ok = 0; break; }
        } else {
            char *hash = strchr(line, '#');
            if (hash && fputs(hash, out) == EOF) { ok = 0; break; }
        }
    }
    free(line);
    if (ferror(in) || !feof(in)) ok = 0;
    if (fclose(out) != 0) ok = 0;
    fclose(in);
    if (!ok) { unlink(dst); return -1; }
    return 0;
}

static int cmd_defaults(int apply)
{
    cfg_t d;
    cfg_defaults(&d);

    char v[64];
    if (!apply) {
        for (size_t i = 0; i < NKEYS; i++) {
            key_to_str(&d, &g_keys[i], v, sizeof v);
            printf("%s=%s\n", g_keys[i].name, v);
        }
        return 0;
    }

    /* 先写到临时副本，全部键都成功才 rename 覆盖正式配置。
     * 之前逐键直接写正式文件：中途某个键失败（磁盘满、rename 失败）会留下
     * "一半默认一半旧值"的配置，而且不通知重载，守护进程还按旧内存值跑。 */
    char tmp[MAXPATH];
    snprintf(tmp, sizeof tmp, "%s.new.%d", g_cfgpath, (int)getpid());
    if (access(g_cfgpath, F_OK) == 0) {
        if (copy_defaults_config(g_cfgpath, tmp) != 0) {
            fprintf(stderr, "cannot copy config to %s: %s\n", tmp, strerror(errno));
            return 1;
        }
    } else {
        FILE *f = fopen(tmp, "w");
        if (!f) { fprintf(stderr, "cannot create %s: %s\n", tmp, strerror(errno)); return 1; }
        int failed = fchmod(fileno(f), 0600) != 0;
        if (fclose(f) != 0) failed = 1;
        if (failed) { unlink(tmp); return 1; }
    }

    for (size_t i = 0; i < NKEYS; i++) {
        key_to_str(&d, &g_keys[i], v, sizeof v);
        if (cfg_set_atomic(tmp, g_keys[i].name, v) != 0) {
            fprintf(stderr, "cannot write %s: %s (config left unchanged)\n",
                    g_keys[i].name, strerror(errno));
            unlink(tmp);
            return 1;
        }
    }
    if (rename(tmp, g_cfgpath) != 0) {
        fprintf(stderr, "cannot replace config: %s (config left unchanged)\n", strerror(errno));
        unlink(tmp);
        return 1;
    }
    printf("restored %zu keys to defaults\n", NKEYS);
    notify_daemon_reload();
    return 0;
}

static int cmd_restore(int force)
{
    if (access(g_abortpath, F_OK) == 0) {
        fprintf(stderr, "takeover protection latched; refusing to clear suspend\n");
        return 4;
    }
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
    /* 两条通道都释放：旧 ctl_mode 留下的 mca 票不会自己消失，只按当前
     * 模式还原会把充电一直压在旧值上。 */
    int hot = -1;  /* -1：未插电或恢复写入失败。 */
    int failed = 0;
    if (is_charging()) {
        /* 与正常退出共用温度门控，不因退出路径不同而解除热保护。 */
        hot = restore_charging_channels();
        failed = hot < 0;
    }
    /* 配置里开着接管就说明这个开关很可能是我们置的，交还系统温控 */
    if (C.thermal_remove && write_file_long(C.p_thermal_remove, 0) < 0) failed = 1;
    C.dry_run = saved;
    if (failed) {
        fprintf(stderr, "restore incomplete; preserving safety where possible\n");
        return 1;
    }

    printf("restored: wired_chg_curr=%d ichg_limit=%ldmA input_suspend=%d thermal_remove=%d\n",
           C.restore_ma, C.restore_ma / 1000L, hot, C.thermal_remove ? 0 : -1);
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

/* 内部只读接口：supervisor、看门狗和 WebUI 共用实际配置解析。 */
static int cmd_config_int(int argc, char **argv)
{
    const char *const keys[] = {"enabled", "thermal_remove", "power_max_w",
        "ctl_mode", "dry_run", "hard_temp_x10"};
    cfg_defaults(&C);
    cfg_load(g_cfgpath);
    /* 演练不接管，不能为它启动会真实停充的看门狗。 */
    const int values[] = {C.enabled, C.dry_run ? 0 : C.thermal_remove,
        C.power_max_w, C.ctl_mode, C.dry_run, C.hard_temp_x10};

    if (argc < 2) return 2;
    for (int arg = 1; arg < argc; arg++) {
        size_t i = 0;
        while (i < sizeof keys / sizeof keys[0] && strcmp(argv[arg], keys[i])) i++;
        if (i == sizeof keys / sizeof keys[0]) return 2;
        printf("%s=%d\n", keys[i], values[i]);
    }
    return 0;
}

/* 严格白名单：只导出 C 已规范化/验证的配置，不能泛化为任意字段读取。 */
static int cmd_config_str(int argc, char **argv)
{
    const char *const keys[] = {"mca_tag", "mca_type", "p_suspend", "p_thermal_remove",
        "p_temp", "p_current", "p_usb_online", "p_status", "p_ctl", "p_ichg"};
    cfg_defaults(&C);
    cfg_load(g_cfgpath);
    const char *const values[] = {C.mca_tag, C.mca_type, C.p_suspend, C.p_thermal_remove,
        C.p_temp, C.p_current, C.p_usb_online, C.p_status, C.p_ctl, C.p_ichg};

    if (argc < 2) return 2;
    for (int arg = 1; arg < argc; arg++) {
        size_t i = 0;
        while (i < sizeof keys / sizeof keys[0] && strcmp(argv[arg], keys[i])) i++;
        if (i == sizeof keys / sizeof keys[0]) return 2;
        printf("%s=%s\n", keys[i], values[i]);
    }
    return 0;
}

static void usage(void)
{
    printf("thermocharge %s\n", TC_VERSION);
    printf("  run      启动恒温充电守护进程\n");
    printf("  status   显示当前状态\n");
    printf("  set k v  修改配置并通知重载 (如 set target_temp 42)\n");
    printf("  defaults [--apply]  打印 / 恢复全部出厂默认值\n");
    printf("  stop     结束守护进程（它会自己还原 sysfs）\n");
    printf("  restore [--force]  还原系统默认限流（守护进程在跑时会拒绝）\n");
    printf("  help     显示本帮助\n");
    printf("  --version  显示版本\n");
    printf("\n");
    printf("主要配置项 (config.conf 或 set):\n");
    printf("  target_temp  43.0  目标电池温度 ℃\n");
    printf("  hard_temp    45.0  硬上限 ℃，超过立即降流并可能暂停充电\n");
    printf("  power_max_w   0    电池侧功率上限 W，0=不额外限制\n");
    printf("  ctl_mode      2    0=wired_chg_curr 1=mca ichg_limit 2=两者\n");
    printf("  max_ma    20000    限流上限 mA（原厂快充 17600，硬上限 20500）\n");
    printf("  reassert_ms 5000   同值重投间隔 ms（防系统把我们的票关掉）\n");
    printf("  min_ma      500    限流下限 mA\n");
    printf("  startup_grace_ms 1500  正常插电等待毫秒数（安全保护优先）\n");
    printf("  dry_run       0    1=只算不写（调试用）\n");
}

int main(int argc, char **argv)
{
    resolve_paths();

    const char *cmd = argc > 1 ? argv[1] : "status";
    if (!strcmp(cmd, "run"))       return cmd_run();
    if (!strcmp(cmd, "status"))    return cmd_status();
    if (!strcmp(cmd, "config-int")) return cmd_config_int(argc - 1, argv + 1);
    if (!strcmp(cmd, "config-str")) return cmd_config_str(argc - 1, argv + 1);
    if (!strcmp(cmd, "set"))       return cmd_set(argc - 1, argv + 1);
    if (!strcmp(cmd, "defaults"))  return cmd_defaults(argc > 2 && !strcmp(argv[2], "--apply"));
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
