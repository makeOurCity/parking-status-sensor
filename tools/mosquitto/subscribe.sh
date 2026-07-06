#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HOST="${1:-127.0.0.1}"
LOG="$ROOT/data/telemetry.jsonl"

mkdir -p "$ROOT/data"
echo "logging to $LOG (Ctrl+C to stop)"
echo "pretty view: $ROOT/watch.sh"
exec mosquitto_sub -h "$HOST" -t 'parking-status/#' -F '%I %t %p' | tee -a "$LOG"
