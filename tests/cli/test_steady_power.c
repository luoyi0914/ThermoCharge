/* Build/run only after explicit authorization; this test includes the daemon source. */
#include <assert.h>
#define main thermocharge_cli_main
#include "../../src/thermocharge.c"
#undef main

static long step(double temp, double volt, double curr, long vote, const char **state)
{
    return trend_power_step(temp, volt, curr, 1.0, vote, power_ceiling_ma(volt), state);
}

static void observe(double temp, long ma)
{
    const char *state;
    trend_reset(ma);
    for (int i = 0; i <= 12; i++) step(temp, 4, ma / 1000.0, ma, &state);
    assert(isfinite(S.projected_temp));
}

static double rise_at(double temp, double dt)
{
    const char *state;
    observe(temp, 8000);
    /* Keep the initial power identical, changing only thermal headroom or dt. */
    S.out_ma = 8000;
    S.watts = 32;
    long ma = trend_power_step(temp, 4, 8, dt, 8000, C.max_ma, &state);
    assert(ma > 8000 && !strcmp(state, "steady_rise"));
    return S.watts - 32;
}

static void legacy_config_is_inert(void)
{
    const char *keys[] = {
        "power_mode", "kp", "ki", "kd", "deadband", "tdot_tau_s",
        "pred_enable", "pred_alpha", "pred_tau_s", "pred_ambient",
        "pred_margin", "pred_horizon_s", "pred_hit_s", "min_regulate_ma",
        "soft_landing", "soft_margin", "soft_band",
    };
    char path[MAXPATH];
    const char *tmp = getenv("TMPDIR");
    snprintf(path, sizeof path, "%s/tc-trend-config-XXXXXX", tmp ? tmp : "/tmp");
    int fd = mkstemp(path);
    assert(fd >= 0);
    FILE *f = fdopen(fd, "w");
    assert(f);
    cfg_defaults(&C);
    cfg_load(path);
    cfg_t expected = C;
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        fprintf(f, "%s=%s\n", keys[i], !strcmp(keys[i], "power_mode") ? "0" : "999");
        for (size_t j = 0; j < NKEYS; j++) assert(strcmp(keys[i], g_keys[j].name));
        char *args[] = {"set", (char *)keys[i], "0"};
        assert(cmd_set(3, args) == 3);
        char *read_args[] = {"config-int", (char *)keys[i]};
        assert(cmd_config_int(2, read_args) == 2);
    }
    assert(fclose(f) == 0);
    cfg_defaults(&C);
    cfg_load(path);
    assert(memcmp(&expected, &C, sizeof C) == 0);
    for (int watts = 0; watts <= 120; watts++) {
        f = fopen(path, "w");
        assert(f);
        fprintf(f, "power_max_w=%d\n", watts);
        assert(fclose(f) == 0);
        cfg_defaults(&C);
        cfg_load(path);
        assert(C.power_max_w == watts);  /* No preset/rounding of free integer caps. */
        assert(power_ceiling_ma(4) == (watts ? (long)fmin(C.max_ma, watts * 250) : C.max_ma));
    }
    unlink(path);
    cfg_defaults(&C);
}

static void config_lines_are_preserved(void)
{
    char path[MAXPATH];
    const char *tmp = getenv("TMPDIR");
    snprintf(path, sizeof path, "%s/tc-trend-lines-XXXXXX", tmp ? tmp : "/tmp");
    int fd = mkstemp(path);
    assert(fd >= 0);
    FILE *f = fdopen(fd, "w");
    assert(f);
    /* The old 512-byte reader parsed this comment's continuation as enabled=0. */
    assert(fputc('#', f) != EOF);
    for (int i = 0; i < MAXLINE - 2; i++) assert(fputc('x', f) != EOF);
    assert(fputs("enabled=0\n", f) >= 0);
    assert(fputs("unknown_user_key=", f) >= 0);
    for (int i = 0; i < 2048; i++) assert(fputc('z', f) != EOF);
    assert(fputs("\nmax_ma=9000", f) >= 0);  /* Deliberately no final newline. */
    assert(fclose(f) == 0);
    cfg_defaults(&C);
    cfg_load(path);
    assert(C.enabled == 1 && C.max_ma == 9000);

    f = fopen(path, "r");
    assert(f);
    char original[4096];
    size_t original_n = fread(original, 1, sizeof original, f);
    assert(!ferror(f) && feof(f));
    assert(fclose(f) == 0);
    assert(cfg_set_atomic(path, "target_temp", "41.0") == 0);
    f = fopen(path, "r");
    assert(f);
    char updated[4096];
    size_t updated_n = fread(updated, 1, sizeof updated, f);
    assert(!ferror(f) && feof(f));
    assert(fclose(f) == 0);
    const char added[] = "\ntarget_temp=41.0\n";
    assert(updated_n == original_n + sizeof added - 1);
    assert(memcmp(updated, original, original_n) == 0);
    assert(memcmp(updated + original_n, added, sizeof added - 1) == 0);
    struct stat st;
    assert(stat(path, &st) == 0 && (st.st_mode & 0777) == 0600);
    unlink(path);
    assert(cfg_set_atomic(path, "target_temp", "42.0") == 0);
    assert(stat(path, &st) == 0 && (st.st_mode & 0777) == 0600);
    unlink(path);
    cfg_defaults(&C);
}

