"""テレメトリ → NGSIv2 エンティティ（ParkingStatusSensor）の変換（#7）。

入力は LTE-M の MQTT ペイロードと、`lorawan.build_telemetry` が作る LoRaWAN 版（同じ形）。
出力は docs/data-model.md のエンティティ項目だけで、診断項目（`sync.*` / `network.*` /
`bootMode.*` / `pot.*` / `power.*` など）は含めない。

ネットワーク呼び出しはしない純粋な関数にしてある（Orion への送信は `orion.py`）。
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from device_master import DeviceMaster

ENTITY_TYPE = "ParkingStatusSensor"
ENTITY_ID_PREFIX = "urn:ngsi:ParkingStatusSensor:"

STATUS_LABELS = {"full": "満", "open": "空", "unknown": "不明"}
# #99 で `available` を `open` に改名した。再書き込み前の LTE-M 端末は旧値を送り続ける。
LEGACY_STATUS = {"available": "open"}
RAW_CHANNELS = ("red", "green", "blue", "clear")


def entity_id(device_id: str) -> str:
    return ENTITY_ID_PREFIX + device_id


def normalize_status(value: Any) -> str:
    """旧値を新値にそろえる。`full` / `open` / `unknown` 以外は `unknown` として扱う。"""
    value = LEGACY_STATUS.get(value, value)
    return value if value in STATUS_LABELS else "unknown"


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_entity(telemetry: dict, master: "DeviceMaster", now_iso: str | None = None) -> dict:
    """テレメトリとデバイスマスターから NGSIv2 エンティティを作る。

    `deviceId` か `status` がなければ ValueError（Orion に書かない）。
    `raw` / `threshold` / `determinedBy` は端末が送ってきたときだけ含める
    （upsert は渡した属性だけ更新するので、無い属性は前の値が残る）。
    `dateObserved` は端末の `timestamp`、無ければ受信時刻。
    """
    device_id = telemetry.get("deviceId")
    if not isinstance(device_id, str) or not device_id:
        raise ValueError("deviceId is missing")
    if "status" not in telemetry:
        raise ValueError("status is missing")

    status = normalize_status(telemetry["status"])
    entity: dict[str, Any] = {
        "id": entity_id(device_id),
        "type": ENTITY_TYPE,
        "name": {"type": "Text", "value": master.name},
        "status": {
            "type": "Text",
            "value": status,
            "metadata": {"label": {"type": "Text", "value": STATUS_LABELS[status]}},
        },
    }

    raw = telemetry.get("raw")
    if isinstance(raw, dict):
        channels = {key: raw[key] for key in RAW_CHANNELS if _is_number(raw.get(key))}
        if channels:
            entity["rawSensor"] = {"type": "StructuredValue", "value": channels}

    determined_by = telemetry.get("determinedBy")
    if isinstance(determined_by, str) and determined_by:
        entity["determinedBy"] = {"type": "Text", "value": determined_by}

    if _is_number(telemetry.get("threshold")):
        entity["threshold"] = {"type": "Number", "value": telemetry["threshold"]}

    timestamp = telemetry.get("timestamp")
    entity["deviceId"] = {"type": "Text", "value": device_id}
    # GeoJSON の座標は [経度, 緯度] の順。
    entity["location"] = {"type": "geo:json", "value": {"type": "Point", "coordinates": [master.lon, master.lat]}}
    entity["dateObserved"] = {
        "type": "DateTime",
        "value": timestamp if isinstance(timestamp, str) and timestamp else (now_iso or _now_iso()),
    }
    return entity
