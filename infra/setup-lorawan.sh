#!/usr/bin/env bash
# AWS IoT Core for LoRaWAN のリソース（Device Profile / Service Profile / Destination /
# ゲートウェイ / Wireless Device）を作る（#40, #98）。何度実行しても同じ結果になる。
#
# Usage:
#   ./setup-lorawan.sh role                  # Destination とゲートウェイ（CUPS）が使う IAM ロール（IAM 権限が要る）
#   ./setup-lorawan.sh profiles [--no-destination]  # Service Profile / Device Profile / Destination
#   ./setup-lorawan.sh gateway [--rotate]    # ゲートウェイ登録 + CUPS 証明書の発行と関連付け
#   ./setup-lorawan.sh device <deviceId>     # Wireless Device（端末 1 台分）を登録
#
# 前提:
# - `profiles --no-destination` は Destination（IAM ロールが要る）を作らない。ロールの用意を
#   待つ間に、ロール不要の Service Profile / Device Profile だけ先に作るときに使う
# - Destination は IAM ロール（既定 IoTWirelessGatewayCertManagerRole、`LORAWAN_ROLE_ARN` で上書き）
#   を使う。`role` で作れる（IAM のロール作成と PassRole が要る権限で実行する）。Power User 権限では
#   作れないので、その場合は管理者に作ってもらう（docs/aws-admin-handoff.md）
# - ゲートウェイ EUI は他の AWS アカウントで再利用できない。別アカウントに登録済みなら、
#   先にそちらで削除する（docs/aws-admin-handoff.md の切替手順を参照）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

usage() {
  sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

load_config
require_aws

ACCOUNT_ID="$(account_id)"
if [[ -z "$LORAWAN_ROLE_ARN" ]]; then
  LORAWAN_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/service-role/${LORAWAN_ROLE_NAME}"
fi

# 名前から ID を引く。見つからなければ空文字を返す。
service_profile_id() {
  local id
  id="$(aws_iotwireless list-service-profiles \
    --query "ServiceProfileList[?Name=='${LORAWAN_SERVICE_PROFILE_NAME}'].Id | [0]" --output text)"
  [[ "$id" == "None" ]] && id=""
  printf '%s' "$id"
}

device_profile_id() {
  local id
  id="$(aws_iotwireless list-device-profiles \
    --query "DeviceProfileList[?Name=='${LORAWAN_DEVICE_PROFILE_NAME}'].Id | [0]" --output text)"
  [[ "$id" == "None" ]] && id=""
  printf '%s' "$id"
}

# Destination とゲートウェイ（CUPS）が使う IAM ロール。AWS コンソールが自動で作るものと同じ
# 名前・パス（/service-role/）で、docs/aws-admin-handoff.md の定義どおりに作る。
cmd_role() {
  echo "=== LoRaWAN IAM role: $LORAWAN_ROLE_NAME ==="
  echo "region=$AWS_REGION profile=$(profile_label) account=$ACCOUNT_ID"

  local trust policy created=0
  ROLE_TMP="$(mktemp -d)"
  trap 'rm -rf "$ROLE_TMP"' EXIT
  trust="$ROLE_TMP/trust.json"
  policy="$ROLE_TMP/destination-policy.json"

  cat >"$trust" <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "iotwireless.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
  cat >"$policy" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iot:Publish",
      "Resource": "arn:aws:iot:${AWS_REGION}:${ACCOUNT_ID}:topic/${LORAWAN_UPLINK_TOPIC}"
    },
    {
      "Effect": "Allow",
      "Action": "iot:DescribeEndpoint",
      "Resource": "*"
    }
  ]
}
POLICY

  if aws_iam get-role --role-name "$LORAWAN_ROLE_NAME" >/dev/null 2>&1; then
    echo "IAM role exists: $LORAWAN_ROLE_NAME (updating trust + policies)"
    aws_iam update-assume-role-policy \
      --role-name "$LORAWAN_ROLE_NAME" \
      --policy-document "file://$trust" >/dev/null
  else
    echo "Creating IAM role: $LORAWAN_ROLE_NAME (path /service-role/)"
    aws_iam create-role \
      --role-name "$LORAWAN_ROLE_NAME" \
      --path /service-role/ \
      --assume-role-policy-document "file://$trust" \
      --description "AWS IoT Core for LoRaWAN: gateway certificate management (CUPS) and Destination publish (#98)" >/dev/null
    created=1
  fi

  aws_iam attach-role-policy \
    --role-name "$LORAWAN_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AWSIoTWirelessGatewayCertManager
  aws_iam put-role-policy \
    --role-name "$LORAWAN_ROLE_NAME" \
    --policy-name parking-status-lorawan-destination \
    --policy-document "file://$policy"

  if [[ "$created" == "1" ]]; then
    echo "Waiting for IAM role propagation..."
    sleep 10
  fi
  echo ""
  echo "=== role done ==="
  echo "role ARN: $(aws_iam get-role --role-name "$LORAWAN_ROLE_NAME" --query Role.Arn --output text)"
  echo "Next: ./setup-lorawan.sh profiles"
}

