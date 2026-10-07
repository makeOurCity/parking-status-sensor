#!/usr/bin/env bash
# Verify IoT Core + Lambda stub setup (post setup.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

DEVICE_ID="${1:-xiao-test-device}"
ACCOUNT_ID="$(account_id)"
ENDPOINT="$(iot_endpoint)"
LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_FUNCTION_NAME}"

echo "=== verify parking-status IoT Core setup ==="
echo "region=$AWS_REGION profile=$(profile_label) account=$ACCOUNT_ID"
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

check "IoT policy: $IOT_POLICY_NAME" \
  aws_iot get-policy --policy-name "$IOT_POLICY_NAME"
check "IoT rule: $IOT_RULE_NAME" \
  aws_iot get-topic-rule --rule-name "$IOT_RULE_NAME"
check "IoT rule: $IOT_LORAWAN_RULE_NAME" \
  aws_iot get-topic-rule --rule-name "$IOT_LORAWAN_RULE_NAME"
check "Lambda: $LAMBDA_FUNCTION_NAME" \
  aws_lambda get-function --function-name "$LAMBDA_FUNCTION_NAME"
check "Lambda invoke permission for IoT rule" \
  aws_lambda get-policy --function-name "$LAMBDA_FUNCTION_NAME"
check "Lambda role can read Wireless Devices (LoRaWAN)" \
  aws_iam get-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name parking-status-bridge-iotwireless-read
check "Device master table: $DEVICE_MASTER_TABLE" \
  aws_dynamodb describe-table --table-name "$DEVICE_MASTER_TABLE"
check "Lambda role can read the device master (dynamodb:GetItem)" \
  aws_iam get-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name parking-status-bridge-device-master-read

# Lambda の環境変数（トークンの値は表示しない）
ORION_ENV="$(aws_lambda get-function-configuration --function-name "$LAMBDA_FUNCTION_NAME" \
  --query 'Environment.Variables' --output json 2>/dev/null || echo null)"
if [[ "$(jq -r '.ORION_URL // empty' <<<"$ORION_ENV")" != "" ]]; then
  echo "  OK  Orion upsert enabled: $(jq -r '.ORION_URL' <<<"$ORION_ENV") (auth: $(jq -r 'if .ORION_COGNITO_CLIENT_ID then "cognito SRP user=" + (.ORION_COGNITO_USERNAME // "?") else "none" end' <<<"$ORION_ENV"))"
else
  echo "  --  Orion upsert disabled (ORION_URL is not set on the Lambda)"
fi

# CloudWatch Logs の保持期間（LOG_RETENTION_DAYS が空なら確認しない）
if [[ -n "$LOG_RETENTION_DAYS" ]]; then
  RETENTION="$(aws_logs describe-log-groups --log-group-name-prefix "$CLOUDWATCH_LOG_GROUP_NAME" \
    --query "logGroups[?logGroupName=='${CLOUDWATCH_LOG_GROUP_NAME}'].retentionInDays | [0]" --output text 2>/dev/null || true)"
  if [[ "$RETENTION" == "$LOG_RETENTION_DAYS" ]]; then
    echo "  OK  CloudWatch Logs retention: ${RETENTION} days"
  else
    echo "  NG  CloudWatch Logs retention: expected ${LOG_RETENTION_DAYS} days (current: ${RETENTION:-no log group}; None = unlimited)"
    fail=1
  fi
fi

echo ""
echo "MQTT endpoint: $ENDPOINT"
echo "Lambda ARN   : $LAMBDA_ARN"
echo ""
echo "Connectivity test:"
echo "  ./test-publish.sh $DEVICE_ID"
echo "  aws logs tail /aws/lambda/${LAMBDA_FUNCTION_NAME} --follow --region ${AWS_REGION}"

if [[ "$fail" -ne 0 ]]; then
  echo ""
  echo "Some checks failed. Run ./setup.sh first." >&2
  exit 1
fi

echo ""
echo "All checks passed."
