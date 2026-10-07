"""LoRaWAN (#40) uplink → LTE-M 版テレメトリと同じ形の dict への正規化。

AWS IoT Core for LoRaWAN の Destination（`lorawan/parking-status/uplink`）に届く
メッセージを受け、コアペイロード（fPort 1, ver 1, 18 バイト）をデコードして
`docs/data-model.md` の JSON に揃える。バイト配置は docs/40-lorawan-design.md §3。

`decode_core` のロジックは tools/lorawan/decode.py と同じ（Lambda の zip に
tools/ を入れないため複製している）。ずれないよう bridge/test_lorawan.py が
test_vectors.json と decode.py の両方と突き合わせる。

#7（Orion への upsert）でも使えるよう、ここは Lambda のログ出力から切り離した
純粋な関数にしてある（ネットワーク呼び出しは `resolve_device_id` だけ）。
"""

from __future__ import annotations

import base64
import binascii
from typing import Any, Callable

CORE_FPORT = 1
CORE_SIZE = 18

STATUS = ["full", "open", "unknown"]
REASON = ["state_change", "heartbeat", "pending_retry", "boot_mode"]
# firmware/src/main.cpp の resetReasonToString / wakeCauseToString と同じ文字列・並び
# （LTE-M 版 JSON の power.resetReason / power.wakeCause と揃える）。
RESET_REASON = [
    "other",
    "power_on",
    "brownout",
    "deep_sleep",
    "software",
    "panic",
    "task_wdt",
    "int_wdt",
    "wdt",
]
WAKE_CAUSE = ["other", "timer", "power_on"]
OUTCOME = [
    "none",
    "confirmed",
    "connect_failed",
    "publish_failed",
    "budget_exhausted",
    "sensor_error",
    "skipped",
]

TRANSPORT_NAME = "lorawan"  # firmware/src/transport.cpp の transportName(kLoRaWan)


class DeviceLookupError(Exception):
    """Wireless Device 名（= deviceId）を引けなかった。再試行しても直らない場合に使う。"""


def is_lorawan_message(event: Any) -> bool:
    """Destination のメッセージか。`WirelessMetadata.LoRaWAN` があれば LoRaWAN と判断する。"""
    if not isinstance(event, dict):
        return False
    metadata = event.get("WirelessMetadata")
    return isinstance(metadata, dict) and "LoRaWAN" in metadata


def _lookup(table: list[str], index: int) -> str:
    return table[index] if index < len(table) else f"reserved({index})"


def decode_core(payload: bytes) -> dict:
    """コアペイロード 18 バイトをデコードする。tools/lorawan/decode.py と同じ結果を返す。"""
    if len(payload) != CORE_SIZE:
        raise ValueError(f"core payload must be {CORE_SIZE} bytes, got {len(payload)}")
    b0, b1 = payload[0], payload[1]
    version = b0 >> 6
    if version != 1:
        raise ValueError(f"unsupported payload version {version}")

    def u16(offset: int) -> int:
        return payload[offset] << 8 | payload[offset + 1]

    return {
        "version": version,
        "status": _lookup(STATUS, (b0 >> 4) & 0x3),
        "reason": _lookup(REASON, (b0 >> 2) & 0x3),
        "coldBoot": bool((b0 >> 1) & 0x1),
        "prevOutcome": _lookup(OUTCOME, b1 >> 5),
        "prevAttempts": (b1 >> 3) & 0x3,
        "bootSlot": b1 & 0x7,
        "raw": {"red": u16(2), "green": u16(4), "blue": u16(6), "white": u16(8)},
        "prevActiveMs": payload[10] * 250,
        "threshold": u16(11),
        "power": {
            "bootCount": int.from_bytes(payload[13:17], "big"),
            "resetReason": _lookup(RESET_REASON, payload[17] & 0xF),
            "wakeCause": _lookup(WAKE_CAUSE, payload[17] >> 4),
        },
    }