cmd_profiles() {
  local with_destination=1
  case "${1:-}" in
    "") ;;
    --no-destination) with_destination=0 ;;
    *) usage ;;
  esac

  echo "=== LoRaWAN profiles / destination ==="
  echo "region=$AWS_REGION profile=$(profile_label) account=$ACCOUNT_ID"

  local sp_id dp_id
  sp_id="$(service_profile_id)"
  if [[ -n "$sp_id" ]]; then
    echo "Service Profile exists: $LORAWAN_SERVICE_PROFILE_NAME ($sp_id)"
  else
    echo "Creating Service Profile: $LORAWAN_SERVICE_PROFILE_NAME"
    # AddGwMetadata: アップリンクに RSSI / SNR などゲートウェイ情報を付ける（bridge が使う）
    sp_id="$(aws_iotwireless create-service-profile \
      --name "$LORAWAN_SERVICE_PROFILE_NAME" \
      --lorawan AddGwMetadata=true \
      --query Id --output text)"
    echo "  created: $sp_id"
  fi

  dp_id="$(device_profile_id)"
  if [[ -n "$dp_id" ]]; then
    echo "Device Profile exists: $LORAWAN_DEVICE_PROFILE_NAME ($dp_id)"
  else
    echo "Creating Device Profile: $LORAWAN_DEVICE_PROFILE_NAME"
    # docs/40-lorawan-design.md §1: LoRaWAN 1.0.3 / RP002-1.0.1 / Class A / OTAA。
    # RX2 は DR2・923.2MHz、既定チャネルは 923.2 / 923.4MHz（AS923-1）。
    local dp_json
    dp_json="$(jq -nc --arg rf "$LORAWAN_GATEWAY_RF_REGION" '{
      SupportsClassB: false,
      SupportsClassC: false,
      MacVersion: "1.0.3",
      RegParamsRevision: "RP002-1.0.1",
      RxDelay1: 1,
      RxDrOffset1: 0,
      RxDataRate2: 2,
      RxFreq2: 9232000,
      FactoryPresetFreqsList: [9232000, 9234000],
      MaxEirp: 5,
      MaxDutyCycle: 0,
      RfRegion: $rf,
      SupportsJoin: true,
      Supports32BitFCnt: true
    }')"
    dp_id="$(aws_iotwireless create-device-profile \
      --name "$LORAWAN_DEVICE_PROFILE_NAME" \
      --lorawan "$dp_json" \
      --query Id --output text)"
    echo "  created: $dp_id"
  fi

  if [[ "$with_destination" == "0" ]]; then
    echo "Skipping Destination (--no-destination). Re-run without the flag once the role exists."
    echo ""
    echo "=== profiles done (no destination) ==="
    return 0
  fi

  # Destination: アップリンクを MQTT トピックに publish する。IoT ルール
  # parking_status_lorawan（setup.sh が作る）がこのトピックを読んで Lambda を起動する。
  if aws_iotwireless get-destination --name "$LORAWAN_DESTINATION_NAME" >/dev/null 2>&1; then
    echo "Updating Destination: $LORAWAN_DESTINATION_NAME"
    aws_iotwireless update-destination \
      --name "$LORAWAN_DESTINATION_NAME" \
      --expression-type MqttTopic \
      --expression "$LORAWAN_UPLINK_TOPIC" \
      --role-arn "$LORAWAN_ROLE_ARN" >/dev/null
  else
    echo "Creating Destination: $LORAWAN_DESTINATION_NAME -> $LORAWAN_UPLINK_TOPIC"
    echo "  role: $LORAWAN_ROLE_ARN"
    aws_iotwireless create-destination \
      --name "$LORAWAN_DESTINATION_NAME" \
      --expression-type MqttTopic \
      --expression "$LORAWAN_UPLINK_TOPIC" \
      --role-arn "$LORAWAN_ROLE_ARN" >/dev/null
  fi

  echo ""
  echo "=== profiles done ==="
  echo "Next:"
  echo "  ./setup-lorawan.sh gateway          # ゲートウェイ登録 + CUPS 証明書"
  echo "  ./setup-lorawan.sh device <deviceId> # Wireless Device"
}

