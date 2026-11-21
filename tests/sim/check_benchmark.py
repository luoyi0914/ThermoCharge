"""Assert predeclared ramp and stability limits on actual-C virtual plant output."""

import csv
import sys
from pathlib import Path


def load(path):
    with Path(path).open() as stream:
        return {row["scenario"]: row for row in csv.DictReader(stream)}


def check(baseline_path, candidate_path):
    baseline = load(baseline_path)
    candidate = load(candidate_path)
    assert set(baseline) == set(candidate)
    for name, row in candidate.items():
        old = baseline[name]
        assert int(row["hard_hits"]) == 0, (name, "hard pause required")
        if name in {"fixed-cap", "proportional"}:
            # Low draw without new response must not renew a recovery budget.
            assert float(row["final_power_w"]) <= float(old["final_power_w"]) + 0.05
            print(f"PASS {name}: bounded low-response output")
            continue
        reached = float(row["reached_s"])
        old_reached = float(old["reached_s"])
        assert 0 <= reached <= old_reached * 0.8, (name, "less than 20% faster")
        peak = float(row["peak_c"])
        limit = 44.0 if name == "disturbance" else 43.5
        assert peak <= limit, (name, "overshoot", peak)
        if name == "disturbance":
            assert peak <= float(old["peak_c"]) + 0.2, (name, "peak regression")
        assert 0 <= float(row["stable_s"]) <= 3300, (name, "no 120s stable window")
        assert float(row["band_fraction"]) >= 0.90, (name, "300s settling occupancy")
        assert float(row["tail_max_c"]) - float(row["tail_min_c"]) <= 0.5
        assert float(row["power_variation_w"]) <= 2.0, (name, "steady oscillation")
        improvement = 100 * (1 - reached / old_reached)
        print(f"PASS {name}: {old_reached:.1f}s -> {reached:.1f}s "
              f"({improvement:.1f}% faster), peak={peak:.3f}C")


if __name__ == "__main__":
    check(*sys.argv[1:])
