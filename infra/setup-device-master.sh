#!/usr/bin/env bash
# デバイスマスターの DynamoDB テーブルを作る（#7, #14）。何度実行しても同じ結果になる。
#
# キャパシティはプロビジョンド 1 RCU / 1 WCU。DynamoDB の無料枠（25 RCU / 25 WCU、
# ストレージ 25 GB。期限なし）に収まる。Lambda は結果をコンテナ内で数分キャッシュするので、
# PoC 規模（数台）なら読み取りはこれで足りる。台数が増えたら容量を上げる。
# 中身の登録・編集は ./device-master.sh。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

echo "=== device master table: $DEVICE_MASTER_TABLE ==="

if aws_dynamodb describe-table --table-name "$DEVICE_MASTER_TABLE" >/dev/null 2>&1; then
  echo "Table exists: $DEVICE_MASTER_TABLE"
  exit 0
fi

echo "Creating DynamoDB table: $DEVICE_MASTER_TABLE"
aws_dynamodb create-table \
  --table-name "$DEVICE_MASTER_TABLE" \
  --attribute-definitions AttributeName=deviceId,AttributeType=S \
  --key-schema AttributeName=deviceId,KeyType=HASH \
  --billing-mode PROVISIONED \
  --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 \
  >/dev/null
aws_dynamodb wait table-exists --table-name "$DEVICE_MASTER_TABLE"
echo "Table is active."
echo ""
echo "Next: ./device-master.sh put <deviceId> <name> <lat> <lon>"
