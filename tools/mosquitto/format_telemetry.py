#!/usr/bin/env python3
"""Pretty-print telemetry.jsonl lines (timestamp topic JSON)."""

import json
import sys


def format_line(line: str) -> str:
    line = line.strip()
    if not line:
        return ""

    parts = line.split(" ", 2)
    if len(parts) < 3:
        return line

    recv_ts, _topic, payload = parts
    time_short = recv_ts.split("T", 1)[-1][:8] if "T" in recv_ts else recv_ts

    try:
        d = json.loads(payload)
    except json.JSONDecodeError:
        return line

    device = d.get("deviceId", "?")
    status = d.get("status", "?")
    raw = d.get("raw", {})
    red = raw.get("red")
    green = raw.get("green")
    clear = raw.get("clear")
    rg = red - green if red is not None and green is not None else None

    power = d.get("power", {})
    net = d.get("network", {})
    boot = power.get("bootCount", "?")
    wake = power.get("wakeCause", "?")
    reset = power.get("resetReason", "?")
    active = power.get("activeMsBeforePublish", "?")
    rssi = net.get("wifiRssi", "-")
    transport = net.get("transport", "?")
    publish_ok = net.get("deliveryConfirmed")
    if publish_ok is None:
        publish_ok = net.get("publishOk")
    publish_attempts = net.get("publishAttempts", "?")
    outbox_pending = net.get("outboxPending")
    wake_interval = power.get("wakeInterval")

    rg_str = f"R-G={rg:+5d}" if rg is not None else "R-G=    ?"
    clear_str = f"clear={clear}" if clear is not None else "clear=?"

    pub_str = ""
    if publish_ok is not None:
        pub_str = f"  ack={'yes' if publish_ok else 'NO'}@{publish_attempts}"
    outbox_str = ""
    if outbox_pending:
        outbox_str = f"  ob={outbox_pending}"
    # Flag an oversleep: the wall-clock wake interval was well beyond the
    # scheduled sleep, i.e. the timer skipped/overslept one or more cycles.
    oversleep_str = ""
    if wake_interval:
        over = wake_interval.get("oversleepMs")
        if isinstance(over, (int, float)) and over >= 30000:
            oversleep_str = f"  OVERSLEEP+{over/1000:.0f}s"

    return (
        f"{time_short}  boot={str(boot):>3}  {status:9}  {rg_str}  {clear_str:12}  "
        f"rssi={str(rssi):>4}  active={active}ms  {wake}/{reset}  {transport}"
        f"{pub_str}{outbox_str}{oversleep_str}  {device}"
    )


def main() -> None:
    for line in sys.stdin:
        out = format_line(line)
        if out:
            print(out, flush=True)


if __name__ == "__main__":
    main()
