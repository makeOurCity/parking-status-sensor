#!/usr/bin/env bash
# Deploy (or update) the parking-status-bridge Lambda (Issue #4 stub → #7 Orion upsert).
# Re-runnable: role, role policies, function code and environment are created or updated in place.
# Lambda の環境変数は config.env（DEVICE_MASTER_TABLE / ORION_*）から作り直す。空の項目は設定しない。
#
# Cognito のパスワード（ORION_COGNITO_PASSWORD）はファイルに書かない運用ができる:
#   - config.env に書いていなければ、Lambda に設定済みの値を引き継ぐ（USER_POOL_ID・CLIENT_ID・USERNAME が同じとき）
#   - 引き継げなければ（初回・ユーザー変更時）、端末から入力を求める（入力は画面に出ない）
#   - `--ask-password` を付けると、設定済みでも入力し直す（パスワードを変えるとき）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

ASK_PASSWORD=0
case "${1:-}" in
  "") ;;
  --ask-password) ASK_PASSWORD=1 ;;
  *) echo "Usage: $0 [--ask-password]" >&2; exit 1 ;;
esac

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
BRIDGE_MODULES=(handler.py lorawan.py ngsi.py orion.py cognito_auth.py device_master.py)

mkdir -p "$BRIDGE_DIR/dist"
rm -f "$ZIP"
(cd "$BRIDGE_DIR" && zip -q -j dist/handler.zip "${BRIDGE_MODULES[@]}")

ACCOUNT_ID="$(account_id)"
LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${LAMBDA_FUNCTION_NAME}"

# --- Cognito password (#7) ---
# 現在の Lambda の環境変数を 1 項目だけ読む（無ければ空）。パスワードを変数や一時ファイルに広げない。
current_lambda_var() {
  aws_lambda get-function-configuration --function-name "$LAMBDA_FUNCTION_NAME" \
    --query "Environment.Variables.$1" --output text 2>/dev/null | grep -vx 'None' || true
}

if [[ -n "$ORION_COGNITO_USER_POOL_ID" && -n "$ORION_COGNITO_CLIENT_ID" && -n "$ORION_COGNITO_USERNAME" && -z "$ORION_COGNITO_PASSWORD" ]]; then
  if [[ "$ASK_PASSWORD" == "0" \
    && "$(current_lambda_var ORION_COGNITO_USER_POOL_ID)" == "$ORION_COGNITO_USER_POOL_ID" \
    && "$(current_lambda_var ORION_COGNITO_CLIENT_ID)" == "$ORION_COGNITO_CLIENT_ID" \
    && "$(current_lambda_var ORION_COGNITO_USERNAME)" == "$ORION_COGNITO_USERNAME" ]]; then
    ORION_COGNITO_PASSWORD="$(current_lambda_var ORION_COGNITO_PASSWORD)"
    [[ -n "$ORION_COGNITO_PASSWORD" ]] && echo "Cognito password: kept from the current Lambda configuration (use --ask-password to change)"
  fi
  if [[ -z "$ORION_COGNITO_PASSWORD" ]]; then
    if [[ ! -t 0 ]]; then
      echo "ORION_COGNITO_PASSWORD is not set and there is no terminal to ask for it." >&2
      echo "Run this script in a terminal, or export ORION_COGNITO_PASSWORD for this run." >&2
      exit 1
    fi
    read -r -s -p "Cognito password for ${ORION_COGNITO_USERNAME}: " ORION_COGNITO_PASSWORD
    echo
    [[ -n "$ORION_COGNITO_PASSWORD" ]] || { echo "Empty password." >&2; exit 1; }
  fi
fi

