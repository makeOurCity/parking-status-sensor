#!/usr/bin/env bash
# Deploy (or update) the parking-status-bridge Lambda stub.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

BRIDGE_DIR="$REPO_ROOT/bridge"
ZIP="$BRIDGE_DIR/dist/handler.zip"
ROLE_NAME="parking-status-bridge-lambda-role"

mkdir -p "$BRIDGE_DIR/dist"
(cd "$BRIDGE_DIR" && zip -q -j dist/handler.zip handler.py)

ACCOUNT_ID="$(account_id)"
LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_FUNCTION_NAME}"

if aws_lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" >/dev/null 2>&1; then
  echo "Updating Lambda: $LAMBDA_FUNCTION_NAME"
  aws_lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --zip-file "fileb://$ZIP" >/dev/null
  exit 0
fi

# Create execution role if needed
TRUST_POLICY="$(mktemp)"
cat >"$TRUST_POLICY" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

ROLE_ARN=""
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
else
  echo "Creating IAM role: $ROLE_NAME"
  ROLE_ARN="$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_POLICY" \
    --query Role.Arn --output text)"
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "Waiting for IAM role propagation..."
  sleep 10
fi
rm -f "$TRUST_POLICY"

echo "Creating Lambda: $LAMBDA_FUNCTION_NAME"
aws_lambda create-function \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --runtime python3.12 \
  --role "$ROLE_ARN" \
  --handler handler.handler \
  --zip-file "fileb://$ZIP" \
  --timeout 10 \
  --memory-size 128 \
  --description "Parking status bridge stub (Issue #4). Replaced by #7 implementation." \
  >/dev/null

echo "Lambda ARN: $LAMBDA_ARN"
