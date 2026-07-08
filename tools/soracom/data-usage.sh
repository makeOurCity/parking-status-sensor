#!/usr/bin/env bash
# Show data usage for one SIM (default: current calendar month, aggregated by month).
#
# Usage:
#   tools/soracom/data-usage.sh <sim-id>
#   tools/soracom/data-usage.sh <sim-id> --days 7    # last N days (day granularity)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
source "$ROOT/_common.sh"

require_soracom
require_jq
ensure_configured

SIM_ID="${1:-}"
PERIOD="month"
FROM=""
TO="$(date +%s)"

usage() {
  echo "Usage: $(basename "$0") <sim-id> [--days N]" >&2
  exit 1
}

[[ -n "$SIM_ID" ]] || usage

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      [[ $# -ge 2 ]] || usage
      PERIOD="day"
      FROM="$(($(date +%s) - $2 * 86400))"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$FROM" ]]; then
  # First day of current month (local time)
  FROM="$(date -j -f "%Y-%m-%d" "$(date +%Y-%m-01)" "+%s" 2>/dev/null || date -d "$(date +%Y-%m-01)" "+%s")"
fi

raw="$(soracom_api stats air sims get --sim-id "$SIM_ID" --from "$FROM" --to "$TO" --period "$PERIOD")"

echo "$raw" | jq '{
  simId: "'"$SIM_ID"'",
  period: "'"$PERIOD"'",
  fromUnix: '"$FROM"',
  toUnix: '"$TO"',
  downloadBytes: ([.[] | .dataTrafficStatsMap[]? | .downloadByteSizeTotal? // 0] | add // 0),
  uploadBytes: ([.[] | .dataTrafficStatsMap[]? | .uploadByteSizeTotal? // 0] | add // 0)
}'
