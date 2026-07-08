#!/usr/bin/env bash
# Force-delete an online SIM session (LTE debug: stuck attach / long active).
#
# Usage:
#   tools/soracom/delete-session.sh <sim-id>
#   tools/soracom/delete-session.sh <sim-id> --yes   # skip confirmation

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_common.sh
source "$ROOT/_common.sh"

require_soracom
ensure_configured

SIM_ID="${1:-}"
YES="${2:-}"

if [[ -z "$SIM_ID" ]]; then
  echo "Usage: $(basename "$0") <sim-id> [--yes]" >&2
  exit 1
fi

if [[ "$YES" != "--yes" ]]; then
  echo "This deletes the current session for SIM ${SIM_ID}."
  echo "Offline SIMs return error SEM0016. Continue? [y/N]"
  read -r ans
  [[ "$ans" =~ ^[yY]$ ]] || exit 0
fi

soracom_api sims delete-session --sim-id "$SIM_ID"
echo "Session deleted for ${SIM_ID}"
