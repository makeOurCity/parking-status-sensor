#!/usr/bin/env python3
"""Integrate U200-1A CSV logs to mAh (Issue #31).

Input columns: ms,current_mA,bus_mV,power_mW
Uses trapezoidal integration on |current| (charge consumed regardless of sign).
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", type=Path, help="Serial log file (CSV)")
    parser.add_argument(
        "--abs",
        action="store_true",
        default=True,
        help="Integrate |current| (default: True)",
    )
    return parser.parse_args()


def load_rows(path: Path) -> list[tuple[float, float]]:
    rows: list[tuple[float, float]] = []
    with path.open(newline="") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("ms,"):
                continue
            parts = line.split(",")
            if len(parts) < 2:
                continue
            try:
                t_ms = float(parts[0])
                current_ma = float(parts[1])
            except ValueError:
                continue
            rows.append((t_ms, current_ma))
    return rows


def integrate_mah(rows: list[tuple[float, float]], use_abs: bool) -> float:
    if len(rows) < 2:
        return 0.0
    charge_uah = 0.0
    for (t0, i0), (t1, i1) in zip(rows, rows[1:]):
        dt_h = (t1 - t0) / 3_600_000.0
        if dt_h <= 0:
            continue
        i_avg = (abs(i0) + abs(i1)) / 2.0 if use_abs else (i0 + i1) / 2.0
        charge_uah += i_avg * 1000.0 * dt_h  # mA·h → µA·h scale fix: mA * h = mAh directly
    return charge_uah / 1000.0  # mAh


def main() -> int:
    args = parse_args()
    rows = load_rows(args.csv_path)
    if not rows:
        print("No data rows found", file=sys.stderr)
        return 1

    duration_s = (rows[-1][0] - rows[0][0]) / 1000.0
    mah = integrate_mah(rows, args.abs)
    avg_ma = mah / (duration_s / 3600.0) if duration_s > 0 else 0.0

    print(f"rows={len(rows)} duration_s={duration_s:.2f}")
    print(f"integrated_mAh={mah:.6f}")
    print(f"avg_current_mA={avg_ma:.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
