#!/usr/bin/env bash
# Verify Cognito User Pool + Identity Pool + IAM role setup (post setup-cognito.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

echo "=== verify parking-status iOS app Cognito setup ==="
echo "region=$AWS_REGION profile=$(profile_label)"
echo ""

fail=0
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  OK  $label"
  else
    echo "  NG  $label"
    fail=1
  fi
}

USER_POOL_ID="$(aws_cognito_idp list-user-pools --max-results 60 \
  --query "UserPools[?Name=='${COGNITO_USER_POOL_NAME}'].Id | [0]" --output text)"
IDENTITY_POOL_ID="$(aws_cognito_identity list-identity-pools --max-results 60 \
  --query "IdentityPools[?IdentityPoolName=='${COGNITO_IDENTITY_POOL_NAME}'].IdentityPoolId | [0]" --output text)"

if [[ -n "$USER_POOL_ID" && "$USER_POOL_ID" != "None" ]]; then
  check "User Pool: $COGNITO_USER_POOL_NAME" \
    aws_cognito_idp describe-user-pool --user-pool-id "$USER_POOL_ID"
  check "App Client: $COGNITO_CLIENT_NAME" \
    bash -c "aws cognito-idp list-user-pool-clients --user-pool-id '$USER_POOL_ID' --max-results 60 --query \"UserPoolClients[?ClientName=='${COGNITO_CLIENT_NAME}']\" --output text | grep -q ."
  check "Cognito user: $IOS_APP_USER_EMAIL" \
    aws_cognito_idp admin-get-user --user-pool-id "$USER_POOL_ID" --username "$IOS_APP_USER_EMAIL"
else
  echo "  NG  User Pool: $COGNITO_USER_POOL_NAME (not found)"
  fail=1
fi

if [[ -n "$IDENTITY_POOL_ID" && "$IDENTITY_POOL_ID" != "None" ]]; then
  check "Identity Pool: $COGNITO_IDENTITY_POOL_NAME" \
    aws_cognito_identity describe-identity-pool --identity-pool-id "$IDENTITY_POOL_ID"
  check "Identity Pool roles attached" \
    bash -c "aws cognito-identity get-identity-pool-roles --identity-pool-id '$IDENTITY_POOL_ID' --query 'Roles.authenticated' --output text | grep -q '^arn:aws:iam::'"
else
  echo "  NG  Identity Pool: $COGNITO_IDENTITY_POOL_NAME (not found)"
  fail=1
fi

check "IAM role: $COGNITO_AUTH_ROLE_NAME" \
  aws_iam get-role --role-name "$COGNITO_AUTH_ROLE_NAME"
check "IAM role policy: cloudwatch-logs-readonly" \
  aws_iam get-role-policy --role-name "$COGNITO_AUTH_ROLE_NAME" --policy-name cloudwatch-logs-readonly

echo ""
if [[ "$fail" -ne 0 ]]; then
  echo "Some checks failed. Run ./setup-cognito.sh first." >&2
  exit 1
fi

echo "All checks passed."
echo ""
echo "User Pool ID    : $USER_POOL_ID"
echo "Identity Pool ID: $IDENTITY_POOL_ID"
echo "Region          : $AWS_REGION"
