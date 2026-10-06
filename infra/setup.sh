#!/usr/bin/env bash
# Create shared IoT policy, device master table, deploy Lambda, and create IoT rules.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

echo "=== parking-status IoT Core setup ==="
echo "region=$AWS_REGION profile=$(profile_label)"

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

# --- Device master table (#7) ---
"$ROOT/setup-device-master.sh"

# --- Lambda ---
echo "Deploying Lambda: $LAMBDA_FUNCTION_NAME"
"$ROOT/deploy-bridge-stub.sh"

LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_FUNCTION_NAME}"

# Allow an IoT rule to invoke the Lambda (idempotent: skipped if the statement exists).
allow_rule_to_invoke_lambda() {
  local rule_name="$1"
  local statement_id="iot-rule-${rule_name}"
  if aws_lambda get-policy --function-name "$LAMBDA_FUNCTION_NAME" 2>/dev/null \
    | grep -qF "$statement_id"; then
    echo "Lambda permission already exists: $statement_id"
  else
    echo "Adding Lambda invoke permission for IoT rule: $rule_name"
    aws_lambda add-permission \
      --function-name "$LAMBDA_FUNCTION_NAME" \
      --statement-id "$statement_id" \
      --action lambda:InvokeFunction \
      --principal iot.amazonaws.com \
      --source-arn "arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:rule/${rule_name}" \
      >/dev/null
  fi
}

# Create or replace an IoT rule that forwards to the Lambda.
upsert_lambda_rule() {
  local rule_name="$1"
  local sql="$2"
  local payload
  payload="$(mktemp)"

  jq -n \
    --arg sql "$sql" \
    --arg arn "$LAMBDA_ARN" \
    '{
      sql: $sql,
      actions: [{lambda: {functionArn: $arn}}],
      ruleDisabled: false,
      awsIotSqlVersion: "2016-03-23"
    }' >"$payload"

  if aws_iot get-topic-rule --rule-name "$rule_name" >/dev/null 2>&1; then
    echo "Updating IoT rule: $rule_name"
    aws_iot replace-topic-rule \
      --rule-name "$rule_name" \
      --topic-rule-payload "file://$payload" >/dev/null
  else
    echo "Creating IoT rule: $rule_name"
    aws_iot create-topic-rule \
      --rule-name "$rule_name" \
      --topic-rule-payload "file://$payload" >/dev/null
  fi
  rm -f "$payload"
}

# --- IoT rules (device telemetry + LoRaWAN uplink) ---
SQL="$(rule_sql)"
LORAWAN_SQL="$(lorawan_rule_sql)"

allow_rule_to_invoke_lambda "$IOT_RULE_NAME"
allow_rule_to_invoke_lambda "$IOT_LORAWAN_RULE_NAME"
upsert_lambda_rule "$IOT_RULE_NAME" "$SQL"
upsert_lambda_rule "$IOT_LORAWAN_RULE_NAME" "$LORAWAN_SQL"

echo ""
echo "=== setup complete ==="
echo "MQTT endpoint : $ENDPOINT"
echo "IoT rule SQL  : $SQL"
echo "LoRaWAN rule  : $LORAWAN_SQL"
echo ""
echo "Next:"
echo "  ./provision-device.sh <deviceId>   # register a Thing + certs"
echo "  ./test-publish.sh <deviceId>       # CLI connectivity test"
