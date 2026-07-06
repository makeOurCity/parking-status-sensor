#!/usr/bin/env bash
# Readable live view of telemetry (replaces raw tail -f on telemetry.jsonl).
#
# Usage:
#   watch.sh              # follow local JSONL log (default)
#   watch.sh --all        # print entire log once, formatted
#   watch.sh --live HOST  # subscribe MQTT directly (pretty only, no JSONL append)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG="$ROOT/data/telemetry.jsonl"
FORMAT="$ROOT/format_telemetry.py"

mode="follow"
host=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      mode="all"
      shift
      ;;
    --live)
      mode="live"
      host="${2:-127.0.0.1}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,7p' "$0"
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -x "$FORMAT" ]]; then
  chmod +x "$FORMAT"
fi

case "$mode" in
  follow)
    if [[ ! -f "$LOG" ]]; then
      echo "log not found: $LOG" >&2
      echo "start subscribe.sh first, or use: watch.sh --live HOST" >&2
      exit 1
    fi
    echo "watching $LOG (Ctrl+C to stop)"
    echo "time       boot  status     R-G      clear        rssi  active     wake/reset  transport  deviceId"
    tail -f "$LOG" | python3 "$FORMAT"
    ;;
  all)
    if [[ ! -f "$LOG" ]]; then
      echo "log not found: $LOG" >&2
      exit 1
    fi
    echo "time       boot  status     R-G      clear        rssi  active     wake/reset  transport  deviceId"
    python3 "$FORMAT" < "$LOG"
    ;;
  live)
    echo "MQTT $host topic parking-status/# (pretty only, Ctrl+C to stop)"
    echo "time       boot  status     R-G      clear        rssi  active     wake/reset  transport  deviceId"
    exec mosquitto_sub -h "$host" -t 'parking-status/#' -F '%I %t %p' | python3 "$FORMAT"
    ;;
esac