# --- Lambda environment (#7) ---
# パスワードを含むので、一時ファイルは本人だけが読める（mktemp は 0600）うえ、終了時に消す。
ENV_FILE="$(mktemp)"
IOTWIRELESS_POLICY=""
DEVICE_MASTER_POLICY=""
trap 'rm -f "$ENV_FILE" "$IOTWIRELESS_POLICY" "$DEVICE_MASTER_POLICY"' EXIT
jq -n \
  --arg table "$DEVICE_MASTER_TABLE" \
  --arg url "$ORION_URL" \
  --arg service "$ORION_FIWARE_SERVICE" \
  --arg path "$ORION_FIWARE_SERVICEPATH" \
  --arg cognito_pool_id "$ORION_COGNITO_USER_POOL_ID" \
  --arg cognito_client_id "$ORION_COGNITO_CLIENT_ID" \
  --arg cognito_username "$ORION_COGNITO_USERNAME" \
  --arg cognito_password "$ORION_COGNITO_PASSWORD" \
  --arg cognito_client_secret "$ORION_COGNITO_CLIENT_SECRET" \
  --arg cognito_token_type "$ORION_COGNITO_TOKEN_TYPE" \
  '{DEVICE_MASTER_TABLE: $table, ORION_URL: $url, ORION_FIWARE_SERVICE: $service,
    ORION_FIWARE_SERVICEPATH: $path,
    ORION_COGNITO_USER_POOL_ID: $cognito_pool_id, ORION_COGNITO_CLIENT_ID: $cognito_client_id,
    ORION_COGNITO_USERNAME: $cognito_username, ORION_COGNITO_PASSWORD: $cognito_password,
    ORION_COGNITO_CLIENT_SECRET: $cognito_client_secret, ORION_COGNITO_TOKEN_TYPE: $cognito_token_type}
   | with_entries(select(.value != "")) | {Variables: .}' >"$ENV_FILE"
if [[ -n "$ORION_COGNITO_USER_POOL_ID$ORION_COGNITO_CLIENT_ID$ORION_COGNITO_USERNAME$ORION_COGNITO_PASSWORD" ]] \
  && [[ -z "$ORION_COGNITO_USER_POOL_ID" || -z "$ORION_COGNITO_CLIENT_ID" || -z "$ORION_COGNITO_USERNAME" || -z "$ORION_COGNITO_PASSWORD" ]]; then
  echo "ORION_COGNITO_USER_POOL_ID / _CLIENT_ID / _USERNAME / _PASSWORD must be set together." >&2
  exit 1
fi
AUTH_LABEL="none"
[[ -n "$ORION_COGNITO_CLIENT_ID" ]] && AUTH_LABEL="cognito SRP (pool=${ORION_COGNITO_USER_POOL_ID}, user=${ORION_COGNITO_USERNAME}, password=set)"
if [[ -n "$ORION_URL" ]]; then
  echo "Orion upsert: enabled ($ORION_URL, service='${ORION_FIWARE_SERVICE}', path='${ORION_FIWARE_SERVICEPATH}', auth=${AUTH_LABEL})"
else
  echo "Orion upsert: disabled (ORION_URL is empty — logs only)"
fi

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

  # デバイスマスター（#7）: テーブルの GetItem だけを許可する（読み取りのみ。編集は開発者が CLI で行う）。
  DEVICE_MASTER_POLICY="$(mktemp)"
  cat >"$DEVICE_MASTER_POLICY" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "dynamodb:GetItem",
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${DEVICE_MASTER_TABLE}"
    }
  ]
}
POLICY
  aws_iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name parking-status-bridge-device-master-read \
    --policy-document "file://$DEVICE_MASTER_POLICY"

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
    --memory-size "$LAMBDA_MEMORY" \
    --environment "file://$ENV_FILE" >/dev/null
  aws_lambda wait function-updated --function-name "$LAMBDA_FUNCTION_NAME"
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
  --environment "file://$ENV_FILE" \
  --description "Parking status bridge: telemetry log + Orion upsert (Issue #4, #7)" \
  >/dev/null

echo "Lambda ARN: $LAMBDA_ARN"
