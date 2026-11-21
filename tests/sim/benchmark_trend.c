/* Virtual-time plant comparison using the actual controller, not a reimplementation.
 * Build with -DTC_SOURCE='"/absolute/path/to/thermocharge.c"' for each version.
 * Plant parameters below are never supplied to the controller. */
#include <assert.h>
#ifndef TC_SOURCE
#define TC_SOURCE "../../src/thermocharge.c"
#endif
#define main thermocharge_cli_main
#include TC_SOURCE
#undef main

static void scenario(const char *name, double tau, double lag, double start,
                     double eff, double cap, int disturbance)
{
    const double dt = 0.5, duration = 3600, target = 43;
    cfg_defaults(&C);
    C.slew_ma_s = 750;
    trend_reset(2000);
    long vote = 2000;
    double temp = start, curr = 0, voltage = 4;
    double reached = -1, peak = start, tail_min = 100, tail_max = -100;
    double band_s = 0, stable_at = -1, after_count = 0, after_good = 0;
    double variation = 0, last_w = 0;
    const char *state = "steady_hold";
    int hard_hits = 0;
    for (int tick = 0; tick < (int)(duration / dt); tick++) {
        double time = tick * dt;
        double measured = round(temp * 10) / 10;
        if (measured >= 45) hard_hits++;
        long ceiling = power_ceiling_ma(voltage);
        vote = trend_power_step(measured, voltage, curr, dt, vote, ceiling, &state);
        assert(vote <= ceiling && vote >= 0);
        double allowed = fmin(vote / 1000.0, cap);
        curr += (allowed * eff - curr) * fmin(1, dt / fmax(lag, dt));
        double ambient = 25;
        if (disturbance && time >= 900 && time < 1500) ambient = 28;
        temp += (ambient + 0.080 * curr * curr - temp) * dt / tau;
        peak = fmax(peak, temp);
        if (reached < 0 && temp >= target - 0.8) reached = time;
        /* Disturbance recovery stability is measured after the last step, not
         * across an intentionally injected change in the plant. Peak is global. */
        if (disturbance && time < 1500) { band_s = 0; stable_at = -1; }
        else if (temp >= target - 0.8 && temp <= target + 0.3) band_s += dt;
        else band_s = 0;
        if (stable_at < 0 && band_s >= 120) stable_at = time;
        if (stable_at >= 0 && time > stable_at && time <= stable_at + 300) {
            after_count++;
            if (temp >= target - 0.8 && temp <= target + 0.3) after_good++;
        }
        if (time >= duration - 300) {
            tail_min = fmin(tail_min, temp);
            tail_max = fmax(tail_max, temp);
            variation += fabs(curr * voltage - last_w);
        }
        last_w = curr * voltage;
    }
    printf("%s,%.1f,%.3f,%.3f,%.3f,%.1f,%.4f,%d,%.3f,%.3f\n",
           name, reached, peak, tail_min, tail_max, stable_at,
           after_count > 0 ? after_good / after_count : 0, hard_hits,
           variation, curr * voltage);
}

int main(void)
{
    puts("scenario,reached_s,peak_c,tail_min_c,tail_max_c,stable_s,band_fraction,hard_hits,power_variation_w,final_power_w");
    scenario("standard", 120, 3, 31, 1, 20, 0);
    scenario("slow-thermal", 300, 3, 31, 1, 20, 0);
    scenario("fast-thermal", 40, 3, 31, 1, 20, 0);
    scenario("delayed", 120, 12, 31, 1, 20, 0);
    scenario("near-target", 120, 3, 42, 1, 20, 0);
    scenario("proportional", 120, 3, 31, 0.625, 20, 0);
    scenario("fixed-cap", 120, 3, 31, 1, 3, 0);
    scenario("disturbance", 120, 3, 31, 1, 20, 1);
    return 0;
}