static void ramp_matrix(void)
{
    const double h[] = {0, 0.2, 1, 3, 6, 10};
    const double rates[] = {-0.01, 0, 0.005, 0.0075, 0.01, 0.015, 0.03, 0.06};
    const double dts[] = {0.2, 0.5, 1, 2, 5, 10};
    for (size_t j = 0; j < sizeof rates / sizeof rates[0]; j++) {
        double previous = -1;
        for (size_t i = 0; i < sizeof h / sizeof h[0]; i++) {
            double r = trend_rise_rate(h[i], rates[j]);
            assert(isfinite(r) && r >= 0 && r < 0.70 && r >= previous);
            previous = r;
        }
    }
    assert(trend_rise_rate(6, 0.01) > 0.25);  /* Old formula stopped completely. */
    assert(trend_rise_rate(0, 0) == 0);
    assert(trend_rise_rate(0.2, 0) < 0.051);
    for (size_t i = 0; i < sizeof h / sizeof h[0]; i++) {
        double previous = 1;
        for (size_t j = 0; j < sizeof rates / sizeof rates[0]; j++) {
            double r = trend_rise_rate(h[i], rates[j]);
            assert(r <= previous);
            previous = r;
        }
    }
    for (size_t i = 0; i < sizeof dts / sizeof dts[0]; i++) {
        double accumulated = 0, dt = dts[i];
        for (int j = 0; j < (int)round(60 / dt); j++)
            accumulated += trend_rise_rate(6, 0.01) * dt;
        assert(fabs(accumulated - 60 * trend_rise_rate(6, 0.01)) < 1e-8);
    }
    /* Recovery is a power ceiling, not extra energy or a per-sample allocation. */
    for (size_t i = 0; i < sizeof dts / sizeof dts[0]; i++) {
        const char *state;
        double dt = dts[i];
        trend_reset(2000);
        long vote = 2000;
        for (int j = 0; j < (int)round(900 / dt); j++) {
            vote = trend_power_step(32, 4, 1, dt, vote, C.max_ma, &state);
            assert(S.watts <= 8 + RECOVERY_BUDGET_W + 1e-7);
        }
        assert(fabs(S.watts - (8 + RECOVERY_BUDGET_W)) < 1e-6);
        double ceiling = S.recovery_limit_w;
        reset_current_observation();
        for (int j = 0; j < 30; j++)
            vote = trend_power_step(32, 4, 1, dt, vote, C.max_ma, &state);
        assert(S.recovery_limit_w == ceiling);
    }
}

