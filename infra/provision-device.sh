#!/usr/bin/env bash
# Register one device: Thing + certificate + policy attachment.
# Writes certs to firmware/certs/ and prints secrets.h hints.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

DEVICE_ID="${1:-}"
if [[ -z "$DEVICE_ID" ]]; then
  echo "Usage: $0 <deviceId>" >&2
  echo "Example: $0 xiao-e83dc1fb05fc" >&2
  exit 1
fi

CERTS_DIR="$REPO_ROOT/firmware/certs"
mkdir -p "$CERTS_DIR"

echo "=== provision device: $DEVICE_ID ==="

# Thing
if aws_iot describe-thing --thing-name "$DEVICE_ID" >/dev/null 2>&1; then
  echo "Thing exists: $DEVICE_ID"
else
  echo "Creating Thing: $DEVICE_ID"
  aws_iot create-thing --thing-name "$DEVICE_ID" >/dev/null
fi

# Keys + certificate
KEYS_JSON="$(mktemp)"
CERT_JSON="$(mktemp)"
trap 'rm -f "$KEYS_JSON" "$CERT_JSON"' EXIT

aws_iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile "$CERTS_DIR/device.pem.crt" \
  --private-key-outfile "$CERTS_DIR/private.pem.key" \
  --public-key-outfile "$CERTS_DIR/public.pem.key" \
  --output json >"$CERT_JSON"

CERT_ARN="$(jq -r .certificateArn "$CERT_JSON")"
CERT_ID="$(jq -r .certificateId "$CERT_JSON")"
echo "Certificate: $CERT_ID"

# Root CA (Amazon Root CA 1)
if [[ ! -f "$CERTS_DIR/AmazonRootCA1.pem" ]]; then
  echo "Downloading Amazon Root CA 1"
  curl -fsSL -o "$CERTS_DIR/AmazonRootCA1.pem" \
    https://www.amazontrust.com/repository/AmazonRootCA1.pem
fi

# Attach cert to Thing
aws_iot attach-thing-principal \
  --thing-name "$DEVICE_ID" \
  --principal "$CERT_ARN" 2>/dev/null || true

# Attach policy to cert
aws_iot attach-policy \
  --policy-name "$IOT_POLICY_NAME" \
  --target "$CERT_ARN" 2>/dev/null || true

ENDPOINT="$(iot_endpoint)"
TOPIC="$(device_telemetry_topic "$DEVICE_ID")"

echo ""
echo "=== device provisioned ==="
echo "Certs written to: firmware/certs/"
echo ""
echo "secrets.h hints (do not commit):"
echo "  #define PSS_DEVICE_ID \"$DEVICE_ID\""
echo "  #define PSS_MQTT_HOST \"$ENDPOINT\""
echo "  #define PSS_MQTT_PORT 8883"
echo "  #define PSS_MQTT_TOPIC \"$TOPIC\""
echo ""
echo "Test:"
echo "  ./test-publish.sh $DEVICE_ID"
