#!/usr/bin/env bash
# Shared helpers for infra scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"

# 設定ファイルは既定で infra/config.env。環境変数 CONFIG_FILE で切り替えられる
# （相対パスは infra/ からの相対）。旧アカウントと組織アカウントの設定を並べて持つときに使う:
#   CONFIG_FILE=config.org.env ./setup.sh
load_config() {
  local config_file="${CONFIG_FILE:-$ROOT/config.env}"
  [[ "$config_file" == /* ]] || config_file="$ROOT/$config_file"

  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  else
    echo "$config_file not found. Copy config.env.example to config.env first." >&2
    exit 1
  fi

  : "${AWS_REGION:=ap-northeast-1}"
  # AWS_PROFILE は既定を持たない。未設定なら環境変数のクレデンシャル（または CLI の既定）を使う。
  # config.env に書くか、実行時に `AWS_PROFILE=xxx ./verify.sh` のように渡す。
  : "${AWS_PROFILE:=}"
  # 実行先アカウントの ID。実際のアカウントと一致しなければ中断する（誤爆防止）。
  : "${EXPECTED_ACCOUNT_ID:=}"
  # IAM ロールを管理者が用意している場合の ARN（指定するとスクリプトはロールを作らない）。
  : "${LAMBDA_ROLE_ARN:=}"
  : "${COGNITO_AUTH_ROLE_ARN:=}"
  : "${LORAWAN_ROLE_ARN:=}"
  : "${IOT_POLICY_NAME:=parking-status-device}"
  : "${IOT_RULE_NAME:=parking_status_telemetry}"
  : "${IOT_LORAWAN_RULE_NAME:=parking_status_lorawan}"
  : "${LORAWAN_UPLINK_TOPIC:=lorawan/parking-status/uplink}"
  : "${LAMBDA_FUNCTION_NAME:=parking-status-bridge}"
  : "${LAMBDA_ROLE_NAME:=parking-status-bridge-lambda-role}"
  : "${MQTT_TOPIC_PREFIX:=parking-status}"
  # デバイスマスター（#7, #14）: deviceId → name / location。DynamoDB のテーブル名。
  : "${DEVICE_MASTER_TABLE:=parking-status-device-master}"
  # Orion 接続（#7）。ORION_URL が空なら Lambda は Orion に送らない（ログ出力のみ）。
  # 値は Lambda の環境変数に入る（deploy-bridge-stub.sh）。空の項目は設定しない。
  : "${ORION_URL:=}"
  : "${ORION_FIWARE_SERVICE:=}"
  : "${ORION_FIWARE_SERVICEPATH:=}"
  # Orion のトークンは有効期限があるので、Lambda が送るたびに Cognito でログインして取る（bridge/cognito_auth.py）。
  # 4 つ（USER_POOL_ID / CLIENT_ID / USERNAME / PASSWORD）そろえて設定する。すべて空なら認証ヘッダなしで送る。
  : "${ORION_COGNITO_USER_POOL_ID:=}"
  : "${ORION_COGNITO_CLIENT_ID:=}"
  : "${ORION_COGNITO_USERNAME:=}"
  : "${ORION_COGNITO_PASSWORD:=}"
  : "${ORION_COGNITO_CLIENT_SECRET:=}"
  : "${ORION_COGNITO_TOKEN_TYPE:=}"
  : "${USE_BASIC_INGEST:=1}"
  : "${COGNITO_USER_POOL_NAME:=parking-status-ios-app}"
  : "${COGNITO_CLIENT_NAME:=parking-status-ios-client}"
  : "${COGNITO_IDENTITY_POOL_NAME:=parking_status_ios_app}"
  : "${COGNITO_AUTH_ROLE_NAME:=parking-status-ios-app-authenticated}"
  : "${CLOUDWATCH_LOG_GROUP_NAME:=/aws/lambda/parking-status-bridge}"
  # Lambda のロググループの保持期間（日）。約 1 年。400 日は、iOS ログビューアのリセット時刻
  # クエリが過去 400 日分を見ることに合わせた値（CloudWatch Logs が受け付ける値のひとつ。
  # 365 なら 1 年ちょうど）。空にすると設定しない（無期限）。
  : "${LOG_RETENTION_DAYS=400}"
  : "${IOS_APP_USER_EMAIL:=}"

  # LoRaWAN (#40, #98)
  : "${LORAWAN_SERVICE_PROFILE_NAME:=parking-status}"
  : "${LORAWAN_DEVICE_PROFILE_NAME:=AS923-1-A-OTAA}"
  : "${LORAWAN_DESTINATION_NAME:=Saga_IoT_Core}"
  : "${LORAWAN_ROLE_NAME:=IoTWirelessGatewayCertManagerRole}"
  : "${LORAWAN_GATEWAY_NAME:=Saga Gateway}"
  : "${LORAWAN_GATEWAY_EUI:=}"
  : "${LORAWAN_GATEWAY_RF_REGION:=AS923-1}"
  : "${LORAWAN_GATEWAY_CERTS_DIR:=$ROOT/gateway-certs}"

  export AWS_REGION
  if [[ -n "$AWS_PROFILE" ]]; then
    export AWS_PROFILE
  else
    export -n AWS_PROFILE
  fi
}

# 表示用。AWS_PROFILE が空なら環境変数のクレデンシャルを使っている。
profile_label() {
  printf '%s' "${AWS_PROFILE:-(env credentials)}"
}

require_aws() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "aws CLI not found. Install AWS CLI v2 first." >&2
    exit 1
  fi
  assert_expected_account
}

# 実行先が意図したアカウントか確認する。EXPECTED_ACCOUNT_ID が未設定、または
# 実際のアカウントと違えば中断する（旧アカウントと組織アカウントの取り違え防止）。
assert_expected_account() {
  if [[ -z "$EXPECTED_ACCOUNT_ID" ]]; then
    echo "EXPECTED_ACCOUNT_ID is not set in config.env." >&2
    echo "Set it to the 12-digit ID of the AWS account this config targets." >&2
    exit 1
  fi
  local actual
  if ! actual="$(aws sts get-caller-identity --query Account --output text 2>&1)"; then
    echo "aws sts get-caller-identity failed (expired token / wrong profile?):" >&2
    echo "$actual" >&2
    exit 1
  fi
  if [[ "$actual" != "$EXPECTED_ACCOUNT_ID" ]]; then
    echo "Account mismatch: credentials are for $actual, but EXPECTED_ACCOUNT_ID=$EXPECTED_ACCOUNT_ID." >&2
    echo "Check AWS_PROFILE / environment credentials / CONFIG_FILE." >&2
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

# Lambda のロググループを（無ければ作って）保持期間を設定する。ロググループは Lambda の最初の
# 実行で自動的に作られるが、保持期間は無期限のまま。作っておけば、最初の実行より前に設定できる。
# 何度実行しても同じ結果になる。
ensure_log_retention() {
  if [[ -z "$LOG_RETENTION_DAYS" ]]; then
    echo "Log retention: not set (LOG_RETENTION_DAYS is empty)"
    return 0
  fi
  local group="$CLOUDWATCH_LOG_GROUP_NAME"
  if ! aws_logs describe-log-groups --log-group-name-prefix "$group" \
    --query "logGroups[?logGroupName=='${group}'].logGroupName" --output text | grep -q .; then
    echo "Creating log group: $group"
    aws_logs create-log-group --log-group-name "$group"
  fi
  aws_logs put-retention-policy --log-group-name "$group" --retention-in-days "$LOG_RETENTION_DAYS"
  echo "Log retention: $group = ${LOG_RETENTION_DAYS} days"
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

aws_iotwireless() {
  aws iotwireless "$@"
}

aws_dynamodb() {
  aws dynamodb "$@"
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
