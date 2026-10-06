#!/usr/bin/env bash
# LoRaWAN のリソース（setup-lorawan.sh の結果）を確認する。読み取り系の呼び出しのみ
# （ReadOnly 権限のプロファイルで実行できる）。
#
# Usage:
#   ./verify-lorawan.sh [deviceId ...]   # 指定した deviceId の Wireless Device も確認する
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

echo "=== verify parking-status LoRaWAN setup ==="
echo "region=$AWS_REGION profile=$(profile_label) account=$(account_id)"
echo ""

fail=0
ok() { echo "  OK  $1"; }
ng() {
  echo "  NG  $1"
  fail=1
}

# `aws ... --query X --output text` の結果が空 / None でなければ OK。
check_found() {
  local label="$1" value="$2"
  if [[ -n "$value" && "$value" != "None" ]]; then
    ok "$label"
  else
    ng "$label (not found)"
  fi
}

check_found "Service Profile: $LORAWAN_SERVICE_PROFILE_NAME" \
  "$(aws_iotwireless list-service-profiles \
    --query "ServiceProfileList[?Name=='${LORAWAN_SERVICE_PROFILE_NAME}'].Id | [0]" --output text)"
check_found "Device Profile: $LORAWAN_DEVICE_PROFILE_NAME" \
  "$(aws_iotwireless list-device-profiles \
    --query "DeviceProfileList[?Name=='${LORAWAN_DEVICE_PROFILE_NAME}'].Id | [0]" --output text)"

if dest_json="$(aws_iotwireless get-destination --name "$LORAWAN_DESTINATION_NAME" 2>/dev/null)"; then
  ok "Destination: $LORAWAN_DESTINATION_NAME"
  expr="$(jq -r '.Expression' <<<"$dest_json")"
  if [[ "$expr" == "$LORAWAN_UPLINK_TOPIC" ]]; then
    ok "Destination topic: $expr"
  else
    ng "Destination topic: $expr (expected $LORAWAN_UPLINK_TOPIC)"
  fi
  echo "      role: $(jq -r '.RoleArn' <<<"$dest_json")"
else
  ng "Destination: $LORAWAN_DESTINATION_NAME (not found)"
fi

if [[ -n "$LORAWAN_GATEWAY_EUI" ]]; then
  gw_id="$(aws_iotwireless get-wireless-gateway \
    --identifier "$LORAWAN_GATEWAY_EUI" --identifier-type GatewayEui \
    --query Id --output text 2>/dev/null || true)"
  if [[ -n "$gw_id" && "$gw_id" != "None" ]]; then
    ok "Gateway: $LORAWAN_GATEWAY_NAME (EUI=$LORAWAN_GATEWAY_EUI)"
    check_found "Gateway certificate associated" \
      "$(aws_iotwireless get-wireless-gateway-certificate --id "$gw_id" \
        --query IotCertificateId --output text 2>/dev/null || true)"
    # 接続状態は M2 の設定を変えた直後は Disconnected のままのことがあるため、失敗扱いにしない。
    echo "      connection: $(aws_iotwireless get-wireless-gateway-statistics \
      --wireless-gateway-id "$gw_id" \
      --query '[ConnectionStatus, LastUplinkReceivedAt]' --output text 2>/dev/null || echo unknown)"
  else
    ng "Gateway: EUI=$LORAWAN_GATEWAY_EUI (not found)"
  fi
else
  echo "  --  Gateway: LORAWAN_GATEWAY_EUI is not set (skipped)"
fi

for device_id in "$@"; do
  check_found "Wireless Device: $device_id" \
    "$(aws_iotwireless list-wireless-devices \
      --query "WirelessDeviceList[?Name=='${device_id}'].Id | [0]" --output text)"
done

echo ""
if [[ "$fail" -ne 0 ]]; then
  echo "Some checks failed. Run ./setup-lorawan.sh first." >&2
  exit 1
fi
echo "All checks passed."
