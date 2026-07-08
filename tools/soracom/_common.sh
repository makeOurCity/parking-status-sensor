#!/usr/bin/env bash
# Shared helpers for tools/soracom/*.sh

set -euo pipefail

require_soracom() {
  if ! command -v soracom >/dev/null 2>&1; then
    cat >&2 <<'EOF'
soracom: command not found

Install (macOS):
  brew trust soracom/soracom-cli
  brew tap soracom/soracom-cli
  brew install soracom-cli

Then configure once:
  soracom configure
  # Coverage: 2 (Japan), Auth: 1 (AuthKey recommended)

See tools/soracom/README.md
EOF
    exit 1
  fi
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq: command not found (brew install jq)" >&2
    exit 1
  fi
}

# Japan IoT SIM (plan-D / plan-KM1). Override: SORACOM_COVERAGE_TYPE=g
SORACOM_COVERAGE_TYPE="${SORACOM_COVERAGE_TYPE:-jp}"

soracom_api() {
  soracom "$@" --coverage-type "$SORACOM_COVERAGE_TYPE"
}

ensure_configured() {
  local profile="${SORACOM_PROFILE:-default}"
  local config="${HOME}/.soracom/${profile}.json"
  if [[ ! -f "$config" ]]; then
    cat >&2 <<EOF
SORACOM CLI is not configured (missing ${config}).

Run once:
  soracom configure
  # or: soracom configure --profile ${profile}

AuthKey creation: User Console → アカウント → AuthKeys
Do not commit credentials to this repository.
EOF
    exit 1
  fi
}
