#!/usr/bin/env python3
"""Summarize voltage dips per wake cycle from a fast-mode log (Issue #74).

Input: logger-devkit-fast CSV
  ms,samples,bus_min_mV,bus_avg_mV,current_max_mA,current_min_mA,current_avg_mA

A wake cycle is a run of windows whose current_max_mA exceeds --wake-ma
(gaps shorter than --merge-ms are joined). For each cycle, prints the idle
voltage just before it, the lowest bus_min_mV inside it, the drop, and the
peak current.
"""

from __future__ import annotations

import argparse
import statistics
import sys
from pathlib import Path

COLS = ["ms", "samples", "bus_min", "bus_avg", "i_max", "i_min", "i_avg"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", type=Path, help="Fast-mode serial log (CSV)")
    parser.add_argument("--wake-ma", type=float, default=10.0,
                        help="current_max threshold treated as awake (default: 10)")
    parser.add_argument("--merge-ms", type=float, default=3000.0,
                        help="join awake runs separated by less than this (default: 3000)")
    return parser.parse_args()


def load_rows(path: Path) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    with path.open(errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("ms,"):
                continue
            parts = line.split(",")
            if len(parts) != len(COLS):
                continue
            try:
                rows.append(dict(zip(COLS, map(float, parts))))
            except ValueError:
                continue
    return rows


def find_cycles(rows: list[dict[str, float]], wake_ma: float,
                merge_ms: float) -> list[tuple[int, int]]:
    cycles: list[list[int]] = []
    for i, row in enumerate(rows):
        if row["i_max"] < wake_ma:
            continue
        if cycles and row["ms"] - rows[cycles[-1][1]]["ms"] < merge_ms:
            cycles[-1][1] = i
        else:
            cycles.append([i, i])
    return [(a, b) for a, b in cycles]


def main() -> int:
    args = parse_args()
    rows = load_rows(args.csv_path)
    if not rows:
        print("No data rows found (is this a fast-mode log?)", file=sys.stderr)
        return 1

    t0 = rows[0]["ms"]
    print(f"windows={len(rows)} duration_s={(rows[-1]['ms'] - t0) / 1000:.1f} "
          f"samples/window median={statistics.median(r['samples'] for r in rows):.0f}")

    cycles = find_cycles(rows, args.wake_ma, args.merge_ms)
    print(f"wake_cycles={len(cycles)}")
    print("start_s,dur_s,idle_mV,min_mV,drop_mV,i_at_min_mA,peak_mA")
    worst = None
    for a, b in cycles:
        pre = [r["bus_avg"] for r in rows[max(0, a - 20):a] if r["i_max"] < args.wake_ma]
        idle = statistics.median(pre) if pre else float("nan")
        seg = rows[a:b + 1]
        low = min(seg, key=lambda r: r["bus_min"])
        peak = max(r["i_max"] for r in seg)
        drop = idle - low["bus_min"]
        print(f"{(rows[a]['ms'] - t0) / 1000:.2f},{(seg[-1]['ms'] - seg[0]['ms']) / 1000:.2f},"
              f"{idle:.0f},{low['bus_min']:.0f},{drop:.0f},{low['i_max']:.0f},{peak:.0f}")
        if worst is None or low["bus_min"] < worst["bus_min"]:
            worst = low
    if worst is not None:
        print(f"# lowest bus_min={worst['bus_min']:.0f}mV at t={(worst['ms'] - t0) / 1000:.2f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
