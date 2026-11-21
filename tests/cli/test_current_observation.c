/* Build/run only after explicit authorization; this test includes the daemon source. */
#include <assert.h>
#define main thermocharge_cli_main
#include "../../src/thermocharge.c"
#undef main

int main(void)
{
    reset_current_observation();
    for (int i = 0; i < 59; i++) assert(!sys_limit_step(8.6, 11927, 11927, 1.0));
    assert(sys_limit_step(8.6, 11927, 11927, 1.0));
    assert(!sys_limit_step(8.6, 11927, 9000, 1.0));
    assert(!sys_limit_step(8.6, 9000, 11927, 60.0));
    assert(!sys_limit_step(8.6, -1, 11927, 60.0));
    assert(!sys_limit_step(NAN, 11927, 11927, 60.0));
    assert(!sys_limit_step(INFINITY, 11927, 11927, 60.0));
    assert(!sys_limit_step(-1.0, 11927, 11927, 60.0));
    assert(!sys_limit_step(0.0, 11927, 11927, NAN));
    assert(!sys_limit_step(0.0, 11927, 11927, -1.0));
    assert(sys_limit_step(0.0, 11927, 11927, 60.0));
    reset_current_observation();
    assert(sys_limit_step(1.8, 6000, 6000, 60.0));
    reset_current_observation();
    assert(!sys_limit_step(0.1, 6000, 6000, 59.0));
    assert(sys_limit_step(0.1, 6000, 6000, 1.0));
    reset_current_observation();
    assert(!sys_limit_step(8.6, 11927, 11927, 1.0));
    assert(!below_vote(8.5, 10000));  /* Exact boundary is not below the vote. */

    cfg_defaults(&C);
    trend_reset(8000);
    const char *state;
    for (int i = 0; i < 30; i++)
        assert(trend_power_step(42.5, 4, 4, 1, 8000, C.max_ma, &state) == 8000);
    assert(isfinite(S.projected_temp));
    assert(!strcmp(state, "steady_hold"));
    /* Observation reset clears evidence, not the existing power/current output. */
    double watts = S.watts;
    double output = S.out_ma;
    reset_current_observation();
    assert(g_sys_low_s == 0 && S.tdot == 0 && S.observed_s == 0);
    assert(isnan(S.last_temp) && isnan(S.filtered_temp) && isnan(S.projected_temp));
    assert(S.watts == watts && S.out_ma == output);
    assert(trend_power_step(32, 4, 8, 1, 8000, C.max_ma, &state) == 8000);
    assert(isnan(S.projected_temp));
    for (int i = 0; i < 11; i++)
        assert(trend_power_step(32, 4, 8, 1, 8000, C.max_ma, &state) == 8000);
    assert(trend_power_step(32, 4, 8, 1, 8000, C.max_ma, &state) > 8000);

    /* Boundary noise is diagnostic evidence, not a delayed 60s rise permit. */
    assert(below_vote(8.49, 10000));
    assert(!below_vote(8.50, 10000));
    assert(!below_vote(8.51, 10000));
    trend_reset(2000);
    long vote = 2000;
    for (int i = 0; i < 900; i++) {
        double measured = 1.70 + (i % 2 ? 0.002 : -0.002);
        vote = trend_power_step(32, 4, measured, 1, vote, C.max_ma, &state);
        assert(S.watts <= 8.6 + RECOVERY_BUDGET_W);
    }
    double recovery_ceiling = S.recovery_limit_w;
    reset_current_observation();
    assert(S.recovery_limit_w == recovery_ceiling);

    C.dry_run = 1;
    trend_reset(8000);
    for (int i = 0; i < 90; i++)
        assert(trend_power_step(32, 4, 8, 1, 8000, C.max_ma, &state) == 8000);
    assert(trend_power_step(43.5, 4, 8, 1, 8000, C.max_ma, &state) < 8000);
    puts("current observation, no system-limit chasing and trend reset: PASS");
    return 0;
}
