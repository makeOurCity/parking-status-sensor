"""Parking status bridge — Lambda stub for Issue #4 connectivity tests.

Issue #7 replaces this with NGSIv2 upsert to FIWARE Orion.
"""

from __future__ import annotations

import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event: dict, context) -> dict:
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
