#!/usr/bin/env bash
# Create shared IoT policy, deploy Lambda stub, and create IoT rule.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

echo "=== parking-status IoT Core setup ==="
echo "region=$AWS_REGION profile=$AWS_PROFILE"

ACCOUNT_ID="$(account_id)"
ENDPOINT="$(iot_endpoint)"
echo "account=$ACCOUNT_ID endpoint=$ENDPOINT"

# --- IoT policy ---
POLICY_DOC="$ROOT/iot-policy.json"
if aws_iot get-policy --policy-name "$IOT_POLICY_NAME" >/dev/null 2>&1; then
  echo "IoT policy exists: $IOT_POLICY_NAME (updating)"
  POLICY_VERSION="$(aws_iot create-policy-version \
    --policy-name "$IOT_POLICY_NAME" \
    --policy-document "file://$POLICY_DOC" \
    --set-as-default \
    --query policyVersionArn --output text)"
  echo "  updated: $POLICY_VERSION"
else
  echo "Creating IoT policy: $IOT_POLICY_NAME"
  aws_iot create-policy \
    --policy-name "$IOT_POLICY_NAME" \
    --policy-document "file://$POLICY_DOC" >/dev/null
fi

# --- Lambda stub ---
echo "Deploying Lambda stub: $LAMBDA_FUNCTION_NAME"
"$ROOT/deploy-bridge-stub.sh"

LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_FUNCTION_NAME}"

# Allow IoT rule to invoke Lambda
STATEMENT_ID="iot-rule-${IOT_RULE_NAME}"
if aws_lambda get-policy --function-name "$LAMBDA_FUNCTION_NAME" 2>/dev/null \
  | grep -q "$STATEMENT_ID"; then
  echo "Lambda permission already exists: $STATEMENT_ID"
else
  echo "Adding Lambda invoke permission for IoT rule"
  aws_lambda add-permission \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --statement-id "$STATEMENT_ID" \
    --action lambda:InvokeFunction \
    --principal iot.amazonaws.com \
    --source-arn "arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:rule/${IOT_RULE_NAME}" \
    >/dev/null
fi

# --- IoT rule ---
SQL="$(rule_sql)"
RULE_PAYLOAD="$(mktemp)"
trap 'rm -f "$RULE_PAYLOAD"' EXIT

jq -n \
  --arg sql "$SQL" \
  --arg arn "$LAMBDA_ARN" \
  '{
    sql: $sql,
    actions: [{lambda: {functionArn: $arn}}],
    ruleDisabled: false,
    awsIotSqlVersion: "2016-03-23"
  }' >"$RULE_PAYLOAD"

if aws_iot get-topic-rule --rule-name "$IOT_RULE_NAME" >/dev/null 2>&1; then
  echo "Updating IoT rule: $IOT_RULE_NAME"
  aws_iot replace-topic-rule \
    --rule-name "$IOT_RULE_NAME" \
    --topic-rule-payload "file://$RULE_PAYLOAD" >/dev/null
else
  echo "Creating IoT rule: $IOT_RULE_NAME"
  aws_iot create-topic-rule \
    --rule-name "$IOT_RULE_NAME" \
    --topic-rule-payload "file://$RULE_PAYLOAD" >/dev/null
fi

echo ""
echo "=== setup complete ==="
echo "MQTT endpoint : $ENDPOINT"
echo "IoT rule SQL  : $SQL"
echo ""
echo "Next:"
echo "  ./provision-device.sh <deviceId>   # register a Thing + certs"
echo "  ./test-publish.sh <deviceId>       # CLI connectivity test"