int main(void)
{
    const char *state;
    cfg_defaults(&C);
    assert(C.power_max_w == 0);
    legacy_config_is_inert();
    config_lines_are_preserved();
    ramp_matrix();

    trend_reset(2000);
    assert(trend_power_step(32, 4, 2, 10, 2000, C.max_ma, &state) == 2000);
    assert(isnan(S.projected_temp));
    for (int i = 0; i < 11; i++) assert(step(32, 4, 2, 2000, &state) == 2000);
    long ma = step(32, 4, 2, 2000, &state);
    assert(fabs(S.watts - 8 - trend_rise_rate(10.4, 0)) < 1e-8);
    assert(ma > 2000 && !strcmp(state, "steady_rise"));
    long next = step(32, 4, ma / 1000.0, ma, &state);
    assert(next > ma && fabs((S.watts - 8) - 2 * trend_rise_rate(10.4, 0)) < 1e-8);

    double near = rise_at(41.8, 1.0);
    double middle = rise_at(40.5, 1.0);
    double cold = rise_at(37.0, 1.0);
    assert(near > 0 && near < middle && middle < cold);
    assert(fabs(cold - trend_rise_rate(5.4, 0)) < 1e-8);
    double half = rise_at(40.5, 0.5);
    assert(fabs(middle - 2 * half) < 1e-9);  /* W/s, not watts per sample. */

    trend_reset(8000);
    for (int i = 0; i < 90; i++) assert(step(42.5, 4, 8, 8000, &state) == 8000);
    assert(!strcmp(state, "steady_hold"));
    assert(fabs(step(42.5, 4.25, 8, 8000, &state) * 4.25 / 1000 - 32) < 0.005);
    trend_reset(8000);
    ma = step(43.3, 4, 8, 8000, &state);
    assert(ma < 8000 && !strcmp(state, "steady_reduce"));

    /* Sensor quantization and jitter near target must not ratchet power down/up. */
    for (int pattern = 0; pattern < 2; pattern++) {
        trend_reset(8000);
        for (int i = 0; i < 240; i++) {
            double temp = 43.0 + ((pattern ? (i / 10) % 2 : i % 2) ? 0.1 : -0.1);
            assert(step(temp, 4, 8, 8000, &state) == 8000);
        }
        assert(fabs(S.tdot) < 0.005 && !strcmp(state, "steady_hold"));
    }

    /* Field report: 34.9 C, 4.073 V, 1.18 A measured vs 1886 mA voted.
     * The low ratio alone must not forbid cold recovery; a flat response bounds it. */
    trend_reset(1886);
    ma = 1886;
    for (int i = 0; i < 12; i++) assert(step(34.9, 4.073, 1.18, ma, &state) == 1886);
    ma = step(34.9, 4.073, 1.18, ma, &state);
    assert(ma > 1886 && !strcmp(state, "steady_rise"));
    for (int i = 0; i < 180; i++) ma = step(34.9, 4.073, 1.18, ma, &state);
    assert(ma > 1886 && ma <= 9000 && !strcmp(state, "steady_hold"));
    assert(step(34.9, 3.8, 1.18, ma, &state) <= ma);  /* Voltage cannot extend the budget. */
    assert(step(34.9, 4.073, NAN, ma, &state) <= ma);
    assert(step(34.9, NAN, 1.18, ma, &state) <= ma);
    trend_reset(1886);
    for (int i = 0; i <= 12; i++) ma = step(34.9, 4.073, 2.4, ma, &state);
    assert(ma > 1886 && !strcmp(state, "steady_rise"));  /* Responsive current opens normal ramp. */

    /* A proportional response below 85% is not a fixed system cap. */
    trend_reset(1886);
    ma = 1886;
    for (int i = 0; i < 90; i++) ma = step(34.9, 4.073, 0.000625 * ma, ma, &state);
    assert(ma > 2600);

    /* A small temperature rise at low temperature does not freeze output. */
    trend_reset(1886);
    ma = 1886;
    for (int i = 0; i < 81; i++) ma = step(34.4 + 0.0075 * i, 4.073, ma / 1000.0, ma, &state);
    next = step(35.02, 4.073, ma / 1000.0, ma, &state);
    assert(next > ma);

    /* Matching watts at higher voltage lowers mA, not temperature-driven power. */
    trend_reset(1886);
    assert(step(34.9, 4.073, 1.18, 1886, &state) == 1886);
    double watts_before_voltage_change = S.watts;
    assert(step(34.9, 4.15, 1.18, 1886, &state) < 1886);
    assert(fabs(S.watts - watts_before_voltage_change) < 0.005);
    trend_reset(8000);
    for (int i = 0; i < 20; i++) step(32, 4, 8, -1, &state);
    assert(S.out_ma == 8000);  /* No confirmed prior vote: no upward control. */
    assert(step(32, 3.8, 8, -1, &state) <= 8000);
    C.dry_run = 1;
    assert(step(32, 3.0, 8, -1, &state) <= 8000);
    C.dry_run = 0;

    trend_reset(8000);
    assert(step(42.5, 4, 8, 8000, &state) == 8000);
    assert(step(42.5, -1, 8, 8000, &state) == 8000);
    assert(S.watts == 32.0);
    assert(step(42.5, 4, 8, 8000, &state) == 8000);

    /* Trend braking starts below target; cooling with headroom rises smoothly. */
    trend_reset(8000);
    ma = 8000;
    for (int i = 0; i <= 20; i++)
        ma = step(40.5 + 0.1 * i, 4, ma / 1000.0, ma, &state);
    assert(S.projected_temp > 43.15 && ma < 8000 && !strcmp(state, "steady_reduce"));
    reset_current_observation();
    assert(isnan(S.projected_temp) && S.tdot == 0);
    assert(step(39, 4, ma / 1000.0, ma, &state) == ma);  /* Jump restarts observation. */
    observe(42.2, 8000);
    ma = step(42.1, 4, 8, 8000, &state);
    assert(ma > 8000 && !strcmp(state, "steady_rise"));

    trend_reset(8000);
    ma = step(43.3, -1, 8, 8000, &state);
    assert(step(43.3, 4, 8, ma, &state) <= ma);
    C.slew_ma_s = 100;
    trend_reset(8000);
    ma = step(44.9, 4, 8, 8000, &state);
    assert(ma == 7900);  /* Normal control is slew-limited, unlike hard safety. */
    double held = S.out_ma;
    assert(trend_power_step(32, 4, 8, 0, ma, C.max_ma, &state) == ma);
    assert(S.out_ma == held);

    cfg_defaults(&C);
    C.power_max_w = 25;
    assert(power_ceiling_ma(4) == 6250);
    assert(power_ceiling_ma(4.5) == 5555);
    assert(power_ceiling_ma(-1) == 4545);
    assert(power_ceiling_ma(NAN) == 4545);
    trend_reset(8000);
    assert(step(42.5, 4, 8, 8000, &state) == 6250);  /* Immediate cap tightening. */
    trend_reset(3000);
    for (int i = 0; i < 60; i++) assert(step(42.5, 4, 3, 3000, &state) == 3000);
    C.power_max_w = 1;
    assert(step(32, 4, 0.25, 250, &state) == 250);
    puts("continuous battery trend, inert legacy config and manual ceiling: PASS");
    return 0;
}