cmd_gateway() {
  local rotate=0
  case "${1:-}" in
    "") ;;
    --rotate) rotate=1 ;;
    *) usage ;;
  esac

  [[ -n "$LORAWAN_GATEWAY_EUI" ]] || die "LORAWAN_GATEWAY_EUI is not set in config.env."

  echo "=== LoRaWAN gateway ==="
  echo "region=$AWS_REGION profile=$(profile_label) account=$ACCOUNT_ID"

  local gw_id out
  gw_id="$(aws_iotwireless get-wireless-gateway \
    --identifier "$LORAWAN_GATEWAY_EUI" --identifier-type GatewayEui \
    --query Id --output text 2>/dev/null || true)"
  if [[ -n "$gw_id" && "$gw_id" != "None" ]]; then
    echo "Gateway exists: $LORAWAN_GATEWAY_NAME ($gw_id)"
  else
    echo "Creating Gateway: $LORAWAN_GATEWAY_NAME (EUI=$LORAWAN_GATEWAY_EUI, $LORAWAN_GATEWAY_RF_REGION)"
    if ! out="$(aws_iotwireless create-wireless-gateway \
      --name "$LORAWAN_GATEWAY_NAME" \
      --lorawan "GatewayEui=${LORAWAN_GATEWAY_EUI},RfRegion=${LORAWAN_GATEWAY_RF_REGION}" \
      --query Id --output text 2>&1)"; then
      echo "$out" >&2
      echo "" >&2
      echo "Gateway EUI は他の AWS アカウント・リージョンに登録済みだと作れない。" >&2
      echo "旧アカウントで delete-wireless-gateway してから再実行する。" >&2
      exit 1
    fi
    gw_id="$out"
    echo "  created: $gw_id"
  fi

  mkdir -p "$LORAWAN_GATEWAY_CERTS_DIR"
  chmod 700 "$LORAWAN_GATEWAY_CERTS_DIR"
  local key_file="$LORAWAN_GATEWAY_CERTS_DIR/cups.key"

  local cert_id old_cert_id=""
  cert_id="$(aws_iotwireless get-wireless-gateway-certificate --id "$gw_id" \
    --query IotCertificateId --output text 2>/dev/null || true)"
  [[ "$cert_id" == "None" ]] && cert_id=""

  local need_cert=1
  if [[ -n "$cert_id" ]]; then
    if [[ "$rotate" == "1" ]]; then
      echo "Rotating certificate: disassociating $cert_id"
      aws_iotwireless disassociate-wireless-gateway-from-certificate --id "$gw_id" >/dev/null
      old_cert_id="$cert_id"
    elif [[ -f "$key_file" ]]; then
      echo "Certificate already associated ($cert_id); using existing $key_file"
      need_cert=0
    else
      die "certificate $cert_id is associated but $key_file is missing (a private key cannot be re-downloaded). Re-run with --rotate to issue a new certificate."
    fi
  fi

  if [[ "$need_cert" == "1" ]]; then
    echo "Creating gateway certificate"
    cert_id="$(aws_iot create-keys-and-certificate \
      --set-as-active \
      --certificate-pem-outfile "$LORAWAN_GATEWAY_CERTS_DIR/cups.crt" \
      --private-key-outfile "$key_file" \
      --query certificateId --output text)"
    chmod 600 "$key_file"
    aws_iotwireless associate-wireless-gateway-with-certificate \
      --id "$gw_id" --iot-certificate-id "$cert_id" >/dev/null
    echo "  associated: $cert_id"
  fi

  # CUPS のエンドポイントとサーバー信頼証明書（アカウント固有）。
  local cups_json lns_uri
  cups_json="$(aws_iotwireless get-service-endpoint --service-type CUPS)"
  jq -j '.ServiceEndpoint' <<<"$cups_json" >"$LORAWAN_GATEWAY_CERTS_DIR/cups.uri"
  jq -r '.ServerTrust' <<<"$cups_json" >"$LORAWAN_GATEWAY_CERTS_DIR/cups.trust"
  lns_uri="$(aws_iotwireless get-service-endpoint --service-type LNS --query ServiceEndpoint --output text)"

  echo ""
  echo "=== gateway done ==="
  echo "Files (git 管理外。cups.key は秘密鍵): $LORAWAN_GATEWAY_CERTS_DIR"
  echo "  cups.uri   : $(cat "$LORAWAN_GATEWAY_CERTS_DIR/cups.uri")"
  echo "  cups.trust / cups.crt / cups.key"
  echo "LNS endpoint : $lns_uri"
  if [[ -n "$old_cert_id" ]]; then
    echo ""
    echo "旧証明書 $old_cert_id は不要なら非アクティブ化する:"
    echo "  aws iot update-certificate --certificate-id $old_cert_id --new-status INACTIVE"
  fi
  echo ""
  echo "SenseCAP M2 の設定（ローカルコンソール > LoRa > LoRa Network）:"
  echo "  Mode: Basics Station / Server: CUPS (port 443) / Authentication: TLS Server and Client Authentication"
  echo "  URI に cups.uri、CA / Client Certificate / Client Key に cups.trust / cups.crt / cups.key の内容を貼り付けて Save & Apply"
  echo "  接続確認: ./verify-lorawan.sh"
}

