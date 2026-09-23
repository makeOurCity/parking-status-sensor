#!/usr/bin/env bash
# Create Cognito User Pool + Identity Pool + IAM role for the iOS log-viewer
# app (Issue #68). Scopes the authenticated IAM role to read-only access on
# a single CloudWatch Logs log group so the app never needs long-lived AWS
# access keys.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found. Install jq first." >&2
  exit 1
fi

if [[ -z "$IOS_APP_USER_EMAIL" ]]; then
  echo "IOS_APP_USER_EMAIL is not set in config.env." >&2
  exit 1
fi

echo "=== parking-status iOS app Cognito setup ==="
echo "region=$AWS_REGION profile=$AWS_PROFILE"

ACCOUNT_ID="$(account_id)"
echo "account=$ACCOUNT_ID"

# --- User Pool ---
USER_POOL_ID="$(aws_cognito_idp list-user-pools --max-results 60 \
  --query "UserPools[?Name=='${COGNITO_USER_POOL_NAME}'].Id | [0]" --output text)"

if [[ -z "$USER_POOL_ID" || "$USER_POOL_ID" == "None" ]]; then
  echo "Creating Cognito User Pool: $COGNITO_USER_POOL_NAME"
  USER_POOL_ID="$(aws_cognito_idp create-user-pool \
    --pool-name "$COGNITO_USER_POOL_NAME" \
    --auto-verified-attributes email \
    --username-attributes email \
    --admin-create-user-config AllowAdminCreateUserOnly=true \
    --policies '{"PasswordPolicy":{"MinimumLength":12,"RequireUppercase":true,"RequireLowercase":true,"RequireNumbers":true,"RequireSymbols":false}}' \
    --query 'UserPool.Id' --output text)"
else
  echo "Cognito User Pool exists: $COGNITO_USER_POOL_NAME ($USER_POOL_ID)"
fi

# --- App Client (public/native, long-lived refresh token) ---
CLIENT_ID="$(aws_cognito_idp list-user-pool-clients --user-pool-id "$USER_POOL_ID" --max-results 60 \
  --query "UserPoolClients[?ClientName=='${COGNITO_CLIENT_NAME}'].ClientId | [0]" --output text)"

# USER_PASSWORD_AUTH is used instead of hand-rolled SRP math (no official
# lightweight Swift SRP client for Cognito). Password still travels over TLS
# only, and only ever once per sign-in — REFRESH_TOKEN_AUTH covers every
# renewal after that. Acceptable for a single-user PoC tool.
if [[ -z "$CLIENT_ID" || "$CLIENT_ID" == "None" ]]; then
  echo "Creating App Client: $COGNITO_CLIENT_NAME (refresh token validity 3650 days)"
  CLIENT_ID="$(aws_cognito_idp create-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-name "$COGNITO_CLIENT_NAME" \
    --no-generate-secret \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --refresh-token-validity 3650 \
    --access-token-validity 60 \
    --id-token-validity 60 \
    --token-validity-units 'RefreshToken=days,AccessToken=minutes,IdToken=minutes' \
    --prevent-user-existence-errors ENABLED \
    --query 'UserPoolClient.ClientId' --output text)"
else
  echo "App Client exists: $COGNITO_CLIENT_NAME ($CLIENT_ID) — updating auth flows"
  aws_cognito_idp update-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-id "$CLIENT_ID" \
    --client-name "$COGNITO_CLIENT_NAME" \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --refresh-token-validity 3650 \
    --access-token-validity 60 \
    --id-token-validity 60 \
    --token-validity-units 'RefreshToken=days,AccessToken=minutes,IdToken=minutes' \
    --prevent-user-existence-errors ENABLED >/dev/null
fi

# --- Developer user ---
if aws_cognito_idp admin-get-user --user-pool-id "$USER_POOL_ID" --username "$IOS_APP_USER_EMAIL" >/dev/null 2>&1; then
  echo "Cognito user exists: $IOS_APP_USER_EMAIL"
  USER_PASSWORD_SET=0
else
  echo "Creating Cognito user: $IOS_APP_USER_EMAIL"
  aws_cognito_idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "$IOS_APP_USER_EMAIL" \
    --user-attributes Name=email,Value="$IOS_APP_USER_EMAIL" Name=email_verified,Value=true \
    --message-action SUPPRESS >/dev/null

  GENERATED_PASSWORD="$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-20)Aa1!"
  aws_cognito_idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "$IOS_APP_USER_EMAIL" \
    --password "$GENERATED_PASSWORD" \
    --permanent >/dev/null
  USER_PASSWORD_SET=1
