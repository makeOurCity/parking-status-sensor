#!/usr/bin/env bash
# List PoC SIMs or show one SIM including session status.
#
# Usage:
#   tools/soracom/sim-status.sh              # all SIMs (compact table)
#   tools/soracom/sim-status.sh <sim-id>     # one SIM (sessionStatus included)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
source "$ROOT/_common.sh"

require_soracom
require_jq
ensure_configured

SIM_ID="${1:-}"

if [[ -n "$SIM_ID" ]]; then
  soracom_api sims get --sim-id "$SIM_ID" | jq '{
    simId,
    status,
    groupId: .groupId,
    tags,
    sessionOnline: (.sessionStatus.online // false),
    speedClass: (.speedClass // null),
    imsi: (.profiles[0].subscribers[0].imsi // null)
  }'
  exit 0
fi

echo "simId,name,site,device-id,status,sessionOnline"
soracom_api sims list --fetch-all | jq -r '.[] | [
  .simId,
  (.tags.name // ""),
  (.tags.site // ""),
  (.tags["device-id"] // ""),
  (.status // ""),
  (if .sessionStatus then (.sessionStatus.online | tostring) else "?" end)
] | @csv'
