#!/usr/bin/env bash
# Publish a sample telemetry payload via AWS IoT Core (CLI test client).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

load_config
require_aws

DEVICE_ID="${1:-}"
if [[ -z "$DEVICE_ID" ]]; then
  echo "Usage: $0 <deviceId>" >&2
  exit 1
fi

ENDPOINT="$(iot_endpoint)"
TOPIC="$(device_telemetry_topic "$DEVICE_ID")"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

PAYLOAD="$(cat <<EOF
{
  "deviceId": "$DEVICE_ID",
  "status": "open",
  "raw": { "red": 150, "green": 820, "blue": 200, "clear": 1200 },
  "threshold": 100,
  "determinedBy": "device",
  "timestamp": "$TIMESTAMP"
}
EOF
)"

echo "endpoint=$ENDPOINT"
echo "topic=$TOPIC"
echo "payload=$PAYLOAD"
echo ""

aws iot-data publish \
  --endpoint-url "https://${ENDPOINT}" \
  --topic "$TOPIC" \
  --qos 1 \
  --cli-binary-format raw-in-base64-out \
  --payload "$PAYLOAD"

echo ""
echo "Published. Check Lambda logs:"
echo "  aws logs tail /aws/lambda/${LAMBDA_FUNCTION_NAME} --follow --region ${AWS_REGION}"
