#!/usr/bin/env bash
# Deploy (or update) the parking-status-bridge Lambda stub.
# Re-runnable: role, role policy, and function are created or updated in place.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

BRIDGE_DIR="$REPO_ROOT/bridge"
ZIP="$BRIDGE_DIR/dist/handler.zip"
ROLE_NAME="$LAMBDA_ROLE_NAME"
# LoRaWAN (#83): コールドスタートで boto3 の import と GetWirelessDevice が走り、
# 128MB / 10s だと約 5.6s かかったため、余裕を持たせる。
LAMBDA_TIMEOUT=30
LAMBDA_MEMORY=256
# handler.py が import するモジュールはすべてここに並べる（zip はこれだけを含む）。
BRIDGE_MODULES=(handler.py lorawan.py)

mkdir -p "$BRIDGE_DIR/dist"
rm -f "$ZIP"
(cd "$BRIDGE_DIR" && zip -q -j dist/handler.zip "${BRIDGE_MODULES[@]}")

ACCOUNT_ID="$(account_id)"
LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_FUNCTION_NAME}"

# --- Execution role ---
# LAMBDA_ROLE_ARN が指定されていれば管理者が用意したロールをそのまま使う
# （Power User 権限では IAM ロールを作れず、PassRole も要る。#98）。
# その場合のロールの中身は docs/aws-admin-handoff.md の定義に従っていること。
ROLE_CREATED=0
if [[ -n "$LAMBDA_ROLE_ARN" ]]; then
  echo "Using existing IAM role (not managed by this script): $LAMBDA_ROLE_ARN"
  ROLE_ARN="$LAMBDA_ROLE_ARN"
else
  if aws_iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    ROLE_ARN="$(aws_iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
  else
    echo "Creating IAM role: $ROLE_NAME"
    TRUST_POLICY="$(mktemp)"
    cat >"$TRUST_POLICY" <<'POLICY'
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
POLICY
    ROLE_ARN="$(aws_iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "file://$TRUST_POLICY" \
      --query Role.Arn --output text)"
    rm -f "$TRUST_POLICY"
    aws_iam attach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    ROLE_CREATED=1
  fi

  # LoRaWAN (#40): Wireless Device ID → 名前（= deviceId）の引き当てだけを許可する。
  # put-role-policy は同名なら上書きなので、何度実行しても同じ結果になる。
  IOTWIRELESS_POLICY="$(mktemp)"
  trap 'rm -f "$IOTWIRELESS_POLICY"' EXIT
  cat >"$IOTWIRELESS_POLICY" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iotwireless:GetWirelessDevice",
      "Resource": "arn:aws:iotwireless:${AWS_REGION}:${ACCOUNT_ID}:WirelessDevice/*"
    }
  ]
}
POLICY
  aws_iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name parking-status-bridge-iotwireless-read \
    --policy-document "file://$IOTWIRELESS_POLICY"

  if [[ "$ROLE_CREATED" == "1" ]]; then
    echo "Waiting for IAM role propagation..."
    sleep 10
  fi
fi

# --- Lambda function ---
if aws_lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" >/dev/null 2>&1; then
  echo "Updating Lambda: $LAMBDA_FUNCTION_NAME"
  aws_lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --zip-file "fileb://$ZIP" >/dev/null
  aws_lambda wait function-updated --function-name "$LAMBDA_FUNCTION_NAME"
  aws_lambda update-function-configuration \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --timeout "$LAMBDA_TIMEOUT" \
    --memory-size "$LAMBDA_MEMORY" >/dev/null
  exit 0
fi

echo "Creating Lambda: $LAMBDA_FUNCTION_NAME"
aws_lambda create-function \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --runtime python3.12 \
  --role "$ROLE_ARN" \
  --handler handler.handler \
  --zip-file "fileb://$ZIP" \
  --timeout "$LAMBDA_TIMEOUT" \
  --memory-size "$LAMBDA_MEMORY" \
  --description "Parking status bridge stub (Issue #4). Replaced by #7 implementation." \
  >/dev/null

echo "Lambda ARN: $LAMBDA_ARN"