def decode_uplink(message: dict) -> dict:
    """Destination のメッセージから PayloadData をデコードする。

    fPort 違い・長さ違い・version 違い・base64 不正は ValueError。
    """
    fport = _lorawan_metadata(message).get("FPort")
    if fport is not None and fport != CORE_FPORT:
        raise ValueError(f"unsupported fPort {fport}")
    payload_data = message.get("PayloadData")
    if not isinstance(payload_data, str):
        raise ValueError("PayloadData is missing")
    try:
        payload = base64.b64decode(payload_data, validate=True)
    except binascii.Error as exc:
        raise ValueError(f"PayloadData is not valid base64: {exc}") from exc
    return decode_core(payload)


def _lorawan_metadata(message: dict) -> dict:
    metadata = (message.get("WirelessMetadata") or {}).get("LoRaWAN")
    return metadata if isinstance(metadata, dict) else {}


def _int_or_original(value: Any) -> Any:
    """`"5"` や `"922600000"` のように文字列で届く数値を int にする。変換できなければそのまま。"""
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return value
    return value


def build_telemetry(message: dict, decoded: dict, device_id: str) -> dict:
    """デコード結果を LTE-M 版テレメトリ（docs/data-model.md）と同じ形の dict にする。

    `decoded` は `decode_uplink(message)` の戻り値。`device_id` は Wireless Device 名。
    """
    lorawan = _lorawan_metadata(message)
    gateways = lorawan.get("Gateways")
    gateway = gateways[0] if isinstance(gateways, list) and gateways and isinstance(gateways[0], dict) else {}
    raw = decoded["raw"]

    return {
        "deviceId": device_id,
        "status": decoded["status"],
        "raw": {
            "red": raw["red"],
            "green": raw["green"],
            "blue": raw["blue"],
            "clear": raw["white"],
        },
        "threshold": decoded["threshold"],
        "determinedBy": "device",
        "timestamp": lorawan.get("Timestamp"),
        "power": dict(decoded["power"]),
        "network": {
            "transport": TRANSPORT_NAME,
            "rssi": gateway.get("Rssi"),
            "snr": gateway.get("Snr"),
            "dataRate": _int_or_original(lorawan.get("DataRate")),
            "fCnt": lorawan.get("FCnt"),
            "frequency": _int_or_original(lorawan.get("Frequency")),
        },
        "sync": {
            "prevOutcome": decoded["prevOutcome"],
            "prevAttempts": decoded["prevAttempts"],
            "prevActiveMs": decoded["prevActiveMs"],
        },
        "lorawan": {
            "reason": decoded["reason"],
            "coldBoot": decoded["coldBoot"],
            "bootSlot": decoded["bootSlot"],
            "wirelessDeviceId": message.get("WirelessDeviceId"),
            "devEui": lorawan.get("DevEui"),
        },
    }


# --- Wireless Device 名の解決 -------------------------------------------------

_device_name_cache: dict[str, str] = {}
_iotwireless_client = None


def _client():
    global _iotwireless_client
    if _iotwireless_client is None:
        import boto3  # Lambda ランタイムに入っている。テストでは使わない。

        _iotwireless_client = boto3.client("iotwireless")
    return _iotwireless_client


def resolve_device_id(wireless_device_id: str | None, client_factory: Callable[[], Any] | None = None) -> str:
    """Wireless Device ID（UUID）→ 名前（= deviceId）。Lambda コンテナ内でキャッシュする。

    見つからない・名前が空のときは DeviceLookupError。それ以外の AWS エラーは
    そのまま上げる（IoT ルール経由の非同期呼び出しなので、Lambda が再試行する）。
    """
    if not wireless_device_id:
        raise DeviceLookupError("WirelessDeviceId is missing")
    cached = _device_name_cache.get(wireless_device_id)
    if cached:
        return cached

    client = (client_factory or _client)()
    try:
        response = client.get_wireless_device(Identifier=wireless_device_id, IdentifierType="WirelessDeviceId")
    except client.exceptions.ResourceNotFoundException as exc:
        raise DeviceLookupError(f"wireless device not found: {wireless_device_id}") from exc

    name = response.get("Name")
    if not name:
        raise DeviceLookupError(f"wireless device has no Name: {wireless_device_id}")
    _device_name_cache[wireless_device_id] = name
    return name


def clear_device_cache() -> None:
    """テスト用。"""
    _device_name_cache.clear()
