#!/usr/bin/env bash
# Shared helpers for infra scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

load_config() {
  if [[ -f "$ROOT/config.env" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/config.env"
  else
    echo "config.env not found. Copy config.env.example to config.env first." >&2
    exit 1
  fi

  : "${AWS_REGION:=ap-northeast-1}"
  : "${AWS_PROFILE:=default}"
  : "${IOT_POLICY_NAME:=parking-status-device}"
  : "${IOT_RULE_NAME:=parking_status_telemetry}"
  : "${IOT_LORAWAN_RULE_NAME:=parking_status_lorawan}"
  : "${LORAWAN_UPLINK_TOPIC:=lorawan/parking-status/uplink}"
  : "${LAMBDA_FUNCTION_NAME:=parking-status-bridge}"
  : "${LAMBDA_ROLE_NAME:=parking-status-bridge-lambda-role}"
  : "${MQTT_TOPIC_PREFIX:=parking-status}"
  : "${USE_BASIC_INGEST:=1}"
  : "${COGNITO_USER_POOL_NAME:=parking-status-ios-app}"
  : "${COGNITO_CLIENT_NAME:=parking-status-ios-client}"
  : "${COGNITO_IDENTITY_POOL_NAME:=parking_status_ios_app}"
  : "${COGNITO_AUTH_ROLE_NAME:=parking-status-ios-app-authenticated}"
  : "${CLOUDWATCH_LOG_GROUP_NAME:=/aws/lambda/parking-status-bridge}"
  : "${IOS_APP_USER_EMAIL:=}"

  export AWS_REGION AWS_PROFILE
}

require_aws() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "aws CLI not found. Install AWS CLI v2 first." >&2
    exit 1
  fi
}

aws_iot() {
  aws iot "$@"
}

aws_lambda() {
  aws lambda "$@"
}

aws_logs() {
  aws logs "$@"
}

aws_cognito_idp() {
  aws cognito-idp "$@"
}

aws_cognito_identity() {
  aws cognito-identity "$@"
}

aws_iam() {
  aws iam "$@"
}

iot_endpoint() {
  aws_iot describe-endpoint --endpoint-type iot:Data-ATS \
    --query endpointAddress --output text
}

account_id() {
  aws sts get-caller-identity --query Account --output text
}

device_telemetry_topic() {
  local device_id="$1"
  if [[ "$USE_BASIC_INGEST" == "1" ]]; then
    printf '$aws/rules/%s/%s/%s/telemetry' \
      "$IOT_RULE_NAME" "$MQTT_TOPIC_PREFIX" "$device_id"
  else
    printf '%s/%s/telemetry' "$MQTT_TOPIC_PREFIX" "$device_id"
  fi
}

rule_sql() {
  if [[ "$USE_BASIC_INGEST" == "1" ]]; then
    printf "SELECT * FROM '\$aws/rules/%s/%s/+/telemetry'" \
      "$IOT_RULE_NAME" "$MQTT_TOPIC_PREFIX"
  else
    printf "SELECT * FROM '%s/+/telemetry'" "$MQTT_TOPIC_PREFIX"
  fi
}

# LoRaWAN (#40): AWS IoT Core for LoRaWAN の Destination が publish するトピックを読む。
lorawan_rule_sql() {
  printf "SELECT * FROM '%s'" "$LORAWAN_UPLINK_TOPIC"
}
