#!/usr/bin/env python3
"""Integrate U200-1A CSV logs to mAh (Issue #31).

Input: normal-mode log (ms,current_mA,bus_mV,power_mW) or fast-mode log
(ms,samples,...,current_avg_mA). The current column is picked from the header
line, or from the column count when the log has no header. Lines starting
with `#` (e.g. `# total,...`) are skipped.
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


# millis()（uint32_t）は約 49.7 日で 1 周する。直前の値が 1 周の手前 10 分以内で、
# 次の値が小さければ 1 周とみなす（途中でロガーを再起動した場合と区別するため）。
MILLIS_WRAP = 1 << 32
WRAP_WINDOW_MS = 600_000

# ヘッダー行が無いログ（`pio device monitor` を途中から始めたもの）の列数 → 電流の列。
# 通常モード: ms,current_mA,bus_mV,power_mW
# 高速モード(#74): ms,samples,bus_min_mV,bus_avg_mV,current_max_mA,current_min_mA,current_avg_mA
CURRENT_COL_BY_WIDTH = {4: 1, 7: 6}


def load_rows(path: Path) -> list[tuple[float, float]]:
    rows: list[tuple[float, float]] = []
    current_col: int | None = None  # ヘッダーで決まる。未確定なら列数から推定
    wrap_offset = 0.0
    prev_raw_ms: float | None = None
    with path.open(newline="", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("ms,"):
                header = line.split(",")
                for name in ("current_avg_mA", "current_mA"):
                    if name in header:
                        current_col = header.index(name)
                        break
                continue
            parts = line.split(",")
            col = current_col if current_col is not None else CURRENT_COL_BY_WIDTH.get(len(parts))
            if col is None or len(parts) <= col:
                continue
            try:
                raw_ms = float(parts[0])
                current_ma = float(parts[col])
            except ValueError:
                continue
            if (prev_raw_ms is not None and raw_ms < prev_raw_ms
                    and prev_raw_ms > MILLIS_WRAP - WRAP_WINDOW_MS):
                wrap_offset += MILLIS_WRAP
            prev_raw_ms = raw_ms
            rows.append((raw_ms + wrap_offset, current_ma))
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
