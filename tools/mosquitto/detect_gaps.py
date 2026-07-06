#!/usr/bin/env python3
"""Detect missing telemetry cycles from bootCount discontinuities.

The device increments an RTC-backed bootCount on every wake. A gap in the
received bootCount sequence therefore means one of:
  - the device never woke for that cycle (timer overslept / skipped), or
  - it woke but published nothing that reached the broker.

Under change-only publishing (production intent), a single dropped transition
can leave the server showing a stale state for hours, so any gap matters.

Usage:
  detect_gaps.py                 # analyse the log once, print a report
  detect_gaps.py --device ID     # restrict to one deviceId
  detect_gaps.py --follow        # tail the log and alert on new gaps live
  detect_gaps.py --json          # machine-readable summary (one JSON object)
"""

import argparse
import json
import sys
import time
from datetime import datetime
from pathlib import Path

DEFAULT_LOG = Path(__file__).resolve().parent / "data" / "telemetry.jsonl"


def parse_ts(value: str) -> datetime | None:
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None


def parse_line(line: str):
    line = line.strip()
    if not line:
        return None
    idx = line.find(" parking-status/")
    if idx < 0:
        return None
    recv_ts = line[:idx]
    rest = line[idx + 1 :]
    sp = rest.find(" ")
    if sp < 0:
        return None
    payload = rest[sp + 1 :]
    try:
        doc = json.loads(payload)
    except json.JSONDecodeError:
        return None
    power = doc.get("power", {})
    net = doc.get("network", {})
    return {
        "recv_ts": recv_ts,
        "device": doc.get("deviceId", "?"),
        "boot": power.get("bootCount"),
        "wake": power.get("wakeCause"),
        "reset": power.get("resetReason"),
        "sleep_s": power.get("sleepSeconds"),
        "status": doc.get("status"),
    }


def split_sessions(records):
    """Split a device's records into runs separated by power_on resets."""
    sessions = []
    cur = []
    for r in records:
        if r["boot"] == 1 and r["wake"] == "power_on" and cur:
            sessions.append(cur)
            cur = []
        cur.append(r)
    if cur:
        sessions.append(cur)
    return sessions


def find_gaps(session):
    gaps = []
    for i in range(1, len(session)):
        prev, cur = session[i - 1], session[i]
        if cur["boot"] is None or prev["boot"] is None:
            continue
        expected = prev["boot"] + 1
        if cur["boot"] > expected:
            t0 = parse_ts(prev["recv_ts"])
            t1 = parse_ts(cur["recv_ts"])
            gap_min = (t1 - t0).total_seconds() / 60 if t0 and t1 else None
            gaps.append(
                {
                    "before_boot": prev["boot"],
                    "after_boot": cur["boot"],
                    "missing": cur["boot"] - expected,
                    "before_ts": prev["recv_ts"],
                    "after_ts": cur["recv_ts"],
                    "gap_min": gap_min,
                }
            )
    return gaps


def analyse(records, device_filter=None):
    by_device = {}
    for r in records:
        if r["boot"] is None:
            continue
        if device_filter and r["device"] != device_filter:
            continue
        by_device.setdefault(r["device"], []).append(r)

    report = {}
    for device, recs in by_device.items():
        sessions = split_sessions(recs)
        session_infos = []
        for s in sessions:
            max_boot = s[-1]["boot"]
            received = len(s)
            gaps = find_gaps(s)
            missing = sum(g["missing"] for g in gaps)
            session_infos.append(
                {
                    "start_ts": s[0]["recv_ts"],
                    "end_ts": s[-1]["recv_ts"],
                    "received": received,
                    "max_boot": max_boot,
                    "missing": missing,
                    "delivery_rate": (
                        received / max_boot * 100 if max_boot else None
                    ),
                    "gaps": gaps,
                }
            )
        report[device] = session_infos
    return report


def print_report(report):
    if not report:
        print("no telemetry records found")
        return
    for device, sessions in report.items():
        print(f"device={device}")
        for i, s in enumerate(sessions):
            rate = f"{s['delivery_rate']:.2f}%" if s["delivery_rate"] else "-"
            head = (
                f"  session {i}: {s['start_ts'][:19]} .. {s['end_ts'][:19]}  "
                f"recv={s['received']} maxboot={s['max_boot']} "
                f"missing={s['missing']} rate={rate}"
            )
            print(head)
            for g in s["gaps"]:
                gm = f"{g['gap_min']:.1f}min" if g["gap_min"] is not None else "?"
                print(
                    f"      GAP boot {g['before_boot']} -> {g['after_boot']} "
                    f"(missing {g['missing']}, {gm}) "
                    f"at {g['before_ts'][11:19]}"
                )


def follow(log: Path, device_filter=None):
    """Tail the log and alert whenever a new bootCount gap appears."""
    last_boot = {}
    print(f"watching {log} for bootCount gaps (Ctrl+C to stop)", flush=True)
    with log.open("r") as fh:
        fh.seek(0, 2)  # end of file
        while True:
            line = fh.readline()
            if not line:
                time.sleep(1.0)
                continue
            rec = parse_line(line)
            if not rec or rec["boot"] is None:
                continue
            if device_filter and rec["device"] != device_filter:
                continue
            dev = rec["device"]
            prev = last_boot.get(dev)
            if rec["boot"] == 1 and rec["wake"] == "power_on":
                last_boot[dev] = 1
                print(f"[{rec['recv_ts'][11:19]}] {dev} power_on reset (boot=1)")
                continue
            if prev is not None and rec["boot"] > prev + 1:
                missing = rec["boot"] - prev - 1
                print(
                    f"[{rec['recv_ts'][11:19]}] ALERT {dev} "
                    f"MISSING {missing} cycle(s): boot {prev} -> {rec['boot']}",
                    flush=True,
                )
            last_boot[dev] = rec["boot"]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--log", type=Path, default=DEFAULT_LOG)
    ap.add_argument("--device", default=None)
    ap.add_argument("--follow", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if not args.log.exists():
        print(f"log not found: {args.log}", file=sys.stderr)
        sys.exit(1)

    if args.follow:
        try:
            follow(args.log, args.device)
        except KeyboardInterrupt:
            pass
        return

    records = []
    for line in args.log.read_text().splitlines():
        rec = parse_line(line)
        if rec:
            records.append(rec)

    report = analyse(records, args.device)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_report(report)


if __name__ == "__main__":
    main()
