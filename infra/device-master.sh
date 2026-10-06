#!/usr/bin/env bash
# デバイスマスター（deviceId → name / location）の登録・確認・削除（#7, #14）。
#
#   ./device-master.sh put <deviceId> <name> <lat> <lon> [--disabled]
#   ./device-master.sh list
#   ./device-master.sh get <deviceId>
#   ./device-master.sh delete <deviceId>
#
# `put` は同じ deviceId なら上書きする。`--disabled` を付けると Orion には書かれない（一時停止・撤去済み）。
# lat / lon は十進数の度（例: 33.2629 130.3008）。Lambda が GeoJSON の [経度, 緯度] に組み立てる。
# 変更が Orion に反映されるのは、Lambda のキャッシュ（数分）が切れたあとのその端末の次の送信から。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT/lib.sh"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

CMD="${1:-}"
[[ -n "$CMD" ]] || usage
shift || true

load_config
require_aws

is_number() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

case "$CMD" in
  put)
    [[ $# -ge 4 ]] || usage
    DEVICE_ID="$1"; NAME="$2"; LAT="$3"; LON="$4"; ENABLED=true
    if [[ "${5:-}" == "--disabled" ]]; then
      ENABLED=false
    elif [[ -n "${5:-}" ]]; then
      usage
    fi
    is_number "$LAT" && is_number "$LON" || { echo "lat / lon must be numbers: $LAT $LON" >&2; exit 1; }
    awk -v lat="$LAT" -v lon="$LON" 'BEGIN { exit !(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) }' \
      || { echo "lat / lon out of range: lat=$LAT lon=$LON (lat first, then lon)" >&2; exit 1; }
    ITEM="$(jq -n --arg id "$DEVICE_ID" --arg name "$NAME" --arg lat "$LAT" --arg lon "$LON" --argjson enabled "$ENABLED" \
      '{deviceId: {S: $id}, name: {S: $name}, lat: {N: $lat}, lon: {N: $lon}, enabled: {BOOL: $enabled}}')"
    aws_dynamodb put-item --table-name "$DEVICE_MASTER_TABLE" --item "$ITEM"
    echo "Saved: $DEVICE_ID ($NAME, lat=$LAT lon=$LON, enabled=$ENABLED)"
    ;;
  list)
    aws_dynamodb scan --table-name "$DEVICE_MASTER_TABLE" --output json \
      | jq -r '.Items | sort_by(.deviceId.S)[]
          | [.deviceId.S, .name.S, .lat.N, .lon.N, (if .enabled.BOOL == false then "disabled" else "enabled" end)]
          | @tsv'
    ;;
  get)
    [[ $# -eq 1 ]] || usage
    aws_dynamodb get-item --table-name "$DEVICE_MASTER_TABLE" --key "$(jq -n --arg id "$1" '{deviceId: {S: $id}}')" \
      --output json | jq '.Item // "not registered"'
    ;;
  delete)
    [[ $# -eq 1 ]] || usage
    aws_dynamodb delete-item --table-name "$DEVICE_MASTER_TABLE" --key "$(jq -n --arg id "$1" '{deviceId: {S: $id}}')"
    echo "Deleted: $1"
    ;;
  *)
    usage
    ;;
esac