cmd_device() {
  local device_id="${1:-}"
  [[ -n "$device_id" ]] || usage

  local dev_eui="${LORAWAN_DEV_EUI:-}" app_eui="${LORAWAN_APP_EUI:-}" app_key="${LORAWAN_APP_KEY:-}"
  [[ -n "$dev_eui" ]] || die "LORAWAN_DEV_EUI is not set (16 hex digits)."
  [[ -n "$app_eui" ]] || die "LORAWAN_APP_EUI is not set (16 hex digits)."
  if [[ -z "$app_key" && -t 0 ]]; then
    # AppKey は秘密。環境変数に置かず、対話で入力すればシェル履歴にも残らない。
    read -rsp "LORAWAN_APP_KEY (32 hex digits, input hidden): " app_key
    echo
  fi
  [[ -n "$app_key" ]] || die "LORAWAN_APP_KEY is not set (32 hex digits)."
  [[ "$dev_eui" =~ ^[0-9A-Fa-f]{16}$ ]] || die "LORAWAN_DEV_EUI must be 16 hex digits."
  [[ "$app_eui" =~ ^[0-9A-Fa-f]{16}$ ]] || die "LORAWAN_APP_EUI must be 16 hex digits."
  [[ "$app_key" =~ ^[0-9A-Fa-f]{32}$ ]] || die "LORAWAN_APP_KEY must be 32 hex digits."

  echo "=== LoRaWAN wireless device: $device_id ==="
  echo "region=$AWS_REGION profile=$(profile_label) account=$ACCOUNT_ID"

  local existing
  existing="$(aws_iotwireless get-wireless-device \
    --identifier "$dev_eui" --identifier-type DevEui \
    --query Name --output text 2>/dev/null || true)"
  if [[ -n "$existing" && "$existing" != "None" ]]; then
    echo "Wireless Device exists: $existing (DevEui=$dev_eui). Nothing to do."
    return 0
  fi

  local sp_id dp_id
  sp_id="$(service_profile_id)"
  dp_id="$(device_profile_id)"
  [[ -n "$sp_id" ]] || die "Service Profile '$LORAWAN_SERVICE_PROFILE_NAME' not found. Run ./setup-lorawan.sh profiles first."
  [[ -n "$dp_id" ]] || die "Device Profile '$LORAWAN_DEVICE_PROFILE_NAME' not found. Run ./setup-lorawan.sh profiles first."
  aws_iotwireless get-destination --name "$LORAWAN_DESTINATION_NAME" >/dev/null 2>&1 \
    || die "Destination '$LORAWAN_DESTINATION_NAME' not found. Run ./setup-lorawan.sh profiles first."

  # AppKey をコマンドライン引数（ps に見える）に載せないよう、一時ファイル経由で渡す。
  INPUT_JSON="$(mktemp)"
  chmod 600 "$INPUT_JSON"
  trap 'rm -f "$INPUT_JSON"' EXIT
  jq -n \
    --arg name "$device_id" \
    --arg desc "Grove Wio-E5 (DevEUI ${dev_eui}) — created by infra/setup-lorawan.sh (#98)" \
    --arg dest "$LORAWAN_DESTINATION_NAME" \
    --arg dev_eui "$dev_eui" --arg app_eui "$app_eui" --arg app_key "$app_key" \
    --arg dp "$dp_id" --arg sp "$sp_id" \
    '{
      Type: "LoRaWAN",
      Name: $name,
      Description: $desc,
      DestinationName: $dest,
      LoRaWAN: {
        DevEui: $dev_eui,
        DeviceProfileId: $dp,
        ServiceProfileId: $sp,
        OtaaV1_0_x: { AppKey: $app_key, AppEui: $app_eui }
      }
    }' >"$INPUT_JSON"

  local wd_id
  wd_id="$(aws_iotwireless create-wireless-device \
    --cli-input-json "file://$INPUT_JSON" \
    --query Id --output text)"
  echo "  created: $wd_id"
  echo ""
  echo "=== device done ==="
  echo "端末（Wio-E5）の次の送信または電源の入れ直しで Join する。確認:"
  echo "  aws logs tail /aws/lambda/${LAMBDA_FUNCTION_NAME} --follow --region ${AWS_REGION}"
}

case "${1:-}" in
  role) cmd_role ;;
  profiles) shift; cmd_profiles "$@" ;;
  gateway) shift; cmd_gateway "$@" ;;
  device) shift; cmd_device "$@" ;;
  *) usage ;;
esac
