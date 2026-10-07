"""Parking status bridge — IoT Core のテレメトリを CloudWatch Logs に出し、Orion に upsert する（Issue #4, #7）。

2 つの入口がある（どちらも IoT ルールの `SELECT *` で呼ばれる）:
- LTE-M / Wi-Fi: 端末が送った JSON がそのまま event になる。
- LoRaWAN (#40): AWS IoT Core for LoRaWAN の Destination のメッセージ。
  `lorawan.py` でデコードして LTE-M 版と同じ形にそろえる。
どちらも `parking-status telemetry received: <JSON>` で CloudWatch Logs に出し、
iOS ログビューアはその行（`telemetry received` を含む行）だけを読む。

処理の順序は「ログ出力 → Orion への upsert」。ログを先に出し、Orion 側の失敗でログが欠けないようにする。
Orion への送信（デバイスマスター参照・変換・upsert）は、失敗しても例外を投げずエラーログを残して正常終了する。
例外にすると IoT ルールが Lambda を再実行し、`telemetry received` の行が重複して iOS アプリに二重表示されるため。
"""

from __future__ import annotations

import json
import logging

import device_master
import lorawan
import ngsi
import orion

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event: dict, context) -> dict:
    if lorawan.is_lorawan_message(event):
        return handle_lorawan(event)

    logger.info("parking-status telemetry received: %s", json.dumps(event, ensure_ascii=False))
    orion_result = forward_to_orion(event)

    # IoT rule passes the MQTT payload fields at the top level when using SELECT *.
    return response(event.get("deviceId", "unknown"), event.get("status", "unknown"), orion_result)


def handle_lorawan(event: dict) -> dict:
    """LoRaWAN のアップリンクを LTE-M 版と同じ形にして出力する。

    デコードできないメッセージは、エラーとしてログに残して正常終了する
    （再試行しても直らないため）。その場合 `telemetry received` の行は出さず、Orion にも送らない。
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
    orion_result = forward_to_orion(telemetry)

    return response(telemetry["deviceId"], telemetry["status"], orion_result)


def forward_to_orion(telemetry: dict) -> str:
    """テレメトリを Orion に upsert する。結果を `upserted` / `skipped` / `failed` / `disabled` で返す。

    - `disabled`: `ORION_URL` が未設定（Orion には送らない）
    - `skipped`: 未登録・無効の `deviceId`、`deviceId` / `status` が無い、デバイスマスターを引けない
    - `failed`: Orion への送信に失敗した
    どの場合も例外は投げない。
    """
    try:
        try:
            config = orion.OrionConfig.from_env()
        except orion.OrionError as exc:  # Cognito 設定の不備
            logger.error("orion upsert failed: %s", exc)
            return "failed"
        if config is None:
            logger.info("orion disabled: ORION_URL is not set")
            return "disabled"

        device_id = telemetry.get("deviceId")
        if not isinstance(device_id, str) or not device_id:
            logger.warning("orion skipped: deviceId is missing")
            return "skipped"

        try:
            master = device_master.lookup(device_id)
        except device_master.DeviceMasterError as exc:
            logger.error("orion skipped: %s", exc)
            return "skipped"
        if master is None:
            logger.warning("orion skipped: %s is not registered in the device master", device_id)
            return "skipped"
        if not master.enabled:
            logger.warning("orion skipped: %s is disabled in the device master", device_id)
            return "skipped"

        try:
            entity = ngsi.build_entity(telemetry, master)
        except ValueError as exc:
            logger.warning("orion skipped: %s", exc)
            return "skipped"

        try:
            status = orion.upsert_entity(entity, config)
        except orion.OrionError as exc:
            logger.error("orion upsert failed: %s (%s)", exc, entity["id"])
            return "failed"
        logger.info("orion upsert ok: %s (HTTP %s)", entity["id"], status)
        return "upserted"
    except Exception:  # noqa: BLE001 — どんな失敗でも例外にしない（上の docstring 参照）
        logger.exception("orion upsert failed: unexpected error")
        return "failed"


def response(device_id: str, status: str, orion_result: str) -> dict:
    return {
        "statusCode": 200,
        "body": json.dumps({"ok": True, "deviceId": device_id, "status": status, "orion": orion_result}),
    }