fi

# --- Identity Pool ---
IDENTITY_POOL_ID="$(aws_cognito_identity list-identity-pools --max-results 60 \
  --query "IdentityPools[?IdentityPoolName=='${COGNITO_IDENTITY_POOL_NAME}'].IdentityPoolId | [0]" --output text)"

PROVIDER_NAME="cognito-idp.${AWS_REGION}.amazonaws.com/${USER_POOL_ID}"

if [[ -z "$IDENTITY_POOL_ID" || "$IDENTITY_POOL_ID" == "None" ]]; then
  echo "Creating Identity Pool: $COGNITO_IDENTITY_POOL_NAME"
  IDENTITY_POOL_ID="$(aws_cognito_identity create-identity-pool \
    --identity-pool-name "$COGNITO_IDENTITY_POOL_NAME" \
    --no-allow-unauthenticated-identities \
    --cognito-identity-providers "ProviderName=${PROVIDER_NAME},ClientId=${CLIENT_ID},ServerSideTokenCheck=false" \
    --query 'IdentityPoolId' --output text)"
else
  echo "Identity Pool exists: $COGNITO_IDENTITY_POOL_NAME ($IDENTITY_POOL_ID)"
fi

# --- IAM role for authenticated identities (CloudWatch Logs read-only) ---
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TRUST_POLICY="$TMP_DIR/trust-policy.json"
sed "s|__IDENTITY_POOL_ID__|${IDENTITY_POOL_ID}|" \
  "$ROOT/cognito-authenticated-trust-policy.json.tmpl" >"$TRUST_POLICY"

LOGS_POLICY="$TMP_DIR/logs-policy.json"
sed -e "s|__REGION__|${AWS_REGION}|" \
    -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|" \
    -e "s|__LOG_GROUP_NAME__|${CLOUDWATCH_LOG_GROUP_NAME}|" \
  "$ROOT/cognito-logs-readonly-policy.json.tmpl" >"$LOGS_POLICY"

if aws_iam get-role --role-name "$COGNITO_AUTH_ROLE_NAME" >/dev/null 2>&1; then
  echo "IAM role exists: $COGNITO_AUTH_ROLE_NAME (updating trust + policy)"
  aws_iam update-assume-role-policy \
    --role-name "$COGNITO_AUTH_ROLE_NAME" \
    --policy-document "file://$TRUST_POLICY" >/dev/null
else
  echo "Creating IAM role: $COGNITO_AUTH_ROLE_NAME"
  aws_iam create-role \
    --role-name "$COGNITO_AUTH_ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_POLICY" \
    --description "Authenticated role for the parking-status iOS log-viewer app (CloudWatch Logs read-only, Issue #68)" >/dev/null
fi

ROLE_ARN="$(aws_iam get-role --role-name "$COGNITO_AUTH_ROLE_NAME" --query 'Role.Arn' --output text)"

aws_iam put-role-policy \
  --role-name "$COGNITO_AUTH_ROLE_NAME" \
  --policy-name "cloudwatch-logs-readonly" \
  --policy-document "file://$LOGS_POLICY" >/dev/null

# --- Attach role to Identity Pool ---
aws_cognito_identity set-identity-pool-roles \
  --identity-pool-id "$IDENTITY_POOL_ID" \
  --roles authenticated="$ROLE_ARN" >/dev/null

echo ""
echo "=== setup complete ==="
echo "User Pool ID    : $USER_POOL_ID"
echo "App Client ID   : $CLIENT_ID"
echo "Identity Pool ID: $IDENTITY_POOL_ID"
echo "IAM role ARN    : $ROLE_ARN"
echo "Log group       : $CLOUDWATCH_LOG_GROUP_NAME"
echo "Region          : $AWS_REGION"
echo "Login username  : $IOS_APP_USER_EMAIL"
if [[ "${USER_PASSWORD_SET:-0}" == "1" ]]; then
  echo ""
  echo "Temporary/permanent password (shown once, store in a password manager):"
  echo "  $GENERATED_PASSWORD"
fi
echo ""
echo "Next:"
echo "  ./verify-cognito.sh   # confirm resources"
