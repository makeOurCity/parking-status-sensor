#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/data"
exec /opt/homebrew/opt/mosquitto/sbin/mosquitto -c "$ROOT/mosquitto.conf" -v
