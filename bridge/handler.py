"""Parking status bridge — Lambda stub for Issue #4 connectivity tests.

Issue #7 replaces this with NGSIv2 upsert to FIWARE Orion.

2 つの入口がある（どちらも IoT ルールの `SELECT *` で呼ばれる）:
- LTE-M / Wi-Fi: 端末が送った JSON がそのまま event になる。
- LoRaWAN (#40): AWS IoT Core for LoRaWAN の Destination のメッセージ。
  `lorawan.py` でデコードして LTE-M 版と同じ形にそろえる。
どちらも `parking-status telemetry received: <JSON>` で CloudWatch Logs に出し、
iOS ログビューアはその行（`telemetry received` を含む行）だけを読む。
"""

from __future__ import annotations

import json
import logging

import lorawan

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event: dict, context) -> dict:
    if lorawan.is_lorawan_message(event):
        return handle_lorawan(event)

    logger.info("parking-status telemetry received: %s", json.dumps(event, ensure_ascii=False))

    # IoT rule passes the MQTT payload fields at the top level when using SELECT *.
    device_id = event.get("deviceId", "unknown")
    status = event.get("status", "unknown")

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "ok": True,
                "deviceId": device_id,
                "status": status,
                "message": "stub handler — Orion upsert is Issue #7",
            }
        ),
    }


def handle_lorawan(event: dict) -> dict:
    """LoRaWAN のアップリンクを LTE-M 版と同じ形にして出力する。

    デコードできないメッセージは、エラーとしてログに残して正常終了する
    （再試行しても直らないため）。その場合 `telemetry received` の行は出さない。
    """
    # 生のメッセージは別の文言で残す（iOS アプリの検索 `telemetry received` に掛けない）。
    logger.info("lorawan uplink raw: %s", json.dumps(event, ensure_ascii=False))

    try:
        decoded = lorawan.decode_uplink(event)
        device_id = lorawan.resolve_device_id(event.get("WirelessDeviceId"))
    except (ValueError, lorawan.DeviceLookupError) as exc:
        logger.error("lorawan uplink rejected: %s", exc)
        return {"statusCode": 200, "body": json.dumps({"ok": False, "error": str(exc)})}

    telemetry = lorawan.build_telemetry(event, decoded, device_id)
    logger.info("parking-status telemetry received: %s", json.dumps(telemetry, ensure_ascii=False))

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "ok": True,
                "deviceId": telemetry["deviceId"],
                "status": telemetry["status"],
                "message": "stub handler — Orion upsert is Issue #7",
            }
        ),
    }
